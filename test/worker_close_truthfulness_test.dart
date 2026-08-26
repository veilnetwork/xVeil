import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/worker_death.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';

/// Three worker lifecycles, one rule, and only ONE of them followed it.
///
/// `WorkerKvLogStore.close` refuses to kill a worker that has not answered its
/// close, and says why: an isolate kill cannot unwind an FFI frame, so the
/// container handle — and its exclusive flock — would be stranded for the life
/// of the process. [WorkerMultiSpaceBacking] answered its own timeout with a
/// fabricated `_MOk` and killed the worker anyway, so a container that had NOT
/// closed reported a clean close to the caller and lost its handle in the deal.
///
/// What is pinned here is the report, not the internals: after a close the
/// worker never answers, the caller must be TOLD, and the worker must still be
/// alive to finish releasing the container.

Uint8List _keys(int seed) => Uint8List.fromList(List.filled(64, seed));

/// The stub's isolate + serving port, kept aside so a test can prove the worker
/// outlived a timed-out close. Production holds no such handle by design.
({Isolate isolate, SendPort port, WorkerDeath watch})? _lastStub;

Future<void> _pumpUntil(bool Function() ready, String what) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue, reason: 'never reached: $what');
}

void main() {
  setUp(() {
    // The wait is what is under test; five real seconds per case is not.
    WorkerMultiSpaceBacking.closeTimeout = const Duration(milliseconds: 150);
  });
  tearDown(() {
    WorkerMultiSpaceBacking.closeTimeout = const Duration(seconds: 5);
    WorkerMultiSpaceBacking.debugBringUpWorker = null;
    // A stub deliberately left running must not outlive its test. Stop
    // watching BEFORE the kill, or its exit is reported as a death nobody is
    // listening for, after the test has already finished.
    _lastStub?.watch.dispose();
    _lastStub?.isolate.kill(priority: Isolate.immediate);
    _lastStub = null;
  });

  test('a close the worker never answers is reported to the caller, and the '
      'worker is left ALIVE to finish releasing the container', () async {
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    // A worker stuck the way a real one gets stuck: inside a long synchronous
    // FFI op, with our close queued behind it. It never answers.
    WorkerMultiSpaceBacking.debugBringUpWorker = (path, tag) =>
        _spawnStubWorker(events.sendPort, answerClose: false);

    final backing = WorkerMultiSpaceBacking('/unused');
    final call = backing
        .openSpace(_keys(1))
        .then<Object>((_) => 'ok', onError: (Object e) => e);
    await _pumpUntil(() => seen.contains('call'), 'the worker being reachable');

    await expectLater(
      backing.close(),
      throwsA(isA<hv.HvException>()),
      reason:
          'the close timed out with the container lock still held, and the '
          'caller was handed a clean-close success anyway',
    );
    expect(seen, contains('close-requested'));

    // ...and the worker is STILL THERE. Killing it here is what strands the
    // native handle: the flock stays held by this process until it exits.
    seen.clear();
    _lastStub!.port.send(_Ping(events.sendPort));
    await _pumpUntil(
      () => seen.contains('call'),
      'the worker answering after the timeout (it was killed instead)',
    );
    await call;
  });

  test('CONTROL: a worker that DOES answer its close reports success and is '
      'shut down', () async {
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    WorkerMultiSpaceBacking.debugBringUpWorker = (path, tag) =>
        _spawnStubWorker(events.sendPort, answerClose: true);

    final backing = WorkerMultiSpaceBacking('/unused');
    final call = backing
        .openSpace(_keys(1))
        .then<Object>((_) => 'ok', onError: (Object e) => e);
    await _pumpUntil(() => seen.contains('call'), 'the worker being reachable');

    await backing.close(); // must NOT throw
    expect(seen, contains('close-requested'));
    await call;
  });

  // ── The single-space store: the same close, and the wait it did not race ──

  test('single-space: a close the worker never answers is reported too, and '
      'the worker is left alive', () async {
    WorkerKvLogStore.closeTimeout = const Duration(milliseconds: 150);
    addTearDown(
      () => WorkerKvLogStore.closeTimeout = const Duration(seconds: 5),
    );
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    final live = await _spawnStubWorker(events.sendPort, answerClose: false);
    final store = WorkerKvLogStore.overWorker(
      isolate: live.isolate,
      toWorker: live.port,
      watch: live.watch,
    );

    await expectLater(
      store.close(),
      throwsA(isA<hv.HvException>()),
      reason: 'the caller was told a still-locked container had closed',
    );
    expect(seen, contains('close-requested'));

    seen.clear();
    _lastStub!.port.send(_Ping(events.sendPort));
    await _pumpUntil(
      () => seen.contains('call'),
      'the worker answering after the timeout (it was killed instead)',
    );
  });

  test('single-space: a worker that DIES mid-close is reported at once, not '
      'after the whole timeout', () async {
    // The wait used to watch the reply alone: `errorsAreFatal` makes a crashed
    // worker die QUIETLY, so this burned the full timeout and then queued a
    // background drain for a reply that could never arrive — leaving the
    // watcher armed and its ports open for the life of the process.
    WorkerKvLogStore.closeTimeout = const Duration(seconds: 30);
    addTearDown(
      () => WorkerKvLogStore.closeTimeout = const Duration(seconds: 5),
    );
    final events = ReceivePort();
    addTearDown(events.close);

    final live = await _spawnStubWorker(
      events.sendPort,
      answerClose: false,
      dieOnClose: true,
    );
    final store = WorkerKvLogStore.overWorker(
      isolate: live.isolate,
      toWorker: live.port,
      watch: live.watch,
    );

    final sw = Stopwatch()..start();
    await expectLater(store.close(), throwsA(isA<hv.HvException>()));
    sw.stop();
    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 10)),
      reason:
          'the close sat on the reply alone while the worker was already dead',
    );
  });

  test('single-space CONTROL: a worker that answers its close is shut down '
      'cleanly', () async {
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    final live = await _spawnStubWorker(events.sendPort, answerClose: true);
    final store = WorkerKvLogStore.overWorker(
      isolate: live.isolate,
      toWorker: live.port,
      watch: live.watch,
    );
    await store.close(); // must NOT throw
    expect(seen, contains('close-requested'));
  });

  test('a request still in flight when the worker goes is TOLD, not left '
      'pending', () async {
    // report15 X15-M5. `close` sets the flag, sends `_MClose` and disposes the
    // death watcher. A request already sent then waited on a race nothing
    // could win: no reply, because the worker shut its receive path, and no
    // death either, because the watcher was gone. The future never completed,
    // and it was holding the caller\'s payload and the screen that asked.
    //
    // The defect HANGS rather than fails, so this carries its own deadline.
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    WorkerMultiSpaceBacking.debugBringUpWorker = (path, tag) =>
        _spawnStubWorker(
          events.sendPort,
          answerClose: true,
          answerCalls: false,
        );

    final backing = WorkerMultiSpaceBacking('/unused');
    final call = backing.openSpace(_keys(1));
    await _pumpUntil(() => seen.contains('call'), 'the worker receiving it');

    await backing.close();

    await expectLater(
      call.timeout(const Duration(seconds: 5)),
      throwsA(isA<StateError>()),
      reason: 'the request was left pending for the life of the process',
    );
  });

  test('CONTROL: a request the worker DID answer still succeeds', () async {
    // Vacuity guard. Failing every in-flight request at close would satisfy
    // the test above and break every ordinary call that finishes while the
    // app is shutting down.
    final events = ReceivePort();
    final seen = <String>[];
    events.listen((dynamic m) => seen.add('$m'));
    addTearDown(events.close);

    WorkerMultiSpaceBacking.debugBringUpWorker = (path, tag) =>
        _spawnStubWorker(events.sendPort, answerClose: true);

    final backing = WorkerMultiSpaceBacking('/unused');
    // Whatever it settles as — the stub answers with a bare `true`, which the
    // decoder rejects — the point is that it SETTLES, from the worker's reply
    // rather than from the close signal.
    final settled = await backing
        .openSpace(_keys(1))
        .then<Object>((v) => v, onError: (Object e) => e)
        .timeout(const Duration(seconds: 5));

    expect(
      settled,
      isNot(isA<StateError>()),
      reason: 'a request the worker answered was failed by the close instead',
    );
    await backing.close();
  });

}

