// Micro-thumbnail embedded IN a file message (media epic: instant preview
// before the blob is downloaded).
//
// The thumb travels inside the content-manifest ADVERT (an unbound field —
// see ContentManifest.thumbB64), so its budget is dictated by the advert
// having to fit ONE datagram alongside the manifest ref (~300 B): raw PNG is
// capped at [kThumbMaxRawBytes] (≈3.4 KB as base64). The generator downsizes
// through a dimension ladder until the encoded PNG fits, and returns null for
// anything undecodable (not an image, corrupt) or still over budget — a thumb
// is always OPTIONAL, the message works without it.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Raw (pre-base64) budget for the embedded thumb PNG. Keeps the manifest
/// ref advert (~300 B) + thumb comfortably under the inline envelope limit.
const int kThumbMaxRawBytes = 2500;

/// True when [name] looks like a video the in-app player can open (by
/// extension; the containers ExoPlayer/AVPlayer overlap on).
bool isVideoFileName(String? name) {
  if (name == null) return false;
  final n = name.toLowerCase();
  return n.endsWith('.mp4') ||
      n.endsWith('.m4v') ||
      n.endsWith('.mov') ||
      n.endsWith('.webm') ||
      n.endsWith('.mkv');
}

/// True when [name] looks like an image we can render inline (by extension).
/// Shared by the chat UI (inline previews) and the send path (thumb
/// generation) — one definition so they cannot disagree.
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

/// Dimension ladder for the longest image side, tried in order until the
/// encoded PNG fits [kThumbMaxRawBytes]. 32 px is a Telegram-class micro
/// preview (the UI upscales + blurs it); photographic PNGs at 32 px are
/// usually 1.5–3 KB, so the smaller rungs are the fallback for noisy images.
const List<int> _thumbDims = [32, 24, 16];

/// Encode a micro-thumbnail from a RAW RGBA frame (a video-note first frame —
/// there is no encoded source file to hand to the codec ladder). Scales to
/// the same ladder rungs and returns base64 PNG under the same byte budget,
/// or null when nothing fits / the frame is empty.
Future<String?> makeRgbaThumbB64(Uint8List rgba, int width, int height) async {
  if (rgba.isEmpty || width <= 0 || height <= 0) return null;
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  final src = await completer.future;
  try {
    for (final dim in _thumbDims) {
      final scale = dim / math.max(width, height);
      final tw = scale >= 1 ? width : math.max(1, (width * scale).round());
      final th = scale >= 1 ? height : math.max(1, (height * scale).round());
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        src,
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final img = await picture.toImage(tw, th);
      picture.dispose();
      try {
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        if (data != null && data.lengthInBytes <= kThumbMaxRawBytes) {
          return base64Encode(data.buffer.asUint8List(0, data.lengthInBytes));
        }
      } finally {
        img.dispose();
      }
      if (scale >= 1) break;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    src.dispose();
  }
}

/// Encode a micro-thumbnail for [bytes] (an image file's full contents) as
/// base64 PNG, or null when [bytes] is not a decodable image or no ladder
/// rung fits the byte budget. Aspect ratio is preserved (longest side =
/// ladder rung); never upscales a source smaller than the rung.
Future<String?> makeMessageThumbB64(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  try {
    buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    // Dimensions without a full-size decode.
    desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width, h = desc.height;
    if (w <= 0 || h <= 0) return null;
    for (final dim in _thumbDims) {
      final scale = dim / math.max(w, h);
      final tw = scale >= 1 ? w : math.max(1, (w * scale).round());
      final th = scale >= 1 ? h : math.max(1, (h * scale).round());
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
          if (data != null && data.lengthInBytes <= kThumbMaxRawBytes) {
            return base64Encode(data.buffer.asUint8List(0, data.lengthInBytes));
          }
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      if (scale >= 1) break; // source already smaller than the rung — a
      // smaller rung cannot shrink it further.
    }
    return null;
  } catch (_) {
    return null; // not an image / decoder rejected it — no thumb.
  } finally {
    desc?.dispose();
    buf?.dispose();
  }
}
