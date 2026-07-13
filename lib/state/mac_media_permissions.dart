import 'dart:io';

import 'package:flutter/services.dart';

/// Apple/Android microphone and camera permission via a MethodChannel.
///
/// macOS and iOS use AVCaptureDevice.requestAccess; Android maps to runtime
/// RECORD_AUDIO/CAMERA. This presents the OS prompt before the native media
/// engine touches the device rather than relying on an implicit CoreAudio
/// access to do it. No-op (granted) on the remaining platforms.
class MacMediaPermissions {
  static const _ch = MethodChannel('xveil/media_permissions');

  static Future<bool> requestMicrophone() => _request('audio');
  static Future<bool> requestCamera() => _request('video');

  static Future<String> microphoneStatus() => _status('audio');
  static Future<String> cameraStatus() => _status('video');

  static Future<bool> _request(String type) async {
    if (!Platform.isMacOS && !Platform.isIOS && !Platform.isAndroid) {
      return true;
    }
    try {
      return (await _ch.invokeMethod<bool>('request', {'type': type})) ?? false;
    } catch (_) {
      return false;
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
