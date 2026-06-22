// `prefer_initializing_formals` suppressed: external NAMED params with private
// fields can't use `this._x` formals (Dart forbids private named args across
// libraries), so an explicit initializer list is required.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:veil_flutter/veil_flutter.dart';

import '../core/ids.dart';
import '../data/transport/veil_addressing.dart';
import '../data/transport/veil_transport.dart';
import 'mailbox_orchestrator.dart';

/// The deposit surface [MessagingService] uses for offline delivery — sealing a
/// message for an offline [recipient] at their advertised relay. Extracted as an
/// interface so the messaging layer can be tested without a live [VeilClient].
abstract interface class MailboxSink {
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  });
}

/// Runs the offline-delivery side of messaging alongside [MessagingService]:
///
///  * **register** — advertise an always-on relay as THIS node's mailbox host
///    (resolve the relay's KEM key by node_id via [VeilClient.lookupRelayX25519],
///    then [VeilClient.registerRendezvousPublisher]) so senders can deposit for
///    us while we're offline.
///  * **drain** — periodically fetch + open our pending blobs ([MailboxOrchestrator.drain])
///    and hand each recovered message to [deliver] as if it had arrived live;
///    the messaging layer dedups by content id (= message uuid), so a blob that
///    was ALSO delivered live is a no-op.
///  * **stash** — seal + deposit a message for an offline recipient at THEIR
///    advertised relay ([MailboxOrchestrator.stash]).
///
/// The mailbox-relay [node_id] this node advertises is injected (`start`) — the
/// POLICY for choosing an always-on [mailbox]-capable relay (a connected relay
/// peer, a configured set, or a daemon auto-selection) is a separate decision;
/// resolving its KEM key by node_id is the part veil now provides.
class MailboxService implements MailboxSink {
  MailboxService({
    required VeilClient client,
    required NodeId me,
    required MailboxOrchestrator orchestrator,
    required void Function(InboundMessage) deliver,
    int ourCertVersion = 0,
    Duration drainInterval = const Duration(seconds: 30),
  })  : _client = client,
        _me = me,
        _orchestrator = orchestrator,
        _deliver = deliver,
        _ourCertVersion = ourCertVersion,
        _drainInterval = drainInterval;

  final VeilClient _client;
  final NodeId _me;
  final MailboxOrchestrator _orchestrator;
  final void Function(InboundMessage) _deliver;
  final int _ourCertVersion;
  final Duration _drainInterval;

  /// 16-byte rendezvous auth-cookie for our published mailbox ad. The NETWORK
  /// FETCH path authorizes by our cryptographic identity (NOT this cookie — see
  /// the no-cookie finding), so this is just the rendezvous-registration token.
  final Uint8List _cookie = _randomBytes(16);

  Timer? _drainTimer;
  bool _draining = false;
  bool _registered = false;
  // Set once the underlying veil handle is permanently closed (the node rebooted
  // out from under this service). Retrying is futile on a dead handle, so we stop
  // the timer instead of busy-looping; a fresh stack rebuild starts a NEW mailbox
  // on the live transport (see messagingServiceProvider).
  bool _handleDead = false;
  // Relay candidates kept so the periodic tick can KEEP retrying registration
  // until one resolves (a relay's published key can appear minutes after we
  // first look — e.g. a just-restarted relay), not just during start()'s window.
  List<NodeId> _relays = const [];

  // The relay we actually REGISTERED a mailbox publisher with. The drain fetches
  // straight from here instead of re-resolving our own rendezvous ad over the
  // DHT each poll (that lookup times out on mobile and stranded pending mail).
  NodeId? _registeredRelay;

  /// Whether we have successfully advertised a mailbox relay this session.
  bool get isRegistered => _registered;

