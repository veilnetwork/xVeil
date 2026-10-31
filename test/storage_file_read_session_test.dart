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

class _HeldMetadata extends SyncWrappedAsyncKvLogStore {
  _HeldMetadata(super.store);
  final entered = Completer<void>();
  final release = Completer<void>();
  bool hold = false;
  bool holdBody = false;
  String holdKey = 'ondisk:shared';
  int reads = 0;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    reads++;
    final result = await super.get(namespace, key);
    if (hold && namespace == Ns.settings && utf8.decode(key) == holdKey) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return result;
  }

  @override
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> ids) async {
    final result = await super.readLogBatch(namespace, ids);
    if (holdBody) {
      holdBody = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

Future<Object?> _read(HiddenVolumeStorage s, String method) => switch (method) {
  'load' => s.loadFile('shared'),
  'range' => s.readFileRange('shared', 0, 2),
  'size' => s.fileSize('shared'),
  'presence' => s.hasFile('shared'),
  'batch' => s.loadFiles(['shared'], maxBytesPerFile: 16),
  _ => throw ArgumentError(method),
};

void main() {
  for (final method in ['load', 'range', 'size', 'presence', 'batch']) {
    test('$method read cannot continue into a replacement identity', () async {
      final rawA = FakeKvLogStore(), rawB = FakeKvLogStore();
      FileStore(rawA).storeFile('shared', Uint8List.fromList([1, 2, 3]));
      FileStore(rawB).storeFile('shared', Uint8List.fromList([9, 8, 7, 6]));
      final a = _HeldMetadata(rawA), b = _HeldMetadata(rawB);
      final storage = HiddenVolumeStorage.async(
        ({required password, required create}) async =>
            utf8.decode(password) == 'a' ? a : b,
      );
      await storage.open(password: 'a');
      addTearDown(storage.close);
      a.hold = true;
      final old = _read(storage, method);
      final check = expectLater(old, throwsStateError);
      await a.entered.future;
      await storage.close();
      expect(await storage.open(password: 'b'), isTrue);
      b.reads = 0;
      a.release.complete();
      await check;
      expect(
        b.reads,
        0,
        reason: 'the old request must never query the new space',
      );
      expect(await storage.loadFile('shared'), [9, 8, 7, 6]);
    });
  }

  test(
    'a read spanning erase is invalid even when the store object stays the same',
    () async {
      final raw = FakeKvLogStore();
      FileStore(raw).storeFile('shared', Uint8List.fromList([1, 2, 3]));
      final held = _HeldMetadata(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(held);
      addTearDown(storage.close);
      held.hold = true;
      final check = expectLater(storage.loadFile('shared'), throwsStateError);
      await held.entered.future;
      await storage.eraseSpace();
      await storage.storeFile('shared', Uint8List.fromList([9, 8]));
      held.release.complete();
      await check;
      expect(await storage.loadFile('shared'), [9, 8]);
    },
  );

  test(
    'bytes read before close cannot finish in a replacement identity',
    () async {
      final rawA = FakeKvLogStore(), rawB = FakeKvLogStore();
      FileStore(rawA).storeFile('shared', Uint8List.fromList([1, 2, 3]));
      FileStore(rawB).storeFile('shared', Uint8List.fromList([9, 8]));
      final a = _HeldMetadata(rawA), b = _HeldMetadata(rawB);
      final storage = HiddenVolumeStorage.async(
        ({required password, required create}) async =>
            utf8.decode(password) == 'a' ? a : b,
      );
      await storage.open(password: 'a');
      addTearDown(storage.close);
      a.holdBody = true;
      final check = expectLater(storage.loadFile('shared'), throwsStateError);
      await a.entered.future;
      await storage.close();
      await storage.open(password: 'b');
      a.release.complete();
      await check;
      expect(await storage.loadFile('shared'), [9, 8]);
    },
  );

  test('an on-disk read cannot follow a replacement blob directory', () async {
    final directory = await Directory.systemTemp.createTemp('xv-read-tier-');
    addTearDown(() => directory.delete(recursive: true));
    final held = _HeldMetadata(FakeKvLogStore());
    final storage = HiddenVolumeStorage.fromAsyncStore(held);
    addTearDown(storage.close);
    storage.useOnDiskTier(Directory('${directory.path}/a'), minBytes: 1);
    await storage.storeFilePiece(
      'shared',
      0,
      1,
      3,
      3,
      Uint8List.fromList([1, 2, 3]),
    );
    held.hold = true;
    final check = expectLater(storage.loadFile('shared'), throwsStateError);
    await held.entered.future;
    storage.useOnDiskTier(Directory('${directory.path}/b'), minBytes: 1);
    held.release.complete();
    await check;
  });

  test('an unrelated pending write does not serialize file reads', () async {
    final raw = FakeKvLogStore();
    FileStore(raw).storeFile('shared', Uint8List.fromList([1, 2, 3]));
    final held = _HeldMetadata(raw);
    final storage = HiddenVolumeStorage.fromAsyncStore(held);
    addTearDown(storage.close);
    held.holdKey = 'file:pending';
    held.hold = true;
    final write = storage.storeFile('pending', Uint8List.fromList([4]));
    await held.entered.future;
    try {
      expect(await storage.loadFile('shared'), [1, 2, 3]);
    } finally {
      held.release.complete();
      await write;
    }
  });
}
