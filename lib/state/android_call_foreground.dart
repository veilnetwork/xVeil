import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';

/// Holds the Android microphone-typed foreground service exactly while a
/// 1:1 or group call is active.
///
/// Without the typed service Android's "while in use" microphone mode feeds
/// silently muted frames to the veil audio engine as soon as the screen
/// locks — Opus keeps sending ~2.5 DTX packets/s, so nothing errors and the
/// far side just hears silence. The service carries only the grant and the
/// ongoing-call notification; capture stays with the native engine.
class AndroidCallForegroundService {
  static const MethodChannel _channel = MethodChannel('xveil/call_foreground');

  /// Test seam: unit tests run on the host, where neither the platform gate
  /// nor a channel handler exists.
  @visibleForTesting
  static Future<bool?> Function(bool active)? debugInvokeOverride;

  static bool _active = false;

  static bool get isActive => _active;

  @visibleForTesting
  static void debugReset() {
    _active = false;
    debugInvokeOverride = null;
  }

  static Future<void> setActive(bool active) async {
    final invoke = debugInvokeOverride;
    if ((!Platform.isAndroid && invoke == null) || _active == active) return;
    try {
      final ok = invoke != null
          ? await invoke(active)
          : await _channel.invokeMethod<bool>('setActive', {'active': active});
      _active = active && ok == true;
      devLog(
        () =>
            'xVeil[call-media]: Android call foreground service '
            'requested=$active ok=${ok == true}',
      );
    } catch (error) {
      _active = false;
      devLog(
        () => 'xVeil[call-media]: Android call foreground service failed: '
            '$error',
      );
    }
  }
}
