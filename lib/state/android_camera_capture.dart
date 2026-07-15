import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Receives one captured frame as tightly-packed I420 (y=w*h, u=v=cw*ch).
typedef I420FrameSink =
    void Function(Uint8List y, Uint8List u, Uint8List v, int width, int height);

/// Android camera SEND path for a video call. macOS captures natively inside
/// libveil_media (AVCaptureSession); Android has no native backend, so this
/// Dart capturer streams YUV420 frames from the `camera` plugin,
/// converts each to I420, and hands them to a sink that pushes into the engine.
///
/// Anonymous media stays deliberately low-res because every RTP packet occupies
/// a padded 16KB onion cell. Direct P2P uses the medium capture preset and lets
/// WebRTC adapt it under the larger route-specific bitrate budget.
/// One capturer per live call.
class AndroidCameraCapture {
  AndroidCameraCapture({this.highQuality = false});

  /// Direct P2P can afford a 720p capture source that WebRTC scales/adapts;
  /// padded onion media keeps the old low-resolution source.
  final bool highQuality;
  CameraController? _ctrl;
  Uint8List? _y, _u, _v; // reused I420 planes (sensor orientation)
  Uint8List? _ry, _ru, _rv; // reused rotated-upright I420 planes
  int _rotCw = 0; // clockwise rotation to make the frame upright (0/90/180/270)

  /// Open the front camera (falls back to the first) and stream frames to
  /// [sink]. Returns false if no camera / permission denied / init failed.
  Future<bool> start(I420FrameSink sink) async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return false;
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      // Camera frames arrive in sensor orientation; rotate them clockwise by
      // sensorOrientation so the far side sees an upright image. (Device-checked:
      // the front sensor here reports 90 -> a 90° CW rotation lands upright; the
      // earlier 360-sensor form produced 270° = upside-down.)
      _rotCw = cam.sensorOrientation % 360;
      debugPrint(
        'veil-cam: lens=${cam.lensDirection} '
        'sensor=${cam.sensorOrientation} rotCw=$_rotCw',
      );
      final ctrl = CameraController(
        cam,
        highQuality ? ResolutionPreset.medium : ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await ctrl.initialize();
      _ctrl = ctrl;
      await ctrl.startImageStream((img) => _onImage(img, sink));
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  final Stopwatch _sw = Stopwatch()..start();
  int _lastPushMs = -1000;
  int get _minGapMs => highQuality ? 50 : 80; // direct ~20fps, onion ~12fps

  void _onImage(CameraImage img, I420FrameSink sink) {
    if (img.format.group != ImageFormatGroup.yuv420 || img.planes.length < 3) {
      return;
    }
    // Drop frames to ~12fps: at the camera's native 30fps the phone would both
    // encode 30 frames/s and decode the remote stream, saturating the CPU.
    final now = _sw.elapsedMilliseconds;
    if (now - _lastPushMs < _minGapMs) return;
    _lastPushMs = now;

    final w = img.width, h = img.height;
    final cw = (w + 1) >> 1, ch = (h + 1) >> 1;
    if (_y == null || _y!.length != w * h) _y = Uint8List(w * h);
    if (_u == null || _u!.length != cw * ch) {
      _u = Uint8List(cw * ch);
      _v = Uint8List(cw * ch);
    }
    _copyY(img.planes[0], _y!, w, h);
    _copyChroma(img.planes[1], _u!, cw, ch);
    _copyChroma(img.planes[2], _v!, cw, ch);

    if (_rotCw == 0) {
      sink(_y!, _u!, _v!, w, h);
      return;
    }
    // Rotate the I420 upright. 90/270 swap the dimensions.
    final swap = _rotCw == 90 || _rotCw == 270;
    final ow = swap ? h : w, oh = swap ? w : h;
    final ocw = (ow + 1) >> 1, och = (oh + 1) >> 1;
    if (_ry == null || _ry!.length != ow * oh) _ry = Uint8List(ow * oh);
    if (_ru == null || _ru!.length != ocw * och) {
      _ru = Uint8List(ocw * och);
      _rv = Uint8List(ocw * och);
    }
    _rotate(_y!, w, h, _ry!, _rotCw);
    _rotate(_u!, cw, ch, _ru!, _rotCw);
    _rotate(_v!, cw, ch, _rv!, _rotCw);
    sink(_ry!, _ru!, _rv!, ow, oh);
  }

  // Rotate a tightly-packed single plane clockwise by deg (90/180/270) from
  // sw x sh into out (dims swapped for 90/270).
  static void _rotate(Uint8List src, int sw, int sh, Uint8List out, int deg) {
    if (deg == 90) {
      final dw = sh; // out width
      for (var y = 0; y < sh; y++) {
        final row = y * sw;
        for (var x = 0; x < sw; x++) {
          out[x * dw + (sh - 1 - y)] = src[row + x];
        }
      }
    } else if (deg == 270) {
      final dw = sh;
      for (var y = 0; y < sh; y++) {
        final row = y * sw;
        for (var x = 0; x < sw; x++) {
          out[(sw - 1 - x) * dw + y] = src[row + x];
        }
      }
    } else {
      // 180
      final n = sw * sh;
      for (var i = 0; i < n; i++) {
        out[i] = src[n - 1 - i];
      }
    }
  }

  static void _copyY(Plane p, Uint8List out, int w, int h) {
    final b = p.bytes;
    final stride = p.bytesPerRow;
    if (stride == w && b.length >= w * h) {
      out.setRange(0, w * h, b);
      return;
    }
    for (var r = 0; r < h; r++) {
      final src = r * stride;
      final n = src + w <= b.length ? w : (b.length - src).clamp(0, w);
      if (n > 0) out.setRange(r * w, r * w + n, b, src);
    }
  }

  // YUV_420_888 chroma may be planar (pixelStride 1) or semi-planar (2, U/V
  // interleaved) depending on the device; de-stride per pixel, guarding the
  // last-row read that a tightly-sized semi-planar buffer can run past.
  static void _copyChroma(Plane p, Uint8List out, int cw, int ch) {
    final b = p.bytes;
    final stride = p.bytesPerRow;
    final px = p.bytesPerPixel ?? 1;
    if (px == 1 && stride == cw && b.length >= cw * ch) {
      out.setRange(0, cw * ch, b);
      return;
    }
    var o = 0;
    for (var r = 0; r < ch; r++) {
      var i = r * stride;
      for (var c = 0; c < cw; c++) {
        out[o++] = i < b.length ? b[i] : 128;
        i += px;
      }
    }
  }

  Future<void> stop() async {
    final c = _ctrl;
    _ctrl = null;
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
    }
    _y = _u = _v = null;
  }
}
