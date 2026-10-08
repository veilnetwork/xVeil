import '../domain/call_signal.dart';

/// Audio activity measured at the receive stream, separately from video and
/// RTCP ingress. Default counters from a timed-out native worker are not data.
class CallAudioReceiveActivity {
  /// WebRTC's delay estimate filters recent buffer growth. Protect audio
  /// using the larger current buffer too, before that filter catches up.
  /// Missing buffer stats on older libraries retain the validated estimate.
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
    return buffer != null && buffer > delay ? buffer : delay;
  }

  int _lastPackets = 0;
  bool supported = false;
  DateTime? lastRxAt;
  DateTime? workerStalledSince;
  int _sequence = 0;
  int? _playoutDelayMs;
  DateTime? _sampledAt;
  int? _lastInterruptionCount;
  int _interruptionCount = 0;
  bool interrupted = false;
  static const sampleLifetime = Duration(seconds: 3);

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
      interruptionCount: fresh && _lastInterruptionCount != null
          ? _interruptionCount
          : null,
    );
  }

  void observe(Map<String, Object?> stats, DateTime now) {
    interrupted = false;
    _sequence++;
    _playoutDelayMs = null;
    _sampledAt = null;
    final packets = stats['audio_rx_pkts'];
    if (packets is! num || packets < 0) {
      workerStalledSince = null;
      return;
    }
    supported = true;
    if (stats['worker_stalled'] == 1) {
      workerStalledSince ??= now;
      return;
    }
    workerStalledSince = null;
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
      _sampledAt = now;
    }
  }

  void reset() {
    // Keep sequence monotonic across session repairs and unknown snapshots.
    _sequence++;
    _playoutDelayMs = null;
    _sampledAt = null;
    _lastPackets = 0;
    _lastInterruptionCount = null;
    interrupted = false;
    supported = false;
    lastRxAt = null;
    workerStalledSince = null;
  }
}
