import '../domain/call_signal.dart';
import 'call_audio_buffer_window.dart';

/// Expedite measured receive-buffer pressure over the existing encrypted
/// health carrier, including a single report when measured pressure clears.
/// Steady healthy audio keeps the ordinary heartbeat cadence.
class CallAudioFeedbackSchedule {
  static const minimumInterval = Duration(seconds: 1);
  DateTime? _lastAttemptAt;
  int? _lastSequence;
  bool? _lastPressure;

  bool attemptedRecently(DateTime now) {
    final last = _lastAttemptAt;
    if (last == null) return false;
    final age = now.difference(last);
    return age >= Duration.zero && age < minimumInterval;
  }

  bool? _pressure(CallAudioPlayoutFeedback? feedback) {
    if (feedback == null) return null;
    final peak = feedback.delayMs;
    final current = feedback.currentDelayMs ?? peak;
    final target = feedback.targetDelayMs;
    if (peak == null ||
        peak < 0 ||
        peak > 60000 ||
        current == null ||
        current < 0 ||
        current > peak ||
        (target != null && (target < 0 || target > 60000))) {
      return null;
    }
    if ((target != null && target >= CallAudioBufferWindow.ceilingMs) ||
        current >= CallAudioBufferWindow.ceilingMs ||
        feedback.bufferGrowing == true) {
      return true;
    }
    // An incomplete/legacy trend is unknown, not evidence that growth stopped.
    return feedback.bufferGrowing == false ? false : null;
  }

  bool shouldSendUrgent(CallAudioPlayoutFeedback? feedback, DateTime now) {
    if (feedback == null ||
        feedback.sequence < 0 ||
        (_lastSequence != null && feedback.sequence <= _lastSequence!)) {
      return false;
    }
    final pressure = _pressure(feedback);
    if (pressure != true && !(pressure == false && _lastPressure == true)) {
      return false;
    }
    // Let the ordinary heartbeat re-anchor a reversed wall clock, rather
    // than using that reversal to authorize a burst of urgent reports.
    return (_lastAttemptAt == null || !now.isBefore(_lastAttemptAt!)) &&
        !attemptedRecently(now);
  }

  /// Count attempts, including rejected local queues, to bound traffic on a
  /// broken path. Only a newer native sample can authorize another urgent one.
  /// Periodic health/capture announcements also consume this interval.
  void recordAttempt(CallAudioPlayoutFeedback? feedback, DateTime now) {
    if (feedback == null || feedback.sequence < 0) return;
    _lastAttemptAt = now;
    if (_lastSequence == null || feedback.sequence > _lastSequence!) {
      _lastSequence = feedback.sequence;
      final pressure = _pressure(feedback);
      if (pressure != null) _lastPressure = pressure;
    }
  }

  void reset() {
    _lastAttemptAt = null;
    _lastSequence = null;
    _lastPressure = null;
  }
}
