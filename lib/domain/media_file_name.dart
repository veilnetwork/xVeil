/// Filename-only media classification shared by Flutter UI and headless core.
bool isVideoFileName(String? name) {
  if (name == null) return false;
  final n = name.toLowerCase();
  return n.endsWith('.mp4') ||
      n.endsWith('.m4v') ||
      n.endsWith('.mov') ||
      n.endsWith('.webm') ||
      n.endsWith('.mkv');
}

bool isImageFileName(String? name) {
  if (name == null) return false;
  final n = name.toLowerCase();
  return n.endsWith('.jpg') ||
      n.endsWith('.jpeg') ||
      n.endsWith('.png') ||
      n.endsWith('.gif') ||
      n.endsWith('.webp') ||
      n.endsWith('.bmp');
}
