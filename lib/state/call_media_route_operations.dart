import 'dart:async';

/// Keep a route change behind an unfinished native session teardown/rebuild.
/// A pending repair must finish before its successor can open another route.
class CallMediaRouteOperations {
  Future<void>? _pending;

  bool get busy => _pending != null;

  /// Recheck ownership after waiting: hangup can retire the old call while a
  /// camera teardown is still pending, and a new call may already exist.
  Future<bool> runForCall(
    String callId,
    String? Function() activeCallId,
    Future<bool> Function() operation,
  ) => run(() async {
    if (activeCallId() != callId) return false;
    return operation();
  });

  Future<T> run<T>(Future<T> Function() operation) async {
    while (_pending != null) {
      await _pending;
    }
    final done = Completer<void>();
    _pending = done.future;
    try {
      return await operation();
    } finally {
      _pending = null;
      done.complete();
    }
  }
}
