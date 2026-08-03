import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';

/// Receives one captured frame as tightly-packed I420 (y=w*h, u=v=cw*ch).
typedef I420FrameSink =
    void Function(Uint8List y, Uint8List u, Uint8List v, int width, int height);

typedef Android420FrameSink =
    bool Function(
      Uint8List y,
      Uint8List u,
      Uint8List v,
      int width,
      int height,
      int yStride,
      int uStride,
      int vStride,
      int uvPixelStride,
      int rotation,
    );

/// Native camera texture used by the in-call self-preview. Unlike the RGBA
/// diagnostic/presentation path this is composited without a YUV -> RGBA copy
/// through Dart, so the preview can follow the camera/display cadence.
final ValueNotifier<CameraController?> androidCallCameraPreviewController =
    ValueNotifier(null);

const MethodChannel _cameraCapabilitiesChannel = MethodChannel(
  'xveil/camera_capabilities',
);

/// Chooses the highest exact capture cadence that the camera reports, capped
/// at 60 fps. Exact ranges matter: a compatibility layer may accept an
/// unsupported 60 fps request but silently broaden it to 10-30, producing a
/// visibly uneven stream instead of failing initialization and letting us
/// retry at 30.
@visibleForTesting
int preferredExactCameraFps(Iterable<int> available) {
  final rates = available.where((fps) => fps > 0 && fps <= 60).toSet();
  if (rates.contains(60)) return 60;
  if (rates.contains(30)) return 30;
  if (rates.isEmpty) return 30;
  return rates.reduce((a, b) => a > b ? a : b);
}

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
  int _rotCw = 0; // clockwise rotation to make the frame upright (0/90/180/270)
  Isolate? _worker;
  ReceivePort? _workerResults;
  StreamSubscription<Object?>? _workerSubscription;
  SendPort? _workerJobs;
  I420FrameSink? _sink;
  Android420FrameSink? _rawSink;
  bool _workerBusy = false;
  int? _requestedFps;
  int _inputFrames = 0;
  int _outputFrames = 0;
  int? _firstInputUs;
  int? _lastInputUs;
  int _maxInputGapUs = 0;
  int _inputHoldsOver75Ms = 0;

  /// Open the front camera (falls back to the first) and stream frames to
  /// [sink]. Returns false if no camera / permission denied / init failed.
  Future<bool> start(I420FrameSink sink) async {
    return _start(i420Sink: sink);
  }

  /// Call-only fast path: hand Camera2's strided Android420 planes to libyuv
  /// instead of de-striding and rotating every pixel in Dart.
  Future<bool> startAndroid420(Android420FrameSink sink) async {
    return _start(rawSink: sink);
  }

  Future<bool> _start({
    I420FrameSink? i420Sink,
    Android420FrameSink? rawSink,
  }) async {
    try {
      _rawSink = rawSink;
      if (i420Sink != null) await _startWorker(i420Sink);
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
      devLog(
        () =>
            'veil-cam: lens=${cam.lensDirection} '
            'sensor=${cam.sensorOrientation} rotCw=$_rotCw',
      );
      final ctrl = await _openController(cam);
      _ctrl = ctrl;
      androidCallCameraPreviewController.value = ctrl;
      await ctrl.startImageStream(_onImage);
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  final Stopwatch _sw = Stopwatch()..start();
  int _lastPushMs = -1000;
  int get _minGapMs => highQuality ? 0 : 80; // direct native rate, onion ~12fps

  double get captureFps {
    final first = _firstInputUs;
    final last = _lastInputUs;
    if (first == null || last == null || last <= first || _inputFrames < 2) {
      return 0;
    }
    return ((_inputFrames - 1) * 1000000 / (last - first) * 10).round() / 10;
  }

  Map<String, Object?> get diagnostics => {
    'camera_requested_fps': _requestedFps ?? 0,
    'camera_capture_fps': captureFps,
    'camera_capture_frames': _inputFrames,
    'camera_processed_frames': _outputFrames,
    'camera_capture_max_gap_ms': _maxInputGapUs ~/ 1000,
    'camera_capture_holds_75ms': _inputHoldsOver75Ms,
  };

  Future<void> _startWorker(I420FrameSink sink) async {
    _sink = sink;
    final ready = Completer<SendPort>();
    final results = ReceivePort();
    _workerResults = results;
    _workerSubscription = results.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! _CameraFrameResult) return;
      _workerBusy = false;
      final activeSink = _sink;
      if (activeSink == null) return;
      final y = message.y.materialize().asUint8List();
      final u = message.u.materialize().asUint8List();
      final v = message.v.materialize().asUint8List();
      _outputFrames++;
      activeSink(y, u, v, message.width, message.height);
    });
    _worker = await Isolate.spawn(_cameraFrameWorker, results.sendPort);
    _workerJobs = await ready.future.timeout(const Duration(seconds: 3));
  }

  /// Ask the Android camera backend for the best stable exact rate on a direct
  /// route, but do not make camera support
  /// for that exact mode a call prerequisite. Devices commonly expose only
  /// 30 fps for the selected front-camera resolution, and camera backends may
  /// reject an unsupported exact FPS range instead of selecting the closest
  /// one. In that case retry with the platform default.
  Future<CameraController> _openController(CameraDescription cam) async {
    var directFps = 30;
    if (highQuality) {
      try {
        final exactRates = await _cameraCapabilitiesChannel
            .invokeListMethod<int>('exactFps', {'cameraId': cam.name});
        directFps = preferredExactCameraFps(exactRates ?? const <int>[]);
        devLog(
          () =>
              'veil-cam: camera=${cam.name} exactFps=$exactRates '
              'selected=$directFps',
        );
      } catch (error) {
        // Stable 30 is a safer compatibility fallback than an unsupported 60:
        // A compatibility layer may accept the latter but silently turn it
        // into variable 10-30. The channel is app-owned and can be absent in
        // older test hosts.
        devLog(() => 'veil-cam: exact FPS query failed, using 30: $error');
      }
    }
    final requestedRates = highQuality
        ? <int?>[directFps, null]
        : const <int?>[null];
    Object? lastError;
    for (final fps in requestedRates) {
      final ctrl = CameraController(
        cam,
        highQuality ? ResolutionPreset.medium : ResolutionPreset.low,
        enableAudio: false,
        fps: fps,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      try {
        await ctrl.initialize();
        _requestedFps = fps;
        devLog(
          () =>
              'veil-cam: requestedFps=${fps ?? 'default'} '
              'preview=${ctrl.value.previewSize}',
        );
        return ctrl;
      } catch (error) {
        lastError = error;
        try {
          await ctrl.dispose();
        } catch (_) {}
      }
    }
    throw StateError('Unable to initialize camera: $lastError');
  }

  void _onImage(CameraImage img) {
    if (img.format.group != ImageFormatGroup.yuv420 || img.planes.length < 3) {
      return;
    }
    // Direct calls use every frame at the highest exact cadence reported by
    // the camera (up to 60 fps; see [_openController]). Padded onion calls stay
    // near 12 fps to protect CPU and cell bandwidth.
    final now = _sw.elapsedMilliseconds;
    if (_minGapMs > 0 && now - _lastPushMs < _minGapMs) return;
    _lastPushMs = now;
    final nowUs = _sw.elapsedMicroseconds;
    final previousUs = _lastInputUs;
    _firstInputUs ??= nowUs;
    if (previousUs != null) {
      final gapUs = nowUs - previousUs;
      if (gapUs > _maxInputGapUs) _maxInputGapUs = gapUs;
      if (gapUs >= 75000) _inputHoldsOver75Ms++;
    }
    _lastInputUs = nowUs;
    _inputFrames++;

    final rawSink = _rawSink;
    if (rawSink != null) {
      final p0 = img.planes[0], p1 = img.planes[1], p2 = img.planes[2];
      final uPixelStride = p1.bytesPerPixel ?? 1;
      final vPixelStride = p2.bytesPerPixel ?? 1;
      if (uPixelStride == vPixelStride &&
          rawSink(
            p0.bytes,
            p1.bytes,
            p2.bytes,
            img.width,
            img.height,
            p0.bytesPerRow,
            p1.bytesPerRow,
            p2.bytesPerRow,
            uPixelStride,
            _rotCw,
          )) {
        _outputFrames++;
      }
      return;
    }

    // Camera callbacks arrive on Flutter's UI isolate. Keep that callback
    // bounded to ownership transfer; de-striding and rotating hundreds of
    // thousands of pixels there made both the preview and all controls hitch.
    if (_workerBusy) return;
    final jobs = _workerJobs;
    if (jobs == null) return;
    _workerBusy = true;
    final p0 = img.planes[0], p1 = img.planes[1], p2 = img.planes[2];
    jobs.send(
      _CameraFrameJob(
        width: img.width,
        height: img.height,
        rotation: _rotCw,
        y: TransferableTypedData.fromList([p0.bytes]),
        u: TransferableTypedData.fromList([p1.bytes]),
        v: TransferableTypedData.fromList([p2.bytes]),
        yStride: p0.bytesPerRow,
        uStride: p1.bytesPerRow,
        vStride: p2.bytesPerRow,
        uPixelStride: p1.bytesPerPixel ?? 1,
        vPixelStride: p2.bytesPerPixel ?? 1,
      ),
    );
  }

  Future<void> stop() async {
    _sink = null;
    _rawSink = null;
    final c = _ctrl;
    _ctrl = null;
    if (identical(androidCallCameraPreviewController.value, c)) {
      androidCallCameraPreviewController.value = null;
    }
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
    }
    _workerJobs = null;
    _workerBusy = false;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    await _workerSubscription?.cancel();
    _workerSubscription = null;
    _workerResults?.close();
    _workerResults = null;
  }
}

