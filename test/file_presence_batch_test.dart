import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

class _Reader extends SyncWrappedAsyncKvLogStore {
  _Reader(super.inner);
  final batches = <List<String>>[];
  var logReads = 0;
  var truncate = false;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<List<Uint8List?>> getBatch(int namespace, List<Uint8List> keys) async {
    batches.add([for (final key in keys) utf8.decode(key)]);
    final values = await super.getBatch(namespace, keys);
    if (entered != null) {
      entered!.complete();
      entered = null;
      await release!.future;
    }
    return truncate ? values.sublist(1) : values;
  }

  @override
  Future<Uint8List?> readLog(int namespace, int id) {
    logReads++;
    return super.readLog(namespace, id);
  }
}

class _WithoutBatch implements AsyncKvLogStore {
  _WithoutBatch(this.inner);
  final AsyncKvLogStore inner;
  @override
  Future<Uint8List?> get(int namespace, Uint8List key) =>
      inner.get(namespace, key);
  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test(
    'storage without worker batching keeps individual presence semantics',
    () async {
      final raw = FakeKvLogStore();
      FileStore(raw).storeFile('whole', Uint8List.fromList([1, 2]));
      final storage = HiddenVolumeStorage.fromAsyncStore(
        _WithoutBatch(SyncWrappedAsyncKvLogStore(raw)),
      );
      addTearDown(storage.close);
      expect(await storage.hasFiles(['missing', 'whole', 'whole']), [
        false,
        true,
        true,
      ]);
      expect(await storage.hasFiles([]), isEmpty);
    },
  );

  test(
    'presence preserves order, duplicates and streamed completeness',
    () async {
      final raw = FakeKvLogStore();
      final reader = _Reader(raw);
      final files = AsyncFileStore(reader);
      await files.storeFile('whole', Uint8List.fromList([1, 2, 3]));
      await files.storeFile('empty', Uint8List(0));
      await files.storeFilePiece(
        'partial',
        0,
        2,
        2,
        4,
        Uint8List.fromList([4, 5]),
      );
      const ids = ['whole', 'missing', 'partial', 'empty', 'whole'];
      final expected = [for (final id in ids) await files.hasFile(id)];
      reader.batches.clear();
      reader.logReads = 0;
      expect(await files.hasFiles(ids), expected);
      expect(expected, [true, false, false, true, true]);
      expect(reader.batches, [
        [for (final id in ids) 'file:$id'],
      ]);
      expect(
        reader.logReads,
        0,
        reason: 'presence must not read file payloads',
      );
      expect(
        await AsyncFileStore(_WithoutBatch(reader)).hasFiles(ids),
        expected,
      );

      await files.storeFilePiece(
        'partial',
        1,
        2,
        2,
        4,
        Uint8List.fromList([6, 7]),
      );
      expect(await files.hasFiles(['partial']), [true]);
      raw.commit(await files.deleteFileOps('whole'));
      expect(await files.hasFiles(['whole', 'partial']), [false, true]);
      expect(await files.hasFiles([]), isEmpty);
      expect(
        await files.hasFiles(List.filled(32, 'partial')),
        everyElement(isTrue),
      );
      await expectLater(
        files.hasFiles(List.filled(33, 'partial')),
        throwsArgumentError,
      );
    },
  );

  test(
    'tier batches match individual checks without retaining metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp('xv-presence-');
      addTearDown(() => directory.delete(recursive: true));
      final raw = FakeKvLogStore();
      final reader = _Reader(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(reader);
      addTearDown(storage.close);
      await storage.storeFile('volume', Uint8List.fromList([1, 2]));
      storage.useOnDiskTier(directory, minBytes: 1);
      await storage.storeFilePiece(
        'disk',
        0,
        1,
        2,
        2,
        Uint8List.fromList([3, 4]),
      );
      await storage.storeFilePiece(
        'partial',
        0,
        2,
        2,
        4,
        Uint8List.fromList([5, 6]),
      );
      final ids = ['disk', 'missing', 'volume', 'partial', 'disk'];
      final expected = [for (final id in ids) await storage.hasFile(id)];
      reader.batches.clear();
      reader.logReads = 0;
      expect(await storage.hasFiles(ids), expected);
      expect(expected, [true, false, true, false, true]);
      expect(reader.batches, [
        [for (final id in ids) 'ondisk:$id'],
        ['file:missing', 'file:volume'],
      ]);
      expect(reader.logReads, 0);
      await storage.deleteStoredFile('disk');
      expect(await storage.hasFiles(ids), [false, false, true, false, false]);
      await expectLater(
        storage.hasFiles(List.filled(33, 'volume')),
        throwsArgumentError,
      );
    },
  );

  test('caller mutation cannot redirect a pending presence request', () async {
    final reader = _Reader(FakeKvLogStore());
    final storage = HiddenVolumeStorage.fromAsyncStore(reader);
    addTearDown(storage.close);
    await storage.storeFile('present', Uint8List.fromList([1]));
    final entered = reader.entered = Completer<void>();
    reader.release = Completer<void>();
    final ids = ['present', 'absent'];
    final pending = storage.hasFiles(ids);
    await entered.future;
    ids.setAll(0, ['absent', 'present']);
    reader.release!.complete();
    expect(await pending, [true, false]);
  });

  test(
    'malformed metadata and truncated batches fail instead of lying',
    () async {
      final raw = FakeKvLogStore();
      final reader = _Reader(raw);
      final files = AsyncFileStore(reader);
      raw.commit([
        PutOp(
          Ns.settings,
          Uint8List.fromList(utf8.encode('file:bad')),
          Uint8List.fromList(utf8.encode('invalid-json')),
        ),
      ]);
      await expectLater(files.hasFiles(['bad']), throwsFormatException);
      reader.truncate = true;
      await expectLater(files.hasFiles(['missing']), throwsStateError);
      final storage = HiddenVolumeStorage.fromAsyncStore(reader);
      addTearDown(storage.close);
      await expectLater(storage.hasFiles(['missing']), throwsStateError);
    },
  );
}
