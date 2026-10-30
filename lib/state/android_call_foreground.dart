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
  static bool _wanted = false;
  static Future<void> _requests = Future<void>.value();

  static bool get isActive => _active;

  @visibleForTesting
  static void debugReset() {
    _active = false;
    _wanted = false;
    _requests = Future<void>.value();
    debugInvokeOverride = null;
  }

  /// Retry the typed grant after the first runtime permission sheet completes.
  /// A late OS answer belongs only to the media session that requested it.
  static Future<void> activateWhenMicrophoneGranted(
    Future<bool> permission, {
    required bool Function() isCurrent,
  }) async {
    final granted = await permission;
    if (granted && isCurrent()) await setActive(true);
  }

  static Future<void> setActive(bool active) {
    final invoke = debugInvokeOverride;
    if (!Platform.isAndroid && invoke == null) return Future<void>.value();
    _wanted = active;
    // Start/stop share one native service. A stop must remain queued even
    // while a previous start has not yet returned its acknowledged state.
    final request = _requests.then((_) async {
      while (true) {
        final wanted = _wanted;
        if (_active == wanted) return;
        try {
          final ok = invoke != null
              ? await invoke(wanted)
              : await _channel.invokeMethod<bool>('setActive', {
                  'active': wanted,
                });
          _active = wanted && ok == true;
          devLog(
            () =>
                'xVeil[call-media]: Android call foreground service '
                'requested=$wanted ok=${ok == true}',
          );
        } catch (error) {
          _active = false;
          devLog(
            () =>
                'xVeil[call-media]: Android call foreground service failed: '
                '$error',
          );
        }
        // A denial is not a busy-retry loop. A later grant/request may retry.
        if (_wanted == wanted) return;
      }
    });
    _requests = request;
    return request;
  }
}
