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
