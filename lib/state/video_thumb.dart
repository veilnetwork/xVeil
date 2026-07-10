// Sender-side video preview frame (media epic: a video message shows a real
// frame in the bubble, not just a play icon).
//
// The frame is grabbed by PLATFORM code from the sender's OWN source file on
// disk (macOS AVAssetImageGenerator / Android MediaMetadataRetriever via the
// `xveil/video_thumb` MethodChannel) — the plaintext already lives there, so
// nothing decrypted is ever written out. The grabbed frame then goes through
// the same [makeMessageThumbB64] ladder/budget as image thumbs and travels in
// the manifest advert's unbound 'th' field. Everything is best-effort: on any
// platform without a handler (Linux, tests) or any grab failure the thumb is
// simply null and the bubble keeps its play-icon row.

import 'package:flutter/services.dart';

import '../core/log.dart';
import 'thumbnail.dart';

/// Longest side of the frame the PLATFORM returns. Deliberately larger than
/// the final 32/24/16 ladder so [makeMessageThumbB64] has clean pixels to
/// downsize from, while keeping the channel payload tiny.
const int kVideoFrameMaxDim = 64;

/// Grabs one representative frame (as an encoded image — PNG/JPEG) from the
/// video file at [path], or null when it cannot. Replaceable for tests.
typedef VideoFrameGrabber = Future<Uint8List?> Function(String path);

/// Process-global grabber the send path uses — tests override it with a fake
/// (the default talks to the platform channel, absent under flutter_test).
VideoFrameGrabber videoFrameGrabber = channelVideoFrameGrabber;

const MethodChannel _channel = MethodChannel('xveil/video_thumb');

/// The production grabber: asks the host platform for a small encoded frame.
Future<Uint8List?> channelVideoFrameGrabber(String path) async {
  try {
    return await _channel.invokeMethod<Uint8List>('frame', {
      'path': path,
      'maxDim': kVideoFrameMaxDim,
    });
  } on MissingPluginException {
    return null; // platform without a handler (Linux) — no thumb, no error
  } on PlatformException catch (e) {
    devLog(() => 'xVeil[video-thumb]: frame grab failed: ${e.code}');
    return null;
  }
}

/// Micro-thumb (base64 PNG, same budget as image thumbs) for the video at
/// [path], or null when the platform can't produce a frame / the frame won't
/// fit the budget. Sender-side only — receivers get the thumb in the advert.
Future<String?> makeVideoThumbB64(String path) async {
  final frame = await videoFrameGrabber(path);
  if (frame == null || frame.isEmpty) return null;
  return makeMessageThumbB64(frame);
}
