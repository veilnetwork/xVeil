import '../domain/call_signal.dart';

/// Receiver feedback for OUR outgoing audio. Freshness uses local receipt time,
/// not the other device's wall clock; replay cannot extend a sample's lifetime.
class CallPeerAudioPlayout {
  static const lifetime = Duration(seconds: 12);
  int _sequence = -1;
  DateTime? _receivedAt;
  int? _delayMs;

  void observe(CallAudioPlayoutFeedback feedback, DateTime now) {
    if (feedback.sequence <= _sequence) return;
    _sequence = feedback.sequence;
    _delayMs = feedback.delayMs;
    _receivedAt = now;
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
    _delayMs = null;
    _receivedAt = null;
  }
}