class _Ping {
  const _Ping(this.reply);
  final SendPort reply;
}

Future<LiveMultiSpaceWorker> _spawnStubWorker(
  SendPort events, {
  required bool answerClose,
  bool dieOnClose = false,
  bool answerCalls = true,
}) async {
  final boot = ReceivePort();
  final death = WorkerDeath();
  final isolate = await Isolate.spawn<List<Object>>(
    _stubWorkerEntry,
    [boot.sendPort, events, answerClose, dieOnClose, answerCalls],
    errorsAreFatal: true,
    onExit: death.exitPort.sendPort,
    onError: death.errorPort.sendPort,
  );
  final port = await boot.first as SendPort;
  boot.close();
  _lastStub = (isolate: isolate, port: port, watch: death);
  return (isolate: isolate, port: port, watch: death);
}

void _stubWorkerEntry(List<Object> args) {
  final boot = args[0] as SendPort;
  final events = args[1] as SendPort;
  final answerClose = args[2] as bool;
  final dieOnClose = args[3] as bool;
  final answerCalls = args[4] as bool;
  final rx = ReceivePort();
  boot.send(rx.sendPort);
  rx.listen((dynamic msg) {
    // `reply` is a public field on the (library-private) request classes, so it
    // is reachable dynamically without importing them.
    final reply = (msg as dynamic).reply as SendPort;
    if (msg.runtimeType.toString().contains('Close')) {
      events.send('close-requested');
      if (dieOnClose) {
        // A worker that faults on the way out: quietly gone, no reply ever.
        rx.close();
        Isolate.current.kill(priority: Isolate.immediate);
        return;
      }
      if (!answerClose) return; // still inside the FFI, like the real thing
      reply.send(true);
      rx.close();
      Isolate.current.kill(priority: Isolate.immediate);
      return;
    }
    events.send('call');
    // A worker that received the request and will never answer it — the shape
    // a close leaves behind when it tears the worker down mid-request.
    if (!answerCalls) return;
    reply.send(true);
  });
}
