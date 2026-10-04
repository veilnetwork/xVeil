import '../domain/call_signal.dart';

/// Audio activity measured at the receive stream, separately from video and
/// RTCP ingress. Default counters from a timed-out native worker are not data.
class CallAudioReceiveActivity {
  int _lastPackets = 0;
  bool supported = false;
  DateTime? lastRxAt;
  DateTime? workerStalledSince;
  int _sequence = 0;
  int? _playoutDelayMs;
  DateTime? _sampledAt;
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
    );
  }

  void observe(Map<String, Object?> stats, DateTime now) {
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
    final count = packets.toInt();
    if (count > _lastPackets) lastRxAt = now;
    _lastPackets = count;
    final delay = stats['audio_delay_ms'];
    // Only a successfully queried audio worker supplies a playout estimate.
    if (stats['worker_stalled'] == 0 &&
        count > 0 &&
        delay is num &&
        delay.isFinite &&
        delay >= 0 &&
        delay <= 60000) {
      _playoutDelayMs = delay.toInt();
      _sampledAt = now;
    }
  }

  void reset() {
    // Keep sequence monotonic across session repairs and unknown snapshots.
    _sequence++;
    _playoutDelayMs = null;
    _sampledAt = null;
    _lastPackets = 0;
    supported = false;
    lastRxAt = null;
    workerStalledSince = null;
  }
}
