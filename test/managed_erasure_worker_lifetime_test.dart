import 'dart:async';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/worker_death.dart';

void _peer(SendPort boot) {
  final requests = ReceivePort();
  boot.send(requests.sendPort);
  requests.listen((dynamic request) {
    final reply = ReceivePort();
    (request.admission as SendPort).send(reply.sendPort);
    reply.listen((_) {});
  });
}

void main() {
  test(
    'worker death and close both retain accepted UI cleanup until it settles',
    () async {
      final boot = ReceivePort(), watch = WorkerDeath();
      final isolate = await Isolate.spawn(
        _peer,
        boot.sendPort,
        onExit: watch.exitPort.sendPort,
        onError: watch.errorPort.sendPort,
        errorsAreFatal: true,
      );
      final entered = Completer<void>(), release = Completer<void>();
      Future<Object?>? removing, closing;
      try {
        final port = await watch.race(boot.first) as SendPort;
        final raw = WorkerKvLogStore.overWorker(
          isolate: isolate,
          toWorker: port,
          watch: watch,
        );
        final actor = ManagedErasureWorker.overWorkerForTesting(
          '/private/tmp/xveil-erasure-protocol-only',
          raw,
        );
        var removed = false, closed = false;
        removing = actor
            .removeManagedFiles(
              retireScopes: () async {
                entered.complete();
                await release.future;
              },
            )
            .then<Object?>(
              (_) {
                removed = true;
                return null;
              },
              onError: (Object e) {
                removed = true;
                return e;
              },
            );
        await Future.any([
          entered.future,
          removing.then((_) => fail('Peer died before cleanup admission')),
        ]);
        isolate.kill(priority: Isolate.immediate);
        await expectLater(watch.future, throwsA(anything));
        closing = actor.close().then<Object?>(
          (_) {
            closed = true;
            return null;
          },
          onError: (Object e) {
            closed = true;
            return e;
          },
        );
        await Future<void>(() {});
        expect(removed, isFalse);
        expect(closed, isFalse);
        release.complete();
        expect(await removing, isA<ManagedWorkerFailure>());
        expect(await closing, isA<ManagedWorkerFailure>());
      } finally {
        if (!release.isCompleted) release.complete();
        await removing;
        await closing;
        watch.dispose();
        isolate.kill(priority: Isolate.immediate);
        boot.close();
      }
    },
  );
}
