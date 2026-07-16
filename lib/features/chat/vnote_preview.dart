// Live video-note frame view, shared by the 1:1 and group bubbles (and the
// recording self-preview): listens to a [VeilVideoFrame] source and paints
// each RGBA frame decoded to a [ui.Image]. Frames arrive faster than decode
// on low-end devices — a frame that lands mid-decode is simply skipped (the
// next listener tick picks a fresh one).

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;

class VnotePreview extends StatefulWidget {
  const VnotePreview({
    super.key,
    required this.frameListenable,
    this.mirror = false,
  });
  final ValueListenable<VeilVideoFrame?> frameListenable;

  /// Horizontally flip the painted frames. The RECORDING self-preview sets
  /// this: the source is always the front-facing lens (Android's vnote
  /// capturer is hard-wired to the front camera; macOS has the one built-in
  /// user-facing camera), and people expect to see themselves as in a mirror
  /// (Telegram behavior). Display-only — the recorded frames and playback
  /// stay unmirrored, which is how the clip should look to the receiver.
  final bool mirror;

  @override
  State<VnotePreview> createState() => _VnotePreviewState();
}

class _VnotePreviewState extends State<VnotePreview> {
  ui.Image? _image;
  bool _decoding = false;

  @override
  void initState() {
    super.initState();
    widget.frameListenable.addListener(_onFrame);
    _onFrame();
  }

  @override
  void dispose() {
    widget.frameListenable.removeListener(_onFrame);
    _image?.dispose();
    super.dispose();
  }

  void _onFrame() {
    final f = widget.frameListenable.value;
    if (f == null || _decoding) return;
    _decoding = true;
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      (img) {
        _decoding = false;
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = img;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return const ColoredBox(
        color: Colors.black26,
        child: Center(child: Icon(Icons.videocam, size: 28)),
      );
    }
    final frame = RawImage(image: img, fit: BoxFit.cover);
    if (!widget.mirror) return frame;
    return Transform.flip(
      key: const ValueKey('vnote-preview-mirror'),
      flipX: true,
      child: frame,
    );
  }
}
