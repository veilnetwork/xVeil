import '../domain/call_signal.dart';
import 'call_audio_buffer_window.dart';
import 'call_audio_playout_reserve.dart';

/// Expedite measured receive-buffer pressure and playout interruptions over
/// the existing encrypted health carrier. A filled reserve gets one
/// confirmation after recovery.
/// Steady healthy audio keeps the ordinary heartbeat cadence.
class CallAudioFeedbackSchedule {
  static const minimumInterval = Duration(seconds: 1);
  static const _reserveConfirmationDelay = Duration(seconds: 2);
  DateTime? _lastAttemptAt;
  int? _lastSequence;
  int? _lastInterruptionCount;
  bool? _lastPressure;
  bool _reserveConfirmationPending = false;

  bool attemptedRecently(DateTime now) {
    final last = _lastAttemptAt;
    if (last == null) return false;
    final age = now.difference(last);
    return age >= Duration.zero && age < minimumInterval;
  }

  int _reserve(CallAudioPlayoutFeedback feedback) =>
      CallAudioPlayoutReserve.creditMs(
        feedback.currentDelayMs,
        feedback.targetDelayMs,
      );

  int? _playoutInterruptions(CallAudioPlayoutFeedback feedback) {
    final count = feedback.interruptionCount;
    final recoveries = feedback.recoveryCount;
    // The total includes intentional catch-up. Modern native reports supply
    // both counters, so a trim alone cannot trigger urgent interruption.
    return count != null &&
            recoveries != null &&
            recoveries >= 0 &&
            count >= recoveries
        ? count - recoveries
        : null;
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
    // Only a measured current delay can confirm a filled jitter reserve. A
    // retained peak or a large target alone still needs the ordinary guard.
    final reserve = _reserve(feedback);
    final ceiling = CallAudioBufferWindow.ceilingMs;
    final interruptions = _playoutInterruptions(feedback);
    final lastInterruptions =
        _lastInterruptionCount ?? (feedback.callScopedCounters ? 0 : null);
    final interrupted =
        interruptions != null &&
        lastInterruptions != null &&
        interruptions > lastInterruptions;
    if (interrupted ||
        (reserve == 0 && target != null && target >= ceiling) ||
        current >= ceiling + reserve ||
        feedback.bufferGrowing == true) {
      return true;
    }
    // An incomplete/legacy trend is unknown, not evidence that growth stopped.
    return feedback.bufferGrowing == false ? false : null;
  }

  bool shouldSendUrgent(CallAudioPlayoutFeedback? feedback, DateTime now) =>
      urgentDelay(feedback, now) == Duration.zero;

  /// Delay before the next eligible urgent report, or null if none is due.
  Duration? urgentDelay(CallAudioPlayoutFeedback? feedback, DateTime now) {
    if (feedback == null ||
        feedback.sequence < 0 ||
        (_lastSequence != null && feedback.sequence <= _lastSequence!)) {
      return null;
    }
    final pressure = _pressure(feedback);
    final lastAttempt = _lastAttemptAt;
    final confirmReserve =
        _reserveConfirmationPending &&
        lastAttempt != null &&
        pressure == false &&
        _reserve(feedback) > 0 &&
        now.difference(lastAttempt) >= _reserveConfirmationDelay;
    if (pressure != true &&
        !(pressure == false && _lastPressure == true) &&
        !confirmReserve) {
      return null;
    }
    // Let the ordinary heartbeat re-anchor a reversed wall clock, rather
    // than using that reversal to authorize a burst of urgent reports.
    if (lastAttempt == null) return Duration.zero;
    if (now.isBefore(lastAttempt)) return null;
    final remaining = minimumInterval - now.difference(lastAttempt);
    return remaining > Duration.zero ? remaining : Duration.zero;
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
      final interruptions = _playoutInterruptions(feedback);
      if (interruptions != null &&
          (_lastInterruptionCount == null ||
              interruptions > _lastInterruptionCount!)) {
        _lastInterruptionCount = interruptions;
      }
      if (pressure != null) {
        // A fresh, measured heartbeat also settles a pending follow-up.
        _reserveConfirmationPending =
            _lastPressure == true &&
            pressure == false &&
            _reserve(feedback) > 0;
        _lastPressure = pressure;
      }
    }
  }

  void reset() {
    _lastAttemptAt = null;
    _lastSequence = null;
    _lastInterruptionCount = null;
    _lastPressure = null;
    _reserveConfirmationPending = false;
  }
}
