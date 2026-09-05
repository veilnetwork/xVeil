// Call-journal store + recorder (multi-device epic, brick 4). The store keeps
// a capped, newest-first journal of [CallLogEntry] rows — one immutable
// encrypted record per call (Storage.appendCallLogEntry; the journal must
// never be a single rewritten settings value, see the PayloadTooLarge note on
// the port). The recorder folds the call FSM's terminal snapshots into it.
// The device-sync bridge taps [CallLogStore.onAdded] to mirror local rows to
// my other devices and feeds mirrored rows in via [addMirrored] (no tap — a
// mirrored row must never re-mirror).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../domain/call.dart';
import '../domain/call_log.dart';
import '../domain/call_signal.dart';
import '../data/storage/storage.dart';
import 'call_service.dart';
import 'providers.dart';

/// Journal size cap — enough scrollback without unbounded growth.
const int kCallLogCap = 200;

class CallLogStore {
  CallLogStore(this._storage);

  final Storage _storage;

  /// Fired for LOCALLY recorded rows only (never from [addMirrored]) — the
  /// device-sync bridge posts these to the device group.
  void Function(CallLogEntry e)? onAdded;

  /// Bumped whenever a row lands (local or mirrored) — the journal screen's
  /// re-render signal.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// Serializes read-modify-write cycles so a local end racing a mirrored row
  /// can't lose either.
  Future<void> _chain = Future.value();

  /// Newest-first journal.
  Future<List<CallLogEntry>> list() => _storage.callLogEntries();

  /// Record a LOCAL row: idempotent by [CallLogEntry.id], capped, then fires
  /// [onAdded]. Returns whether a new row was written.
  Future<bool> add(CallLogEntry e) async {
    final wrote = await _insert(e);
    if (wrote) onAdded?.call(e);
    return wrote;
  }

  /// Record a row mirrored from ANOTHER of my devices — same dedupe/cap, but
  /// never fires [onAdded], so it cannot echo back into the device group.
  Future<bool> addMirrored(CallLogEntry e) => _insert(e);

  Future<bool> _insert(CallLogEntry e) {
    final done = _chain.then((_) async {
      final wrote = await _storage.appendCallLogEntry(e, cap: kCallLogCap);
      if (wrote) changes.value++;
      return wrote;
    });
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }
}

/// The journal for the active identity's store (re-points on identity switch).
final callLogStoreProvider = Provider<CallLogStore>(
  (ref) => CallLogStore(ref.watch(storageProvider)),
);

/// Folds the call FSM's terminal snapshots into the journal. Eagerly watched
/// from the app scope (like the group bridge) so calls are journaled even
/// while no journal UI exists.
/// This conversation's calls, newest-last, for the chat timeline.
///
/// Watches [CallLogStore.changes] so a call that ends while the chat is open
/// appears without anybody reopening it.
final callLogForPeerProvider =
    FutureProvider.family<List<CallLogEntry>, String>((ref, peerHex) async {
      final store = ref.watch(callLogStoreProvider);
      // The notifier is the store's "something changed" tick; rebuilding on it
      // is what makes a call that just ended show up in the open chat.
      final listenable = store.changes;
      void bump() => ref.invalidateSelf();
      listenable.addListener(bump);
      ref.onDispose(() => listenable.removeListener(bump));
      final all = await store.list();
      final mine = [for (final e in all) if (e.peerHex == peerHex) e]
        ..sort((a, b) => a.atMs.compareTo(b.atMs));
      return mine;
    });

final callLogRecorderProvider = Provider<void>((ref) {
  final svc = ref.watch(callServiceProvider);
  final store = ref.read(callLogStoreProvider);
  final sub = svc.changes.listen((c) {
    if (c == null || c.status != CallStatus.ended) return;
    final connected = c.connectedAt != null;
    final endedAt = c.endedAt ?? DateTime.now();
    // Fire-and-forget, but never SILENT: a journal row that fails to persist
    // is exactly the bug class that hid the PayloadTooLarge loss for weeks.
    unawaited(store
        .add(CallLogEntry(
          id: c.callId,
          peerHex: c.peer.hex,
          outgoing: c.direction == CallDirection.outgoing,
          video: c.media.video || c.media.screen,
          outcome: callLogOutcomeFor(
            outgoing: c.direction == CallDirection.outgoing,
            connected: connected,
            reason: c.endReason ?? CallEndReason.unknown,
          ),
          atMs: c.startedAt.millisecondsSinceEpoch,
          durationSec: connected
              ? endedAt.difference(c.connectedAt!).inSeconds
              : 0,
        ))
        .catchError((Object e) {
      devLog(() => 'xVeil[call-log]: journal write failed ${c.callId}: $e');
      return false;
    }));
  });
  ref.onDispose(sub.cancel);
});
