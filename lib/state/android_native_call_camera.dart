import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';

/// Geometry and texture identity returned by the app-owned Camera2 call path.
@immutable
class AndroidNativeCameraPreview {
  const AndroidNativeCameraPreview({
    required this.textureId,
    required this.width,
    required this.height,
    required this.rotation,
    required this.mirror,
    required this.fps,
    required this.cameraId,
    required this.facing,
  });

  final int textureId;

  /// The size the TEXTURE has, not the size the sensor captures.
  ///
  /// The two differ whenever the sensor is mounted at 90/270: Flutter's
  /// external-texture renderer applies the SurfaceTexture producer matrix, so
  /// the texture arrives upright with the sensor's axes already swapped. The
  /// platform side reports the swapped pair for exactly this reason — laying an
  /// upright texture out at the sensor's landscape size is what squashed the
  /// self-view (2026-08-07).
  final int width;
  final int height;
  final int rotation;

  /// Additional Dart flip, after Flutter applies the producer matrix. Camera2
  /// supplies its front-lens mirror in that matrix and needs no extra flip.
  final bool mirror;
  final int fps;
  final String cameraId;
  final String facing;

  static AndroidNativeCameraPreview? fromMap(Map<Object?, Object?>? value) {
    if (value == null) return null;
    final textureId = (value['textureId'] as num?)?.toInt();
    final width = (value['width'] as num?)?.toInt();
    final height = (value['height'] as num?)?.toInt();
    // Camera2's ImageReader frames and its SurfaceTexture preview have
    // different orientation contracts. Native code rotates the former before
    // encoding; Flutter's external-texture renderer already consumes the
    // latter's producer matrix. Keep this explicitly preview-only. The legacy
    // key remains a compatibility fallback for an older platform half during
    // hot restart.
    final rotation =
        (value['previewRotation'] as num?)?.toInt() ??
        (value['rotation'] as num?)?.toInt();
    final fps = (value['fps'] as num?)?.toInt();
    final mirror = value['mirror'];
    final cameraId = value['cameraId'];
    final facing = value['facing'];
    if (textureId == null ||
        textureId < 0 ||
        width == null ||
        width <= 0 ||
        height == null ||
        height <= 0 ||
        rotation == null ||
        !const <int>{0, 90, 180, 270}.contains(rotation) ||
        fps == null ||
        fps <= 0 ||
        mirror is! bool ||
        cameraId is! String ||
        cameraId.isEmpty ||
        facing is! String) {
      return null;
    }
    return AndroidNativeCameraPreview(
      textureId: textureId,
      width: width,
      height: height,
      rotation: rotation,
      mirror: mirror,
      fps: fps,
      cameraId: cameraId,
      facing: facing,
    );
  }
}

@immutable
class AndroidNativeCameraDevice {
  const AndroidNativeCameraDevice({
    required this.id,
    required this.label,
    required this.facing,
  });

  final String id;
  final String label;
  final String facing;

  static AndroidNativeCameraDevice? fromMap(Map<Object?, Object?> value) {
    final id = value['id'];
    final label = value['label'];
    final facing = value['facing'];
    if (id is! String || id.isEmpty || label is! String || facing is! String) {
      return null;
    }
    return AndroidNativeCameraDevice(id: id, label: label, facing: facing);
  }
}

/// Shared only for the self-preview surface; camera pixels remain native.
final ValueNotifier<AndroidNativeCameraPreview?>
androidNativeCallCameraPreview = ValueNotifier<AndroidNativeCameraPreview?>(
  null,
);

class _CameraRequest {
  _CameraRequest(this.owner);

  final AndroidNativeCallCamera owner;
}

