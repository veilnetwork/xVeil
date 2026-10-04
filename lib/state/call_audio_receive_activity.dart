/// Audio activity measured at the receive stream, separately from video and
/// RTCP ingress. Default counters from a timed-out native worker are not data.
class CallAudioReceiveActivity {
  int _lastPackets = 0;
  bool supported = false;
  DateTime? lastRxAt;
  DateTime? workerStalledSince;

  void observe(Map<String, Object?> stats, DateTime now) {
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
  }

  void reset() {
    _lastPackets = 0;
    supported = false;
    lastRxAt = null;
    workerStalledSince = null;
  }
}
