// Call journal persistence (Ns.callLog append-log): one immutable record per
// call, legacy single-value migration, cap eviction that frees log slots, and
// the PayloadTooLarge regression stance — the journal never rewrites a hot
// settings key again.


import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/call_log.dart';

SpaceOpener _mem(FakeKvLogStore s) =>
    ({required password, required bool create}) => s;

/// A store whose journal APPEND fails, everything else working. Models the
/// container refusing the write (WrongNamespaceKind, PayloadTooLarge, a full
/// disk) so the caller's stance on a failed append is testable at all.
class _AppendRefusingStore extends FakeKvLogStore {
  @override
  int commit(List<KvLogOp> ops) {
    if (ops.any((op) => op is AppendLogOp && op.namespace == Ns.callLog)) {
      throw StateError('journal append refused');
    }
    return super.commit(ops);
  }
}

/// The mirror image: the append lands, the EVICTION commit is refused.
class _EvictionRefusingStore extends FakeKvLogStore {
  @override
  int commit(List<KvLogOp> ops) {
    if (ops.any((op) => op is DeleteLogOp && op.namespace == Ns.callLog)) {
      throw StateError('journal eviction refused');
    }
    return super.commit(ops);
  }
}

Future<(HiddenVolumeStorage, FakeKvLogStore)> _open() async {
  final kv = FakeKvLogStore();
  final storage = HiddenVolumeStorage(_mem(kv));
  await storage.open(password: 'p', createIfMissing: true);
  return (storage, kv);
}

CallLogEntry _entry(String id, int atMs) => CallLogEntry(
      id: id,
      peerHex: 'aa',
      outgoing: true,
      video: false,
      outcome: CallLogOutcome.completed,
      atMs: atMs,
      durationSec: 3,
    );

