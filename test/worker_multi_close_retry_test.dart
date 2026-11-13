@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart'
    show WorkerKvLogStore;
import 'package:xveil/data/storage/worker_death.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';

import 'support/fake_multi_space.dart';

class _Release {
  const _Release(this.fail);
  final bool? fail;
}

class _Barrier {
  const _Barrier(this.reply);
  final SendPort reply;
}

class _Die {
  const _Die();
}

class _Invalid {
  const _Invalid(this.foreign);
  final bool foreign;
}

void _controlled((SendPort, SendPort) args) {
  final (boot, events) = args;
  final rx = ReceivePort();
  SendPort? pending;
  var count = 0;
  rx.listen((dynamic message) {
    if (message is _Invalid) {
      pending!.send(
        message.foreign
            ? WorkerKvLogStore.debugSuccessReply()
            : WorkerMultiSpaceBacking.debugSuccessReply(0),
      );
      pending = null;
    } else if (message is _Release) {
      pending!.send(
        message.fail == null
            ? true
            : message.fail!
            ? WorkerMultiSpaceBacking.debugFailureReply(
                'Busy',
                'synthetic refusal',
              )
            : WorkerMultiSpaceBacking.debugSuccessReply(),
      );
      pending = null;
    } else if (message is _Barrier) {
      message.reply.send(count);
    } else if (message is _Die) {
      rx.close();
      Isolate.current.kill(priority: Isolate.immediate);
    } else if (message.runtimeType.toString().contains('Close')) {
      pending = message.reply as SendPort;
      events.send(++count);
    } else {
      (message.reply as SendPort).send(
        WorkerMultiSpaceBacking.debugSuccessReply(0),
      );
    }
  });
  boot.send(rx.sendPort);
}

class _FailOnce extends FakeMultiSpaceBacking {
  _FailOnce(this.events);
  final SendPort events;
  var attempts = 0;
  @override
  void close() {
    events.send(++attempts);
    if (attempts == 1) throw hv.HvException('Busy', 'synthetic native refusal');
  }
}

void _realServer((SendPort, SendPort) args) {
  args.$1.send(WorkerMultiSpaceBacking.debugServeBacking(_FailOnce(args.$2)));
}

