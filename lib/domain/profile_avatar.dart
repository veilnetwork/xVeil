import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// One encrypted setting and one live authenticated frame; always below both
/// the HV value limit and the 6144-byte authenticated transport limit.
const kAvatarMaxBytes = 1300;
const kSelfAvatarSetting = 'profile.avatar:self';
String peerAvatarSetting(String peer) => 'profile.avatar:$peer';

class ProfileAvatar {
  const ProfileAvatar(this.updatedAt, this.bytes);
  final int updatedAt;
  final Uint8List? bytes;

  String encode() => jsonEncode({
    'v': 1,
    'at': updatedAt,
    'd': bytes == null ? null : base64Encode(bytes!),
  });

  static ProfileAvatar? decode(String raw) {
    if (raw.length > 1900) return null;
    try {
      final v = jsonDecode(raw);
      if (v is! Map ||
          v['v'] != 1 ||
          v['at'] is! int ||
          v['at'] < 0 ||
          v['at'] > 9007199254740991) {
        return null;
      }
      if (v['d'] == null) return ProfileAvatar(v['at'], null);
      if (v['d'] is! String) return null;
      final bytes = base64Decode(v['d']);
      if (bytes.isEmpty || bytes.length > kAvatarMaxBytes) return null;
      final info = image.JpegDecoder().startDecode(bytes);
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width > 128 ||
          info.height > 128) {
        return null;
      }
      // Header dimensions bound allocations before full decode; no external
      // URL, source filename or EXIF is ever accepted as profile metadata.
      if (image.decodeJpg(bytes) == null) return null;
      return ProfileAvatar(v['at'], bytes);
    } catch (_) {
      return null;
    }
  }
}

/// Input is a small, re-rendered PNG produced by Flutter's image codec. Re-encode
/// pixels as JPEG, dropping source metadata, and reduce until one bounded value
/// fits. This function is also usable in an isolate.
Uint8List? encodeAvatarPixels(Uint8List png) {
  final pixels = image.decodePng(png);
  if (pixels == null || pixels.width > 128 || pixels.height > 128) return null;
  final side = pixels.width < pixels.height ? pixels.width : pixels.height;
  final square = image.copyCrop(
    pixels,
    x: (pixels.width - side) ~/ 2,
    y: (pixels.height - side) ~/ 2,
    width: side,
    height: side,
  );
  square.exif = image.ExifData();
  square.iccProfile = null;
  square.textData = null;
  for (final size in [128, 96, 64, 48, 32]) {
    final resized = side <= size
        ? square
        : image.copyResize(square, width: size, height: size);
    for (final quality in [80, 60, 40]) {
      final bytes = image.encodeJpg(resized, quality: quality);
      if (bytes.length <= kAvatarMaxBytes) return bytes;
    }
  }
  return null;
}
