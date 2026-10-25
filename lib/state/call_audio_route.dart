import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/call_signal.dart';

enum CallAudioRoute { earpiece, speaker, external }

/// Owns the phone's communication-audio route for both direct and group calls.
///
/// Connected headphones take precedence on Android. Without them, video uses
/// the loudspeaker and audio uses the receiver when a call starts. Once chosen,
/// the route stays in place across camera changes until release or an explicit
/// user selection. Reapplying a default can disconnect Android's audio devices.
class CallAudioRouter {
  CallAudioRouter({MethodChannel? channel, bool? hasNativePhoneRoute})
    : _channel = channel ?? const MethodChannel('xveil/call_audio_route'),
      _hasNativePhoneRoute =
          hasNativePhoneRoute ?? (Platform.isAndroid || Platform.isIOS);

  final MethodChannel _channel;
  final bool _hasNativePhoneRoute;
  bool _routeEstablished = false;
  final ValueNotifier<CallAudioRoute> route = ValueNotifier(
    CallAudioRoute.earpiece,
  );

  bool get supportsPhoneRouting => _hasNativePhoneRoute;

  Future<bool> useDefaultFor(CallMedia media) => _routeEstablished
      ? Future.value(true)
      : _applyRoute(
          media.video || media.screen
              ? CallAudioRoute.speaker
              : CallAudioRoute.earpiece,
          preferExternal: true,
        );

  Future<bool> setRoute(CallAudioRoute next) =>
      _applyRoute(next, preferExternal: next == CallAudioRoute.external);

  Future<bool> _applyRoute(
    CallAudioRoute next, {
    bool preferExternal = false,
  }) async {
    if (!_hasNativePhoneRoute) {
      route.value = next;
      _routeEstablished = true;
      return true;
    }
    try {
      final result = await _channel.invokeMethod<Object?>('setRoute', {
        'speaker': next == CallAudioRoute.speaker,
        if (preferExternal) 'preferExternal': true,
      });
      // Android reports the effective route; iOS and older hosts return bool.
      if (result is String) {
        for (final candidate in CallAudioRoute.values) {
          if (candidate.name == result) {
            route.value = candidate;
            _routeEstablished = true;
            return true;
          }
        }
        return false;
      }
      if (result == true) {
        route.value = next;
        _routeEstablished = true;
      }
      return result == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> toggle() => _applyRoute(
    route.value == CallAudioRoute.speaker
        ? CallAudioRoute.earpiece
        : CallAudioRoute.speaker,
    preferExternal: route.value == CallAudioRoute.speaker,
  );

  Future<void> release() async {
    if (_hasNativePhoneRoute) {
      try {
        await _channel.invokeMethod<void>('release');
      } on PlatformException {
        // Route cleanup is best-effort during media teardown.
      } on MissingPluginException {
        // Older builds do not expose the route channel.
      }
    }
    _routeEstablished = false;
    route.value = CallAudioRoute.earpiece;
  }
}

final callAudioRouter = CallAudioRouter();
