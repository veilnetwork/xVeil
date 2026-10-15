/// Endpoint audio buffer trend. Callers supply only fresh native/peer samples.
/// A cached peer report cannot fill a window with repeated observations.
class CallAudioBufferWindow {
  static const samples = 6;
  static const ceilingMs = 200;
  static const growthMs = 20;
  final List<int> _delays = [];
  int? _sequence;
  bool _growing = false;
  bool _usingMeasuredTrend = false;

  bool? get growing => _delays.length == samples ? _growing : null;

  /// Bounded local diagnostics; callers cannot mutate the policy's window.
  List<int> get diagnosticSamples => List<int>.unmodifiable(_delays);

  bool observe(int? delayMs, {int? sequence, bool? measuredGrowing}) {
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
    final measured = measuredGrowing != null;
    if (measured != _usingMeasuredTrend) {
      // Never mix a receiver's native window with our downsampled legacy one.
      _delays.clear();
      _usingMeasuredTrend = measured;
    }
    _delays.add(delayMs);
    if (_delays.length > samples) _delays.removeAt(0);
    _growing = measuredGrowing ?? false;
    if (!measured && _delays.length == samples) {
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
    _usingMeasuredTrend = false;
  }
}
