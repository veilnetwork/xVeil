// Sticker domain helpers (stickers epic, brick 1).
//
// A sticker is a SMALL IMAGE sent through the content path under the `.stkr`
// extension — the bytes are an ordinary decodable image (PNG/JPEG/WebP;
// animated WebP animates for free in Image.memory, which is why Lottie was
// rejected: stickers here are built FROM THE USER'S OWN PICTURES, not a
// designer JSON format). The extension only drives the bubble choice: the
// receiver renders the image NAKED (no bubble chrome), Telegram-style. An
// ordinary image micro-thumb rides the sidecar for render-before-download.

import 'dart:typed_data';
import 'dart:ui' as ui;

// File extension a sticker is sent under.
const String kStickerFileExt = '.stkr';

/// Soft cap for sticker bytes: anything under the receiver's auto-download
/// cap lands instantly; imports downscale to fit (512 px longest side).
const int kStickerMaxBytes = 256 * 1024;
const int kStickerMaxDim = 512;

bool isStickerFileName(String? name) {
  if (name == null) return false;
  return name.toLowerCase().endsWith(kStickerFileExt);
}

/// Normalize an imported image for use as a sticker: decode, and if it exceeds
/// [kStickerMaxDim] on the long side OR [kStickerMaxBytes], re-encode as PNG
/// scaled down (aspect-preserved). Returns the original bytes when already
/// small enough (keeps animated WebP intact — those animate for free), or null
/// when [bytes] is not a decodable image.
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
    // Already within budget → keep as-is (preserves WebP animation).
    if (long <= kStickerMaxDim && bytes.length <= kStickerMaxBytes) {
      return bytes;
    }
    final scale = long > kStickerMaxDim ? kStickerMaxDim / long : 1.0;
    final tw = (w * scale).round().clamp(1, kStickerMaxDim);
    final th = (h * scale).round().clamp(1, kStickerMaxDim);
    final codec =
        await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
    try {
      final frame = await codec.getNextFrame();
      try {
        final data =
            await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return data.buffer.asUint8List(0, data.lengthInBytes);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null; // not an image / decoder rejected it
  } finally {
    desc?.dispose();
    buf?.dispose();
  }
}
