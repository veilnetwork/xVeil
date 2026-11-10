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
  bool refuseMetadata = false, shortMetadata = false;
  final metadataRequests = <int>[];
  bool inBatch = false;
  final groupRequests = <List<LogReadGroup>>[];
  @override
  Future<Uint8List?> get(int ns, Uint8List key) {
    if (!inBatch) individual++;
    return super.get(ns, key);
  }

  @override
  Future<List<Uint8List?>> getBatch(int ns, List<Uint8List> keys) async {
    batches++;
    metadataRequests.add(keys.length);
    if (refuseMetadata) throw StateError('fixture metadata refusal');
    inBatch = true;
    try {
      final values = await super.getBatch(ns, keys);
      return shortMetadata ? values.sublist(1) : values;
    } finally {
      inBatch = false;
    }
  }

  @override
  Future<List<Uint8List>?> readLogBatch(int ns, List<int> ids) {
    bodies++;
    return super.readLogBatch(ns, ids);
  }

  @override
  Future<List<Uint8List>?> readLogGroups(int ns, List<LogReadGroup> groups) {
    bodies++;
    groupRequests.add([
      for (final group in groups)
        (ids: List<int>.of(group.ids), maxBytes: group.maxBytes),
    ]);
    return super.readLogGroups(ns, groups);
  }

  void reset() {
    individual = batches = bodies = 0;
    groupRequests.clear();
    metadataRequests.clear();
  }
}

class _HeldBodies extends _Counted {
  _HeldBodies(super.store);
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = true;
  @override
  Future<List<Uint8List>?> readLogBatch(int ns, List<int> ids) async {
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.readLogBatch(ns, ids);
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
  String? forbiddenMetadata;
  @override
  Uint8List? get(int ns, Uint8List key) {
    if (ns == Ns.settings && utf8.decode(key) == forbiddenMetadata) {
      throw StateError('unused tier metadata unreadable');
    }
    return super.get(ns, key);
  }

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
    'payload waves span files, preserve duplicates and stay within 64 records',
    () async {
      final raw = FakeKvLogStore();
      final store = _Counted(raw);
      final files = AsyncFileStore(store);
      final expected = <Uint8List>[];
      for (final count in [63, 2, 64, 0, 1]) {
        final bytes = Uint8List.fromList(
          List.generate(count * 3800, (i) => (i + count) % 251),
        );
        await files.storeFile('f${expected.length}', bytes);
        expected.add(bytes);
      }
      store.reset();
      expect(
        await files.loadFiles([
          'f0',
          'f1',
          'f2',
          'f3',
          'f4',
          'f1',
        ], maxBytesPerFile: 64 * 3800),
        [...expected, expected[1]],
      );
      expect(
        store.bodies,
        3,
        reason: '132 records use three waves, not one wave per file',
      );
      expect(
        store.groupRequests.map(
          (wave) => wave.fold<int>(0, (n, g) => n + g.ids.length),
        ),
        [64, 64, 4],
      );
      expect(
        store.groupRequests[1].first.maxBytes,
        63 * 3800,
        reason: 'the second half of a file retains its remaining byte budget',
      );
    },
  );

  test(
    'an over-ceiling file crossing waves stops before the next file',
    () async {
      final raw = _Guarded();
      raw.commit([
        for (var id = 1; id <= 66; id++)
          AppendLogOp(Ns.fileChunks, id, Uint8List.fromList([id])),
        PutOp(
          Ns.settings,
          _key('file:first'),
          _key(jsonEncode({'size': 0, 'base': 1, 'count': 65})),
        ),
        PutOp(
          Ns.settings,
          _key('file:later'),
          _key(jsonEncode({'size': 1, 'base': 66, 'count': 1})),
        ),
      ]);
      raw.forbidden = 66;
      expect(
        await AsyncFileStore(
          SyncWrappedAsyncKvLogStore(raw),
        ).loadFiles(['first', 'later'], maxBytesPerFile: 64),
        isNull,
      );
    },
  );

  test(
    'a later malformed manifest cannot overtake an earlier missing payload',
    () async {
      final raw = FakeKvLogStore();
      raw.commit([
        PutOp(
          Ns.settings,
          _key('file:first'),
          _key(jsonEncode({'size': 1, 'base': 1, 'count': 1})),
        ),
        PutOp(Ns.settings, _key('file:later'), _key('{invalid json')),
      ]);
      expect(
        await AsyncFileStore(
          SyncWrappedAsyncKvLogStore(raw),
        ).loadFiles(['first', 'later'], maxBytesPerFile: 64),
        isNull,
      );
    },
  );
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
    'inline whole-file batch uses one metadata request and reads every payload',
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
      expect(actual.batches, 1);
      expect(actual.individual, 0);
      expect(
        actual.bodies,
        1,
        reason: 'small files share one bounded payload request',
      );
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
  test('single inline header uses one bounded metadata request', () async {
    final raw = FakeKvLogStore();
    final actual = _Counted(raw);
    final storage = HiddenVolumeStorage.fromAsyncStore(actual);
    addTearDown(storage.close);
    await storage.storeFile('header', Uint8List.fromList([1, 2, 3]));
    actual.reset();
    expect(await storage.loadFile('header', maxBytes: 3), [1, 2, 3]);
    expect(actual.batches, 1);
    expect(actual.individual, 0);
    expect(actual.bodies, 1);
  });

