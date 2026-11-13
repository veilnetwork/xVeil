@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/worker_death.dart';
import 'package:xveil/domain/storage_usage.dart';

class _Store extends FakeKvLogStore implements StorageUsageSource {
  _Store(this.events);
  final SendPort events;
  final gate = Completer<void>();
  bool busy = false;
  int touches = 0;
  @override
  Future<StorageUsage> storageUsage() async {
    busy = true;
    events.send('started');
    try {
      await gate.future;
      return const StorageUsage(
        dataBytes: 17,
        blobBytes: 5,
        metadataBytes: 3,
        otherBytes: 0,
        files: 4,
        unrecognizedEntries: 0,
      );
    } finally {
      busy = false;
    }
  }

  void _check() {
    if (busy) {
      touches++;
      throw StateError('fixture inventory is active');
    }
  }

  @override
  Uint8List? get(int namespace, Uint8List key) {
    _check();
    return super.get(namespace, key);
  }

  @override
  int commit(List<KvLogOp> ops) {
    _check();
    return super.commit(ops);
  }

  @override
  void close() {
    _check();
    super.close();
  }
}

void _fixture((SendPort, SendPort, bool) args) {
  final (boot, events, enabled) = args;
  final raw = _Store(events);
  final control = ReceivePort();
  control.listen((dynamic command) {
    final (SendPort reply, bool release) = command as (SendPort, bool);
    if (release && !raw.gate.isCompleted) raw.gate.complete();
    reply.send(raw.touches);
  });
  boot.send((
    WorkerKvLogStore.debugServeStore(enabled ? raw : FakeKvLogStore()),
    control.sendPort,
  ));
}

void main() {
  for (final close in [false, true]) {
    test(
      'inventory serializes ${close ? 'close, including timeout' : 'reads and writes'}',
      () async {
        final boot = ReceivePort(), events = ReceivePort();
        final watch = WorkerDeath();
        final isolate = await Isolate.spawn(
          _fixture,
          (boot.sendPort, events.sendPort, true),
          errorsAreFatal: true,
          onExit: watch.exitPort.sendPort,
          onError: watch.errorPort.sendPort,
        );
        final (port, control) = await boot.first as (SendPort, SendPort);
        boot.close();
        final worker = WorkerKvLogStore.overWorker(
          isolate: isolate,
          toWorker: port,
          watch: watch,
        );
        Future<int> inspect({bool release = false}) async {
          final reply = ReceivePort();
          try {
            control.send((reply.sendPort, release));
            return await reply.first as int;
          } finally {
            reply.close();
          }
        }

        try {
          final usage = worker.storageUsage();
          expect(await events.first, 'started');
          if (close) {
            WorkerKvLogStore.closeTimeout = Duration.zero;
            await expectLater(worker.close(), throwsA(isA<hv.HvException>()));
            expect(await inspect(), 0);
            expect(watch.debugWatching, isTrue);
            await inspect(release: true);
            expect((await usage)!.totalBytes, 25);
            await worker.debugLateClose;
            expect(watch.debugWatching, isFalse);
          } else {
            final key = Uint8List.fromList([1]),
                value = Uint8List.fromList([2]);
            final writing = worker.commit([PutOp(1, key, value)]);
            final reading = worker.get(1, key);
            expect(await inspect(), 0);
            await inspect(release: true);
            expect((await usage)!.totalBytes, 25);
            await writing;
            expect(await reading, value);
            expect(await inspect(), 0);
          }
        } finally {
          WorkerKvLogStore.closeTimeout = const Duration(seconds: 5);
          if (watch.debugWatching) {
            await inspect(release: true);
            await worker.close();
          }
          watch.dispose();
          isolate.kill(priority: Isolate.immediate);
          events.close();
        }
      },
    );
  }

  test('legacy wrappers explicitly report unsupported accounting', () async {
    final storage = SyncWrappedAsyncKvLogStore(FakeKvLogStore());
    expect(await storage.storageUsage(), isNull);
    await storage.close();
  });
}