  /// Advertise an always-on mailbox host (the first of [relays] whose relay-key
  /// record resolves) and begin draining. Safe to call again (e.g. after a
  /// reconnect): registration is re-attempted until one candidate sticks, and
  /// the drain timer is only armed once. Candidates that aren't relay-capable
  /// (no resolvable relay-key record) are simply skipped — the resolve itself
  /// validates the choice, so a wrong/derived node_id is non-fatal.
  Future<void> start({required List<NodeId> relays}) async {
    if (_handleDead) return; // this service is bound to a dead handle; no-op
    _relays = relays;
    debugPrint('xVeil[mailbox]: start — ${relays.length} relay candidate(s), '
        'me=${_me.short}, alreadyRegistered=$_registered');
    // Resolving a relay's KEM key is a DHT FIND_VALUE; right after the node
    // connects its routing table is barely warm, so the first attempt often
    // returns null even though the relay DOES advertise an entry. A quick
    // backoff (≈0,4,8,16s) catches the warm-up case fast; thereafter the
    // periodic drain tick KEEPS retrying registration (see [_drainTick]) until a
    // relay resolves — so a relay whose key only appears later (e.g. a restarted
    // seed) is still picked up. Idempotent; stops as soon as one sticks.
    const backoffSecs = [0, 4, 8, 16];
    for (var attempt = 0; attempt < backoffSecs.length && !_registered; attempt++) {
      if (backoffSecs[attempt] > 0) {
        await Future<void>.delayed(Duration(seconds: backoffSecs[attempt]));
      }
      await _tryRegister();
    }
    debugPrint('xVeil[mailbox]: start done — registered=$_registered');
    _drainTimer ??= Timer.periodic(_drainInterval, (_) => _drainTick());
    unawaited(_drainTick()); // don't wait a full interval for the first drain
  }

  /// One pass over the relay candidates, registering at the first that resolves.
  Future<void> _tryRegister() async {
    for (final relay in _relays) {
      if (_registered) break;
      await _register(relay);
    }
  }

  Future<void> _register(NodeId relay) async {
    if (_registered) return;
    try {
      final kem = await _client.lookupRelayX25519(relay.bytes);
      if (kem == null) {
        // The relay advertises no resolvable relay-key record yet — a later
        // start()/reconnect retries.
        debugPrint('xVeil[mailbox]: relay ${relay.short} — KEM key NOT resolved '
            '(no relay-dir entry); skipping');
        return;
      }
      await _client.registerRendezvousPublisher(
        rendezvousNodeId: relay.bytes,
        authCookie: _cookie,
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: kem,
      );
      _registered = true;
      _registeredRelay = relay; // drain fetches straight from here (no DHT re-resolve)
      debugPrint('xVeil[mailbox]: REGISTERED rendezvous publisher @ relay '
          '${relay.short} (me=${_me.short} reachable by node_id now)');
    } catch (e) {
      debugPrint('xVeil[mailbox]: register @ ${relay.short} FAILED: $e');
      // A closed handle never recovers on this transport — stop the retry loop
      // so we don't spam every drain tick. The provider rebuilds a fresh mailbox
      // when the stack comes back up.
      if (e.toString().contains('handle already closed')) {
        _handleDead = true;
        _drainTimer?.cancel();
        _drainTimer = null;
        debugPrint('xVeil[mailbox]: handle dead — stopping retries until a fresh '
            'stack rebuilds this service');
      }
    }
  }

  /// Seal [payload] (the same `WireEnvelope` bytes we'd send live) for offline
  /// [recipient] under [contentId] (the message uuid) and deposit it at the
  /// recipient's advertised relay. Best-effort: throws on no-route / no relay so
  /// the caller's outbox retries.
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) {
    return _orchestrator.stash(
      me: _me,
      recipient: recipient,
      appId: chatAppIdFor(recipient),
      endpointId: veilChatEndpointId,
      data: payload,
      contentId: contentId,
    );
  }

  Future<void> _drainTick() async {
    if (_draining || _handleDead) return;
    _draining = true;
    try {
      // Keep trying to advertise a mailbox relay until one resolves — a relay's
      // published key can appear well after we first connect, so this persistent
      // retry (every drain interval) is what makes us reachable by node_id once
      // a relay is actually resolvable.
      if (!_registered && _relays.isNotEmpty) {
        await _tryRegister();
      }
      final recovered = await _orchestrator.drain(
        me: _me,
        authCookie: Uint8List(0), // ignored on the network path
        ourCertVersion: _ourCertVersion,
        // Fetch straight from the relay we registered with (if any) — skips the
        // flaky DHT self-ad resolve that was stranding mail on mobile.
        knownRelays: _registeredRelay != null ? [_registeredRelay!] : const [],
        // Dedup is enforced downstream by the messaging layer (it stores by the
        // same content id), so we re-deliver everything the relay returns and
        // let that gate duplicates — keeps this layer storage-free.
        alreadyHave: (_) async => false,
      );
      for (final m in recovered) {
        _deliver(InboundMessage(src: m.sender, payload: m.data));
      }
    } catch (_) {
      // Transient drain failure (DHT lookup / circuit not ready) — next tick.
    } finally {
      _draining = false;
    }
  }

  Future<void> dispose() async {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = r.nextInt(256);
    }
    return b;
  }
}
