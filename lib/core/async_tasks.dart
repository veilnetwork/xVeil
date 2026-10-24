import 'dart:async';

/// Work owned by one provider/identity. Stop admission synchronously, then
/// join everything admitted before close. Errors still reach each caller.
class AsyncTasks {
  final Set<Future<dynamic>> _pending = {};
  bool _closed = false;
  Future<void>? _closing;

  bool get isClosed => _closed;

  void start(Future<void> Function() action) => unawaited(run(action));

  Future<void> run(Future<void> Function() action) {
    if (_closed) return Future<void>.value();
    return runRequired(action);
  }

  /// Awaited operations must fail instead of reporting a skipped write as
  /// success. Background replays use [run] and retry from durable state later.
  Future<T> runRequired<T>(Future<T> Function() action) {
    if (_closed) return Future<T>.error(StateError('task owner is closing'));
    late Future<T> task;
    task = Future<T>.sync(action).whenComplete(() {
      _pending.remove(task);
    });
    _pending.add(task);
    return task;
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= Future.wait(_pending.toList()).then((_) {});
  }
}
