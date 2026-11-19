@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/worker_death.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';

void _unexpectedWorker((SendPort, ReceivePort) args) {
  throw StateError('an unsendable message started a worker');
}

void main() {
  test('closing during a refused isolate launch confirms release', () async {
    final releaseLaunch = Completer<void>();
    final unsendable = ReceivePort();
    WorkerMultiSpaceBacking.debugBringUpWorker = (_, _) async {
      await releaseLaunch.future;
      await WorkerDeath.spawn(
        _unexpectedWorker,
        (reply) => (reply, unsendable),
        worker: 'multi-space worker',
      );
      throw StateError('an unsendable message started a worker');
    };
    addTearDown(() {
      WorkerMultiSpaceBacking.debugBringUpWorker = null;
      unsendable.close();
    });
    final backing = WorkerMultiSpaceBacking('unused');
    final opening = expectLater(
      backing.openSpace(Uint8List(64)),
      throwsA(isA<StorageWorkerSpawnFailure>()),
    );
    final closing = expectLater(backing.close(), completes);
    releaseLaunch.complete();
    await opening;
    await closing;
    await backing.close();
  });

  test(
    'an explicit native bootstrap refusal has no backing to retire',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-multi-open-refusal-',
      );
      final file = File('${fixture.path}/absent.hv');
      final backing = WorkerMultiSpaceBacking(file.path);
      try {
        await expectLater(
          backing.openSpace(Uint8List(64)),
          throwsA(isA<hv.HvException>()),
        );
        await backing.close();
        await backing.close();
        expect(file.existsSync(), isFalse);
        expect(fixture.listSync(), isEmpty);
      } finally {
        await backing.close();
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