class AndroidNativeCallCamera {
  AndroidNativeCallCamera({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('xveil/native_call_camera');

  final MethodChannel _channel;
  // MainActivity owns one Camera2 capture for all Dart bridge instances. Claim
  // it before the first await: FIFO commands do not imply FIFO async replies.
  static _CameraRequest? _activeRequest;
  _CameraRequest? _request;
  final Set<Future<void>> _drainingStops = {};
  Timer? _statsTimer;
  AndroidNativeCameraPreview? _preview;
  Map<String, Object?> _diagnostics = const {};

  bool get isRunning => _preview != null;
  String? get cameraId => _preview?.cameraId;
  Map<String, Object?> get diagnostics => _diagnostics;

  Future<bool> start({
    required int engineAddress,
    required int width,
    required int height,
    required int fps,
    String? cameraId,
  }) async {
    final previous = _activeRequest;
    previous?.owner._retireLocal(previous);
    final request = _CameraRequest(this);
    _request = request;
    _activeRequest = request;
    final stopped = _stopPlatform(retiringOwner: previous?.owner);
    androidNativeCallCameraPreview.value = null;
    await stopped;
    if (!_owns(request)) return _finishSupersededStart();
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>('start', {
        'engine': engineAddress,
        'width': width,
        'height': height,
        'fps': fps,
        if (cameraId != null && cameraId.isNotEmpty) 'cameraId': cameraId,
      });
      // A later start/stop already owns the platform. In particular, never
      // clean up this stale reply with a global stop of its replacement.
      if (!_owns(request)) return _finishSupersededStart();
      final preview = AndroidNativeCameraPreview.fromMap(result);
      if (preview == null) {
        await stop();
        return false;
      }
      _preview = preview;
      _diagnostics = {
        'camera_native': true,
        'camera_id': preview.cameraId,
        'camera_facing': preview.facing,
        'camera_requested_fps': preview.fps,
        'camera_running': true,
      };
      _statsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(refreshStats()),
      );
      androidNativeCallCameraPreview.value = preview;
      // ValueNotifier listeners run synchronously and may stop or replace us.
      if (!_owns(request)) return _finishSupersededStart();
      unawaited(refreshStats());
      return true;
    } on PlatformException catch (error) {
      if (!_owns(request)) return _finishSupersededStart();
      devLog(
        () => 'veil-camera2: start failed ${error.code}: ${error.message}',
      );
      await stop();
      return false;
    } catch (error) {
      if (!_owns(request)) return _finishSupersededStart();
      devLog(() => 'veil-camera2: start failed: $error');
      await stop();
      return false;
    }
  }

  Future<List<AndroidNativeCameraDevice>> listDevices() async {
    try {
      final values = await _channel.invokeListMethod<Object?>('list');
      return (values ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map(AndroidNativeCameraDevice.fromMap)
          .whereType<AndroidNativeCameraDevice>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> refreshStats() async {
    final preview = _preview;
    if (preview == null) return;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
      // A camera switch can complete while this platform reply is in flight.
      // Retired capture stats must not clear the new texture or its mirroring.
      if (value == null ||
          !identical(_preview, preview) ||
          !identical(androidNativeCallCameraPreview.value, preview)) {
        return;
      }
      _diagnostics = {
        'camera_native': true,
        'camera_id': preview.cameraId,
        'camera_facing': preview.facing,
        ...value.map((key, item) => MapEntry(key?.toString() ?? '', item))
          ..remove(''),
      };
      if (_diagnostics['camera_running'] == false) {
        _preview = null;
        androidNativeCallCameraPreview.value = null;
        _statsTimer?.cancel();
        _statsTimer = null;
      }
    } catch (_) {
      // Diagnostics must never affect capture or a running call.
    }
  }

  bool _owns(_CameraRequest request) =>
      identical(_request, request) && identical(_activeRequest, request);

  Future<bool> _finishSupersededStart() async {
    // The caller may release this start's engine as soon as false is returned.
    // Cancellation must therefore fence its old native callbacks just like stop.
    await Future.wait(_drainingStops.toList());
    return false;
  }

  void _retireLocal(_CameraRequest request) {
    if (!identical(_request, request)) return;
    _request = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _preview = null;
    _diagnostics = const {};
  }

  void _trackStop(Future<void> stopped) {
    if (!_drainingStops.add(stopped)) return;
    unawaited(
      stopped.then<void>((_) {
        _drainingStops.remove(stopped);
      }),
    );
  }

  Future<void> _stopPlatform({AndroidNativeCallCamera? retiringOwner}) {
    final stopped = () async {
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {
        // Idempotent teardown; the Android activity owns a final cleanup too.
      }
    }();
    _trackStop(stopped);
    retiringOwner?._trackStop(stopped);
    return stopped;
  }

  Future<void> stop() async {
    final request = _request;
    if (request != null && _owns(request)) {
      _retireLocal(request);
      _activeRequest = null;
      _stopPlatform();
      androidNativeCallCameraPreview.value = null;
    }
    // A replacement can have already sent stop for us. Its acknowledgement
    // fences old Camera2/copy callbacks: an obsolete owner must still await it
    // before its engine is freed, without issuing another stop of the new lens.
    await Future.wait(_drainingStops.toList());
  }
}
