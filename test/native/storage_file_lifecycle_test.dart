import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

import '../support/timed_native_store.dart';

class _HeldNativeStore extends TimedNativeStore {
  _HeldNativeStore(AsyncKvLogStore store)
    : super(store, Stopwatch()..start(), (_) {});

  final entered = Completer<void>();
  final release = Completer<void>();
  bool holdNext = false;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    if (holdNext &&
        namespace == Ns.settings &&
        utf8.decode(key).startsWith('file:')) {
      holdNext = false;
      entered.complete();
      await release.future;
    }
    return super.get(namespace, key);
  }
}

void main() {
  final nativePath = Platform.environment['XVEIL_HV_DYLIB'];
  for (final erase in [false, true]) {
    test(
      'native accepted files settle before ${erase ? 'erase' : 'close/reopen'}',
      () async {
        expect(ensureHiddenVolumeLoaded(dylibPath: nativePath), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-native-file-life-',
        );
        final password = Uint8List.fromList(utf8.encode('native-test-fixture'));
        final paths = ['${dir.path}/a.hv', '${dir.path}/b.hv'];
        final raw = [
          for (final path in paths)
            HvKvLogStore(
              hv.HvSpace.create(
                path: path,
                password: password,
                argon: hv.ArgonPreset.light,
              ),
            ),
        ];
        FileStore(raw[0]).storeFile('victim', Uint8List.fromList([1]));
        FileStore(raw[1]).storeFile('victim', Uint8List.fromList([2]));
        for (final store in raw) {
          store.close();
        }
        // Exercise the ordinary worker-backed adapter and its exclusive
        // native container lock, not only an inline Future around native IO.
        final a = _HeldNativeStore(
          (await workerSpaceOpener(paths[0])(
            password: password,
            create: false,
          ))!,
        );
        final b = _HeldNativeStore(
          (await workerSpaceOpener(paths[1])(
            password: password,
            create: false,
          ))!,
        );
        final storage = HiddenVolumeStorage.async(
          ({required password, required create}) async =>
              utf8.decode(password) == 'a' ? a : b,
        );
        try {
          expect(await storage.open(password: 'a'), isTrue);
          a.holdNext = true;
          final writing = storage.storeFile(
            'accepted',
            Uint8List.fromList([3]),
          );
          await a.entered.future;
          final piece = storage.storeFilePiece(
            'accepted-piece',
            0,
            1,
            1,
            1,
            Uint8List.fromList([4]),
          );
          final deleting = storage.deleteStoredFile('victim');
          final maintenance = erase ? storage.eraseSpace() : storage.close();
          final late = expectLater(
            storage.storeFile('refused', Uint8List.fromList([5])),
            throwsStateError,
          );
          final opening = erase
              ? Future<bool>.value(true)
              : storage.open(password: 'b');
          a.release.complete();
          await Future.wait([
            writing,
            piece,
            deleting,
            maintenance,
            late,
            opening,
          ]);
          expect(await storage.loadFile('accepted'), isNull);
          expect(await storage.loadFile('accepted-piece'), isNull);
          expect(await storage.loadFile('refused'), isNull);
          expect(await storage.loadFile('victim'), erase ? isNull : [2]);
          await storage.close();
          if (erase) await b.close();

          // Reopen actual native storage to inspect durable results, not a view
          // kept alive by the gate adapter after its original handle closed.
          final reopened = HvKvLogStore(
            hv.HvSpace.open(path: paths[0], password: password),
          );
          try {
            final files = AsyncFileStore(SyncWrappedAsyncKvLogStore(reopened));
            expect(await files.loadFile('accepted'), erase ? isNull : [3]);
            expect(
              await files.loadFile('accepted-piece'),
              erase ? isNull : [4],
            );
            expect(await files.loadFile('victim'), isNull);
          } finally {
            reopened.close();
          }
        } finally {
          if (!a.release.isCompleted) a.release.complete();
          await storage.close();
          // Native handles are idempotently closed on every assertion path.
          await a.close();
          await b.close();
          password.fillRange(0, password.length, 0);
          await dir.delete(recursive: true);
        }
      },
      skip: nativePath == null || nativePath.isEmpty
          ? 'set XVEIL_HV_DYLIB to a verified libhidden_volume_ffi'
          : false,
    );
  }
}
