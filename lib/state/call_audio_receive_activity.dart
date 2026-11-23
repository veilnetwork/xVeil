import '../domain/call_signal.dart';
import 'call_audio_buffer_window.dart';
import 'call_audio_playout_reserve.dart';
import 'call_peer_audio_recovery.dart';

/// Audio activity measured at the receive stream, separately from video and
/// RTCP ingress. Default counters from a timed-out native worker are not data.
class CallAudioReceiveActivity {
  static num? _nativeReceiveAgeMs(Map<String, Object?> stats) {
    final age = stats['audio_rx_native_age_ms'];
    return age is num && age.isFinite && age >= 0 && age <= 60000 ? age : null;
  }

  /// A current native snapshot, independent of the periodic activity cache.
  /// Reading it must not consume interruption feedback or rebase counters.
  static DateTime? nativeLastRxAt(
    Map<String, Object?> stats,
    DateTime sampledAt,
  ) {
    final packets = stats['audio_rx_pkts'];
    final age = _nativeReceiveAgeMs(stats);
    if (stats['worker_stalled'] != 0 ||
        packets is! num ||
        !packets.isFinite ||
        packets <= 0 ||
        age == null) {
      return null;
    }
    return sampledAt.subtract(Duration(milliseconds: age.toInt()));
  }

  /// WebRTC's delay estimate filters recent buffer growth. Protect audio
  /// using the larger current buffer too, before that filter catches up.
  /// Relative RTP lag additionally accounts for backlog before this receiver.
  /// Missing pressure stats on older libraries retain the validated estimate.
  static int? nativePlayoutDelay(
    Map<String, Object?> stats, {
    bool bufferedOnly = false,
  }) {
    final packets = stats['audio_rx_pkts'];
    if (stats['worker_stalled'] != 0 ||
        packets is! num ||
        !packets.isFinite ||
        packets <= 0) {
      return null;
    }
    // Modern engines can count RTP padding before receiving audio payload.
    // An explicit unknown arrival cannot qualify that stream's buffer.
    if (stats.containsKey('audio_rx_native_age_ms') &&
        _nativeReceiveAgeMs(stats) == null) {
      return null;
    }
    int? valid(Object? value) =>
        value is num && value.isFinite && value >= 0 && value <= 60000
        ? value.toInt()
        : null;
    final delay = valid(stats['audio_delay_ms']);
    if (delay == null || bufferedOnly) return delay;
    final buffer = valid(stats['audio_jb_ms']);
    final pressure = valid(stats['audio_pressure_delay_ms']);
    var worst = buffer != null && buffer > delay ? buffer : delay;
    if (pressure != null && pressure > worst) worst = pressure;
    return worst;
  }

  static int? nativeTargetDelay(Map<String, Object?> stats) {
    // The target is measured alongside the current queue. Packet age gates
    // recovery and outgoing feedback separately from that paired reading.
    if (_nativeReceiveAgeMs(stats) == null ||
        nativePlayoutDelay(stats) == null) {
      return null;
    }
    final target = stats['audio_jb_target_ms'];
    return target is num && target.isFinite && target >= 0 && target <= 60000
        ? target.toInt()
        : null;
  }

  /// Normalize one receiver before aggregating independent group streams.
  static int? nativePlayoutDelayAfterReserve(
    Map<String, Object?> stats, {
    bool requireFullReserve = false,
  }) {
    final delay = nativePlayoutDelay(stats);
    if (delay == null) return null;
    // nativePlayoutDelay validates the queue delay. Upstream RTP age can
    // increase pressure without filling this receiver's local reserve.
    final buffered = (stats['audio_delay_ms'] as num).toInt();
    final credit = CallAudioPlayoutReserve.creditMs(
      buffered,
      nativeTargetDelay(stats),
    );
    if (requireFullReserve &&
        credit != CallAudioPlayoutReserve.maximumCreditMs) {
      return null;
    }
    return delay - credit;
  }

  int _lastPackets = 0;
  bool supported = false;
  DateTime? lastRxAt;
  DateTime? workerStalledSince;
  int _sequence = 0;
  int? _playoutDelayMs;
  int? _bufferedDelayMs;
  int? _targetDelayMs;
  DateTime? _sampledAt;
  bool _freshEngine = false;
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
    if (delay == null) {
      if (_sampledAt == null) return current;
      // The last native sample expired without a replacement. Withdraw it
      // once with a new sequence, so the peer's replay guard accepts the
      // unknown state and a delayed copy cannot restore the old measurement.
      _sampledAt = null;
      return CallAudioPlayoutFeedback(sequence: ++_sequence);
    }
    var peak = delay;
    for (final sample in _feedbackPeaks) {
      if (sample.delay > peak) peak = sample.delay;
    }
    return CallAudioPlayoutFeedback(
      sequence: current.sequence,
      delayMs: peak,
      currentDelayMs: delay,
      bufferedDelayMs: current.bufferedDelayMs,
      targetDelayMs: current.targetDelayMs,
      bufferGrowing: _playoutWindow.growing,
      interruptionCount: current.interruptionCount,
      recoveryCount: current.recoveryCount,
      callScopedCounters:
          current.interruptionCount != null && current.recoveryCount != null,
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
      currentDelayMs: fresh ? _playoutDelayMs : null,
      bufferedDelayMs: fresh ? _bufferedDelayMs : null,
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
    _bufferedDelayMs = null;
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
      final previous =
          _lastInterruptionCount ?? (_freshEngine ? 0 : interruptions);
      if (interruptions > previous) {
        _interruptionCount += interruptions - previous;
        interrupted = true;
      }
      _lastInterruptionCount = interruptions;
    }
    final recoveries = stats['audio_latency_recovery_count'];
    if (stats['worker_stalled'] == 0 && recoveries is int && recoveries >= 0) {
      final previous = _lastRecoveryCount ?? (_freshEngine ? 0 : recoveries);
      if (recoveries > previous) {
        _interruptionCount += recoveries - previous;
        _recoveryCount += recoveries - previous;
        recovered = true;
      }
      _lastRecoveryCount = recoveries;
    }
    final count = packets.toInt();
    final nativeAge = _nativeReceiveAgeMs(stats);
    if (count > 0 && nativeAge != null) {
      lastRxAt = now.subtract(Duration(milliseconds: nativeAge.toInt()));
    } else if (!stats.containsKey('audio_rx_native_age_ms') &&
        count > _lastPackets) {
      // Older media libraries expose only the counter. A new library's
      // unknown timestamp must stay unknown rather than look freshly received.
      lastRxAt = now;
    }
    _lastPackets = count;
    final delay = nativePlayoutDelay(stats);
    final arrival = lastRxAt;
    // Only a fresh receive sample contributes feedback, including its peak.
    if (delay != null &&
        arrival != null &&
        !arrival.isAfter(now) &&
        now.difference(arrival) <= sampleLifetime) {
      _playoutDelayMs = delay;
      _bufferedDelayMs = (stats['audio_delay_ms'] as num).toInt();
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
    _playoutWindow.observe(playoutFeedback(now).delayMs, sampledAt: now);
  }

  /// A newly created engine starts its counters at zero before the first poll.
  /// Attaching to a running stream requires a measured baseline instead.
  void reset({bool freshEngine = false}) {
    // Keep sequence monotonic across session repairs and unknown snapshots.
    _sequence++;
    _playoutDelayMs = null;
    _bufferedDelayMs = null;
    _targetDelayMs = null;
    _sampledAt = null;
    _feedbackPeaks.clear();
    _playoutWindow.reset();
    _lastObservedAt = null;
    _lastPackets = 0;
    _freshEngine = freshEngine;
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
