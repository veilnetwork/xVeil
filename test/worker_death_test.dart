import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/worker_death.dart';

/// The storage worker runs in its own isolate, and every RPC used to
/// `await reply.first` with nothing watching that isolate. A worker that
/// crashed — an FFI fault, an uncaught error, an OOM kill — therefore left the
/// caller's future pending FOREVER: the UI showed a spinner no timeout would
/// end, and every later call joined it. `errorsAreFatal: true` made the isolate
/// die quietly; nothing was listening for the death (audit XV-07).
///
/// Two levels are covered here. The first group exercises the ISOLATE CONTRACT
/// the supervisor is built on — that `onExit`/`onError` fire and that racing a
/// pending reply against them converts an unbounded hang into an error. If Dart
/// ever stopped delivering these, the supervisor would silently stop working
/// and this is what would notice.
///
/// The second exercises [WorkerDeath] itself, which both the single-space store
/// and the all-online multi-space backing now share — the latter matters more,
/// because there ONE worker holds every hosted identity's store and its death
/// takes all of them down at once.
void _crashingWorker(SendPort _) {
  throw StateError('worker exploded');
}

void _silentExitWorker(SendPort _) {
  // Returns without ever replying — the OOM-kill / abort shape, where there is
  // no error to report, only an absence.
}

void main() {
  test('an isolate that throws reports through onError AND onExit', () async {
    final reply = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    addTearDown(() {
      reply.close();
      errors.close();
      exits.close();
    });

    await Isolate.spawn<SendPort>(
      _crashingWorker,
      reply.sendPort,
      errorsAreFatal: true,
      onError: errors.sendPort,
      onExit: exits.sendPort,
    );

    final error = await errors.first.timeout(const Duration(seconds: 10));
    expect('$error', contains('worker exploded'));
    await exits.first.timeout(const Duration(seconds: 10));
  });

  test('a reply raced against death fails instead of hanging', () async {
    // The shape of the fix: the RPC future and the death future race, so a
    // crash becomes an error the caller can report and recover from. Without
    // the race this test hangs until the suite's own timeout.
    final reply = ReceivePort();
    final exits = ReceivePort();
    addTearDown(() {
      reply.close();
      exits.close();
    });

    final death = Completer<Never>();
    exits.listen((_) {
      if (!death.isCompleted) {
        death.completeError(StateError('worker died'), StackTrace.current);
      }
    });

    await Isolate.spawn<SendPort>(
      _silentExitWorker,
      reply.sendPort,
      errorsAreFatal: true,
      onExit: exits.sendPort,
    );

    await expectLater(
      Future.any<Object?>([reply.first, death.future])
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<StateError>()),
      reason: 'a silent exit must surface as an error, not as a pending future',
    );
  });

  group('WorkerDeath, the shared supervisor', () {
    test('an isolate error completes the future with the reason', () async {
      final death = WorkerDeath();
      addTearDown(death.dispose);
      final reply = ReceivePort();
      addTearDown(reply.close);

      await Isolate.spawn<SendPort>(
        _crashingWorker,
        reply.sendPort,
        errorsAreFatal: true,
        onExit: death.exitPort.sendPort,
        onError: death.errorPort.sendPort,
      );

      await expectLater(
        death.future.timeout(const Duration(seconds: 10)),
        throwsA(
          isA<hv.HvException>().having(
            (e) => '$e',
            'message',
            contains('worker exploded'),
          ),
        ),
      );
    });

    test('a silent exit is reported too, not only errors Dart can describe',
        () async {
      // The OOM-kill / FFI-abort shape: no error, only an absence. `onExit`
      // is what makes it visible.
      final death = WorkerDeath();
      addTearDown(death.dispose);
      final reply = ReceivePort();
      addTearDown(reply.close);

      await Isolate.spawn<SendPort>(
        _silentExitWorker,
        reply.sendPort,
        errorsAreFatal: true,
        onExit: death.exitPort.sendPort,
        onError: death.errorPort.sendPort,
      );

      await expectLater(
        Future.any<Object?>([reply.first, death.future])
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<hv.HvException>()),
        reason: 'a worker that vanishes must not leave the caller waiting',
      );
    });

    test('dispose stops watching without inventing a death', () async {
      // Our own teardown kills the worker; reporting that as a crash would
      // turn every clean close into an error.
      final death = WorkerDeath();
      var reported = false;
      death.future.then((_) {}, onError: (_) => reported = true);
      death.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reported, isFalse);
    });
  });

  test('a worker that answers is unaffected by the watch', () async {
    // The race must not turn a working RPC into a failure — a supervisor that
    // breaks the happy path is worse than none.
    final reply = ReceivePort();
    final exits = ReceivePort();
    addTearDown(() {
      reply.close();
      exits.close();
    });

    final death = Completer<Never>();
    exits.listen((_) {
      if (!death.isCompleted) {
        death.completeError(StateError('worker died'), StackTrace.current);
      }
    });
    // Never observed on the success path; keep it handled so an exit after the
    // reply is not reported as unhandled.
    death.future.ignore();

    await Isolate.spawn<SendPort>(
      _answeringWorker,
      reply.sendPort,
      errorsAreFatal: true,
      onExit: exits.sendPort,
    );

    final r = await Future.any<Object?>([reply.first, death.future])
        .timeout(const Duration(seconds: 10));
    expect(r, 'pong');
  });
}

void _answeringWorker(SendPort reply) {
  reply.send('pong');
}

