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

Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));

class _Counted extends SyncWrappedAsyncKvLogStore {
  _Counted(super.store);
  int individual = 0, batches = 0, bodies = 0;
  bool inBatch = false;
  @override
  Future<Uint8List?> get(int ns, Uint8List key) {
    if (!inBatch) individual++;
    return super.get(ns, key);
  }

  @override
  Future<List<Uint8List?>> getBatch(int ns, List<Uint8List> keys) async {
    batches++;
    inBatch = true;
    try {
      return await super.getBatch(ns, keys);
    } finally {
      inBatch = false;
    }
  }

  @override
  Future<List<Uint8List>?> readLogBatch(int ns, List<int> ids) {
    bodies++;
    return super.readLogBatch(ns, ids);
  }

  void reset() {
    individual = batches = bodies = 0;
  }
}

class _HeldKeys extends SyncWrappedAsyncKvLogStore {
  _HeldKeys(super.store);
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = true;
  @override
  Future<Uint8List?> get(int ns, Uint8List key) async {
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.get(ns, key);
  }
}

class _Guarded extends FakeKvLogStore {
  int? forbidden;
  @override
  Uint8List? readLog(int ns, int id) {
    if (ns == Ns.fileChunks && id == forbidden) {
      throw StateError('later payload must stay unread');
    }
    return super.readLog(ns, id);
  }
}

