import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/call_signal.dart';

enum CallAudioRoute { earpiece, speaker }

/// Owns the phone's communication-audio route for both direct and group calls.
///
/// A call that starts with video uses the loudspeaker; an audio-only call uses
/// the receiver as a conventional handset call. The route remains user
/// switchable from the shared in-call controls.
class CallAudioRouter {
  CallAudioRouter({MethodChannel? channel, bool? hasNativePhoneRoute})
    : _channel = channel ?? const MethodChannel('xveil/call_audio_route'),
      _hasNativePhoneRoute =
          hasNativePhoneRoute ?? (Platform.isAndroid || Platform.isIOS);

  final MethodChannel _channel;
  final bool _hasNativePhoneRoute;
  final ValueNotifier<CallAudioRoute> route = ValueNotifier(
    CallAudioRoute.earpiece,
  );

  bool get supportsPhoneRouting => _hasNativePhoneRoute;

  Future<bool> useDefaultFor(CallMedia media) => setRoute(
    media.video || media.screen
        ? CallAudioRoute.speaker
        : CallAudioRoute.earpiece,
  );

  Future<bool> setRoute(CallAudioRoute next) async {
    if (!_hasNativePhoneRoute) {
      route.value = next;
      return true;
    }
    try {
      final applied =
          await _channel.invokeMethod<bool>('setRoute', {
            'speaker': next == CallAudioRoute.speaker,
          }) ??
          false;
      if (applied) route.value = next;
      return applied;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> toggle() => setRoute(
    route.value == CallAudioRoute.speaker
        ? CallAudioRoute.earpiece
        : CallAudioRoute.speaker,
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
    route.value = CallAudioRoute.earpiece;
  }
}

final callAudioRouter = CallAudioRouter();
