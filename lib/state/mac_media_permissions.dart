import 'dart:io';

import 'package:flutter/services.dart';

enum MediaPermissionStatus { allowed, denied, restricted, unavailable }

/// Apple/Android microphone and camera permission via a MethodChannel.
///
/// macOS and iOS use AVCaptureDevice.requestAccess; Android maps to runtime
/// RECORD_AUDIO/CAMERA. This presents the OS prompt before the native media
/// engine touches the device rather than relying on an implicit CoreAudio
/// access to do it. No-op (granted) on the remaining platforms.
class MacMediaPermissions {
  static const _ch = MethodChannel('xveil/media_permissions');

  static Future<bool> requestMicrophone() async =>
      await requestMicrophoneAccess() == MediaPermissionStatus.allowed;
  static Future<bool> requestCamera() async =>
      await requestCameraAccess() == MediaPermissionStatus.allowed;

  static Future<MediaPermissionStatus> requestMicrophoneAccess() =>
      _request('audio');
  static Future<MediaPermissionStatus> requestCameraAccess() =>
      _request('video');

  static Future<String> microphoneStatus() => _status('audio');
  static Future<String> cameraStatus() => _status('video');

  static bool get hasPermissionBridge =>
      Platform.isMacOS || Platform.isIOS || Platform.isAndroid;

  static Future<MediaPermissionStatus> _request(String type) async {
    if (!hasPermissionBridge) return MediaPermissionStatus.allowed;
    try {
      final granted = await _ch.invokeMethod<Object>('request', {'type': type});
      return switch (granted) {
        true => MediaPermissionStatus.allowed,
        false => MediaPermissionStatus.denied,
        'restricted' => MediaPermissionStatus.restricted,
        _ => MediaPermissionStatus.unavailable,
      };
    } catch (_) {
      return MediaPermissionStatus.unavailable;
    }
  }

  static Future<String> _status(String type) async {
    if (!Platform.isMacOS && !Platform.isIOS && !Platform.isAndroid) {
      return 'unsupported';
    }
    try {
      return (await _ch.invokeMethod<String>('status', {'type': type})) ??
          'unknown';
    } catch (_) {
      return 'error';
    }
  }
}
