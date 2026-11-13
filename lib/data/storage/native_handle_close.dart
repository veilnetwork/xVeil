/// A consuming native free cannot be retried safely after an error. The FFI
/// wrapper already marks its pointer closed and detaches its finalizer before
/// the call; another wrapper.close() would return without touching native code.
/// Preserve the error instead of mistaking that no-op for confirmed release.
/// This applies to native handles, not to retryable worker/backing protocols.
final class NativeHandleClose {
  NativeHandleClose(this._release);
  final void Function() _release;
  Object? _failure;
  StackTrace? _failureTrace;
  bool _released = false;

  void close() {
    if (_released) return;
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure, _failureTrace!);
    }
    try {
      _release();
      _released = true;
    } catch (error, stack) {
      _failure = error;
      _failureTrace = stack;
      rethrow;
    }
  }
}
