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
  final int width;
  final int height;
  final int rotation;
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

class AndroidNativeCallCamera {
  AndroidNativeCallCamera({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('xveil/native_call_camera');

  final MethodChannel _channel;
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
    await stop();
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>('start', {
        'engine': engineAddress,
        'width': width,
        'height': height,
        'fps': fps,
        if (cameraId != null && cameraId.isNotEmpty) 'cameraId': cameraId,
      });
      final preview = AndroidNativeCameraPreview.fromMap(result);
      if (preview == null) {
        await _channel.invokeMethod<void>('stop');
        return false;
      }
      _preview = preview;
      androidNativeCallCameraPreview.value = preview;
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
      unawaited(refreshStats());
      return true;
    } on PlatformException catch (error) {
      devLog(
        () => 'veil-camera2: start failed ${error.code}: ${error.message}',
      );
      return false;
    } catch (error) {
      devLog(() => 'veil-camera2: start failed: $error');
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
      if (value == null) return;
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

  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _preview = null;
    _diagnostics = const {};
    androidNativeCallCameraPreview.value = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Idempotent teardown; the Android activity also owns a final cleanup.
    }
  }
}