void main() {
  test('one immutable log record per call; the hot settings key is never '
      'written (PayloadTooLarge regression)', () async {
    final (storage, kv) = await _open();
    for (var i = 0; i < 30; i++) {
      expect(
        await storage.appendCallLogEntry(_entry('c$i', 1000 + i), cap: 200),
        isTrue,
      );
    }
    // 30 journal rows = 30 records in the dedicated namespace…
    expect((await storage.namespaceCounts())['callLog'], 30);
    // …and NO single-value journal blob anywhere in settings.
    expect(await storage.getSetting('call_log'), isNull);

    final rows = await storage.callLogEntries();
    expect(rows.length, 30);
    expect(rows.first.id, 'c29', reason: 'newest first');
    expect(rows.last.id, 'c0');
  });

  test('idempotent by id', () async {
    final (storage, _) = await _open();
    expect(await storage.appendCallLogEntry(_entry('c1', 1000), cap: 5), isTrue);
    expect(
      await storage.appendCallLogEntry(_entry('c1', 9999), cap: 5),
      isFalse,
      reason: 'same call id must not journal twice',
    );
    expect((await storage.callLogEntries()).length, 1);
  });

  test('cap evicts the oldest rows AND frees their log slots', () async {
    final (storage, _) = await _open();
    for (var i = 0; i < 25; i++) {
      await storage.appendCallLogEntry(_entry('c$i', 1000 + i), cap: 20);
    }
    final rows = await storage.callLogEntries();
    expect(rows.length, 20);
    expect(rows.first.id, 'c24');
    expect(rows.any((e) => e.id == 'c4'), isFalse);
    // The evicted rows' records are DELETED, not tombstoned — the bounded
    // per-namespace log index must not accumulate dead journal slots.
    expect((await storage.namespaceCounts())['callLog'], 20);
  });

  // A FULL journal is where the store used to stop recording. Eviction and the
  // new row went into ONE batch, and hidden-volume refuses a transaction that
  // both appends to and deletes from one Log namespace — so every call past
  // the cap threw `WrongNamespaceKind: delete_log cannot be mixed with
  // append_log in one Tx`, the recorder logged it, and the history quietly
  // froze at exactly `cap` rows with the OLDEST ones. Caught on a live
  // macOS -> Android call, never by the suite: the in-memory fake accepted the
  // batch the native store rejects.
  test('a full journal keeps recording: eviction and the new row are separate '
      'commits', () async {
    final (storage, kv) = await _open();
    for (var i = 0; i < 12; i++) {
      expect(
        await storage.appendCallLogEntry(_entry('c$i', 1000 + i), cap: 5),
        isTrue,
        reason: 'call $i must be journaled, full journal or not',
      );
    }
    final rows = await storage.callLogEntries();
    // Five newest, and the newest of all is the LAST call — not a journal
    // frozen at the first five.
    expect(rows.map((e) => e.id).toList(), [
      'c11',
      'c10',
      'c9',
      'c8',
      'c7',
    ]);
    expect(kv.count(Ns.callLog), 5);
  });

  // The whole bug class is "the write failed and only a log line said so".
  // Splitting the batch must not turn into swallowing the append as well: a
  // refused append has to reach the recorder, which is the only thing that
  // reports a lost call. `isTrue` from a store that wrote nothing is the shape
  // that hid the PayloadTooLarge loss for weeks.
  test('a refused journal append is reported, never reported as written',
      () async {
    final kv = _AppendRefusingStore();
    final storage = HiddenVolumeStorage(_mem(kv));
    await storage.open(password: 'p', createIfMissing: true);
    await expectLater(
      storage.appendCallLogEntry(_entry('c1', 1000), cap: 5),
      throwsA(isA<StateError>()),
    );
    expect(kv.count(Ns.callLog), 0);
    expect(await storage.callLogEntries(), isEmpty);
  });

  // The two commits are NOT symmetric, on purpose. A refused append means the
  // call was not recorded and the recorder must hear about it; a refused
  // eviction means the call WAS recorded and the journal is one row over its
  // cap, which the next append recomputes and fixes. Reporting the second as a
  // failed journal write would name a call that is sitting in the journal.
  test('a refused eviction still records the call', () async {
    final kv = _EvictionRefusingStore();
    final storage = HiddenVolumeStorage(_mem(kv));
    await storage.open(password: 'p', createIfMissing: true);
    for (var i = 0; i < 3; i++) {
      expect(
        await storage.appendCallLogEntry(_entry('c$i', 1000 + i), cap: 2),
        isTrue,
      );
    }
    // Nothing was evicted (the store refused), but every call is journaled.
    expect(
      (await storage.callLogEntries()).map((e) => e.id).toList(),
      ['c2', 'c1', 'c0'],
    );
  });

  test('the fake rejects the batch the native store rejects', () {
    final kv = FakeKvLogStore();
    final payload = Uint8List.fromList([1]);
    // Append + delete in ONE commit, for one log namespace: `Tx::delete_log`.
    expect(
      () => kv.commit([
        AppendLogOp(Ns.callLog, 2, payload),
        DeleteLogOp(Ns.callLog, 1),
      ]),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('delete_log cannot be mixed with append_log'),
        ),
      ),
    );
    // Reverse order is rejected too: `Tx::check_namespace_kind` sees the
    // namespace already claimed by key.
    expect(
      () => kv.commit([
        DeleteLogOp(Ns.callLog, 1),
        AppendLogOp(Ns.callLog, 2, payload),
      ]),
      throwsA(isA<StateError>()),
    );
    // Addressing ONE namespace by key and by log id in one commit is the same
    // refusal (R-NSKIND single-kind-per-namespace).
    expect(
      () => kv.commit([
        PutOp(Ns.callLog, payload, payload),
        AppendLogOp(Ns.callLog, 2, payload),
      ]),
      throwsA(isA<StateError>()),
    );
    // Separate namespaces in one commit are fine — that is how every append
    // carries its settings counter.
    expect(
      kv.commit([
        AppendLogOp(Ns.callLog, 2, payload),
        PutOp(Ns.settings, payload, payload),
      ]),
      isPositive,
    );
  });

  test('a row older than a full journal is accepted then aged out', () async {
    final (storage, _) = await _open();
    for (var i = 0; i < 3; i++) {
      await storage.appendCallLogEntry(_entry('c$i', 2000 + i), cap: 3);
    }
    // Older than everything, journal already full: reported written (the
    // recorder is never punished), stored nowhere.
    expect(await storage.appendCallLogEntry(_entry('old', 1), cap: 3), isTrue);
    final rows = await storage.callLogEntries();
    expect(rows.length, 3);
    expect(rows.any((e) => e.id == 'old'), isFalse);
  });

  test('eraseSpace clears the journal namespace', () async {
    final (storage, kv) = await _open();
    await storage.appendCallLogEntry(_entry('c1', 1000), cap: 10);
    expect(kv.count(Ns.callLog), 1);
    await storage.eraseSpace();
    expect(kv.count(Ns.callLog), 0);
  });
}
