import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

/// The storage worker runs in its own isolate, and every RPC used to
/// `await reply.first` with nothing watching that isolate. A worker that
/// crashed — an FFI fault, an uncaught error, an OOM kill — therefore left the
/// caller's future pending FOREVER: the UI showed a spinner no timeout would
/// end, and every later call joined it. `errorsAreFatal: true` made the isolate
/// die quietly; nothing was listening for the death (audit XV-07).
///
/// `_WorkerDeath` is private to the store, so this exercises the ISOLATE
/// CONTRACT it is built on — that `onExit`/`onError` fire and that racing a
/// pending reply against them converts an unbounded hang into an error. If Dart
/// ever stopped delivering these, the supervisor would silently stop working
/// and this is what would notice.
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
