import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';

Future<({bool released, String? failure, bool reopenedOnWorker})> _probe(
  bool useKeys,
  String expectedError,
) async {
  if (!ensureHiddenVolumeLoaded()) {
    throw StateError('native storage library unavailable');
  }
  final fixture = Directory.systemTemp.createTempSync('xveil-busy-handoff-');
  final path = '${fixture.path}/fixture.hv';
  final password = Uint8List.fromList(List.filled(24, 7));
  final old = hv.HvSpace.create(
    path: path,
    password: password,
    argon: hv.ArgonPreset.min,
  );
  final keys = old.spaceKeys();
  final absent = expectedError == 'Io';
  final displaced = File('$path.displaced');
  if (absent) {
    old.close();
    File(path).renameSync(displaced.path);
  }
  final openWithPassword = workerSpaceOpener(path);
  final openWithKeys = workerKeysSpaceOpener(path);
  Future<AsyncKvLogStore?> open() => useKeys
      ? openWithKeys(keys)
      : openWithPassword(password: password, create: false);

  var released = false;
  String? failure;
  try {
    try {
      final store = await runZoned(
        open,
        zoneSpecification: ZoneSpecification(
          runBinary:
              <R, T1, T2>(
                Zone self,
                ZoneDelegate parent,
                Zone zone,
                R Function(T1, T2) callback,
                T1 first,
                T2 second,
              ) {
                // Restore the file after the first native error reaches the
                // opener and before it can try again in the calling isolate.
                if (!released &&
                    first is hv.HvException &&
                    first.kind == expectedError) {
                  if (absent) {
                    displaced.renameSync(path);
                  } else {
                    old.close();
                  }
                  released = true;
                }
                return parent.runBinary(zone, callback, first, second);
              },
        ),
      );
      await store?.close();
    } on hv.HvException catch (error) {
      failure = error.kind;
    }
    final reopened = await open();
    try {
      return (
        released: released,
        failure: failure,
        reopenedOnWorker: reopened is WorkerKvLogStore,
      );
    } finally {
      await reopened?.close();
    }
  } finally {
    if (!absent && !released) old.close();
    fixture.deleteSync(recursive: true);
  }
}

void main() {
  for (final useKeys in [false, true]) {
    for (final failure in ['Busy', 'Io']) {
      test(
        'native $failure keeps the ${useKeys ? 'keys' : 'password'} opener off the UI isolate',
        () async {
          final result = await Isolate.run(() => _probe(useKeys, failure));
          expect(
            result.released,
            isTrue,
            reason: 'native $failure reached the opener',
          );
          expect(result, (
            released: true,
            failure: failure,
            reopenedOnWorker: true,
          ));
        },
      );
    }
  }
}
