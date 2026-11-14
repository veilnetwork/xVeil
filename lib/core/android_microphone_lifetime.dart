import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'log.dart';

abstract interface class MicrophoneResourceRetirement {
  Future<void> verifyReleasedResources();
  Future<void> releaseAdmission();
}

final class _NativeMicrophoneRetirement
    implements MicrophoneResourceRetirement {
  _NativeMicrophoneRetirement(this.token);
  final String token;
  @override
  Future<void> verifyReleasedResources() => AndroidMicrophoneLifetime.channel
      .invokeMethod<void>('verifyRetirement', {'token': token});
  @override
  Future<void> releaseAdmission() => AndroidMicrophoneLifetime.channel
      .invokeMethod<void>('releaseRetirement', {'token': token});
}

final class _NoMicrophoneRetirement implements MicrophoneResourceRetirement {
  @override
  Future<void> verifyReleasedResources() async {}
  @override
  Future<void> releaseAdmission() async {}
}

/// A resource proof, not permission to erase. Publishing a fresh Dart lifetime
/// is separate from native release: the daemon must have released its own gate.
final class AndroidMicrophoneRetirement {
  AndroidMicrophoneRetirement._(this._lifetime, this._native);
  final AndroidMicrophoneLifetime _lifetime;
  final MicrophoneResourceRetirement _native;
  bool _released = false, _published = false;

  Future<void> verifyReleasedResources() => _native.verifyReleasedResources();
  Future<void> releaseNativeAdmission() async {
    if (_released) return;
    await _native.releaseAdmission();
    _released = true;
  }

  void publishFreshLifetime() {
    if (_published) return;
    if (!_released ||
        !identical(AndroidMicrophoneLifetime._current, _lifetime)) {
      throw StateError('microphone retirement unavailable');
    }
    AndroidMicrophoneLifetime._current = AndroidMicrophoneLifetime._();
    _published = true;
  }
}

/// Every controller binds before awaiting permissions. Old controllers cannot
/// adopt the fresh profile's service facade after erasure admission reopens.
final class AndroidMicrophoneLifetime {
  AndroidMicrophoneLifetime._();
  static AndroidMicrophoneLifetime _current = AndroidMicrophoneLifetime._();
  static AndroidMicrophoneLifetime current() => _current;
  static const channel = MethodChannel('xveil/call_foreground');

  @visibleForTesting
  static Future<bool?> Function(bool active)? debugInvokeOverride;
  @visibleForTesting
  static Future<MicrophoneResourceRetirement> Function()? debugRetireOverride;
  @visibleForTesting
  static void debugReset() {
    _current = AndroidMicrophoneLifetime._();
    debugInvokeOverride = null;
    debugRetireOverride = null;
  }

  bool? _knownActive = false;
  bool _wanted = false, _retired = false;
  Future<void> _requests = Future<void>.value();
  Future<AndroidMicrophoneRetirement>? _retiring;
  AndroidMicrophoneRetirement? _retirement;

  /// Cached start acknowledgement for presentation only. Unknown is never
  /// evidence of resource absence; erasure requires the native retirement port.
  bool get isActive => _knownActive == true;
  void sealAdmission() => _retired = true;

  Future<void> activateWhenMicrophoneGranted(
    Future<bool> permission, {
    required bool Function() isCurrent,
  }) async {
    final granted = await permission;
    if (granted && !_retired && isCurrent()) await setActive(true);
  }

  Future<void> setActive(bool active) {
    if (_retired) {
      return Future.error(StateError('microphone lifetime has ended'));
    }
    final invoke = debugInvokeOverride;
    if (!Platform.isAndroid && invoke == null) return Future<void>.value();
    _wanted = active;
    final request = _requests.then((_) async {
      while (true) {
        final wanted = _wanted;
        if (_knownActive == wanted) return;
        try {
          final ok = invoke != null
              ? await invoke(wanted)
              : await channel.invokeMethod<bool>('setActive', {
                  'active': wanted,
                });
          _knownActive = ok == true ? wanted : (wanted ? false : null);
          devLog(
            () =>
                'xVeil[call-media]: Android microphone service '
                'requested=$wanted acknowledged=${ok == true}',
          );
        } catch (_) {
          _knownActive = null;
          devLog(
            () => 'xVeil[call-media]: Android microphone service unavailable',
          );
        }
        if (_wanted == wanted) return;
      }
    });
    // The continuation is asynchronous; reserve its place before an injected
    // adapter can reenter retirement from inside the accepted operation.
    _requests = request;
    return request;
  }

  Future<AndroidMicrophoneRetirement> retireForErasure() {
    sealAdmission();
    final completed = _retirement;
    if (completed != null) return Future.value(completed);
    final pending = _retiring;
    if (pending != null) return pending;
    final accepted = _requests;
    final result = Completer<AndroidMicrophoneRetirement>();
    _retiring = result.future;
    unawaited(() async {
      try {
        await accepted;
        final override = debugRetireOverride;
        final MicrophoneResourceRetirement native;
        if (override != null) {
          native = await override();
        } else if (!Platform.isAndroid && debugInvokeOverride == null) {
          native = _NoMicrophoneRetirement();
        } else {
          final token = await channel.invokeMethod<String>('retire');
          if (token == null || token.isEmpty || token.length > 64) {
            throw StateError('microphone retirement unavailable');
          }
          native = _NativeMicrophoneRetirement(token);
        }
        result.complete(
          _retirement = AndroidMicrophoneRetirement._(this, native),
        );
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _retiring = null;
      }
    }());
    return result.future;
  }
}
