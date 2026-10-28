import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

class _BudgetStore extends FakeKvLogStore {
  int scrubs = 0;
  bool failScrub = false;
  bool failStateCommit = false;
  bool failCompletionCommit = false;

  @override
  int commit(List<KvLogOp> ops) {
    if (failStateCommit &&
        ops.any(
          (op) =>
              op is PutOp && op.namespace == Ns.ratchet && op.key.length == 66,
        )) {
      throw StateError('fixture state commit failure');
    }
    if (failCompletionCommit &&
        ops.length == 1 &&
        ops.single is PutOp &&
        (ops.single as PutOp).namespace == Ns.ratchet &&
        (ops.single as PutOp).key.length == 1) {
      throw StateError('fixture cleanup completion failure');
    }
    return super.commit(ops);
  }

  @override
  void scrub() {
    scrubs++;
    if (failScrub) throw StateError('fixture vacuum failure');
    super.scrub();
  }
}

Uint8List _key(int n) => Uint8List(kRatchetKeyLen)..[0] = n;
Uint8List _blob(int n) => Uint8List(1400)..[0] = n;

HiddenVolumeStorage _storage(_BudgetStore store) =>
    HiddenVolumeStorage(({required password, required create}) => store);

Future<void> _save(HiddenVolumeStorage storage, int n, {int key = 1}) =>
    storage.saveRatchetStates([RatchetStateEntry(_key(key), _blob(n))]);

Future<void> _saves(HiddenVolumeStorage storage, int count) async {
  for (var i = 0; i < count; i++) {
    await _save(storage, i);
  }
}

class _PausedStore extends SyncWrappedAsyncKvLogStore {
  _PausedStore(super.inner);
  Completer<void>? entered;
  Completer<void>? release;
  bool closed = false;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (entered != null &&
        ops.any((op) => op is PutOp && op.namespace == Ns.ratchet)) {
      entered!.complete();
      entered = null;
      await release!.future;
    }
    if (closed) throw StateError('write after close');
    return super.commit(ops);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  test('cleanup count survives reopening the encrypted space', () async {
    final raw = _BudgetStore();
    var storage = _storage(raw);
    await storage.open(password: 'fixture');
    await _saves(storage, 64);
    await storage.close();
    storage = _storage(raw);
    await storage.open(password: 'fixture');
    addTearDown(storage.close);
    await _saves(storage, 64);
    expect(raw.scrubs, 1);
    expect(await storage.loadRatchetState(_key(1)), _blob(63));
  });

  test('switching spaces keeps independent cleanup counts', () async {
    final a = _BudgetStore(), b = _BudgetStore();
    final storage = HiddenVolumeStorage(
      ({required password, required create}) => password[0] == 65 ? a : b,
    );
    addTearDown(storage.close);
    await storage.open(password: 'A');
    await _saves(storage, 64);
    await storage.open(password: 'B');
    await _saves(storage, 64);
    expect(a.scrubs, 0);
    expect(b.scrubs, 0);
    await storage.open(password: 'A');
    await _saves(storage, 64);
    expect(a.scrubs, 1);
    expect(b.scrubs, 0);
  });

  test('failed cleanup blocks reopen until recovery succeeds', () async {
    final raw = _BudgetStore();
    final original = _storage(raw);
    await original.open(password: 'fixture');
    await _saves(original, 127);
    raw.failScrub = true;
    await expectLater(_save(original, 127), throwsStateError);
    await original.close();
    final restarted = _storage(raw);
    addTearDown(restarted.close);
    await expectLater(restarted.open(password: 'fixture'), throwsStateError);
    expect(restarted.isOpen, isFalse);
    raw.failScrub = false;
    await restarted.open(password: 'fixture');
    expect(raw.scrubs, 3);
    expect(await restarted.loadRatchetState(_key(1)), _blob(127));
  });

  test('already-open views recover before exposing ratchet state', () async {
    for (final asyncView in [false, true]) {
      final raw = _BudgetStore();
      final original = _storage(raw);
      await original.open(password: 'fixture');
      await _saves(original, 127);
      raw.failScrub = true;
      await expectLater(_save(original, 127), throwsStateError);
      await original.close();
      final view = asyncView
          ? HiddenVolumeStorage.fromAsyncStore(SyncWrappedAsyncKvLogStore(raw))
          : HiddenVolumeStorage.fromStore(raw);
      addTearDown(view.close);
      await expectLater(view.ratchetConversationKeys(), throwsStateError);
      await expectLater(view.loadRatchetState(_key(1)), throwsStateError);
      raw.failScrub = false;
      expect(await view.ratchetConversationKeys(), [_key(1)]);
      expect(await view.loadRatchetState(_key(1)), _blob(127));
    }
  });

  test('close drains an accepted ratchet write', () async {
    final backing = _PausedStore(_BudgetStore());
    final storage = HiddenVolumeStorage.fromAsyncStore(backing);
    final entered = Completer<void>(), release = Completer<void>();
    backing.entered = entered;
    backing.release = release;
    final writing = _save(storage, 7);
    await entered.future;
    final closing = storage.close();
    await Future<void>.delayed(Duration.zero);
    expect(backing.closed, isFalse);
    await expectLater(_save(storage, 8), throwsStateError);
    release.complete();
    await writing;
    await closing;
    expect(backing.closed, isTrue);
  });

