// Call journal persistence (Ns.callLog append-log): one immutable record per
// call, legacy single-value migration, cap eviction that frees log slots, and
// the PayloadTooLarge regression stance — the journal never rewrites a hot
// settings key again.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/call_log.dart';

SpaceOpener _mem(FakeKvLogStore s) =>
    ({required password, required bool create}) => s;

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

  test('cap evicts the oldest rows AND frees their log slots in the same '
      'commit', () async {
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

  test('legacy single-value journal migrates once: rows carried over, hot key '
      'deleted, dedupe against already-migrated records', () async {
    final (storage, _) = await _open();
    final legacy = jsonEncode([
      _entry('a', 100).toJson(),
      _entry('b', 200).toJson(),
      {'garbage': true},
      _entry('b', 200).toJson(), // duplicate id inside the blob
    ]);
    await storage.putSetting('call_log', legacy);

    // First journal READ drains the legacy blob.
    final rows = await storage.callLogEntries();
    expect([for (final e in rows) e.id], ['b', 'a']);
    expect(await storage.getSetting('call_log'), isNull,
        reason: 'the hot key must be gone after the drain');
    expect((await storage.namespaceCounts())['callLog'], 2);

    // Migration does not resurrect on later appends.
    await storage.appendCallLogEntry(_entry('c', 300), cap: 10);
    expect([for (final e in await storage.callLogEntries()) e.id],
        ['c', 'b', 'a']);
  });

  test('migration runs before an append too, and an unreadable legacy blob is '
      'dropped without killing the journal', () async {
    final (storage, _) = await _open();
    await storage.putSetting('call_log', '{not json');
    await storage.appendCallLogEntry(_entry('c1', 1000), cap: 10);
    expect(await storage.getSetting('call_log'), isNull);
    expect([for (final e in await storage.callLogEntries()) e.id], ['c1']);
  });

  test('eraseSpace clears the journal namespace', () async {
    final (storage, kv) = await _open();
    await storage.appendCallLogEntry(_entry('c1', 1000), cap: 10);
    expect(kv.count(Ns.callLog), 1);
    await storage.eraseSpace();
    expect(kv.count(Ns.callLog), 0);
  });
}
