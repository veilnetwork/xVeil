import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/worker_death.dart';

class _Release {
  const _Release(this.fail);
  final bool? fail;
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
        message.fail == null
            ? true
            : message.fail!
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
  final arrivals = <int, Completer<void>>{};

  Future<void> arrived(int count) {
    if (seen.contains(count)) return Future.value();
    return (arrivals[count] ??= Completer<void>()).future;
  }

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
    arrivals.clear();
    events = ReceivePort();
    subscription = events.listen((dynamic count) {
      seen.add(count as int);
      arrivals.remove(count)?.complete();
    });
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

  test('an unknown acknowledgement does not prove release', () async {
    final invalid = expectLater(store.close(), throwsA(isA<hv.HvException>()));
    expect(await barrier(), 1);
    port.send(const _Release(null));
    await invalid;
    expect(watch.debugWatching, isTrue);
    final retry = store.close();
    expect(await barrier(), 2);
    port.send(const _Release(false));
    await retry;
    expect(watch.debugWatching, isFalse);
  });

  test(
    'failed bootstrap ownership blocks another open until release is confirmed',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'xveil-worker-retirement-',
      );
      final profile = '${temporary.path}/profile';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      final id = ManagedIdentityId('1' * 32);
      try {
        expect(ManagedWorkerIdentity.debugRetiringOwnerCount, 0);
        final first = expectLater(
          ManagedWorkerIdentity.debugFailedBootstrap(
            profileDirectory: profile,
            id: id,
            owner: store,
          ),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        await arrived(1);
        port.send(const _Release(true));
        await first;
        expect(ManagedWorkerIdentity.debugRetiringOwnerCount, 1);
        final blocked = expectLater(
          ManagedWorkerIdentity.openUnencrypted(
            profileDirectory: '$profile/.',
            id: id,
          ),
          throwsA(
            isA<ManagedWorkerFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedWorkerFailureKind.busy,
            ),
          ),
        );
        await arrived(2);
        expect(Directory(profile).listSync(), isEmpty);
        port.send(const _Release(true));
        await blocked;
        expect(ManagedWorkerIdentity.debugRetiringOwnerCount, 1);
        final released = expectLater(
          ManagedWorkerIdentity.openUnencrypted(
            profileDirectory: '$profile/',
            id: id,
          ),
          throwsA(
            isA<ManagedWorkerFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedWorkerFailureKind.missing,
            ),
          ),
        );
        await arrived(3);
        expect(Directory(profile).listSync(), isEmpty);
        port.send(const _Release(false));
        await released;
        expect(ManagedWorkerIdentity.debugRetiringOwnerCount, 0);
        expect(watch.debugWatching, isFalse);
        expect(Directory(profile).listSync(), isEmpty);
      } finally {
        temporary.deleteSync(recursive: true);
      }
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
