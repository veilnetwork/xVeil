/// Endpoint audio buffer trend. Callers supply only fresh native/peer samples.
/// A cached peer report cannot fill a window with repeated observations.
class CallAudioBufferWindow {
  static const samples = 6;
  static const ceilingMs = 300;
  static const growthMs = 40;
  static const growthConfirmation = Duration(seconds: 3);
  static const sampleLifetime = Duration(seconds: 6);
  final List<int> _delays = [];
  int? _sequence;
  bool _growing = false;
  bool _usingMeasuredTrend = false;
  DateTime? _lastSampleAt, _growthSince;
  int _growthSamples = 0;
  bool _pressure = false;

  bool? get growing =>
      _usingMeasuredTrend || _delays.length == samples ? _growing : null;

  /// Bounded local diagnostics; callers cannot mutate the policy's window.
  List<int> get diagnosticSamples => List<int>.unmodifiable(_delays);

  bool observe(
    int? delayMs, {
    int? sequence,
    bool? measuredGrowing,
    DateTime? sampledAt,
  }) {
    if (delayMs == null || delayMs < 0 || delayMs > 60000) {
      reset();
      return false;
    }
    if (sequence != null && _sequence != null && sequence <= _sequence!) {
      // Hold the verdict while a still-fresh report is cached. A lower
      // sequence is a replay, so it must not substitute a different delay.
      return _pressure;
    }
    final previousAt = _lastSampleAt;
    if (sampledAt != null && previousAt != null) {
      if (sampledAt == previousAt) return _pressure;
      if (sampledAt.isBefore(previousAt) ||
          sampledAt.difference(previousAt) > sampleLifetime) {
        // A clock correction or an observation gap cannot prove continuous
        // growth. Keep the peer replay watermark while warming new evidence.
        _delays.clear();
        _growthSince = null;
        _growthSamples = 0;
      }
    }
    _lastSampleAt = sampledAt;
    _sequence = sequence;
    final measured = measuredGrowing != null;
    if (measured != _usingMeasuredTrend) {
      // Never mix a receiver's native window with our downsampled legacy one.
      _delays.clear();
      _usingMeasuredTrend = measured;
      _growthSince = null;
      _growthSamples = 0;
    }
    _delays.add(delayMs);
    if (_delays.length > samples) _delays.removeAt(0);
    _growing = measuredGrowing ?? false;
    if (!measured && _delays.length == samples) {
      final earlier = _delays.take(3).toList()..sort();
      final recent = _delays.skip(3).toList()..sort();
      final before = earlier[1];
      final after = recent[1];
      // Compare medians to reject a solitary spike. The recent half must
      // still rise: an earlier step followed by a plateau or drain is not
      // ongoing growth, even while the older baseline remains in the window.
      // Packet timing can move the median between already observed bounds.
      // Require the entire recent range above the earlier peak, rather than
      // treating an overlapping oscillation as a new backlog and shedding
      // otherwise healthy video.
      // A newest sample already draining from the preceding peak cannot
      // confirm that older ascent, even if it remains above the old range.
      _growing =
          after - before >= growthMs &&
          delayMs - before >= growthMs &&
          delayMs - earlier.last >= growthMs &&
          recent.first > earlier.last &&
          delayMs >= _delays[samples - 2] &&
          delayMs > _delays[samples - 3];
    }
    // Publish the raw trend to the peer so its sender can start the same
    // confirmation period without another receiver-side delay. Only the
    // returned verdict may reduce local video or competing source budgets.
    // A short rise that drains must not spend a long camera recovery period.
    if (_growing) {
      _growthSamples++;
      _growthSince ??= sampledAt;
    } else {
      _growthSamples = 0;
      _growthSince = null;
    }
    final confirmed =
        _growing &&
        (sampledAt != null && _growthSince != null
            ? sampledAt.difference(_growthSince!) >= growthConfirmation
            : _growthSamples >= 4);
    _pressure = delayMs >= ceilingMs || confirmed;
    return _pressure;
  }

  void reset() {
    _delays.clear();
    _sequence = null;
    _growing = false;
    _usingMeasuredTrend = false;
    _lastSampleAt = _growthSince = null;
    _growthSamples = 0;
    _pressure = false;
  }
}
