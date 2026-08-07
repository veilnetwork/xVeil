/// Zero-padded 24h `HH:mm` for chat timestamps.
String formatHhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Full local `YYYY-MM-DD HH:mm:ss` for message-detail views. No intl dep —
/// kept dependency-free and deterministic (used in the message-info sheet).
String formatDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// Coarse "how long ago", for spans a person reads rather than measures.
///
/// Deliberately one unit and no decimals: the question it answers is whether a
/// device has been away for minutes or for months, and a subtitle that says
/// "43.7 days" reads like a measurement nobody asked for. No intl dependency,
/// same as the rest of this file.
String formatAgo(Duration d) {
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  final months = d.inDays ~/ 30;
  if (months < 12) return '${months}mo ago';
  return '${d.inDays ~/ 365}y ago';
}

/// Human-readable byte size (B/KB/MB/GB, one decimal above KB).
String formatBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}
