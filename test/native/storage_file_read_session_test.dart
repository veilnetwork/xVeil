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

class _ReadGate extends TimedNativeStore {
  _ReadGate(AsyncKvLogStore store) : super(store, Stopwatch()..start(), (_) {});
  final entered = Completer<void>();
  final release = Completer<void>();
  bool hold = false;
  int reads = 0;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    reads++;
    // Pause after the real worker has completed this exact metadata request.
    // Closing that worker can therefore finish while the Dart caller waits.
    final result = await super.get(namespace, key);
    if (hold &&
        namespace == Ns.settings &&
        utf8.decode(key) == 'ondisk:shared') {
      hold = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  for (final range in [false, true]) {
    test(
      'worker-backed ${range ? 'range' : 'whole-file'} read cannot enter a newly opened identity',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final directory = await Directory.systemTemp.createTemp(
          'xv-read-session-',
        );
        final password = Uint8List.fromList(utf8.encode('native-read-fixture'));
        final paths = ['${directory.path}/a.hv', '${directory.path}/b.hv'];
        for (var i = 0; i < paths.length; i++) {
          final raw = HvKvLogStore(
            hv.HvSpace.create(
              path: paths[i],
              password: password,
              argon: hv.ArgonPreset.light,
            ),
          );
          try {
            FileStore(raw).storeFile(
              'shared',
              Uint8List.fromList(i == 0 ? [1, 2, 3] : [9, 8, 7, 6]),
            );
          } finally {
            raw.close();
          }
        }
        final a = _ReadGate(
          (await workerSpaceOpener(paths[0])(
            password: password,
            create: false,
          ))!,
        );
        final b = _ReadGate(
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
          a.hold = true;
          final oldRead = range
              ? storage.readFileRange('shared', 0, 2)
              : storage.loadFile('shared');
          final rejected = expectLater(oldRead, throwsStateError);
          await a.entered.future;
          await storage.close();
          expect(await storage.open(password: 'b'), isTrue);
          b.reads = 0;
          a.release.complete();
          await rejected;
          expect(
            b.reads,
            0,
            reason:
                'old reads must never enqueue work on the replacement worker',
          );
          expect(await storage.loadFile('shared'), [9, 8, 7, 6]);
          await storage.close();
          // Verify the old container's exclusive native handle was released.
          final reopened = HvKvLogStore(
            hv.HvSpace.open(path: paths[0], password: password),
          );
          try {
            expect(FileStore(reopened).loadFile('shared'), [1, 2, 3]);
          } finally {
            reopened.close();
          }
        } finally {
          if (!a.release.isCompleted) a.release.complete();
          await storage.close();
          await a.close();
          await b.close();
          password.fillRange(0, password.length, 0);
          await directory.delete(recursive: true);
        }
      },
      skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
          ? false
          : 'set XVEIL_HV_DYLIB to a verified native library',
    );
  }
}
