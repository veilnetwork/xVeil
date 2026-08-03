import 'dart:async';
import 'dart:io';

import '../core/log.dart';
import 'api_server.dart' show pushWebhookEvent;

/// Delivers API events to the operator's webhook URL, one at a time, from a
/// bounded queue.
///
/// WHAT [setTarget] AND [close] GUARANTEE, EXACTLY: after either returns —
/// in fact from the moment either is *called* — this pump makes no new
/// delivery and no retry to the previous target. That is the whole promise.
/// It is NOT a recall: a POST whose bytes are already on the wire has been
/// sent, and nothing here or anywhere else takes it back. The exchange in
/// flight does get its socket aborted (see [_severClient]), so the previous
/// target stops receiving the REST of it — but treat that as cutting a wire,
/// not as revocation.
///
/// Why the barrier has to exist at all: a retry schedule outlives the reason
/// it was scheduled. Two attempts, two seconds apart, five seconds of deadline
/// each, is a captured address that stays live for about twelve seconds after
/// nothing is supposed to be reaching it any more — and these events carry a
/// peer's node id and a message preview. Cancelling only the SUBSCRIPTION (all
/// the GUI controller used to do) stops new events and leaves every delivery
/// already started running to completion against the identity the app has just
/// left. Events of the PREVIOUS identity kept arriving at the PREVIOUS
/// identity's webhook (audit X-07); the same fix landed for the WebSocket half
/// of the feed and left this half alone.
///
/// The generation counter that enforces it never leaves this object: it is not
/// persisted, not sent, and not observable from outside the process, so it
/// introduces no long-lived identifier of its own.
///
/// Public so its bounds can be tested: an unbounded pump is indistinguishable
/// from a bounded one until the target stops answering (audit XV-09).
class WebhookPump {
  WebhookPump(this._events);

  /// How many undelivered events the pump will hold.
  ///
  /// Every event used to spawn its own unawaited retry task — two attempts
  /// with a two-second wait between them. A webhook target that hangs, plus an
  /// event stream that does not stop, meant futures and sockets accumulating
  /// with nothing bounding either (audit XV-09).
  static const queueCap = 256;

  /// One deadline for the whole exchange of one attempt.
  static const _deadline = Duration(seconds: 5);
  static const _retryDelay = Duration(seconds: 2);
  static const _attempts = 2;

  /// Opens the event feed. A factory rather than a stored stream because the
  /// GUI rebuilds its feed whenever the services behind it change, and the
  /// pump must subscribe to the CURRENT one at retarget time rather than to
  /// whichever one existed when it was constructed.
  final Stream<Map<String, dynamic>> Function() _events;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Stands in for the network. TESTS ONLY — null in production.
  ///
  /// Not annotated `@visibleForTesting`: that lives in `package:meta` via
  /// `package:flutter/foundation.dart`, and the headless daemon is
  /// deliberately Flutter-free — there is a test that fails if anything it
  /// imports reaches into the framework. A comment does the same job without
  /// dragging Flutter into a daemon that must run without it.
  Future<void> Function(String target, Map<String, dynamic> event)? deliver;

  /// Pending events, oldest first. One worker drains it, so at most one
  /// delivery is ever in flight and the order the daemon observed is the order
  /// the target sees.
  final List<Map<String, dynamic>> _queue = [];
  String? _target;
  bool _draining = false;
  bool _closed = false;
  int _dropped = 0;

  /// Bumped by every [setTarget] and by [close]. Each delivery captures it and
  /// re-reads it before every attempt; a mismatch means the address this work
  /// was for is no longer ours to talk to.
  int _generation = 0;

  /// One client across deliveries instead of one per attempt: it keeps the
  /// loopback connection warm, and — the reason it is a field — it gives
  /// [setTarget] and [close] something to actually pull the plug on.
  HttpClient? _client;

  HttpClient get _http =>
      _client ??= (HttpClient()..connectionTimeout = _deadline);

