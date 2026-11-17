import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/call_signal.dart';
import '../core/diagnostic_journal.dart';

enum CallAudioRoute { earpiece, speaker, external }

/// Owns the phone's communication-audio route for both direct and group calls.
///
/// Connected headphones take precedence on Android. Without them, video uses
/// the loudspeaker and audio uses the receiver when a call starts. Once chosen,
/// the route stays in place across camera changes until release or an explicit
/// user selection. Reapplying a default can disconnect Android's audio devices.
class CallAudioRouter {
  CallAudioRouter({
    MethodChannel? channel,
    bool? hasNativePhoneRoute,
    DiagnosticJournal? diagnostics,
  }) : _channel = channel ?? const MethodChannel('xveil/call_audio_route'),
       _diagnostics = diagnostics ?? diagnosticJournal,
       _hasNativePhoneRoute =
           hasNativePhoneRoute ?? (Platform.isAndroid || Platform.isIOS);

  final MethodChannel _channel;
  final DiagnosticJournal _diagnostics;
  final bool _hasNativePhoneRoute;
  bool _routeEstablished = false;
  int _operationEpoch = 0;
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
    final operation = ++_operationEpoch;
    bool current() => operation == _operationEpoch;
    var success = false;
    var code = 0;
    try {
      CallAudioRoute? effective;
      if (!_hasNativePhoneRoute) {
        effective = next;
      } else {
        try {
          final result = await _channel.invokeMethod<Object?>('setRoute', {
            'speaker': next == CallAudioRoute.speaker,
            if (preferExternal) 'preferExternal': true,
          });
          if (!current()) return false;
          // Android reports the effective route; iOS and older hosts return bool.
          if (result is String) {
            for (final candidate in CallAudioRoute.values) {
              if (candidate.name == result) {
                effective = candidate;
                break;
              }
            }
          } else if (result == true) {
            effective = next;
          }
        } on PlatformException {
          code = 1;
          return false;
        } on MissingPluginException {
          code = 2;
          return false;
        }
      }
      if (effective == null) return false;
      // Listeners may synchronously request a default or release this route.
      // Publish the established flag first; never restore it after callbacks.
      _routeEstablished = true;
      route.value = effective;
      if (!current()) return false;
      success = true;
      return true;
    } finally {
      // A retired result must not overwrite the current diagnostic outcome.
      if (current()) {
        _diagnostics.record(
          DiagnosticEvent.audioRoute,
          values: {
            DiagnosticMetric.supported: _hasNativePhoneRoute ? 1 : 0,
            DiagnosticMetric.success: success ? 1 : 0,
            DiagnosticMetric.state: route.value.index,
            DiagnosticMetric.code: code,
          },
        );
      }
    }
  }

  Future<bool> toggle() => _applyRoute(
    route.value == CallAudioRoute.speaker
        ? CallAudioRoute.earpiece
        : CallAudioRoute.speaker,
    preferExternal: route.value == CallAudioRoute.speaker,
  );

  Future<void> release() async {
    final operation = ++_operationEpoch;
    _routeEstablished = false;
    // Enqueue native release BEFORE notifying listeners: a reentrant setup
    // must be ordered after it on the shared platform channel.
    final stopped = _hasNativePhoneRoute
        ? Future<void>.sync(() => _channel.invokeMethod<void>('release'))
        : null;
    if (operation == _operationEpoch) route.value = CallAudioRoute.earpiece;
    if (stopped != null) {
      try {
        await stopped;
      } on PlatformException {
        // Route cleanup is best-effort during media teardown.
      } on MissingPluginException {
        // Older builds do not expose the route channel.
      }
    }
    // New setup may already own the route; this reply changes no local state.
  }
}

final callAudioRouter = CallAudioRouter();
