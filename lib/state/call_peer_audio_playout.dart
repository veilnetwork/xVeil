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
  int? _recoveryCount;
  bool _recovered = false;

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
    final rawRecoveries = feedback.recoveryCount;
    final recoveries =
        rawRecoveries != null &&
            count != null &&
            rawRecoveries >= 0 &&
            rawRecoveries <= count
        ? rawRecoveries
        : null;
    final recoveryDelta =
        recoveries != null &&
            _recoveryCount != null &&
            recoveries > _recoveryCount!
        ? recoveries - _recoveryCount!
        : 0;
    if (count != null) {
      if (_interruptionCount != null && count > _interruptionCount!) {
        if (count - _interruptionCount! > recoveryDelta) _interrupted = true;
      }
      _interruptionCount = count;
    }
    if (recoveries != null &&
        count != null &&
        recoveries >= 0 &&
        recoveries <= count) {
      if (recoveryDelta > 0) _recovered = true;
      _recoveryCount = recoveries;
    }
  }

  /// Consume once, so one health frame cannot reset every recovery sample.
  bool takeInterruption() {
    final interrupted = _interrupted;
    _interrupted = false;
    return interrupted;
  }

  bool takeRecovery() {
    final recovered = _recovered;
    _recovered = false;
    return recovered;
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
    _recovered = false;
    _delayMs = null;
    _currentDelayMs = null;
    _targetDelayMs = null;
    _bufferGrowing = null;
    _receivedAt = null;
  }
}
