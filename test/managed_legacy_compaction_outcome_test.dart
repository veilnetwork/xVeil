import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/worker_death.dart';

void _dieWithoutAnswer(SendPort boot) {
  final requests = ReceivePort();
  boot.send(requests.sendPort);
  requests.listen((_) => Isolate.exit());
}

void main() {
  test(
    'worker death without publication reply is an uncertain bounded outcome',
    () async {
      final boot = ReceivePort();
      final watch = WorkerDeath();
      final isolate = await Isolate.spawn(
        _dieWithoutAnswer,
        boot.sendPort,
        onExit: watch.exitPort.sendPort,
        onError: watch.errorPort.sendPort,
        errorsAreFatal: true,
      );
      final port = await boot.first as SendPort;
      boot.close();
      final store = WorkerKvLogStore.overWorker(
        isolate: isolate,
        toWorker: port,
        watch: watch,
      );
      final worker = ManagedLegacyCompactionWorker.overWorkerForTesting(
        'disposable-compaction-fixture',
        store,
      );
      try {
        await expectLater(
          worker.run(beforePublication: () async {}),
          throwsA(
            isA<ManagedLegacyCompactionFailure>()
                .having(
                  (e) => e.mayHaveApplied,
                  'uncertain publication',
                  isTrue,
                )
                .having((e) => e.recovery, 'no recovery witness', isNull)
                .having(
                  (e) => e.toString(),
                  'bounded outcome',
                  isNot(contains('storage worker')),
                ),
          ),
        );
        // This fake owns no native handles. Still require the actual production
        // close protocol to report death rather than claim native release.
        await expectLater(store.close(), throwsA(isA<hv.HvException>()));
      } finally {
        isolate.kill(priority: Isolate.immediate);
        watch.dispose();
      }
    },
  );
}
