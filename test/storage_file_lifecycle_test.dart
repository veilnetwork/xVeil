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

class _HeldFileStore extends SyncWrappedAsyncKvLogStore {
  _HeldFileStore(this.raw) : super(raw);

  final FakeKvLogStore raw;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool holdNext = false;
  bool closed = false;
  bool failPublication = false;
  bool failErase = false;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    if (holdNext &&
        namespace == Ns.settings &&
        utf8.decode(key).startsWith('file:')) {
      holdNext = false;
      entered.complete();
      await release.future;
    }
    if (closed) throw StateError('closed fixture store');
    return super.get(namespace, key);
  }

  @override
  Future<int> commit(List<KvLogOp> ops) {
    if (closed) return Future.error(StateError('closed fixture store'));
    if (failPublication &&
        ops.whereType<PutOp>().any(
          (op) => utf8.decode(op.key).startsWith('file:'),
        )) {
      failPublication = false;
      return Future.error(StateError('refused fixture publication'));
    }
    return super.commit(ops);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }

  @override
  Future<int> eraseNamespace(int namespace) {
    if (failErase) {
      failErase = false;
      return Future.error(StateError('refused fixture erase'));
    }
    return super.eraseNamespace(namespace);
  }
}

Future<String> _outcome(Future<void> work) =>
    work.then((_) => 'ok', onError: (_) => 'error');

void main() {
  test('queued file writes and deletes cannot cross a close/reopen', () async {
    final a = _HeldFileStore(FakeKvLogStore());
    final b = _HeldFileStore(FakeKvLogStore());
    FileStore(a.raw).storeFile('victim', Uint8List.fromList([1]));
    FileStore(b.raw).storeFile('victim', Uint8List.fromList([2]));
    final storage = HiddenVolumeStorage.async(
      ({required password, required create}) async =>
          utf8.decode(password) == 'a' ? a : b,
    );
    expect(await storage.open(password: 'a'), isTrue);
    a.holdNext = true;
    final first = _outcome(
      storage.storeFile('old-file', Uint8List.fromList([3])),
    );
    await a.entered.future;
    final piece = _outcome(
      storage.storeFilePiece('old-piece', 0, 1, 1, 1, Uint8List.fromList([4])),
    );
    final deletion = _outcome(storage.deleteStoredFile('victim'));
    final closing = storage.close();
    var reopened = false;
    final opening = storage.open(password: 'b').then((ok) {
      reopened = ok;
    });
    await Future<void>.delayed(Duration.zero);
    final reopenedBeforeRelease = reopened;
    a.release.complete();
    final outcomes = await Future.wait([first, piece, deletion]);
    await closing;
    await opening;
    try {
      expect(await storage.loadFile('old-piece'), isNull);
      expect(await storage.loadFile('old-file'), isNull);
      expect(await storage.loadFile('victim'), [2]);
      expect(reopenedBeforeRelease, isFalse);
      expect(outcomes, everyElement('ok'));
      expect(FileStore(a.raw).loadFile('old-file'), [3]);
      expect(
        await AsyncFileStore(
          SyncWrappedAsyncKvLogStore(a.raw),
        ).loadFile('old-piece'),
        [4],
      );
      expect(FileStore(a.raw).loadFile('victim'), isNull);
    } finally {
      await storage.close();
    }
  });

  test('erase waits for accepted files and does not resurrect them', () async {
    final a = _HeldFileStore(FakeKvLogStore());
    final storage = HiddenVolumeStorage.fromAsyncStore(a);
    a.holdNext = true;
    final first = _outcome(
      storage.storeFile('before', Uint8List.fromList([5])),
    );
    await a.entered.future;
    final piece = _outcome(
      storage.storeFilePiece(
        'before-piece',
        0,
        1,
        1,
        1,
        Uint8List.fromList([6]),
      ),
    );
    final erasing = storage.eraseSpace();
    final late = _outcome(storage.storeFile('late', Uint8List.fromList([7])));
    await Future<void>.delayed(Duration.zero);
    a.release.complete();
    final outcomes = await Future.wait([first, piece, late]);
    await erasing;
    try {
      expect(await storage.loadFile('before'), isNull);
      expect(await storage.loadFile('before-piece'), isNull);
      expect(await storage.loadFile('late'), isNull);
      expect(outcomes, ['ok', 'ok', 'error']);
      expect(a.raw.count(Ns.fileChunks), 0);
    } finally {
      await storage.close();
    }
  });

  test(
    'a failed accepted file does not poison close or its queued successor',
    () async {
      final a = _HeldFileStore(FakeKvLogStore());
      final storage = HiddenVolumeStorage.fromAsyncStore(a);
      a.holdNext = true;
      final first = _outcome(
        storage.storeFile('failed', Uint8List.fromList([8])),
      );
      await a.entered.future;
      final second = _outcome(
        storage.storeFile('kept', Uint8List.fromList([9])),
      );
      a.failPublication = true;
      final closing = storage.close();
      final late = _outcome(storage.deleteStoredFile('kept'));
      a.release.complete();
      expect(await first, 'error');
      expect(await second, 'ok');
      expect(await late, 'error');
      await closing;
      expect(a.closed, isTrue);
      expect(storage.isOpen, isFalse);
      expect(FileStore(a.raw).loadFile('kept'), [9]);
    },
  );

  test(
    'erase includes ciphertext created by an accepted queued disk piece',
    () async {
      final dir = await Directory.systemTemp.createTemp('xveil-file-erase-');
      final a = _HeldFileStore(FakeKvLogStore());
      final storage = HiddenVolumeStorage.fromAsyncStore(a);
      storage.useOnDiskTier(dir, minBytes: 0);
      a.holdNext = true;
      final first = _outcome(
        storage.storeFile('gate', Uint8List.fromList([1])),
      );
      await a.entered.future;
      final piece = _outcome(
        storage.storeFilePiece(
          'disk-piece',
          0,
          1,
          2,
          2,
          Uint8List.fromList([2, 3]),
        ),
      );
      final erasing = storage.eraseSpace();
      await Future<void>.delayed(Duration.zero);
      a.release.complete();
      await Future.wait([first, piece, erasing]);
      try {
        expect(await storage.hasFile('disk-piece'), isFalse);
        expect(
          await dir.list(recursive: true).where((e) => e is File).toList(),
          isEmpty,
        );
      } finally {
        await storage.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('a failed erase releases the file fence for recovery', () async {
    final a = _HeldFileStore(FakeKvLogStore());
    final storage = HiddenVolumeStorage.fromAsyncStore(a);
    a.failErase = true;
    await expectLater(storage.eraseSpace(), throwsStateError);
    try {
      await storage.storeFile('recovered', Uint8List.fromList([10]));
      expect(await storage.loadFile('recovered'), [10]);
    } finally {
      await storage.close();
    }
  });
}
