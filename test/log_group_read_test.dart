import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

class _Guarded extends FakeKvLogStore {
  int? forbidden;
  @override
  Uint8List? readLog(int ns, int id) {
    if (id == forbidden) throw StateError('later record was read');
    return super.readLog(ns, id);
  }
}

class _Held extends SyncWrappedAsyncKvLogStore {
  _Held(super.store);
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = true;
  @override
  Future<Uint8List?> readLog(int ns, int id) async {
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.readLog(ns, id);
  }
}

void main() {
  test(
    'groups preserve exact order, duplicates, empty groups and namespace',
    () async {
      final raw = FakeKvLogStore();
      raw.commit([
        for (var i = 1; i <= 3; i++)
          AppendLogOp(Ns.fileChunks, i, Uint8List.fromList([i])),
      ]);
      final store = SyncWrappedAsyncKvLogStore(raw);
      final groups = [
        (ids: [3, 1, 3], maxBytes: 3),
        (ids: <int>[], maxBytes: 0),
        (ids: [2], maxBytes: 0x7fffffffffffffff),
      ];
      expect(await store.readLogGroups(Ns.fileChunks, groups), [
        [3, 1, 3],
        <int>[],
        [2],
      ]);
      expect(await store.readLogGroups(Ns.messageLog, groups), isNull);
      expect(await store.readLogGroups(Ns.fileChunks, []), isEmpty);
    },
  );
  test(
    'missing and over-budget records stop before later IDs or groups',
    () async {
      final raw = _Guarded();
      raw.commit([
        AppendLogOp(Ns.fileChunks, 1, Uint8List.fromList([1, 2])),
        AppendLogOp(Ns.fileChunks, 3, Uint8List.fromList([3])),
      ]);
      final store = SyncWrappedAsyncKvLogStore(raw);
      raw.forbidden = 3;
      expect(
        await store.readLogGroups(Ns.fileChunks, [
          (ids: [1, 2, 3], maxBytes: 8),
        ]),
        isNull,
      );
      expect(
        await store.readLogGroups(Ns.fileChunks, [
          (ids: [1], maxBytes: 1),
          (ids: [3], maxBytes: 8),
        ]),
        isNull,
      );
      expect(
        await store.readLogGroups(Ns.fileChunks, [
          (ids: [1, 3], maxBytes: 1),
        ]),
        isNull,
      );
      raw.forbidden = 1;
      await expectLater(
        store.readLogGroups(Ns.fileChunks, [
          (ids: [1], maxBytes: -1),
        ]),
        throwsArgumentError,
      );
      await expectLater(
        store.readLogGroups(Ns.fileChunks, [
          (ids: List.filled(65, 1), maxBytes: 1000),
        ]),
        throwsArgumentError,
      );
      await expectLater(
        store.readLogGroups(
          Ns.fileChunks,
          List.filled(9, (ids: <int>[], maxBytes: 0)),
        ),
        throwsArgumentError,
      );
    },
  );
  test('a pending read owns every nested ID list and group budget', () async {
    final raw = FakeKvLogStore();
    raw.commit([
      for (var i = 1; i <= 3; i++)
        AppendLogOp(Ns.fileChunks, i, Uint8List.fromList([i])),
    ]);
    final store = _Held(raw);
    final first = [1], second = [2];
    final groups = [(ids: first, maxBytes: 1), (ids: second, maxBytes: 1)];
    final pending = store.readLogGroups(Ns.fileChunks, groups);
    await store.entered.future;
    first[0] = 3;
    second[0] = 3;
    groups[1] = (ids: [3], maxBytes: 0);
    groups.clear();
    store.release.complete();
    expect(await pending, [
      [1],
      [2],
    ]);
  });
}
