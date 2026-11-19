import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;

/// Whether a LOCAL preview should be shown mirrored.
///
/// A person looking at themselves expects a mirror: that is what every mirror
/// they have ever used does, and an un-mirrored self-view reads as "inverted"
/// even though it is what everybody else sees. Android already did this for a
/// front lens and the desktop path did not, so the same call showed the phone
/// its owner the right way round and the laptop its owner reversed.
///
/// A SHARED SCREEN is the exception and the reason this is a function rather
/// than a constant: text on a mirrored screen share is unreadable, and it is
/// not a face — nobody expects a mirror of their desktop.
bool selfViewMirrored({required bool screenSharing}) => !screenSharing;

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
    this.mirrored = false,
    this.enabled = true,
    this.frameBeforeSourceChange,
    this.staleLabel,
    this.staleAfter = const Duration(seconds: 4),
  });

  final ValueListenable<VeilVideoFrame?> frameListenable;
  final Object freshnessToken;
  final String waitingLabel;
  final BoxFit fit;
  final IconData placeholderIcon;

  /// Mirror only the camera pixels; waiting and stale labels stay readable.
  final bool mirrored;

  /// Keep the source boundary while a separate surface owns the preview.
  /// Enabling again waits for a frame newer than the value already cached.
  final bool enabled;

  /// The caller observed a source change before this surface was mounted.
  /// Compare against that frame without retaining its pixel buffer.
  final WeakReference<VeilVideoFrame>? frameBeforeSourceChange;

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
  ui.Image? _image;
  VeilVideoFrame? _pending;
  VeilVideoFrame? _blockedFrame;
  bool _busy = false;
  bool _waitingForFreshFrame = false;
  Timer? _decodeTimer;
  DateTime? _lastDecodeAt;
  Duration _minDecodeInterval = const Duration(microseconds: 16667);
  int _generation = 0;
  // Whole seconds of the 1 s stale timer since the last accepted frame.
  // Tick-counted (not wall-clock) so the widget-test fake clock drives it.
  int _ticksSinceFrame = 0;
  bool _stale = false;
  Timer? _staleTimer;

  @override
  void initState() {
    super.initState();
    widget.frameListenable.addListener(_onFrame);
    // An already-confirmed static screen may never emit another frame. A new
    // surface may inherit it unless the caller saw a change after that frame.
    final previous = widget.frameBeforeSourceChange?.target;
    _resetSource(
      blockCurrent:
          !widget.enabled ||
          (previous != null &&
              identical(previous, widget.frameListenable.value)),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode no faster than this Flutter view can present. A 60 Hz display
    // gets a 60 fps ceiling, a 120 Hz display can present all source frames,
    // and a 30 Hz external display avoids decoding frames that cannot be
    // shown. The source itself remains the lower bound (normally 30 or 60).
    final refreshRate = View.of(context).display.refreshRate;
    final safeRate = refreshRate.isFinite && refreshRate > 1
        ? refreshRate
        : 60.0;
    _minDecodeInterval = Duration(
      microseconds: (1000000 / safeRate).round().clamp(1000, 1000000),
    );
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
        oldWidget.enabled != widget.enabled ||
        oldWidget.freshnessToken != widget.freshnessToken) {
      _resetSource(blockCurrent: true);
    }
    if (!widget.enabled || widget.staleLabel == null) _stopStaleTimer();
  }

  @override
  void dispose() {
    widget.frameListenable.removeListener(_onFrame);
    _decodeTimer?.cancel();
    _stopStaleTimer();
    _image?.dispose();
    super.dispose();
  }

  void _refreshStale() {
    _ticksSinceFrame++;
    final stale =
        _image != null && _ticksSinceFrame >= widget.staleAfter.inSeconds;
    if (stale != _stale && mounted) setState(() => _stale = stale);
  }

  void _stopStaleTimer() {
    _staleTimer?.cancel();
    _staleTimer = null;
  }

  void _resetSource({required bool blockCurrent}) {
    _generation++;
    _decodeTimer?.cancel();
    _decodeTimer = null;
    _stopStaleTimer();
    _pending = null;
    _lastDecodeAt = null;
    _ticksSinceFrame = 0;
    _stale = false;
    _image?.dispose();
    _image = null;
    final current = widget.enabled ? widget.frameListenable.value : null;
    _blockedFrame = blockCurrent ? current : null;
    _waitingForFreshFrame = blockCurrent;
    if (!blockCurrent) _acceptFrame(current);
  }

  void _onFrame() {
    if (widget.enabled) _acceptFrame(widget.frameListenable.value);
  }

  void _acceptFrame(VeilVideoFrame? frame) {
    if (frame == null) {
      // Invalidate a decode that may already be executing off the widget tree;
      // otherwise its callback could resurrect the last frame after teardown.
      _generation++;
      _decodeTimer?.cancel();
      _decodeTimer = null;
      _stopStaleTimer();
      _pending = null;
      _ticksSinceFrame = 0;
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
    if (widget.staleLabel != null) {
      _staleTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        _refreshStale();
      });
    }
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
    if (!widget.enabled) return const SizedBox.shrink();
    final image = _image;
    if (image != null) {
      final staleLabel = widget.staleLabel;
      final rawImage = RawImage(image: image, fit: widget.fit);
      final frame = widget.mirrored
          ? Transform.flip(flipX: true, child: rawImage)
          : rawImage;
      return ColoredBox(
        key: const ValueKey('call-video-frame'),
        color: Colors.black,
        child: _stale && staleLabel != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  frame,
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
            : frame,
      );
    }
    return CallVideoWaitingView(
      waitingLabel: widget.waitingLabel,
      placeholderIcon: widget.placeholderIcon,
    );
  }
}

class CallVideoWaitingView extends StatelessWidget {
  const CallVideoWaitingView({
    super.key,
    required this.waitingLabel,
    this.placeholderIcon = Icons.videocam_outlined,
  });

  final String waitingLabel;
  final IconData placeholderIcon;

  @override
  Widget build(BuildContext context) {
    const fontSize = 13.0;
    const iconSize = 38.0;
    const gap = 10.0;
    final label = Text(
      waitingLabel,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.68),
        fontSize: fontSize,
      ),
    );
    // Prefer space for the status text over a decorative icon on small tiles.
    final scaledText = MediaQuery.textScalerOf(context).scale(fontSize);
    return Semantics(
      label: waitingLabel,
      liveRegion: true,
      excludeSemantics: true,
      child: Center(
        key: const ValueKey('call-video-waiting'),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight < iconSize + gap + 2 * scaledText) {
              return label;
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  placeholderIcon,
                  color: Colors.white.withValues(alpha: 0.42),
                  size: iconSize,
                ),
                const SizedBox(height: gap),
                Flexible(child: label),
              ],
            );
          },
        ),
      ),
    );
  }
}
