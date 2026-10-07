import '../domain/call_signal.dart';

/// Receiver feedback for OUR outgoing audio. Freshness uses local receipt time,
/// not the other device's wall clock; replay cannot extend a sample's lifetime.
class CallPeerAudioPlayout {
  static const lifetime = Duration(seconds: 12);
  int _sequence = -1;
  DateTime? _receivedAt;
  int? _delayMs;
  int? _interruptionCount;
  bool _interrupted = false;

  void observe(CallAudioPlayoutFeedback feedback, DateTime now) {
    if (feedback.sequence <= _sequence) return;
    _sequence = feedback.sequence;
    _delayMs = feedback.delayMs;
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

  /// A local unmute or rebuild needs new feedback, while old frames must still
  /// be rejected. A new call gets a new tracker instead.
  void invalidateMeasurement() {
    _interrupted = false;
    _delayMs = null;
    _receivedAt = null;
  }
}
