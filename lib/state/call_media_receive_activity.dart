/// Aggregate media liveness, independent of quality/adaptation callbacks.
/// A failed worker snapshot must not rebase the counter and turn an old
/// packet into a new receipt when the worker responds again.
class CallMediaReceiveActivity {
  int _packets = 0;
  DateTime? _lastRxAt;

  DateTime? get lastRxAt => _lastRxAt;

  DateTime? observe(Map<String, Object?> stats, DateTime sampledAt) {
    final stalled = stats['worker_stalled'];
    final packets = stats['rx_pkts'];
    // Older engines omit the worker flag; a present failure is not telemetry.
    if ((stalled != null && stalled != 0) || packets is! int || packets < 0) {
      return null;
    }
    if (packets > _packets) {
      _packets = packets;
      _lastRxAt = sampledAt;
    }
    return _lastRxAt;
  }

  void reset() {
    _packets = 0;
    _lastRxAt = null;
  }
}