void main() {
  late WorkerMultiSpaceBacking backing;
  late LiveMultiSpaceWorker live;
  late ReceivePort events;
  late StreamIterator<dynamic> iterator;
  late Completer<void> publish;
  late int bringups;

  Future<int> barrier() async {
    final reply = ReceivePort();
    try {
      live.port.send(_Barrier(reply.sendPort));
      return await reply.first as int;
    } finally {
      reply.close();
    }
  }

  Future<void> spawn({bool real = false}) async {
    final boot = ReceivePort();
    final watch = WorkerDeath();
    final isolate = await Isolate.spawn(
      real ? _realServer : _controlled,
      (boot.sendPort, events.sendPort),
      onExit: watch.exitPort.sendPort,
      onError: watch.errorPort.sendPort,
      errorsAreFatal: true,
    );
    final port = await boot.first as SendPort;
    boot.close();
    live = (isolate: isolate, port: port, watch: watch);
    WorkerMultiSpaceBacking.debugBringUpWorker = (_, _) async {
      bringups++;
      await publish.future;
      return live;
    };
    backing = WorkerMultiSpaceBacking('/synthetic-unused');
  }

  Future<void> ready() async {
    publish.complete();
    expect(await backing.openSpace(Uint8List(64)), 0);
  }

  Future<void> arrived(int count) async {
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, count);
  }

  setUp(() async {
    bringups = 0;
    publish = Completer<void>();
    events = ReceivePort();
    iterator = StreamIterator(events);
    await spawn();
  });
  tearDown(() async {
    live.watch.dispose();
    live.isolate.kill(priority: Isolate.immediate);
    await iterator.cancel();
    events.close();
    WorkerMultiSpaceBacking.debugBringUpWorker = null;
    WorkerMultiSpaceBacking.closeTimeout = const Duration(seconds: 5);
  });

  test('refusal retains the owner and a retry reaches the worker', () async {
    await ready();
    final first = expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    live.port.send(const _Release(true));
    await first;
    expect(live.watch.debugWatching, isTrue);
    await expectLater(backing.openSpace(Uint8List(64)), throwsStateError);
    final retry = backing.close();
    expect(await barrier(), 2);
    live.port.send(const _Release(false));
    await retry;
    expect(live.watch.debugWatching, isFalse);
    expect(live.watch.debugWaitingCount, 0);
    await backing.close();
  });

  test('concurrent close waits for one actual acknowledgement', () async {
    await ready();
    final first = backing.close();
    var settled = false;
    final second = backing.close().whenComplete(() => settled = true);
    expect(await barrier(), 1);
    expect(settled, isFalse);
    live.port.send(const _Release(false));
    await Future.wait([first, second]);
  });

  test('timeout retries join the pending wire request', () async {
    await ready();
    WorkerMultiSpaceBacking.closeTimeout = Duration.zero;
    await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    expect(live.watch.debugWaitingCount, 1);
    live.port.send(const _Release(false));
    await backing.debugLateClose;
    await backing.close();
    expect(live.watch.debugWatching, isFalse);
  });

  test('late error is a refusal and stays retryable', () async {
    await ready();
    WorkerMultiSpaceBacking.closeTimeout = Duration.zero;
    await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    live.port.send(const _Release(true));
    await backing.debugLateClose;
    expect(live.watch.debugWatching, isTrue);
    expect(live.watch.debugWaitingCount, 0);
    WorkerMultiSpaceBacking.closeTimeout = const Duration(seconds: 5);
    final retry = backing.close();
    expect(await barrier(), 2);
    live.port.send(const _Release(false));
    await retry;
  });

  test('unknown acknowledgement cannot prove release', () async {
    await ready();
    final invalid = expectLater(
      backing.close(),
      throwsA(isA<hv.HvException>()),
    );
    expect(await barrier(), 1);
    live.port.send(const _Release(null));
    await invalid;
    expect(live.watch.debugWatching, isTrue);
    final retry = backing.close();
    expect(await barrier(), 2);
    live.port.send(const _Release(false));
    await retry;
  });

  test('worker death remains an error on repeated close', () async {
    await ready();
    final first = expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    live.port.send(const _Die());
    await first;
    await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(live.watch.debugWatching, isFalse);
  });

  for (final foreign in [true, false]) {
    test(
      '${foreign ? 'foreign protocol' : 'nonempty payload'} is not a close witness',
      () async {
        await ready();
        final first = expectLater(
          backing.close(),
          throwsA(isA<hv.HvException>()),
        );
        expect(await barrier(), 1);
        live.port.send(_Invalid(foreign));
        await first;
        expect(live.watch.debugWatching, isTrue);
        final retry = backing.close();
        expect(await barrier(), 2);
        live.port.send(const _Release(false));
        await retry;
      },
    );
  }

  test('timeout during bootstrap retains its one cleanup attempt', () async {
    final opening = expectLater(
      backing.openSpace(Uint8List(64)),
      throwsStateError,
    );
    WorkerMultiSpaceBacking.closeTimeout = Duration.zero;
    await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 0);
    expect(bringups, 1);
    publish.complete();
    await arrived(1);
    live.port.send(const _Release(false));
    await backing.debugLateClose;
    await opening;
    await backing.close();
    expect(live.watch.debugWatching, isFalse);
  });

  test('closing a never-started backing does not bring up a worker', () async {
    await backing.close();
    await backing.close();
    expect(bringups, 0);
    expect(await barrier(), 0);
  });

  test(
    'an unwitnessed bootstrap failure cannot become a successful close',
    () async {
      WorkerMultiSpaceBacking.debugBringUpWorker = (_, _) async =>
          throw StateError('synthetic unwitnessed failure');
      await expectLater(backing.openSpace(Uint8List(64)), throwsStateError);
      await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
      await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
    },
  );

  test(
    'close during bootstrap reports a refused rollback and retains ownership',
    () async {
      final opening = expectLater(
        backing.openSpace(Uint8List(64)),
        throwsStateError,
      );
      final closed = expectLater(
        backing.close(),
        throwsA(isA<hv.HvException>()),
      );
      publish.complete();
      await arrived(1);
      live.port.send(const _Release(true));
      await closed;
      await opening;
      expect(live.watch.debugWatching, isTrue);
      final retry = backing.close();
      expect(await barrier(), 2);
      live.port.send(const _Release(false));
      await retry;
    },
  );

  test(
    'the production command server preserves a failed-close backing',
    () async {
      live.watch.dispose();
      live.isolate.kill(priority: Isolate.immediate);
      await spawn(real: true);
      await ready();
      await expectLater(backing.close(), throwsA(isA<hv.HvException>()));
      await arrived(1);
      expect(live.watch.debugWatching, isTrue);
      final reply = ReceivePort();
      try {
        live.port.send(
          WorkerMultiSpaceBacking.debugCountRequest(0, reply.sendPort),
        );
        final dynamic denied = await live.watch.race(reply.first);
        expect(denied.kind, 'Internal');
        expect(denied.message, 'storage worker is closing');
      } finally {
        reply.close();
      }
      await backing.close();
      await arrived(2);
      expect(live.watch.debugWatching, isFalse);
    },
  );
}
