import 'dart:async';

import '../core/error_journal.dart';
import '../data/storage/storage.dart';
import '../domain/call_log.dart';

/// Hands locally committed results to the durable device journal. Admission to
/// this worker is only a nudge: the obligation already lives in the container.
/// Retrying after a crash never depends on an in-memory callback surviving.
class CallLogPublisher {
  CallLogPublisher({
    required this.storage,
    required this.isLinked,
    required this.loadPublished,
    required this.post,
    required this.reconcile,
    ErrorJournal? journal,
    this.retryEvery = const Duration(seconds: 30),
  }) : journal = journal ?? errorJournal;

  final Storage storage;
  final Future<bool> Function() isLinked;
  // This must read COMMITTED, verified events, including future-stamped ones.
  // Effective state alone would re-publish those on every boot until due.
  final Future<List<CallLogEntry>> Function() loadPublished;
  final Future<bool> Function(CallLogEntry) post;
  final Future<void> Function(CallLogEntry) reconcile;
  final ErrorJournal journal;
  final Duration retryEvery;
  Timer? _timer;
  Future<bool>? _work;
  bool _closed = false, _again = false, _seeded = false;
  String? _resumeAfter;

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
    kind: 'call-history-sync',
    error: StateError('Call history synchronization failed'),
    atMs: DateTime.now().millisecondsSinceEpoch,
  );

  Future<bool> _drain() async {
    var success = true;
    // Bound one admission even if calls keep arriving during every await.
    // Outstanding records remain durable and the periodic retry resumes them.
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
    final linked = await isLinked();
    if (_closed) return false;
    var pending = await storage.pendingCallLogSync(afterCallId: _resumeAfter);
    if (pending.isEmpty && _resumeAfter != null) {
      _resumeAfter = null;
      pending = await storage.pendingCallLogSync();
    }
    if (linked && !_seeded) {
      _seeded = await storage.getSetting('call.sync.migrated.v1') == '1';
    }
    // Idle retries need only the small pending-key scan. Do not repeatedly
    // load and verify the whole group when there is nothing to hand off.
    if (pending.isEmpty && (!linked || _seeded)) return true;
    final published = <String, CallLogEntry>{};
    if (linked) {
      for (final row in await loadPublished()) {
        final old = published[row.id];
        if (old == null || compareCallLogEntries(row, old) > 0) {
          published[row.id] = row;
        }
      }
      if (!_seeded) {
        // Upgrade pre-ledger profiles too. Mirrored rows already in the group
        // do not get queued or echoed. This bounded retained history cannot
        // recover an OLD result already lost before this version was installed.
        for (final row in await storage.callLogEntries()) {
          if (_closed) return false;
          final old = published[row.id];
          if (old == null || compareCallLogEntries(row, old) > 0) {
            await storage.queueCallLogSync(row);
          }
        }
        // Mark only after all obligations are durable. On later boots an
        // expired/compacted group row must not trigger full legacy replay.
        await storage.putSetting('call.sync.migrated.v1', '1');
        _seeded = true;
        _resumeAfter = null;
        pending = await storage.pendingCallLogSync();
      }
    }
    var success = true;
    String? cursor;
    for (var page = 0; page < 8 && !_closed; page++) {
      if (page > 0) {
        pending = await storage.pendingCallLogSync(afterCallId: cursor);
      }
      if (pending.isEmpty) {
        _resumeAfter = null;
        break;
      }
      cursor = pending.last.entry.id;
      _resumeAfter = cursor;
      // GroupService batches up to 64 posts. Awaiting each individually would
      // force a full group load/save per call during legacy recovery.
      final results = await Future.wait([
        for (final record in pending)
          (() async {
            try {
              if (_closed) return false;
              if (linked) {
                final row = record.entry, old = published[row.id];
                if (old == null || compareCallLogEntries(row, old) > 0) {
                  if (!await post(row)) {
                    _report();
                    return false;
                  }
                }
                await reconcile(row);
              }
              // Without a group there is no sibling to correct. Retained
              // history is copied by the normal link history snapshot later;
              // do not accumulate an unbounded outbox for an unlinked identity.
              if (!await storage.acknowledgeCallLogSync(record)) {
                // Another local result arrived during this handoff. Its CAS
                // token differs: leave it and re-read it before going idle.
                _again = true;
              }
              return true;
            } catch (_) {
              _report();
              return false;
            }
          })(),
      ]);
      success = results.every((ok) => ok) && success;
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
