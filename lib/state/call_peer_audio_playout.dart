import '../domain/call_signal.dart';

/// Receiver feedback for OUR outgoing audio. Freshness uses local receipt time,
/// not the other device's wall clock; replay cannot extend a sample's lifetime.
class CallPeerAudioPlayout {
  static const lifetime = Duration(seconds: 12);
  int _sequence = -1;
  DateTime? _receivedAt;
  int? _delayMs;
  int? _currentDelayMs;
  int? _targetDelayMs;
  bool? _bufferGrowing;
  int get sampleSequence => _sequence;
  int? _interruptionCount;
  bool _interrupted = false;

  void observe(CallAudioPlayoutFeedback feedback, DateTime now) {
    if (feedback.sequence <= _sequence) return;
    _sequence = feedback.sequence;
    _delayMs = feedback.delayMs;
    _currentDelayMs = feedback.currentDelayMs ?? feedback.delayMs;
    final target = feedback.targetDelayMs;
    _targetDelayMs =
        feedback.delayMs != null &&
            target != null &&
            target >= 0 &&
            target <= 60000
        ? target
        : null;
    final current = feedback.currentDelayMs;
    final peak = feedback.delayMs;
    _bufferGrowing =
        current != null &&
            peak != null &&
            current >= 0 &&
            current <= peak &&
            peak <= 60000
        ? feedback.bufferGrowing
        : null;
    _receivedAt = now;
    final count = feedback.interruptionCount;
    if (count != null) {
      if (_interruptionCount != null && count > _interruptionCount!) {
        _interrupted = true;
      }
      _interruptionCount = count;
    }
  }

  /// Consume once, so one health frame cannot reset every recovery sample.
  bool takeInterruption() {
    final interrupted = _interrupted;
    _interrupted = false;
    return interrupted;
  }

  int? delayMs(DateTime now) {
    final received = _receivedAt;
    if (received == null ||
        now.difference(received) < Duration.zero ||
        now.difference(received) > lifetime) {
      return null;
    }
    return _delayMs;
  }

  /// Same receipt/replay lifetime as the peak; a current snapshot cannot
  /// survive after the authenticated report has expired.
  int? currentDelayMs(DateTime now) =>
      delayMs(now) == null ? null : _currentDelayMs;

  int? targetDelayMs(DateTime now) =>
      delayMs(now) == null ? null : _targetDelayMs;

  bool? bufferGrowing(DateTime now) =>
      currentDelayMs(now) == null ? null : _bufferGrowing;

  /// A local unmute or rebuild needs new feedback, while old frames must still
  /// be rejected. A new call gets a new tracker instead.
  void invalidateMeasurement() {
    _interrupted = false;
    _delayMs = null;
    _currentDelayMs = null;
    _targetDelayMs = null;
    _bufferGrowing = null;
    _receivedAt = null;
  }
}
