// Call-journal store + recorder (multi-device epic, brick 4). The store keeps
// a capped, newest-first list of [CallLogEntry] rows in the encrypted settings
// namespace ('call_log'); the recorder folds the call FSM's terminal snapshots
// into it. The device-sync bridge taps [CallLogStore.onAdded] to mirror local
// rows to my other devices and feeds mirrored rows in via [addMirrored] (no
// tap — a mirrored row must never re-mirror).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  static const _key = 'call_log';
  final Storage _storage;

  /// Fired for LOCALLY recorded rows only (never from [addMirrored]) — the
  /// device-sync bridge posts these to the device group.
  void Function(CallLogEntry e)? onAdded;

  /// Serializes read-modify-write cycles so a local end racing a mirrored row
  /// can't lose either.
  Future<void> _chain = Future.value();

  /// Newest-first journal.
  Future<List<CallLogEntry>> list() async {
    final raw = await _storage.getSetting(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final d = jsonDecode(raw);
      if (d is! List) return const [];
      return [
        for (final j in d)
          if (j is Map) ?CallLogEntry.fromJson(Map<String, dynamic>.from(j)),
      ];
    } catch (_) {
      return const [];
    }
  }

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
      final cur = await list();
      if (cur.any((x) => x.id == e.id)) return false;
      final next = [...cur, e]..sort((a, b) => b.atMs.compareTo(a.atMs));
      await _storage.putSetting(
        _key,
        jsonEncode([for (final x in next.take(kCallLogCap)) x.toJson()]),
      );
      return true;
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
final callLogRecorderProvider = Provider<void>((ref) {
  final svc = ref.watch(callServiceProvider);
  final store = ref.read(callLogStoreProvider);
  final sub = svc.changes.listen((c) {
    if (c == null || c.status != CallStatus.ended) return;
    final connected = c.connectedAt != null;
    final endedAt = c.endedAt ?? DateTime.now();
    unawaited(store.add(CallLogEntry(
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
    )));
  });
  ref.onDispose(sub.cancel);
});