  test(
    'maximum combined metadata batch keeps duplicates and fresh replacements',
    () async {
      final raw = FakeKvLogStore();
      final actual = _Counted(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(actual);
      addTearDown(storage.close);
      for (var i = 0; i < 8; i++) {
        await storage.storeFile('f$i', Uint8List.fromList([i]));
      }
      final ids = ['f7', 'f0', 'f7', 'f3', 'f1', 'f2', 'f4', 'f6'];
      actual.reset();
      expect(await storage.loadFiles(ids, maxBytesPerFile: 2), [
        for (final id in ids) [int.parse(id.substring(1))],
      ]);
      expect(actual.metadataRequests, [16]);
      expect(actual.individual, 0);
      await storage.storeFile('f7', Uint8List.fromList([9, 8]));
      actual.reset();
      expect(await storage.loadFile('f7', maxBytes: 2), [9, 8]);
      expect(actual.metadataRequests, [2]);
      actual.reset();
      expect(await storage.loadFile('f7', maxBytes: 1), isNull);
      expect(actual.bodies, 0);
    },
  );

  for (final batch in [false, true]) {
    for (final short in [false, true]) {
      test(
        '${batch ? 'batch' : 'single'} refuses ${short ? 'short' : 'failed'} metadata without payload fallback',
        () async {
          final actual = _Counted(FakeKvLogStore());
          final storage = HiddenVolumeStorage.fromAsyncStore(actual);
          addTearDown(storage.close);
          await storage.storeFile('held', Uint8List.fromList([1, 2]));
          actual.reset();
          actual.shortMetadata = short;
          actual.refuseMetadata = !short;
          await expectLater(
            batch
                ? storage.loadFiles(['held'], maxBytesPerFile: 4)
                : storage.loadFile('held', maxBytes: 4),
            throwsStateError,
          );
          expect(actual.individual, !short ? 1 : 0);
          expect(actual.bodies, 0);
        },
      );
    }
  }

  test(
    'handed-off metadata owns its vector and bytes while prior payload waits',
    () async {
      final raw = _Guarded();
      final store = _HeldBodies(raw);
      final files = AsyncFileStore(store);
      await files.storeFile('first', Uint8List.fromList([1]));
      final malformedSize = _key(
        jsonEncode({'size': 'bad', 'base': 2, 'count': 1}),
      );
      final ids = ['first', 'later'];
      final metadata = [
        raw.get(Ns.settings, _key('file:first')),
        malformedSize,
      ];
      raw.forbidden = 2;
      final reading = files.loadFilesWithMetadata(
        ids,
        metadata,
        maxBytesPerFile: 8,
      );
      await store.entered.future;
      malformedSize.fillRange(0, malformedSize.length, 0);
      metadata.clear();
      ids.clear();
      store.release.complete();
      expect(await reading, isNull);
      expect(store.bodies, 1);
    },
  );

  test(
    'handed-off metadata retains limits and length validation before payload',
    () async {
      final actual = _Counted(FakeKvLogStore());
      final files = AsyncFileStore(actual);
      await expectLater(
        files.loadFilesWithMetadata(
          List.filled(9, 'x'),
          [],
          maxBytesPerFile: 8,
        ),
        throwsArgumentError,
      );
      await expectLater(
        files.loadFilesWithMetadata(['x'], [], maxBytesPerFile: 8),
        throwsStateError,
      );
      await expectLater(
        files.loadFilesWithMetadata([], [], maxBytesPerFile: -1),
        throwsArgumentError,
      );
      expect(
        await files.loadFilesWithMetadata([], [], maxBytesPerFile: 0),
        isEmpty,
      );
      expect(actual.bodies, 0);
      expect(actual.batches, 0);
      expect(actual.individual, 0);
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
  for (final batch in [false, true]) {
    test(
      '${batch ? 'batch' : 'single'} keeps valid external tier when unused inline metadata fails',
      () async {
        final dir = await Directory.systemTemp.createTemp('xv-tier-pair-');
        addTearDown(() => dir.delete(recursive: true));
        final raw = _Guarded();
        final storage = HiddenVolumeStorage.fromStore(raw);
        addTearDown(storage.close);
        storage.useOnDiskTier(dir, minBytes: 1);
        await storage.storeFilePiece(
          'both',
          0,
          1,
          3,
          3,
          Uint8List.fromList([9, 8, 7]),
        );
        FileStore(raw).storeFile('both', Uint8List.fromList([1]));
        raw.forbiddenMetadata = 'file:both';
        raw.forbidden = 1;
        if (batch) {
          expect(await storage.loadFiles(['both'], maxBytesPerFile: 8), [
            [9, 8, 7],
          ]);
          expect(await storage.loadFiles(['both'], maxBytesPerFile: 2), isNull);
          expect(
            await storage.loadFiles(['missing', 'both'], maxBytesPerFile: 8),
            isNull,
          );
        } else {
          expect(await storage.loadFile('both', maxBytes: 8), [9, 8, 7]);
          expect(await storage.loadFile('both', maxBytes: 2), isNull);
        }
      },
    );
  }
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
  test(
    'a maximum integer ceiling does not overflow the metadata budget',
    () async {
      final files = AsyncFileStore(
        SyncWrappedAsyncKvLogStore(FakeKvLogStore()),
      );
      await files.storeFile('small', Uint8List.fromList([1, 2]));
      expect(
        await files.loadFiles(['small'], maxBytesPerFile: 0x7fffffffffffffff),
        [
          [1, 2],
        ],
      );
    },
  );
}
