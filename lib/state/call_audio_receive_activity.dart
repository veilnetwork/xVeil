import '../domain/call_signal.dart';
import 'call_audio_buffer_window.dart';
import 'call_peer_audio_recovery.dart';

/// Audio activity measured at the receive stream, separately from video and
/// RTCP ingress. Default counters from a timed-out native worker are not data.
class CallAudioReceiveActivity {
  /// A current native snapshot, independent of the periodic activity cache.
  /// Reading it must not consume interruption feedback or rebase counters.
  static DateTime? nativeLastRxAt(
    Map<String, Object?> stats,
    DateTime sampledAt,
  ) {
    final packets = stats['audio_rx_pkts'];
    final age = stats['audio_rx_native_age_ms'];
    if (stats['worker_stalled'] != 0 ||
        packets is! num ||
        !packets.isFinite ||
        packets <= 0 ||
        age is! num ||
        !age.isFinite ||
        age < 0 ||
        age > 60000) {
      return null;
    }
    return sampledAt.subtract(Duration(milliseconds: age.toInt()));
  }

  /// WebRTC's delay estimate filters recent buffer growth. Protect audio
  /// using the larger current buffer too, before that filter catches up.
  /// Relative RTP lag additionally accounts for backlog before this receiver.
  /// Missing pressure stats on older libraries retain the validated estimate.
  static int? nativePlayoutDelay(Map<String, Object?> stats) {
    final packets = stats['audio_rx_pkts'];
    if (stats['worker_stalled'] != 0 ||
        packets is! num ||
        !packets.isFinite ||
        packets <= 0) {
      return null;
    }
    int? valid(Object? value) =>
        value is num && value.isFinite && value >= 0 && value <= 60000
        ? value.toInt()
        : null;
    final delay = valid(stats['audio_delay_ms']);
    if (delay == null) return null;
    final buffer = valid(stats['audio_jb_ms']);
    final pressure = valid(stats['audio_pressure_delay_ms']);
    var worst = buffer != null && buffer > delay ? buffer : delay;
    if (pressure != null && pressure > worst) worst = pressure;
    return worst;
  }

  static int? nativeTargetDelay(Map<String, Object?> stats) {
    if (nativePlayoutDelay(stats) == null) return null;
    final age = stats['audio_rx_native_age_ms'];
    if (age is! num ||
        !age.isFinite ||
        age < 0 ||
        age > sampleLifetime.inMilliseconds) {
      return null;
    }
    final target = stats['audio_jb_target_ms'];
    return target is num && target.isFinite && target >= 0 && target <= 60000
        ? target.toInt()
        : null;
  }

  int _lastPackets = 0;
  bool supported = false;
  DateTime? lastRxAt;
  DateTime? workerStalledSince;
  int _sequence = 0;
  int? _playoutDelayMs;
  int? _targetDelayMs;
  DateTime? _sampledAt;
  int? _lastInterruptionCount;
  int? _lastRecoveryCount;
  CallAudioRecoveryIdentity? _nativeRecoveryIdentity;
  int _interruptionCount = 0;
  int _recoveryCount = 0;
  bool interrupted = false;
  bool recovered = false;
  static const sampleLifetime = Duration(seconds: 3);
  // Health signals are sent every five seconds, while native stats are polled
  // every second. Preserve intervening peaks for the outgoing report without
  // making local adaptation wait for old congestion to expire.
  static const feedbackWindow = Duration(seconds: 5);
  final List<({DateTime at, int delay})> _feedbackPeaks = [];
  DateTime? _lastObservedAt;
  final _playoutWindow = CallAudioBufferWindow();

  void _expireFeedbackPeaks(DateTime now) {
    _feedbackPeaks.removeWhere((sample) {
      final age = now.difference(sample.at);
      return age < Duration.zero || age > feedbackWindow;
    });
  }

  /// Report congestion between heartbeats, even if the buffer has recovered
  /// by the next send. A fresh current measurement is still required.
  CallAudioPlayoutFeedback outgoingPlayoutFeedback(DateTime now) {
    final current = playoutFeedback(now);
    _expireFeedbackPeaks(now);
    final delay = current.delayMs;
    if (delay == null) return current;
    var peak = delay;
    for (final sample in _feedbackPeaks) {
      if (sample.delay > peak) peak = sample.delay;
    }
    return CallAudioPlayoutFeedback(
      sequence: current.sequence,
      delayMs: peak,
      currentDelayMs: delay,
      targetDelayMs: current.targetDelayMs,
      bufferGrowing: _playoutWindow.growing,
      interruptionCount: current.interruptionCount,
      recoveryCount: current.recoveryCount,
      recoveryOrigin: current.recoveryOrigin,
      recoveryDiscardedMs: current.recoveryDiscardedMs,
    );
  }

