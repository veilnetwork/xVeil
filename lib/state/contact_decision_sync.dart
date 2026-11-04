import 'dart:async';

import '../core/error_journal.dart';
import '../core/ids.dart';
import '../data/storage/storage.dart';
import '../domain/device_sync.dart';

DeviceSyncEvent contactDecisionEvent(PendingContactDecision record) =>
    DeviceSyncEvent(
      kind: DeviceSyncKind.contactUp,
      key: 's:${record.peer.hex}',
      tsMs: record.atMs,
      payload: {'status': record.status.name},
    );

/// Transfers a durable local decision to the committed device journal. A
/// callback merely wakes the worker; retries never mint a newer decision.
class ContactDecisionPublisher {
  ContactDecisionPublisher({
    required this.storage,
    required this.isLinked,
    required this.isOwnDevice,
    required this.loadPublished,
    required this.post,
    this.retryEvery = const Duration(seconds: 15),
    ErrorJournal? journal,
  }) : journal = journal ?? errorJournal;

  final Storage storage;
  final Future<bool> Function() isLinked;
  final Future<bool> Function(NodeId) isOwnDevice;
  // Verified, COMMITTED rows, including future stamps for duplicate suppression.
  final Future<List<DeviceSyncEvent>> Function() loadPublished;
  // True means local commit + durable replication admission, not delivery.
  final Future<List<bool>> Function(List<DeviceSyncEvent>) post;
  final Duration retryEvery;
  final ErrorJournal journal;
  Timer? _timer;
  Future<bool>? _work;
  bool _closed = false, _again = false;
  String? _cursor;

  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(retryEvery, (_) => nudge());
    nudge();
  }

  void nudge() {
    if (_closed) return;
    _again = true;
    unawaited(flush());
  }

  Future<bool> flush() {
    if (_closed) return Future.value(false);
    return _work ??= _drain().whenComplete(() => _work = null);
  }

  void _report() => journal.record(
    kind: 'contact-status-sync',
    error: StateError('Contact decision synchronization failed'),
    atMs: DateTime.now().millisecondsSinceEpoch,
  );

  Future<bool> _drain() async {
    var success = true;
    for (var round = 0; round < 4; round++) {
      _again = false;
      try {
        success = await _pass() && success;
      } catch (_) {
        _report();
        success = false;
      }
      if (_closed || !_again) break;
    }
    return success;
  }

  Future<bool> _pass() async {
    if (!await isLinked() || _closed) return false;
    var pending = await storage.pendingContactDecisions(afterPeerHex: _cursor);
    if (pending.isEmpty && _cursor != null) {
      _cursor = null;
      pending = await storage.pendingContactDecisions();
    }
    if (_closed || pending.isEmpty) return !_closed;
    final published = <String, List<DeviceSyncEvent>>{};
    for (final event in await loadPublished()) {
      published.putIfAbsent(event.key, () => []).add(event);
    }
    if (_closed) return false;
    var success = true;
    for (var page = 0; page < 8 && !_closed; page++) {
      if (page > 0) {
        pending = await storage.pendingContactDecisions(afterPeerHex: _cursor);
      }
      if (pending.isEmpty) {
        _cursor = null;
        break;
      }
      _cursor = pending.last.peer.hex;
      final toPost = <PendingContactDecision>[];
      for (final record in pending) {
        if (_closed) return false;
        final own = await isOwnDevice(record.peer);
        if (_closed) return false;
        final event = contactDecisionEvent(record);
        final covered = (published[event.key] ?? const <DeviceSyncEvent>[]).any(
          (old) =>
              !isNewerDeviceSync(event, old) &&
              (!isNewerDeviceSync(old, event) ||
                  deviceSyncEffectiveAt(
                    old,
                    DateTime.now().millisecondsSinceEpoch,
                  )),
        );
        if (own || covered) {
          if (!await storage.acknowledgeContactDecision(record)) _again = true;
        } else {
          toPost.add(record);
        }
      }
      if (_closed) return false;
      if (toPost.isEmpty) continue;
      final events = [
        for (final record in toPost) contactDecisionEvent(record),
      ];
      final results = await post(events);
      if (results.length != toPost.length) {
        throw StateError('Contact publication result count mismatch');
      }
      // Close joins this handoff, but does not start another storage operation
      // after the host has stopped admission to the old identity.
      if (_closed) return false;
      for (var i = 0; i < toPost.length; i++) {
        if (!results[i]) {
          _report();
          success = false;
          continue;
        }
        published.putIfAbsent(events[i].key, () => []).add(events[i]);
        if (!await storage.acknowledgeContactDecision(toPost[i])) _again = true;
      }
    }
    return success;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await _work;
  }
}