  /// Abort whatever the current client is doing and drop it.
  ///
  /// `force: true` is what severs a socket that a deadline has already given
  /// up on; without it a target that answers its headers and then dribbles
  /// forever keeps the connection and its buffers (audit XV-09). It is also
  /// what makes a retarget cut the exchange in flight rather than merely stop
  /// the ones after it.
  void _severClient() {
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      client.close(force: true);
    } catch (_) {
      // A client already torn down by its own failure path. Nothing to undo.
    }
  }

  /// Point the pump at [target] (null = nowhere), barring everything the
  /// previous target had coming.
  Future<void> setTarget(String? target) async {
    // Every line up to the first `await` is the barrier, and it is deliberately
    // synchronous: a stale retry or a stale event must not get a turn between
    // the decision to retarget and the decision taking effect.
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    _target = target;
    // A retarget abandons what was queued for the old destination: those
    // events were addressed somewhere else, and delivering them to a new URL
    // would be a leak, not a catch-up.
    _queue.clear();
    _severClient();
    // `cancel()` stops delivery from the moment it is called, so no event of
    // the old feed can reach `_enqueue` and be mistaken for one of the new
    // target's.
    await previous?.cancel();
    if (_closed || generation != _generation) return;
    if (target == null) return;
    _subscription = _events().listen(_enqueue);
  }

  /// Feed the pump directly, without a stream. Tests only.
  void enqueueForTest(Map<String, dynamic> event) => _enqueue(event);

  /// How many events are waiting. Tests only.
  int get queueLengthForTest => _queue.length;

  void _enqueue(Map<String, dynamic> event) {
    if (_closed) return;
    if (_queue.length >= queueCap) {
      // Oldest out. A monitoring target that has fallen behind wants the
      // CURRENT state of the node, not the state it had when it stopped
      // answering.
      _queue.removeAt(0);
      _dropped++;
      if (_dropped == 1 || _dropped % 100 == 0) {
        devLog(
          () =>
              'xVeil[api]: webhook queue full, dropped $_dropped '
              'event(s) — target is not keeping up',
        );
      }
    }
    _queue.add(event);
    unawaited(_drain());
  }

  /// One worker, re-entrancy guarded. Deliveries are sequential, so a slow
  /// target costs latency rather than an unbounded pile of sockets.
  ///
  /// The loop re-reads [_target] every turn, so a retarget that lands during a
  /// delivery is picked up on the next one: the event already taken out of the
  /// queue is finished (or abandoned) against the address it was addressed to,
  /// and never re-aimed at the new one.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (!_closed && _queue.isNotEmpty) {
        final generation = _generation;
        final target = _target;
        if (target == null) {
          _queue.clear();
          return;
        }
        final event = _queue.removeAt(0);
        await _deliver(target, event, generation);
      }
    } finally {
      _draining = false;
    }
  }

  /// One event, up to [_attempts] tries — each one gated on [generation] still
  /// being current. The wait between attempts is exactly the window a retarget
  /// lands in, which is why the check is inside the loop rather than before it.
  Future<void> _deliver(
    String target,
    Map<String, dynamic> event,
    int generation,
  ) async {
    for (var attempt = 0; attempt < _attempts; attempt++) {
      if (_closed || generation != _generation) return;
      final override = deliver;
      if (override != null) {
        await override(target, event);
        return;
      }
      if (await pushWebhookEvent(
        target,
        event,
        timeout: _deadline,
        client: _http,
      )) {
        return;
      }
      // The attempt failed, and a deadline that fired leaves a socket the
      // shared client would otherwise keep. Drop the client so the next
      // attempt dials fresh.
      _severClient();
      if (attempt + 1 < _attempts) await Future<void>.delayed(_retryDelay);
    }
    devLog(() => 'xVeil[api]: webhook push failed twice, dropped');
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    _target = null;
    final previous = _subscription;
    _subscription = null;
    _queue.clear();
    _severClient();
    await previous?.cancel();
  }
}