class _CameraFrameJob {
  const _CameraFrameJob({
    required this.width,
    required this.height,
    required this.rotation,
    required this.y,
    required this.u,
    required this.v,
    required this.yStride,
    required this.uStride,
    required this.vStride,
    required this.uPixelStride,
    required this.vPixelStride,
  });

  final int width, height, rotation;
  final TransferableTypedData y, u, v;
  final int yStride, uStride, vStride, uPixelStride, vPixelStride;
}

class _CameraFrameResult {
  const _CameraFrameResult({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
  });

  final int width, height;
  final TransferableTypedData y, u, v;
}

void _cameraFrameWorker(SendPort results) {
  final jobs = ReceivePort();
  results.send(jobs.sendPort);
  jobs.listen((message) {
    if (message is! _CameraFrameJob) return;
    final w = message.width, h = message.height;
    final cw = (w + 1) >> 1, ch = (h + 1) >> 1;
    final y = Uint8List(w * h);
    final u = Uint8List(cw * ch);
    final v = Uint8List(cw * ch);
    _copyPlane(
      message.y.materialize().asUint8List(),
      y,
      w,
      h,
      message.yStride,
      1,
    );
    _copyPlane(
      message.u.materialize().asUint8List(),
      u,
      cw,
      ch,
      message.uStride,
      message.uPixelStride,
    );
    _copyPlane(
      message.v.materialize().asUint8List(),
      v,
      cw,
      ch,
      message.vStride,
      message.vPixelStride,
    );

    var outY = y, outU = u, outV = v;
    var ow = w, oh = h;
    if (message.rotation != 0) {
      final swap = message.rotation == 90 || message.rotation == 270;
      ow = swap ? h : w;
      oh = swap ? w : h;
      final ocw = (ow + 1) >> 1, och = (oh + 1) >> 1;
      outY = Uint8List(ow * oh);
      outU = Uint8List(ocw * och);
      outV = Uint8List(ocw * och);
      _rotatePlane(y, w, h, outY, message.rotation);
      _rotatePlane(u, cw, ch, outU, message.rotation);
      _rotatePlane(v, cw, ch, outV, message.rotation);
    }
    results.send(
      _CameraFrameResult(
        width: ow,
        height: oh,
        y: TransferableTypedData.fromList([outY]),
        u: TransferableTypedData.fromList([outU]),
        v: TransferableTypedData.fromList([outV]),
      ),
    );
  });
}

