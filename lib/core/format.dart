/// Zero-padded 24h `HH:mm` for chat timestamps.
String formatHhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
