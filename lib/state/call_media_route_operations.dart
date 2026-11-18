import 'dart:async';

/// Serialize route changes and native session rebuilds within one call.
class CallMediaRouteOperations {
  Future<void>? _pending;
  bool _retired = false;

  bool get busy => _pending != null;
  bool get retired => _retired;

  /// The running operation still owns its cleanup. Queued operations cannot
  /// act on a new call, even if it reuses the call ID.
  void retire() => _retired = true;

  /// Recheck ownership after waiting: hangup can retire the old call while a
  /// camera teardown is still pending, and a new call may already exist.
  Future<bool> runForCall(
    String callId,
    String? Function() activeCallId,
    Future<bool> Function() operation,
  ) => run(() async {
    if (retired || activeCallId() != callId) return false;
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
