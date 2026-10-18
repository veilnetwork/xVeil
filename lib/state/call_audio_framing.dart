/// WebRTC's transport overhead is per logical packet on a path. Replication
/// cost is reported separately: counting it as one larger header would also
/// multiply payload, conflating the two congestion models. Endpoint admission
/// still charges every physical copy; no relay receives this local model.
int? callAudioFramingOverhead(Map<String, Object?>? cost) {
  if (cost == null) return null;
  final packet = cost['packet_bytes'];
  final overhead = cost['per_path_overhead_bytes'];
  final wire = cost['per_path_wire_bytes_x2'];
  final total = cost['source_wire_bytes_x2'];
  final copies = cost['source_copies_limit'];
  if (packet is! int ||
      packet < 12 ||
      packet > 1000 ||
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
