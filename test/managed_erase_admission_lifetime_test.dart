import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/worker_death.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/storage_protection.dart';

/// Protocol-only peer. Native authentication is covered separately by the real
/// catalog-worker cases; this peer asks for UI work and never acknowledges RPC.
void _peer(SendPort boot) {
  final requests = ReceivePort();
  boot.send(requests.sendPort);
  requests.listen((dynamic request) {
    final reply = ReceivePort();
    (request.beforeErase as SendPort).send(reply.sendPort);
    reply.listen((_) {});
  });
}

void main() {
  test(
    'worker death cannot release an erase caller before accepted UI cleanup settles',
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
      Future<Object?>? attempt;
      try {
        final port = await watch.race(boot.first) as SendPort;
        final raw = WorkerKvLogStore.overWorker(
          isolate: isolate,
          toWorker: port,
          watch: watch,
        );
        final actor = ManagedCatalogWorker.overWorkerForTesting(raw);
        var finished = false;
        final keys = Uint8List(64)..fillRange(0, 64, 7);
        attempt = actor
            .erase(
              ManagedIdentityEntry(
                id: ManagedIdentityId('1' * 32),
                protection: StorageProtection.encrypted,
              ),
              keys: keys,
              beforeErase: () async {
                entered.complete();
                await release.future;
              },
            )
            .then<Object?>(
              (_) {
                finished = true;
                return null;
              },
              onError: (Object error) {
                finished = true;
                return error;
              },
            );
        await Future.any<void>([
          entered.future,
          attempt.then<void>(
            (_) => throw StateError('worker ended before UI admission'),
          ),
        ]);
        isolate.kill(priority: Isolate.immediate);
        await expectLater(watch.future, throwsA(isA<hv.HvException>()));
        await Future<void>(() {});
        expect(
          finished,
          isFalse,
          reason:
              'RPC death is not a witness that the accepted OS cleanup finished',
        );
        release.complete();
        expect(await attempt, isA<hv.HvException>());
        expect(
          keys,
          everyElement(7),
          reason: 'the caller keeps its own borrowed credential bytes',
        );
        await expectLater(actor.close(), throwsA(isA<hv.HvException>()));
      } finally {
        if (!release.isCompleted) release.complete();
        await attempt;
        watch.dispose();
        isolate.kill(priority: Isolate.immediate);
        boot.close();
      }
    },
  );
}