class _NoKvBatch implements AsyncKvLogStore, AsyncLogBatchReader {
  _NoKvBatch(this.inner);
  final SyncWrappedAsyncKvLogStore inner;
  @override
  Future<Uint8List?> get(int ns, Uint8List key) => inner.get(ns, key);
  @override
  Future<Uint8List?> readLog(int ns, int id) => inner.readLog(ns, id);
  @override
  Future<List<Uint8List>?> readLogBatch(int ns, List<int> ids) =>
      inner.readLogBatch(ns, ids);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

void main() {
  test(
    'metadata batch preserves order missing slots duplicates and namespace',
    () async {
      final raw = FakeKvLogStore();
      raw.commit([
        PutOp(Ns.settings, _key('a'), _key('A')),
        PutOp(Ns.settings, _key('b'), _key('B')),
      ]);
      final store = _Counted(raw);
      expect(
        await store.getBatch(Ns.settings, [
          _key('b'),
          _key('missing'),
          _key('a'),
          _key('b'),
        ]),
        [_key('B'), null, _key('A'), _key('B')],
      );
      expect(await store.getBatch(Ns.fileChunks, [_key('a')]), [null]);
      expect(await store.getBatch(Ns.settings, []), isEmpty);
      await expectLater(
        store.getBatch(Ns.settings, List.generate(65, (_) => _key('a'))),
        throwsArgumentError,
      );
    },
  );
  test(
    'metadata request owns both its key list and mutable key bytes',
    () async {
      final raw = FakeKvLogStore();
      raw.commit([
        PutOp(Ns.settings, _key('a'), _key('A')),
        PutOp(Ns.settings, _key('b'), _key('B')),
      ]);
      final store = _HeldKeys(raw), first = _key('a'), second = _key('b');
      final keys = [first, second];
      final read = store.getBatch(Ns.settings, keys);
      await store.entered.future;
      first[0] = 120;
      second[0] = 121;
      keys.clear();
      store.release.complete();
      expect(await read, [_key('A'), _key('B')]);
    },
  );
  test(
    'inline whole-file batch uses two metadata requests and reads every payload',
    () async {
      final raw = FakeKvLogStore();
      // Use the exact store behind the storage facade, not a fabricated read cache.
      final actual = _Counted(raw),
          storage = HiddenVolumeStorage.fromAsyncStore(actual);
      addTearDown(storage.close);
      final expected = [
        Uint8List(0),
        Uint8List.fromList(List.generate(6000, (i) => i % 251)),
        Uint8List.fromList(List.generate(64000, (i) => (i * 7) % 251)),
      ];
      for (var i = 0; i < expected.length; i++) {
        await storage.storeFile('f$i', expected[i]);
      }
      actual.reset();
      expect(
        await storage.loadFiles(['f0', 'f1', 'f2'], maxBytesPerFile: 65536),
        expected,
      );
      expect(actual.batches, 2);
      expect(actual.individual, 0);
      expect(actual.bodies, 2);
      actual.reset();
      expect(await storage.loadFiles([], maxBytesPerFile: 0), isEmpty);
      expect(actual.batches, 0);
      await expectLater(
        storage.loadFiles(List.filled(9, 'f1'), maxBytesPerFile: 65536),
        throwsArgumentError,
      );
      expect(actual.batches, 0);
    },
  );
  test(
    'missing payload stops the batch before later files and does not poison repair',
    () async {
      final raw = _Guarded();
      final files = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      for (var i = 1; i <= 3; i++) {
        await files.storeFile('f$i', Uint8List.fromList([i]));
      }
      raw.commit([DeleteLogOp(Ns.fileChunks, 2)]);
      raw.forbidden = 3;
      expect(
        await files.loadFiles(['f1', 'f2', 'f3'], maxBytesPerFile: 8),
        isNull,
      );
      raw.forbidden = null;
      await files.storeFile('f2', Uint8List.fromList([2]));
      expect(await files.loadFiles(['f1', 'f2', 'f3'], maxBytesPerFile: 8), [
        [1],
        [2],
        [3],
      ]);
    },
  );
  test(
    'recorded ceiling refuses bytes and unmeasurable metadata before payload',
    () async {
      final raw = FakeKvLogStore();
      final actual = _Counted(raw);
      final files = AsyncFileStore(actual);
      await files.storeFile('f', Uint8List(6000));
      actual.reset();
      expect(await files.loadFiles(['f'], maxBytesPerFile: 5999), isNull);
      expect(actual.bodies, 0);
      final metadata =
          jsonDecode(utf8.decode(raw.get(Ns.settings, _key('file:f'))!)) as Map;
      metadata.remove('size');
      raw.commit([
        PutOp(Ns.settings, _key('file:f'), _key(jsonEncode(metadata))),
      ]);
      actual.reset();
      expect(await files.loadFiles(['f'], maxBytesPerFile: 65536), isNull);
      expect(actual.bodies, 0);
    },
  );
  test(
    'a legacy empty payload record still fits a zero-byte ceiling',
    () async {
      final raw = FakeKvLogStore();
      raw.commit([
        AppendLogOp(Ns.fileChunks, 1, Uint8List(0)),
        PutOp(
          Ns.settings,
          _key('file:empty'),
          _key(jsonEncode({'size': 0, 'base': 1, 'count': 1})),
        ),
      ]);
      final files = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      expect(await files.loadFiles(['empty'], maxBytesPerFile: 0), [<int>[]]);
      expect(await files.loadFile('empty', maxBytes: 0), isEmpty);
    },
  );

  test(
    'underreported size and excessive record counts cannot defeat the batch ceiling',
    () async {
      final raw = FakeKvLogStore();
      final store = _Counted(raw);
      final files = AsyncFileStore(store);
      await files.storeFile('f', Uint8List(6000));
      final key = _key('file:f');
      final original =
          jsonDecode(utf8.decode(raw.get(Ns.settings, key)!)) as Map;
      raw.commit([
        PutOp(Ns.settings, key, _key(jsonEncode({...original, 'size': 1}))),
      ]);
      expect(await files.loadFiles(['f'], maxBytesPerFile: 100), isNull);
      raw.commit([
        PutOp(
          Ns.settings,
          key,
          _key(jsonEncode({'size': 1, 'base': 1, 'count': 65537})),
        ),
      ]);
      store.reset();
      expect(await files.loadFiles(['f'], maxBytesPerFile: 100), isNull);
      expect(
        store.bodies,
        0,
        reason: 'refuse implausible expansion before enqueuing payload reads',
      );
    },
  );
  test(
    'streamed files and readers without KV batches preserve ordinary behavior',
    () async {
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      await storage.storeFilePiece(
        'stream',
        0,
        2,
        4,
        8,
        Uint8List.fromList([1, 2, 3, 4]),
      );
      await storage.storeFilePiece(
        'stream',
        1,
        2,
        4,
        8,
        Uint8List.fromList([5, 6, 7, 8]),
      );
      expect(await storage.loadFiles(['stream'], maxBytesPerFile: 8), [
        [1, 2, 3, 4, 5, 6, 7, 8],
      ]);
      final fallback = HiddenVolumeStorage.fromAsyncStore(
        _NoKvBatch(SyncWrappedAsyncKvLogStore(raw)),
      );
      expect(await fallback.loadFiles(['stream'], maxBytesPerFile: 8), [
        [1, 2, 3, 4, 5, 6, 7, 8],
      ]);
      expect(await fallback.loadFiles(['stream'], maxBytesPerFile: 7), isNull);
    },
  );
  test('mixed on-disk and inline batches keep blob precedence', () async {
    final dir = await Directory.systemTemp.createTemp('xv-batch-tier-');
    addTearDown(() => dir.delete(recursive: true));
    final raw = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    addTearDown(storage.close);
    storage.useOnDiskTier(dir, minBytes: 2);
    await storage.storeFilePiece(
      'both',
      0,
      1,
      3,
      3,
      Uint8List.fromList([9, 8, 7]),
    );
    FileStore(raw).storeFile('both', Uint8List.fromList([1]));
    FileStore(raw).storeFile('inline', Uint8List.fromList([2]));
    expect(await storage.loadFiles(['both', 'inline'], maxBytesPerFile: 8), [
      [9, 8, 7],
      [2],
    ]);
    expect(await storage.loadFiles(['both'], maxBytesPerFile: 2), isNull);
  });
  test('a maximum integer ceiling does not overflow the metadata budget', () async {
    final files = AsyncFileStore(SyncWrappedAsyncKvLogStore(FakeKvLogStore()));
    await files.storeFile('small', Uint8List.fromList([1, 2]));
    expect(await files.loadFiles(['small'], maxBytesPerFile: 0x7fffffffffffffff), [[1, 2]]);
  });

}
