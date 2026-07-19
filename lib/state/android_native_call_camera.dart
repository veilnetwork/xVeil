import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  });

  final int textureId;
  final int width;
  final int height;
  final int rotation;
  final bool mirror;
  final int fps;

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
        mirror is! bool) {
      return null;
    }
    return AndroidNativeCameraPreview(
      textureId: textureId,
      width: width,
      height: height,
      rotation: rotation,
      mirror: mirror,
      fps: fps,
    );
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
  Map<String, Object?> get diagnostics => _diagnostics;

  Future<bool> start({
    required int engineAddress,
    required int width,
    required int height,
    required int fps,
  }) async {
    await stop();
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>('start', {
        'engine': engineAddress,
        'width': width,
        'height': height,
        'fps': fps,
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
      debugPrint('veil-camera2: start failed ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('veil-camera2: start failed: $error');
      return false;
    }
  }

  Future<void> refreshStats() async {
    if (_preview == null) return;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
      if (value == null) return;
      _diagnostics = value.map(
        (key, item) => MapEntry(key?.toString() ?? '', item),
      )..remove('');
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
