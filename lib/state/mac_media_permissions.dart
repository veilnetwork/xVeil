import 'dart:io';

import 'package:flutter/services.dart';

/// macOS microphone/camera TCC permission via a MethodChannel to
/// AVCaptureDevice.requestAccess (see macos/Runner/MainFlutterWindow.swift).
/// The canonical way to present the system prompt — WebRTC's ADM reaching
/// CoreAudio directly does not reliably trigger it. No-op (granted) off macOS.
class MacMediaPermissions {
  static const _ch = MethodChannel('xveil/media_permissions');

  static Future<bool> requestMicrophone() => _request('audio');
  static Future<bool> requestCamera() => _request('video');

  static Future<String> microphoneStatus() => _status('audio');

  static Future<bool> _request(String type) async {
    // macOS + Android drive the native xveil/media_permissions channel
    // (AVCaptureDevice / ActivityCompat.requestPermissions). Other platforms
    // have no runtime gate here → treat as granted.
    if (!Platform.isMacOS && !Platform.isAndroid) return true;
    try {
      return (await _ch.invokeMethod<bool>('request', {'type': type})) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _status(String type) async {
    if (!Platform.isMacOS && !Platform.isAndroid) return 'unsupported';
    try {
      return (await _ch.invokeMethod<String>('status', {'type': type})) ??
          'unknown';
    } catch (_) {
      return 'error';
    }
  }
}