  test('failed state commit does not consume the cleanup budget', () async {
    final raw = _BudgetStore();
    final storage = _storage(raw);
    await storage.open(password: 'fixture');
    addTearDown(storage.close);
    await _saves(storage, 126);
    raw.failStateCommit = true;
    await expectLater(_save(storage, 126), throwsStateError);
    raw.failStateCommit = false;
    await _save(storage, 126);
    expect(raw.scrubs, 0);
    await _save(storage, 127);
    expect(raw.scrubs, 1);
  });

  test('failed cleanup completion repeats vacuum after reopen', () async {
    final raw = _BudgetStore();
    var storage = _storage(raw);
    await storage.open(password: 'fixture');
    await _saves(storage, 127);
    raw.failCompletionCommit = true;
    await expectLater(_save(storage, 127), throwsStateError);
    expect(raw.scrubs, 1);
    await storage.close();
    raw.failCompletionCommit = false;
    storage = _storage(raw);
    await storage.open(password: 'fixture');
    addTearDown(storage.close);
    expect(raw.scrubs, 2);
    expect(await storage.loadRatchetState(_key(1)), _blob(127));
    await _save(storage, 128);
    expect(raw.scrubs, 2);
  });

  test('concurrent writes cannot lose cleanup increments', () async {
    final raw = _BudgetStore();
    final storage = _storage(raw);
    await storage.open(password: 'fixture');
    addTearDown(storage.close);
    await Future.wait([
      for (var i = 0; i < 128; i++) _save(storage, i, key: i),
    ]);
    expect(raw.scrubs, 1);
    expect(await storage.ratchetConversationKeys(), hasLength(128));
    for (var i = 0; i < 128; i++) {
      expect(await storage.loadRatchetState(_key(i)), _blob(i));
    }
  });

  test(
    'forgetting the last state retains cleanup obligation on failure',
    () async {
      final raw = _BudgetStore();
      var storage = _storage(raw);
      await storage.open(password: 'fixture');
      await _save(storage, 7);
      raw.failScrub = true;
      await expectLater(
        storage.forgetRatchetStates([_key(1)]),
        throwsStateError,
      );
      await storage.close();
      raw.failScrub = false;
      storage = _storage(raw);
      await storage.open(password: 'fixture');
      addTearDown(storage.close);
      expect(raw.scrubs, 2);
      expect(await storage.ratchetConversationKeys(), isEmpty);
      expect(await storage.loadRatchetState(_key(1)), isNull);
    },
  );

  test('legacy live states are cleaned once before restore', () async {
    final raw = _BudgetStore();
    var storage = _storage(raw);
    await storage.open(password: 'fixture');
    await _save(storage, 7);
    await storage.close();
    // Reproduce the pre-marker disk layout without depending on its tag.
    for (final key in raw.kvKeys(Ns.ratchet)) {
      if (key.length == 1) raw.commit([DeleteOp(Ns.ratchet, key)]);
    }
    storage = _storage(raw);
    await storage.open(password: 'fixture');
    expect(raw.scrubs, 1);
    expect(storage.anchorBeforeMaintenance, isNotNull);
    expect(await storage.loadRatchetState(_key(1)), _blob(7));
    await storage.close();
    storage = _storage(raw);
    await storage.open(password: 'fixture');
    addTearDown(storage.close);
    expect(raw.scrubs, 1);
    expect(storage.anchorBeforeMaintenance, isNull);
  });

  test('damaged budget is treated conservatively', () async {
    final raw = _BudgetStore();
    final storage = _storage(raw);
    await storage.open(password: 'fixture');
    await _save(storage, 7);
    await storage.close();
    final budget = raw.kvKeys(Ns.ratchet).singleWhere((k) => k.length == 1);
    raw.commit([PutOp(Ns.ratchet, budget, Uint8List(2))]);
    await storage.open(password: 'fixture');
    addTearDown(storage.close);
    expect(raw.scrubs, 1);
    expect(await storage.loadRatchetState(_key(1)), _blob(7));
  });

  test(
    'erase waits for an accepted write and removes its budget too',
    () async {
      final raw = _BudgetStore();
      final backing = _PausedStore(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(backing);
      addTearDown(storage.close);
      final entered = Completer<void>(), release = Completer<void>();
      backing.entered = entered;
      backing.release = release;
      final writing = _save(storage, 7);
      await entered.future;
      final erasing = storage.eraseSpace();
      await Future<void>.delayed(Duration.zero);
      await expectLater(_save(storage, 8), throwsStateError);
      release.complete();
      await writing;
      await erasing;
      expect(raw.count(Ns.ratchet), 0);
      expect(await storage.ratchetConversationKeys(), isEmpty);
      // Erase must also discard the in-memory count of the previous contents.
      final scrubs = raw.scrubs;
      await _saves(storage, 127);
      expect(raw.scrubs, scrubs);
      await _save(storage, 127);
      expect(raw.scrubs, scrubs + 1);
    },
  );
}
