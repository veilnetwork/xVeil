import 'dart:async';

/// A profile's accepted model operations outlive their settings screens.
/// Retirement is permanent: new work needs a fresh owner after cleanup ends.
class ProfileModelWork {
  final _tasks = <ProfileModelTask>{};
  final _lanes = <String>{};
  bool _retired = false;
  Future<void>? _draining;

  ProfileModelTask? begin({String? lane, bool Function()? stillCurrent}) {
    if (_retired ||
        (stillCurrent != null && !stillCurrent()) ||
        (lane != null && _lanes.contains(lane))) {
      return null;
    }
    if (lane != null) _lanes.add(lane);
    final task = ProfileModelTask._(this, lane, stillCurrent);
    _tasks.add(task);
    return task;
  }

  /// Seals admission before returning. Accepted tasks may still finish native
  /// I/O; their completion is joined even when cancellation is unavailable.
  Future<void> retire() {
    _retired = true;
    return _draining ??= Future.wait<void>([
      for (final task in _tasks) task._done.future,
    ]);
  }
}

final class ProfileModelTask {
  ProfileModelTask._(this._owner, this._lane, this._stillCurrent);
  final ProfileModelWork _owner;
  final String? _lane;
  final bool Function()? _stillCurrent;
  final _done = Completer<void>();
  bool _started = false;
  bool get current =>
      !_owner._retired && !_done.isCompleted && (_stillCurrent?.call() ?? true);

  Future<T> run<T>(FutureOr<T> Function() operation) async {
    if (_started) throw StateError('model task already started');
    _started = true;
    try {
      return await operation();
    } finally {
      _owner._tasks.remove(this);
      if (_lane case final lane?) _owner._lanes.remove(lane);
      _done.complete();
    }
  }
}
