import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';

typedef _WorkerFixture = ({
  SendPort ready,
  String path,
  Uint8List keys,
  bool multi,
});

final _key = Uint8List.fromList([1]);
final _value = Uint8List.fromList([2]);

Future<void> _openFixture(_WorkerFixture fixture) async {
  final Future<int> Function(List<KvLogOp>) commit;
  if (fixture.multi) {
    final store = WorkerMultiSpaceBacking(fixture.path);
    final id = await store.openSpace(fixture.keys);
    commit = (ops) => store.commit(id, ops);
  } else {
    final store = await WorkerKvLogStore.openWithKeys(
      path: fixture.path,
      keys: fixture.keys,
      paddingPreset: hv.PaddingPreset.bucket256KiB,
    );
    commit = store!.commit;
  }
  final retire = ReceivePort();
  fixture.ready.send(retire.sendPort);
  await retire.first;
  retire.close();
  unawaited(commit([PutOp(1, _key, _value)]));
  // Let the multi-space proxy send the request after its ready future. The
  // fixture exits without waiting for the worker's reply or calling close.
  await Future<void>.delayed(Duration.zero);
  Isolate.exit();
}

void main() {
  for (final multi in [false, true]) {
    test(
      '${multi ? 'multi' : 'single'} worker drains writes on owner exit',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-owner-exit-',
        );
        final path = '${fixture.path}/test.hv';
        final space = hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList(List.filled(24, 7)),
          argon: hv.ArgonPreset.min,
        );
        final keys = space.spaceKeys();
        space.close();
        hv.HvSpace open() => hv.HvSpace.openWithKeys(path: path, keys: keys);
        final ready = ReceivePort();
        final exited = ReceivePort();
        final owner = await Isolate.spawn(_openFixture, (
          ready: ready.sendPort,
          path: path,
          keys: keys,
          multi: multi,
        ), onExit: exited.sendPort);
        try {
          final retire =
              await ready.first.timeout(const Duration(seconds: 5)) as SendPort;
          expect(
            () => open().close(),
            throwsA(
              isA<hv.HvException>().having(
                (error) => error.kind,
                'kind',
                'Busy',
              ),
            ),
          );
          retire.send(null);
          await exited.first.timeout(const Duration(seconds: 5));
          final limit = Stopwatch()..start();
          while (true) {
            try {
              final reopened = open();
              try {
              expect(reopened.get(1, _key), _value);
              } finally {
                reopened.close();
              }
              break;
            } on hv.HvException catch (error) {
              if (error.kind != 'Busy' ||
                  limit.elapsed > const Duration(seconds: 3)) {
                rethrow;
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          }
        } finally {
          owner.kill(priority: Isolate.immediate);
          ready.close();
          exited.close();
          fixture.deleteSync(recursive: true);
        }
      },
    );
  }
}
