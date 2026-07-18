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
    this.staleLabel,
    this.staleAfter = const Duration(seconds: 4),
  });

  final ValueListenable<VeilVideoFrame?> frameListenable;
  final Object freshnessToken;
  final String waitingLabel;
  final BoxFit fit;
  final IconData placeholderIcon;

  /// When set, a stream that STOPS delivering new frames (backgrounded peer
  /// app, stopped camera, stalled route) badges the last frame with this label
  /// after [staleAfter] instead of silently freezing — a frozen frame reads
  /// as a broken call, and nothing else tells the viewer the difference.
  final String? staleLabel;
  final Duration staleAfter;

  @override
  State<CallVideoFrameView> createState() => _CallVideoFrameViewState();
}

class _CallVideoFrameViewState extends State<CallVideoFrameView> {
  // The direct-P2P profile produces 20 fps. The old 66 ms renderer cap was
  // only ~15 fps, so one frame in four was discarded after it had already
  // crossed the network and decoded successfully. That presented as regular
  // judder even on a clean LAN call. Keep the UI ceiling aligned with the
  // profile; [_pending] still coalesces while an image decode is busy, so a
  // slow device retains latest-frame semantics instead of building a stale
  // render queue.
  static const _minDecodeInterval = Duration(milliseconds: 50);

  ui.Image? _image;
  VeilVideoFrame? _pending;
  VeilVideoFrame? _blockedFrame;
  bool _busy = false;
  bool _waitingForFreshFrame = false;
  Timer? _decodeTimer;
  DateTime? _lastDecodeAt;
  int _generation = 0;
  // Whole seconds of the 1 s stale timer since the last accepted frame.
  // Tick-counted (not wall-clock) so the widget-test fake clock drives it.
  int _ticksSinceFrame = 0;
  bool _hasFrameSource = false;
  bool _stale = false;
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    widget.frameListenable.addListener(_onFrame);
    // A newly mounted surface (for example mini → full) may inherit an
    // already-confirmed static screen frame. Only a token transition inside a
    // living surface proves that its current frame belongs to the old source.
    _resetSource(blockCurrent: false);
    if (widget.staleLabel != null) {
      _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _refreshStale();
      });
    }
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
    _staleTimer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _refreshStale() {
    if (_hasFrameSource) _ticksSinceFrame++;
    final stale =
        _image != null &&
        _hasFrameSource &&
        _ticksSinceFrame >= widget.staleAfter.inSeconds;
    if (stale != _stale && mounted) setState(() => _stale = stale);
  }

  void _resetSource({required bool blockCurrent}) {
    _generation++;
    _decodeTimer?.cancel();
    _decodeTimer = null;
    _pending = null;
    _lastDecodeAt = null;
    _ticksSinceFrame = 0;
    _hasFrameSource = false;
    _stale = false;
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
      _ticksSinceFrame = 0;
      _hasFrameSource = false;
      _stale = false;
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
    _ticksSinceFrame = 0;
    _hasFrameSource = true;
    if (_stale && mounted) setState(() => _stale = false);
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
      final staleLabel = widget.staleLabel;
      return ColoredBox(
        key: const ValueKey('call-video-frame'),
        color: Colors.black,
        child: _stale && staleLabel != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(image: image, fit: widget.fit),
                  ColoredBox(
                    key: const ValueKey('call-video-stale'),
                    color: Colors.black54,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.pause_circle_outline,
                            color: Colors.white.withValues(alpha: 0.7),
                            size: 34,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            staleLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : RawImage(image: image, fit: widget.fit),
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
