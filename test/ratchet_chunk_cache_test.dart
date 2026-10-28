import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

class _HeadCountingStore extends FakeKvLogStore {
  int headReads = 0;
  int scrubs = 0;
  bool loseNextStateReply = false;

  @override
  Uint8List? get(int namespace, Uint8List key) {
    if (namespace == Ns.ratchet && key.length == kRatchetKeyLen + 2) {
      headReads++;
    }
    return super.get(namespace, key);
  }

  @override
  int commit(List<KvLogOp> ops) {
    final result = super.commit(ops);
    if (loseNextStateReply &&
        ops.any(
          (op) =>
              op is PutOp &&
              op.namespace == Ns.ratchet &&
              op.key.length == kRatchetKeyLen + 2,
        )) {
      loseNextStateReply = false;
      throw StateError('fixture lost reply after durable commit');
    }
    return result;
  }

  @override
  void scrub() {
    scrubs++;
    super.scrub();
  }
}

Uint8List _key(int i) => Uint8List(kRatchetKeyLen)..[0] = i;
Uint8List _blob(int length, int i) => Uint8List(length)..[0] = i;
Future<void> _save(
  HiddenVolumeStorage storage,
  int length,
  int i, {
  int peer = 1,
}) => storage.saveRatchetStates([
  RatchetStateEntry(_key(peer), _blob(length, i)),
]);
int _records(_HeadCountingStore raw) =>
    raw.kvKeys(Ns.ratchet).where((k) => k.length == kRatchetKeyLen + 2).length;

void main() {
  test('repeated durable saves reuse the last committed run length', () async {
    final raw = _HeadCountingStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    await _save(storage, 1400, 1);
    expect(raw.headReads, 1);
    for (var i = 2; i < 10; i++) {
      await _save(storage, 1400, i);
    }
    expect(
      raw.headReads,
      1,
      reason: 'no repeated worker round trip for a known committed head',
    );
    await _save(storage, 60000, 10);
    await _save(storage, 100, 11);
    expect(raw.headReads, 1);
    expect(
      _records(raw),
      1,
      reason: 'a cached run length must still prune every old tail',
    );
    expect(await storage.loadRatchetState(_key(1)), _blob(100, 11));
  });

  test('uncertain commit invalidates cached lengths before retry', () async {
    final raw = _HeadCountingStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    await _save(storage, 1400, 1);
    raw.loseNextStateReply = true;
    await expectLater(_save(storage, 60000, 2), throwsStateError);
    raw.headReads = 0;
    await _save(storage, 100, 3);
    expect(
      raw.headReads,
      1,
      reason: 'read the actual durable head after any write error',
    );
    expect(_records(raw), 1);
    expect(await storage.loadRatchetState(_key(1)), _blob(100, 3));
  });

  test('uncertain commit also reloads the durable cleanup count', () async {
    final raw = _HeadCountingStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    for (var i = 0; i < 126; i++) {
      await _save(storage, 1400, i);
    }
    raw.loseNextStateReply = true;
    await expectLater(_save(storage, 1400, 126), throwsStateError);
    await _save(storage, 1400, 127);
    expect(
      raw.scrubs,
      1,
      reason: 'the unacknowledged durable write still counts',
    );
  });

  test(
    'successive versions in one batch prune the preceding draft tail',
    () async {
      final raw = _HeadCountingStore();
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      await storage.saveRatchetStates([
        RatchetStateEntry(_key(1), _blob(60000, 1)),
        RatchetStateEntry(_key(1), _blob(100, 2)),
      ]);
      expect(_records(raw), 1);
      expect(await storage.loadRatchetState(_key(1)), _blob(100, 2));
    },
  );

  test('identity handoff cannot reuse another space run length', () async {
    final a = _HeadCountingStore(), b = _HeadCountingStore();
    final seedB = HiddenVolumeStorage.fromStore(b);
    await _save(seedB, 60000, 1);
    await seedB.close();
    final storage = HiddenVolumeStorage(
      ({required password, required create}) => password[0] == 65 ? a : b,
    );
    addTearDown(storage.close);
    await storage.open(password: 'A');
    await _save(storage, 100, 1);
    await storage.open(password: 'B');
    b.headReads = 0;
    await _save(storage, 100, 2);
    expect(b.headReads, 1);
    expect(_records(b), 1);
    expect(await storage.loadRatchetState(_key(1)), _blob(100, 2));
    await storage.open(password: 'A');
    expect(await storage.loadRatchetState(_key(1)), _blob(100, 1));
  });

  test('forget and recreate reads the current head again', () async {
    final raw = _HeadCountingStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    await _save(storage, 60000, 1);
    await storage.forgetRatchetStates([_key(1)]);
    raw.headReads = 0;
    await _save(storage, 100, 2);
    expect(raw.headReads, 1);
    expect(_records(raw), 1);
    expect(await storage.loadRatchetState(_key(1)), _blob(100, 2));
  });

  test('run length cache is bounded and evicted entries use disk', () async {
    final raw = _HeadCountingStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    for (var i = 0; i < 129; i++) {
      await _save(storage, 1400, 1, peer: i);
    }
    raw.headReads = 0;
    await _save(storage, 100, 2, peer: 0);
    expect(raw.headReads, 1, reason: 'oldest cached run was evicted');
    raw.headReads = 0;
    await _save(storage, 100, 2, peer: 128);
    expect(raw.headReads, 0, reason: 'the newest committed run remains cached');
    expect(_records(raw), 256);
  });
}
