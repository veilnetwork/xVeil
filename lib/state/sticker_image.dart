import 'dart:typed_data';
import 'dart:ui' as ui;

import 'sticker_message.dart';
import '../domain/inline_custom_emoji.dart';

/// Flutter image-codec adapter for sticker import. Kept out of the sticker
/// wire/domain library so the headless daemon can compile without `dart:ui`.
Future<Uint8List?> normalizeStickerBytes(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  try {
    buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width, h = desc.height;
    if (w <= 0 || h <= 0) return null;
    final long = w > h ? w : h;
    if (long <= kStickerMaxDim && bytes.length <= kStickerMaxBytes) {
      return bytes;
    }
    final scale = long > kStickerMaxDim ? kStickerMaxDim / long : 1.0;
    final tw = (w * scale).round().clamp(1, kStickerMaxDim);
    final th = (h * scale).round().clamp(1, kStickerMaxDim);
    final codec = await desc.instantiateCodec(
      targetWidth: tw,
      targetHeight: th,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) return null;
        return data.buffer.asUint8List(0, data.lengthInBytes);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    desc?.dispose();
    buf?.dispose();
  }
}

/// Produce a tiny static PNG suitable for the inline custom-emoji sidecar.
/// The original sticker blob is never modified; animated/large stickers keep
/// their full form when sent normally, while this derived copy is retried down
/// a dimension ladder until it fits the authenticated-frame budget.
Future<Uint8List?> normalizeCustomEmojiBytes(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  try {
    buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width, h = desc.height;
    if (w <= 0 || h <= 0) return null;
    final longest = w > h ? w : h;
    for (final maxDim in const [48, 40, 32, 28, 24, 20, 16, 12]) {
      final scale = maxDim / longest;
      final tw = (w * scale).round().clamp(1, maxDim);
      final th = (h * scale).round().clamp(1, maxDim);
      final codec = await desc.instantiateCodec(
        targetWidth: tw,
        targetHeight: th,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) continue;
          final png = data.buffer.asUint8List(0, data.lengthInBytes);
          if (png.length <= kInlineCustomEmojiMaxBytes) {
            return Uint8List.fromList(png);
          }
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    desc?.dispose();
    buf?.dispose();
  }
}
