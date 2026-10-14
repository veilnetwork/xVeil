/// Endpoint audio buffer trend. Callers supply only fresh native/peer samples.
/// A cached peer report cannot fill a window with repeated observations.
class CallAudioBufferWindow {
  static const samples = 6;
  static const ceilingMs = 200;
  static const growthMs = 20;
  final List<int> _delays = [];
  int? _sequence;
  bool _growing = false;

  bool observe(int? delayMs, {int? sequence}) {
    if (delayMs == null || delayMs < 0 || delayMs > 60000) {
      reset();
      return false;
    }
    if (sequence != null && _sequence != null && sequence <= _sequence!) {
      // Hold the verdict while a still-fresh report is cached. A lower
      // sequence is a replay, so it must not substitute a different delay.
      return _delays.isNotEmpty && (_delays.last >= ceilingMs || _growing);
    }
    _sequence = sequence;
    _delays.add(delayMs);
    if (_delays.length > samples) _delays.removeAt(0);
    _growing = false;
    if (_delays.length == samples) {
      final before = (_delays.take(3).toList()..sort())[1];
      final after = (_delays.skip(3).toList()..sort())[1];
      // Compare medians to reject a solitary spike. The recent half must
      // still rise: an earlier step followed by a plateau or drain is not
      // ongoing growth, even while the older baseline remains in the window.
      _growing =
          after - before >= growthMs &&
          delayMs - before >= growthMs &&
          delayMs - _delays.first >= growthMs &&
          delayMs > _delays[samples - 3];
    }
    return delayMs >= ceilingMs || _growing;
  }

  void reset() {
    _delays.clear();
    _sequence = null;
    _growing = false;
  }
}