  CallAudioPlayoutFeedback playoutFeedback(DateTime now) {
    final sample = _sampledAt;
    final audio = lastRxAt;
    final fresh =
        sample != null &&
        audio != null &&
        now.difference(sample) >= Duration.zero &&
        now.difference(sample) <= sampleLifetime &&
        now.difference(audio) >= Duration.zero &&
        now.difference(audio) <= sampleLifetime;
    return CallAudioPlayoutFeedback(
      sequence: _sequence,
      delayMs: fresh ? _playoutDelayMs : null,
      targetDelayMs: fresh ? _targetDelayMs : null,
      interruptionCount:
          fresh &&
              (_lastInterruptionCount != null || _lastRecoveryCount != null)
          ? _interruptionCount
          : null,
      recoveryCount: fresh && _lastRecoveryCount != null
          ? _recoveryCount
          : null,
      recoveryOrigin: fresh ? _nativeRecoveryIdentity?.origin : null,
      recoveryDiscardedMs: fresh ? _nativeRecoveryIdentity?.discardedMs : null,
    );
  }

  void observe(Map<String, Object?> stats, DateTime now) {
    final previous = _lastObservedAt;
    if (previous != null &&
        (!now.isAfter(previous) || now.difference(previous) > sampleLifetime)) {
      _playoutWindow.reset();
    }
    if (_lastObservedAt != null && now.isBefore(_lastObservedAt!)) {
      _feedbackPeaks.clear();
    }
    _lastObservedAt = now;
    _expireFeedbackPeaks(now);
    interrupted = false;
    recovered = false;
    _sequence++;
    _playoutDelayMs = null;
    _targetDelayMs = null;
    _sampledAt = null;
    _nativeRecoveryIdentity = null;
    final packets = stats['audio_rx_pkts'];
    if (packets is! num || packets < 0) {
      workerStalledSince = null;
      _playoutWindow.reset();
      return;
    }
    supported = true;
    if (stats['worker_stalled'] == 1) {
      workerStalledSince ??= now;
      _playoutWindow.reset();
      return;
    }
    workerStalledSince = null;
    _nativeRecoveryIdentity = callAudioRecoveryIdentity(
      stats['audio_receiver_recovery_origin'],
      stats['audio_receiver_recovery_discarded_ms'],
    );
    final interruptions = stats['audio_interruption_count'];
    if (stats['worker_stalled'] == 0 &&
        interruptions is int &&
        interruptions >= 0) {
      final previous = _lastInterruptionCount;
      if (previous != null && interruptions > previous) {
        _interruptionCount += interruptions - previous;
        interrupted = true;
      }
      _lastInterruptionCount = interruptions;
    }
    final recoveries = stats['audio_latency_recovery_count'];
    if (stats['worker_stalled'] == 0 && recoveries is int && recoveries >= 0) {
      final previous = _lastRecoveryCount;
      if (previous != null && recoveries > previous) {
        _interruptionCount += recoveries - previous;
        _recoveryCount += recoveries - previous;
        recovered = true;
      }
      _lastRecoveryCount = recoveries;
    }
    final count = packets.toInt();
    final nativeAge = stats['audio_rx_native_age_ms'];
    if (count > 0 && nativeAge is num && nativeAge.isFinite && nativeAge >= 0) {
      lastRxAt = now.subtract(Duration(milliseconds: nativeAge.toInt()));
    } else if (!stats.containsKey('audio_rx_native_age_ms') &&
        count > _lastPackets) {
      // Older media libraries expose only the counter. A new library's
      // unknown timestamp must stay unknown rather than look freshly received.
      lastRxAt = now;
    }
    _lastPackets = count;
    final delay = nativePlayoutDelay(stats);
    // Only a successfully queried audio worker supplies a playout estimate.
    if (delay != null) {
      _playoutDelayMs = delay;
      _targetDelayMs = nativeTargetDelay(stats);
      _sampledAt = now;
      // A newer equal/higher sample outlives the older one. Keep descending
      // candidates so expiry also preserves smaller intervening peaks. Normal
      // polling retains at most six; valid integer delays bound even a debug
      // caller sampling faster to at most 60001 candidates.
      while (_feedbackPeaks.isNotEmpty && _feedbackPeaks.last.delay <= delay) {
        _feedbackPeaks.removeLast();
      }
      _feedbackPeaks.add((at: now, delay: delay));
    }
    _playoutWindow.observe(playoutFeedback(now).delayMs);
  }

  void reset() {
    // Keep sequence monotonic across session repairs and unknown snapshots.
    _sequence++;
    _playoutDelayMs = null;
    _targetDelayMs = null;
    _sampledAt = null;
    _feedbackPeaks.clear();
    _playoutWindow.reset();
    _lastObservedAt = null;
    _lastPackets = 0;
    _lastInterruptionCount = null;
    _lastRecoveryCount = null;
    _nativeRecoveryIdentity = null;
    interrupted = false;
    recovered = false;
    supported = false;
    lastRxAt = null;
    workerStalledSince = null;
  }
}
