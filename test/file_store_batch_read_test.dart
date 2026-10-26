import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

class _CountingReader extends SyncWrappedAsyncKvLogStore {
  _CountingReader(super.inner);
  final batches = <List<int>>[];
  var singleReads = 0;
  @override
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> ids) {
    batches.add(List.of(ids));
    return super.readLogBatch(namespace, ids);
  }

  @override
  Future<Uint8List?> readLog(int namespace, int id) {
    singleReads++;
    return super.readLog(namespace, id);
  }
}

class _WithoutBatch implements AsyncKvLogStore {
  _WithoutBatch(this.inner);
  final AsyncKvLogStore inner;
  var reads = 0;
  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      inner.get(namespace, key);
  @override
  Future<Uint8List?> readLog(int namespace, int id) {
    reads++;
    return inner.readLog(namespace, id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _GuardedStore extends FakeKvLogStore {
  int? forbidden;
  @override
  Uint8List? readLog(int namespace, int id) {
    if (namespace == Ns.fileChunks && id == forbidden) {
      throw StateError('must stop at the earlier missing record');
    }
    return super.readLog(namespace, id);
  }
}

void main() {
  test(
    'whole-file reads use bounded batches with identical bytes and fallback',
    () async {
      final raw = FakeKvLogStore();
      final writer = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      for (final count in [0, 1, 64, 65, 190]) {
        final data = Uint8List.fromList(
          List.generate(count * 3800, (i) => i % 251),
        );
        final id = 'batch-$count';
        await writer.storeFile(id, data);
        final reader = _CountingReader(raw);
        final result = await AsyncFileStore(reader).loadFile(id);
        expect(result, data);
        expect(reader.singleReads, count);
        expect(reader.batches.length, (count + 63) ~/ 64);
        expect(
          reader.batches.every(
            (b) => b.length <= AsyncLogBatchReader.maxRecords,
          ),
          isTrue,
        );
        final fallback = _WithoutBatch(SyncWrappedAsyncKvLogStore(raw));
        expect(await AsyncFileStore(fallback).loadFile(id), data);
        expect(fallback.reads, count);
      }
    },
  );

  test('size guard refuses before chunk requests', () async {
    final raw = FakeKvLogStore();
    await AsyncFileStore(
      SyncWrappedAsyncKvLogStore(raw),
    ).storeFile('large', Uint8List(8000));
    final reader = _CountingReader(raw);
    expect(
      await AsyncFileStore(reader).loadFile('large', maxBytes: 7999),
      isNull,
    );
    expect(reader.batches, isEmpty);
    expect(reader.singleReads, 0);
  });

  test(
    'exact ids preserve order and stop before later corrupt records',
    () async {
      final raw = _GuardedStore();
      raw.commit([
        AppendLogOp(Ns.fileChunks, 1, Uint8List.fromList([1])),
        AppendLogOp(Ns.fileChunks, 3, Uint8List.fromList([3])),
        AppendLogOp(Ns.fileChunks, 4, Uint8List.fromList([4])),
      ]);
      final reader = SyncWrappedAsyncKvLogStore(raw);
      expect(await reader.readLogBatch(Ns.fileChunks, [3, 1]), [
        [3],
        [1],
      ]);
      raw.forbidden = 4;
      expect(await reader.readLogBatch(Ns.fileChunks, [1, 2, 4]), isNull);
      expect(await reader.readLogBatch(Ns.fileChunks, []), isEmpty);
      await expectLater(
        reader.readLogBatch(Ns.fileChunks, List.filled(65, 1)),
        throwsArgumentError,
      );
    },
  );

  test('missing file record cannot be filled by a neighboring file', () async {
    final raw = FakeKvLogStore();
    final reader = _CountingReader(raw);
    final files = AsyncFileStore(reader);
    await files.storeFile(
      'first',
      Uint8List.fromList(List.generate(8000, (i) => i % 251)),
    );
    await files.storeFile('neighbor', Uint8List.fromList([7, 8, 9]));
    raw.commit([DeleteLogOp(Ns.fileChunks, 2)]);
    expect(await files.loadFile('first'), isNull);
    expect(await files.loadFile('neighbor'), [7, 8, 9]);
  });
}