void _copyPlane(
  Uint8List bytes,
  Uint8List out,
  int width,
  int height,
  int rowStride,
  int pixelStride,
) {
  if (pixelStride == 1 && rowStride == width && bytes.length >= out.length) {
    out.setRange(0, out.length, bytes);
    return;
  }
  var offset = 0;
  for (var row = 0; row < height; row++) {
    var input = row * rowStride;
    for (var column = 0; column < width; column++) {
      out[offset++] = input < bytes.length ? bytes[input] : 128;
      input += pixelStride;
    }
  }
}

void _rotatePlane(Uint8List src, int sw, int sh, Uint8List out, int degrees) {
  if (degrees == 90) {
    final dw = sh;
    for (var y = 0; y < sh; y++) {
      final row = y * sw;
      for (var x = 0; x < sw; x++) {
        out[x * dw + (sh - 1 - y)] = src[row + x];
      }
    }
  } else if (degrees == 270) {
    final dw = sh;
    for (var y = 0; y < sh; y++) {
      final row = y * sw;
      for (var x = 0; x < sw; x++) {
        out[(sw - 1 - x) * dw + y] = src[row + x];
      }
    }
  } else {
    final length = sw * sh;
    for (var i = 0; i < length; i++) {
      out[i] = src[length - 1 - i];
    }
  }
}
