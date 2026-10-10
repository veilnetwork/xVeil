import 'dart:async';

/// Bounded diagnostic borrowing of a qualified alternate native sender. No
/// route-operation lock is held; repair/hangup supersedes each pending await.
class CallAudioMirrorLease {
  int _generation = 0;
  bool _opening = false;
  int? _channel;
  bool Function(int)? _bind;
  void Function(int)? _close;
  Timer? _timer;

  bool get enabled => _channel != null;

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final channel = _channel;
    final bind = _bind;
    final close = _close;
    _channel = null;
    _bind = null;
    _close = null;
    if (channel == null) return;
    try {
      bind!(0);
    } finally {
      close!(channel);
    }
  }

  Future<Map<String, Object?>> start({
    required Duration duration,
    required bool Function() stillOwned,
    required Future<int?> Function() openAlternate,
    required Future<bool> Function(int) qualify,
    required bool Function(int) bind,
    required void Function(int) close,
  }) async {
    if (duration <= Duration.zero || duration > const Duration(seconds: 60)) {
      throw ArgumentError.value(duration, 'duration', 'must be >0 and <=60s');
    }
    if (enabled || _opening) return {'ok': false, 'reason': 'busy'};
    _opening = true;
    final generation = _generation;
    bool owned() => generation == _generation && stillOwned();
    int? candidate;
    var installed = false;
    try {
      if (!owned()) return {'ok': false, 'reason': 'call_changed'};
      candidate = await openAlternate();
      if (!owned()) return {'ok': false, 'reason': 'call_changed'};
      if (candidate == null) return {'ok': false, 'reason': 'unavailable'};
      if (!await qualify(candidate)) {
        return {'ok': false, 'reason': 'delivery_unconfirmed'};
      }
      if (!owned()) return {'ok': false, 'reason': 'call_changed'};
      if (!bind(candidate)) return {'ok': false, 'reason': 'bind_failed'};
      _channel = candidate;
      _bind = bind;
      _close = close;
      installed = true;
      _timer = Timer(duration, stop);
      return {'ok': true, 'enabled': true, 'seconds': duration.inSeconds};
    } catch (_) {
      return {'ok': false, 'reason': 'mirror_error'};
    } finally {
      if (!installed && candidate != null) close(candidate);
      _opening = false;
    }
  }
}
