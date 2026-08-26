import 'dart:async';
import 'dart:isolate';

// `meta`, not `flutter/foundation`: this file is on the headless daemon's
// import graph, which a gate test keeps Flutter-free.
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:hidden_volume/hidden_volume.dart' as hv;

/// Watches a worker isolate and turns its death into a failed future.
///
/// `onExit` fires for any termination; `onError` fires first when the isolate
/// died from an uncaught error and carries the message. Both are wired so a
/// silent exit — an OOM kill, an FFI abort — is reported too, not only the
/// errors Dart could describe.
class WorkerDeath {
  WorkerDeath() {
    errorPort.listen((message) {
      final detail = message is List && message.isNotEmpty
          ? '${message.first}'
          : '$message';
      _die('storage worker isolate error: $detail');
    });
    exitPort.listen((_) => _die('storage worker isolate exited'));
  }

  final exitPort = ReceivePort();
  final errorPort = ReceivePort();
  final _completer = Completer<Never>();

  /// Operations still waiting on an answer, each holding the gate that will
  /// carry the death to its caller. Entries are removed as their operations
  /// answer, so this is the count in flight and not a tally of everything that
  /// ever ran.
  final _waiting = <Completer<Object?>>{};

  Future<Never> get future => _completer.future;

  /// Wait for [operation], but give up if this worker dies first.
  ///
  /// NOT `Future.any([operation, death.future])`, which is what this replaced.
  /// That helper attaches a listener to every future it is given and cancels
  /// none of them, so each call left a listener on the shared, never-completed
  /// death future — and that listener holds the closure over the completer
  /// that already carries the ANSWER. Here the answer is a KV value, i.e.
  /// plaintext. [dispose] deliberately leaves the death future uncompleted, so
  /// the pile was released only when a worker genuinely exited; until then
  /// every byte ever read stayed reachable.
  ///
  /// This is report14 HV14-H1, which was found and fixed in the hidden_volume
  /// plugin's own bindings. These two storage workers are a second, structurally
  /// identical copy of that design and were not swept with it.
  ///
  /// Here the registration is on THIS side and is removed the moment the
  /// operation answers, so nothing outlives the call that made it.
  ///
  /// One case does linger by construction: a caller that puts a timeout on the
  /// returned future and walks away leaves its gate registered, because the
  /// operation it is waiting on may still answer. That is bounded by the
  /// callers who do it — close, once per worker — rather than by throughput.
  Future<Object?> race(Future<Object?> operation) {
    if (_completer.isCompleted) {
      // Already dead: the answer is the death. [operation] is not abandoned
      // though — it can still complete, usually with an ERROR, because the
      // caller's next move on a dead worker is to close the reply port and
      // `Stream.first` on a closed port throws. Nobody reads that, but an error
      // future with no handler is reported as an uncaught async error. Handled
      // here, which is what the racing helper did as a side effect of
      // listening on both.
      operation.ignore();
      return _completer.future;
    }
    final gate = Completer<Object?>();
    _waiting.add(gate);
    operation.then(
      (Object? value) {
        if (_waiting.remove(gate)) gate.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (_waiting.remove(gate)) gate.completeError(error, stack);
      },
    );
    return gate.future;
  }

  /// In flight right now — for tests that assert this does not grow.
  @visibleForTesting
  int get debugWaitingCount => _waiting.length;

  void _die(String why) {
    if (_completer.isCompleted) return;
    final error = hv.HvException('Internal', why);
    final stack = StackTrace.current;
    _completer.completeError(error, stack);
    // The death is delivered through the registry below, so this future can
    // have no listener at all — and an error future without one is reported as
    // unhandled when it is collected. It was always handled before only as a
    // side effect of every in-flight call listening on it, which is precisely
    // the listening that leaked.
    _completer.future.ignore();
    // Everything still waiting gets the same answer the future carries. Taken
    // out of the set first: a listener downstream could otherwise reach back
    // in while this is iterating.
    final waiting = _waiting.toList();
    _waiting.clear();
    for (final gate in waiting) {
      gate.completeError(error, stack);
    }
  }

  /// Stop watching. The future is left as it is: a caller already holding it
  /// must still see the death, and completing it here would invent one.
  ///
  /// What is NOT left as it is: anything still registered. After this the
  /// ports that would report a death are closed, so [_die] can never run and
  /// those gates can never be answered from here — and the operations behind
  /// them are gone too, because the only caller that disposes is one that has
  /// just torn the worker down. Leaving them open is a future that never
  /// completes, holding the caller's payload and the screen that asked
  /// (report15 X15-M5). Nothing is invented: the request genuinely will not be
  /// answered, and that is what they are told.
  void dispose() {
    exitPort.close();
    errorPort.close();
    // An uncompleted error future with no listener is an unhandled-error
    // report at GC time; give it a handler that does nothing.
    _completer.future.ignore();
    // Out of the set first, like `_die` does, so a listener downstream cannot
    // reach back in while this is iterating. `race` re-checks membership
    // before completing, so an operation that answers after this cannot
    // complete a gate twice.
    final waiting = _waiting.toList();
    _waiting.clear();
    final error = StateError(
      'storage worker was shut down while a request was in flight',
    );
    final stack = StackTrace.current;
    for (final gate in waiting) {
      gate.completeError(error, stack);
    }
  }
}
