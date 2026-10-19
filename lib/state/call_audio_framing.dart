/// WebRTC's transport overhead is per logical packet on a path. Replication
/// cost is reported separately: counting it as one larger header would also
/// multiply payload, conflating the two congestion models. Endpoint admission
/// still charges every physical copy; no relay receives this local model.
int? callMediaFramingOverhead(Map<String, Object?>? cost) {
  if (cost == null) return null;
  final packet = cost['packet_bytes'];
  final overhead = cost['per_path_overhead_bytes'];
  final wire = cost['per_path_wire_bytes_x2'];
  final total = cost['source_wire_bytes_x2'];
  final copies = cost['source_copies_limit'];
  if (packet is! int ||
      packet < 12 ||
      packet > 1460 ||
      overhead is! int ||
      overhead < 1 ||
      overhead > 4096 ||
      wire is! int ||
      wire < 2 * packet ||
      copies is! int ||
      copies < 1 ||
      copies > 8 ||
      total is! int ||
      total < wire ||
      total > copies * wire ||
      overhead != (wire - 2 * packet + 1) ~/ 2) {
    return null;
  }
  return overhead;
}

/// Retains only acknowledged video framing. Unknown source metadata or a busy
/// native worker leaves the current hint in place and is retried next time.
class CallVideoFraming {
  int _lastPackets = 0, _lastBytes = 0;
  int _packetBytes = 200;
  int appliedOverheadBytes = 0;
  Map<String, Object?>? sourceCost;

  void refresh({
    Map<String, dynamic>? stats,
    required Map<String, Object?>? Function(int packetBytes) query,
    required bool Function(int overheadBytes) apply,
  }) {
    final packets = stats?['video_tx_payload_pkts'];
    final bytes = stats?['video_tx_payload_bytes'];
    if (packets is int && bytes is int) {
      final count = packets - _lastPackets;
      final payload = bytes - _lastBytes;
      if (count > 0 && payload > 0) {
        // One negotiated TWCC extension: RTP header 20. Native counters omit
        // RTP headers and exclude padding, so neither is counted twice.
        _packetBytes = ((payload / count).ceil() + 20).clamp(12, 1000);
      }
      _lastPackets = packets;
      _lastBytes = bytes;
    }
    sourceCost = query(_packetBytes);
    if (sourceCost?['packet_bytes'] != _packetBytes) return;
    final overhead = callMediaFramingOverhead(sourceCost);
    // The pinned video RTP sender subtracts this from a 1500-byte path MTU.
    if (overhead == null ||
        overhead > 1024 ||
        overhead == appliedOverheadBytes) {
      return;
    }
    if (apply(overhead)) appliedOverheadBytes = overhead;
  }
}
