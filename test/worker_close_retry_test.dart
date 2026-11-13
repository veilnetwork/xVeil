import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/worker_death.dart';

class _Release {
  const _Release(this.fail);
  final bool fail;
}

class _Barrier {
  const _Barrier(this.reply);
  final SendPort reply;
}

class _FailOnceStore extends FakeKvLogStore {
  _FailOnceStore(this.events);
  final SendPort events;
  int attempts = 0;
  @override
  void close() {
    events.send(++attempts);
    if (attempts == 1) {
      throw hv.HvException('Busy', 'synthetic native close refusal');
    }
    super.close();
  }
}

void _realServerWorker((SendPort, SendPort) args) {
  final (boot, events) = args;
  boot.send(WorkerKvLogStore.debugServeStore(_FailOnceStore(events)));
}

void _controlledWorker((SendPort, SendPort) args) {
  final (boot, events) = args;
  final requests = ReceivePort();
  boot.send(requests.sendPort);
  SendPort? pending;
  var count = 0;
  requests.listen((dynamic message) {
    if (message is _Release) {
      pending!.send(
        message.fail
            ? WorkerKvLogStore.debugFailureReply(
                'Busy',
                'synthetic close refusal',
              )
            : WorkerKvLogStore.debugSuccessReply(),
      );
      pending = null;
    } else if (message is _Barrier) {
      message.reply.send(count);
    } else {
      pending = message.reply as SendPort;
      events.send(++count);
    }
  });
}

void main() {
  late Isolate isolate;
  late SendPort port;
  late WorkerDeath watch;
  late WorkerKvLogStore store;
  late ReceivePort events;
  late StreamSubscription<dynamic> subscription;
  late List<int> seen;

  Future<int> barrier() async {
    final reply = ReceivePort();
    try {
      port.send(_Barrier(reply.sendPort));
      return await reply.first as int;
    } finally {
      reply.close();
    }
  }

  setUp(() async {
    seen = [];
    events = ReceivePort();
    subscription = events.listen((dynamic count) => seen.add(count as int));
    final boot = ReceivePort();
    watch = WorkerDeath();
    isolate = await Isolate.spawn(
      _controlledWorker,
      (boot.sendPort, events.sendPort),
      onExit: watch.exitPort.sendPort,
      onError: watch.errorPort.sendPort,
      errorsAreFatal: true,
    );
    port = await boot.first as SendPort;
    boot.close();
    store = WorkerKvLogStore.overWorker(
      isolate: isolate,
      toWorker: port,
      watch: watch,
    );
  });
  tearDown(() async {
    watch.dispose();
    isolate.kill(priority: Isolate.immediate);
    await subscription.cancel();
    events.close();
    WorkerKvLogStore.closeTimeout = const Duration(seconds: 5);
  });

  test(
    'failed close retains its owner and a retry actually reaches it',
    () async {
      final first = expectLater(store.close(), throwsA(isA<hv.HvException>()));
      expect(await barrier(), 1);
      port.send(const _Release(true));
      await first;
      expect(watch.debugWatching, isTrue);
      await expectLater(store.get(1, Uint8List(1)), throwsA(isA<StateError>()));
      final retry = store.close();
      expect(await barrier(), 2);
      port.send(const _Release(false));
      await retry;
      expect(watch.debugWatching, isFalse);
      expect(watch.debugWaitingCount, 0);
      await store.close();
    },
  );

  test('concurrent close waits for the same actual acknowledgement', () async {
    final first = store.close();
    var secondSettled = false;
    final second = store.close().whenComplete(() => secondSettled = true);
    expect(await barrier(), 1);
    expect(secondSettled, isFalse);
    port.send(const _Release(false));
    await Future.wait([first, second]);
    expect(watch.debugWaitingCount, 0);
  });

  test(
    'retry after timeout joins the live attempt instead of inventing success',
    () async {
      WorkerKvLogStore.closeTimeout = Duration.zero;
      await expectLater(store.close(), throwsA(isA<hv.HvException>()));
      expect(await barrier(), 1);
      await expectLater(store.close(), throwsA(isA<hv.HvException>()));
      expect(await barrier(), 1);
      expect(watch.debugWaitingCount, 1);
      port.send(const _Release(false));
      await store.debugLateClose;
      expect(watch.debugWatching, isFalse);
      await store.close();
    },
  );

  test(
    'a late refusal remains retryable without an extra death listener',
    () async {
      WorkerKvLogStore.closeTimeout = Duration.zero;
      await expectLater(store.close(), throwsA(isA<hv.HvException>()));
      expect(await barrier(), 1);
      port.send(const _Release(true));
      await store.debugLateClose;
      expect(watch.debugWatching, isTrue);
      expect(watch.debugWaitingCount, 0);
      WorkerKvLogStore.closeTimeout = const Duration(seconds: 5);
      final retry = store.close();
      expect(await barrier(), 2);
      port.send(const _Release(false));
      await retry;
      expect(watch.debugWatching, isFalse);
    },
  );

  test('worker death is never converted to success on a later close', () async {
    final closing = expectLater(store.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    isolate.kill(priority: Isolate.immediate);
    await closing;
    await expectLater(store.close(), throwsA(isA<hv.HvException>()));
    expect(watch.debugWatching, isFalse);
  });

  test(
    'production command server retains a store whose close failed',
    () async {
      final boot = ReceivePort();
      final attempts = ReceivePort();
      final iterator = StreamIterator(attempts);
      final realWatch = WorkerDeath();
      final realWorker = await Isolate.spawn(
        _realServerWorker,
        (boot.sendPort, attempts.sendPort),
        onExit: realWatch.exitPort.sendPort,
        onError: realWatch.errorPort.sendPort,
        errorsAreFatal: true,
      );
      try {
        final realPort = await boot.first as SendPort;
        final realStore = WorkerKvLogStore.overWorker(
          isolate: realWorker,
          toWorker: realPort,
          watch: realWatch,
        );
        final failed = expectLater(
          realStore.close(),
          throwsA(isA<hv.HvException>().having((e) => e.kind, 'kind', 'Busy')),
        );
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current, 1);
        await failed;
        expect(realWatch.debugWatching, isTrue);
        final retry = realStore.close();
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current, 2);
        await retry;
        expect(realWatch.debugWatching, isFalse);
      } finally {
        realWatch.dispose();
        realWorker.kill(priority: Isolate.immediate);
        boot.close();
        await iterator.cancel();
        attempts.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
