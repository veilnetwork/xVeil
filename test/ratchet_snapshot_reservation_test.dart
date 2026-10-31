import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

Uint8List _key(int n) => Uint8List(kRatchetKeyLen)..[0] = n;
Uint8List _blob(int length, int tag) => Uint8List(length)..[0] = tag;
String _marks(int next) => encodeRatchetReservations([
  RatchetSendPosition(Uint8List(32)..[0] = 7, next),
]);

class _RecordedStore extends FakeKvLogStore {
  final commits = <List<KvLogOp>>[];
  int? failAt;
  bool loseReply = false;
  @override
  int commit(List<KvLogOp> ops) {
    commits.add(List.of(ops));
    if (commits.length == failAt && !loseReply) {
      throw StateError('injected transaction rejection');
    }
    final sequence = super.commit(ops);
    if (commits.length == failAt) {
      throw StateError('injected lost transaction reply');
    }
    return sequence;
  }
}

void main() {
  test('a snapshot and its sending reservation share one commit', () async {
    final raw = _RecordedStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    final key = _key(1);
    await storage.saveRatchetStates([
      RatchetStateEntry(key, _blob(1400, 1), sendReservation: _marks(32)),
    ]);
    expect(await storage.loadRatchetState(key), _blob(1400, 1));
    expect(await storage.getSetting(ratchetReservationKey(key)), _marks(32));
    expect(raw.commits, hasLength(1));
    final writes = raw.commits.single.whereType<PutOp>().toList();
    expect(writes.any((op) => op.namespace == Ns.ratchet), isTrue);
    expect(
      writes
          .where((op) => op.namespace == Ns.settings)
          .map((op) => utf8.decode(op.key)),
      ['set:${ratchetReservationKey(key)}'],
    );
  });

  for (final uncertain in [false, true]) {
    test(
      'paired replacement stays whole after failure (uncertain=$uncertain)',
      () async {
        final raw = _RecordedStore();
        final storage = HiddenVolumeStorage.fromStore(raw);
        addTearDown(storage.close);
        final key = _key(1);
        await storage.saveRatchetStates([
          RatchetStateEntry(key, _blob(1400, 1), sendReservation: _marks(32)),
        ]);
        raw.commits.clear();
        raw.failAt = 1;
        raw.loseReply = uncertain;
        await expectLater(
          storage.saveRatchetStates([
            RatchetStateEntry(key, _blob(100, 2), sendReservation: _marks(64)),
          ]),
          throwsStateError,
        );
        expect(
          await storage.loadRatchetState(key),
          uncertain ? _blob(100, 2) : _blob(1400, 1),
        );
        expect(
          await storage.getSetting(ratchetReservationKey(key)),
          _marks(uncertain ? 64 : 32),
        );
        raw.failAt = null;
        await storage.saveRatchetStates([
          RatchetStateEntry(key, _blob(100, 2), sendReservation: _marks(64)),
        ]);
        expect(await storage.loadRatchetState(key), _blob(100, 2));
        expect(
          await storage.getSetting(ratchetReservationKey(key)),
          _marks(64),
        );
        expect(
          raw.kvKeys(Ns.ratchet).where((k) => k.length == kRatchetKeyLen + 2),
          hasLength(1),
        );
      },
    );
  }

  test('a failed later batch leaves only complete old or new pairs', () async {
    final raw = _RecordedStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    await storage.saveRatchetStates([
      for (var i = 1; i <= 2; i++)
        RatchetStateEntry(
          _key(i),
          _blob(64 * 1024 - 4, i),
          sendReservation: _marks(32),
        ),
    ]);
    raw.commits.clear();
    raw.failAt = 2;
    await expectLater(
      storage.saveRatchetStates([
        for (var i = 1; i <= 2; i++)
          RatchetStateEntry(
            _key(i),
            _blob(64 * 1024 - 4, i + 10),
            sendReservation: _marks(64),
          ),
      ]),
      throwsStateError,
    );
    expect(raw.commits, hasLength(2));
    expect(await storage.loadRatchetState(_key(1)), _blob(64 * 1024 - 4, 11));
    expect(
      await storage.getSetting(ratchetReservationKey(_key(1))),
      _marks(64),
    );
    expect(await storage.loadRatchetState(_key(2)), _blob(64 * 1024 - 4, 2));
    expect(
      await storage.getSetting(ratchetReservationKey(_key(2))),
      _marks(32),
    );
  });

  test(
    'paired operation budget includes the reservation and cleanup marker',
    () async {
      final raw = _RecordedStore();
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      await storage.saveRatchetStates([
        RatchetStateEntry(
          _key(1),
          _blob(126 * 1024 - 4, 1),
          sendReservation: _marks(32),
        ),
      ]);
      expect(raw.commits.single, hasLength(128));
      raw.commits.clear();
      await expectLater(
        storage.saveRatchetStates([
          RatchetStateEntry(
            _key(2),
            _blob(127 * 1024 - 4, 2),
            sendReservation: _marks(32),
          ),
        ]),
        throwsA(isA<RatchetSnapshotReservationTooLarge>()),
      );
      expect(raw.commits, isEmpty);
      await storage.saveRatchetStates([
        RatchetStateEntry(_key(2), _blob(127 * 1024 - 4, 2)),
      ]);
      expect(raw.commits.single, hasLength(128));
      raw.commits.clear();
      await expectLater(
        storage.saveRatchetStates([
          RatchetStateEntry(
            _key(2),
            _blob(100, 3),
            sendReservation: _marks(64),
          ),
        ]),
        throwsA(isA<RatchetSnapshotReservationTooLarge>()),
      );
      expect(raw.commits, isEmpty, reason: 'obsolete tail deletes count too');
      expect(await storage.loadRatchetState(_key(2)), _blob(127 * 1024 - 4, 2));
    },
  );

  test('paired inputs are frozen before the storage gate yields', () async {
    final raw = _RecordedStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    final key = _key(1), bytes = _blob(1400, 1);
    final entries = [
      RatchetStateEntry(key, bytes, sendReservation: _marks(32)),
    ];
    final work = storage.saveRatchetStates(entries);
    key[0] = 2;
    bytes[0] = 99;
    entries.clear();
    await work;
    expect(await storage.loadRatchetState(_key(1)), _blob(1400, 1));
    expect(await storage.loadRatchetState(_key(2)), isNull);
    expect(
      await storage.getSetting(ratchetReservationKey(_key(1))),
      _marks(32),
    );
  });

  test('invalid paired metadata fails before any input is committed', () async {
    final raw = _RecordedStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    await expectLater(
      storage.saveRatchetStates([
        RatchetStateEntry(_key(1), _blob(100, 1), sendReservation: _marks(32)),
        RatchetStateEntry(_key(2), _blob(100, 2), sendReservation: 'é' * 1025),
      ]),
      throwsA(isA<RatchetSnapshotReservationTooLarge>()),
    );
    expect(raw.commits, isEmpty);
    expect(await storage.loadRatchetState(_key(1)), isNull);
  });
}
