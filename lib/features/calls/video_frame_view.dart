import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;

/// Coalescing RGBA renderer shared by direct and group calls.
///
/// [freshnessToken] identifies the logical source currently expected on the
/// single video track (for example camera vs screen). When it changes, the
/// already-decoded image is deliberately discarded and the current notifier
/// value is ignored until a newer frame arrives. This prevents the last camera
/// frame from masquerading as a screen share while platform consent is still
/// open, and likewise prevents a stopped screen from freezing over the resumed
/// camera.
class CallVideoFrameView extends StatefulWidget {
  const CallVideoFrameView({
    super.key,
    required this.frameListenable,
    required this.freshnessToken,
    required this.waitingLabel,
    this.fit = BoxFit.contain,
    this.placeholderIcon = Icons.videocam_outlined,
  });

  final ValueListenable<VeilVideoFrame?> frameListenable;
  final Object freshnessToken;
  final String waitingLabel;
  final BoxFit fit;
  final IconData placeholderIcon;

  @override
  State<CallVideoFrameView> createState() => _CallVideoFrameViewState();
}

class _CallVideoFrameViewState extends State<CallVideoFrameView> {
  static const _minDecodeInterval = Duration(milliseconds: 66);

  ui.Image? _image;
  VeilVideoFrame? _pending;
  VeilVideoFrame? _blockedFrame;
  bool _busy = false;
  bool _waitingForFreshFrame = false;
  Timer? _decodeTimer;
  DateTime? _lastDecodeAt;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.frameListenable.addListener(_onFrame);
    // A newly mounted surface (for example mini → full) may inherit an
    // already-confirmed static screen frame. Only a token transition inside a
    // living surface proves that its current frame belongs to the old source.
    _resetSource(blockCurrent: false);
  }

  @override
  void didUpdateWidget(covariant CallVideoFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final listenableChanged =
        oldWidget.frameListenable != widget.frameListenable;
    if (listenableChanged) {
      oldWidget.frameListenable.removeListener(_onFrame);
      widget.frameListenable.addListener(_onFrame);
    }
    if (listenableChanged ||
        oldWidget.freshnessToken != widget.freshnessToken) {
      _resetSource(blockCurrent: true);
    }
  }

  @override
  void dispose() {
    widget.frameListenable.removeListener(_onFrame);
    _decodeTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _resetSource({required bool blockCurrent}) {
    _generation++;
    _decodeTimer?.cancel();
    _decodeTimer = null;
    _pending = null;
    _lastDecodeAt = null;
    _image?.dispose();
    _image = null;
    final current = widget.frameListenable.value;
    _blockedFrame = blockCurrent ? current : null;
    _waitingForFreshFrame = blockCurrent;
    if (!blockCurrent) _acceptFrame(current);
  }

  void _onFrame() => _acceptFrame(widget.frameListenable.value);

  void _acceptFrame(VeilVideoFrame? frame) {
    if (frame == null) {
      // Invalidate a decode that may already be executing off the widget tree;
      // otherwise its callback could resurrect the last frame after teardown.
      _generation++;
      _decodeTimer?.cancel();
      _decodeTimer = null;
      _pending = null;
      if (!_waitingForFreshFrame && _image != null && mounted) {
        setState(() {
          _image?.dispose();
          _image = null;
        });
      }
      return;
    }
    if (_waitingForFreshFrame && identical(frame, _blockedFrame)) return;
    _blockedFrame = null;
    _waitingForFreshFrame = false;
    _pending = frame;
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_busy || _decodeTimer != null) return;
    final last = _lastDecodeAt;
    if (last == null) {
      _drain();
      return;
    }
    final elapsed = DateTime.now().difference(last);
    if (elapsed >= _minDecodeInterval) {
      _drain();
      return;
    }
    _decodeTimer = Timer(_minDecodeInterval - elapsed, () {
      _decodeTimer = null;
      if (mounted) _drain();
    });
  }

  void _drain() {
    final frame = _pending;
    if (frame == null) {
      _busy = false;
      return;
    }
    _pending = null;
    _busy = true;
    _lastDecodeAt = DateTime.now();
    final generation = _generation;
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || generation != _generation) {
          image.dispose();
          if (mounted) {
            _busy = false;
            if (_pending != null) _scheduleDrain();
          }
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
        _busy = false;
        if (_pending != null) _scheduleDrain();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) {
      return ColoredBox(
        key: const ValueKey('call-video-frame'),
        color: Colors.black,
        child: RawImage(image: image, fit: widget.fit),
      );
    }
    return Semantics(
      label: widget.waitingLabel,
      liveRegion: true,
      excludeSemantics: true,
      child: Center(
        key: const ValueKey('call-video-waiting'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.placeholderIcon,
              color: Colors.white.withValues(alpha: 0.42),
              size: 38,
            ),
            const SizedBox(height: 10),
            Text(
              widget.waitingLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.68),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
