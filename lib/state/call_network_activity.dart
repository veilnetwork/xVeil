import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';

/// Owns platform activity only while call media is alive. Local platform
/// power policy never changes a packet, route, or relay scheduling class.
class CallNetworkActivity {
  CallNetworkActivity({
    required Future<bool> Function(bool) setActive,
    Future<CallNetworkResourceRetirement> Function()? retireResources,
  })
    // Keep the injected setter public without exposing its stored field.
    // ignore: prefer_initializing_formals
    : _setActive = setActive,
       // ignore: prefer_initializing_formals
       _retireResources = retireResources;

  static const _channel = MethodChannel('xveil/call_network');
  static CallNetworkActivity _current = _platform();
  static CallNetworkActivity get shared => _current;
  static CallNetworkActivity _platform() => CallNetworkActivity(
    setActive: _setPlatformActive,
    retireResources: _retirePlatform,
  );

  @visibleForTesting
  static Future<bool> Function(bool)? debugSetActiveOverride;
  @visibleForTesting
  static Future<CallNetworkResourceRetirement> Function()? debugRetireOverride;
  @visibleForTesting
  static void debugReset() {
    if (_current._owners.isNotEmpty ||
        _current._cleanupPending ||
        _current._pending != 0) {
      throw StateError('network resource still owned');
    }
    debugSetActiveOverride = null;
    debugRetireOverride = null;
    _current = _platform();
  }

  static Future<CallNetworkResourceRetirement> _retirePlatform() async {
    final override = debugRetireOverride;
    if (override != null) return override();
    if (!Platform.isAndroid &&
        !Platform.isMacOS &&
        debugSetActiveOverride == null) {
      return _NoNetworkRetirement();
    }
    // A supported platform with no retirement port must refuse, even if the
    // Dart owner set is empty. Its cache cannot prove native resource absence.
    final token = await _channel.invokeMethod<String>('retire');
    if (token == null || token.isEmpty || token.length > 64) {
      throw StateError('network retirement unavailable');
    }
    return _NativeNetworkRetirement(token);
  }

  static Future<bool> _setPlatformActive(bool active) async {
    final override = debugSetActiveOverride;
    if (override != null) return override(active);
    if (!Platform.isAndroid && !Platform.isMacOS) return false;
    final result = await _channel.invokeMethod<bool>('setActive', {
      'active': active,
    });
    if (result == null) throw StateError('network activity unavailable');
    return result;
  }

  final Future<bool> Function(bool) _setActive;
  final Future<CallNetworkResourceRetirement> Function()? _retireResources;
  bool _retired = false;
  int _pending = 0;
  Future<CallNetworkRetirement>? _retiring;
  CallNetworkRetirement? _retirement;
  final Set<Object> _owners = Set.identity();
  Future<void> _tail = Future.value();
  bool _active = false;
  // A rejected/lost acquire reply can still leave a native partial grant.
  // Desired call owners and unconfirmed native cleanup are separate facts.
  bool _cleanupPending = false;

  bool heldBy(Object owner) => _active && _owners.contains(owner);

  Future<T> _serialized<T>(Future<T> Function() operation) {
    _pending++;
    final next = _tail.then((_) => operation());
    _tail = next.then<void>(
      (_) {
        _pending--;
      },
      onError: (Object _, StackTrace _) {
        _pending--;
      },
    );
    return next;
  }

  Future<bool> acquire(Object owner) {
    if (_retired) return Future.value(false);
    return _serialized(() async {
      if (!_active || _cleanupPending) {
        try {
          _active = await _setActive(true);
          _cleanupPending = !_active;
        } catch (_) {
          _active = false;
          _cleanupPending = true;
        }
      }
      // Failed/unsupported acquisition cannot retain a dead call controller.
      if (_active) _owners.add(owner);
      return _active;
    });
  }

  Future<void> release(Object owner) {
    if (_retired) return Future.value();
    return _serialized(() async {
      _owners.remove(owner);
      if (_owners.isNotEmpty) return;
      _cleanupPending = _cleanupPending || _active;
      if (!_cleanupPending) return;
      try {
        // false acknowledges inactive; true reports that resources remain.
        _active = await _setActive(false);
        _cleanupPending = _active;
      } catch (_) {
        // Teardown stays non-throwing, but it cannot turn an absent/failed reply
        // into resource absence. A repeat release or acquire retries the port.
        _cleanupPending = true;
      }
    });
  }

  void sealAdmission() => _retired = true;

  Future<CallNetworkRetirement> retireForErasure() {
    sealAdmission();
    final completed = _retirement;
    if (completed != null) return Future.value(completed);
    final pending = _retiring;
    if (pending != null) return pending;
    final accepted = _tail;
    final result = Completer<CallNetworkRetirement>();
    _retiring = result.future;
    unawaited(() async {
      try {
        await accepted;
        final retire = _retireResources;
        if (retire == null) throw StateError('network retirement unavailable');
        final native = await retire();
        await native.verifyReleasedResources();
        _active = false;
        _cleanupPending = false;
        _owners.clear();
        result.complete(_retirement = CallNetworkRetirement._(this, native));
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _retiring = null;
      }
    }());
    return result.future;
  }
}

abstract interface class CallNetworkResourceRetirement {
  Future<void> verifyReleasedResources();
  Future<void> releaseAdmission();
}

final class _NoNetworkRetirement implements CallNetworkResourceRetirement {
  @override
  Future<void> verifyReleasedResources() async {}
  @override
  Future<void> releaseAdmission() async {}
}

final class _NativeNetworkRetirement implements CallNetworkResourceRetirement {
  _NativeNetworkRetirement(this.token);
  final String token;
  @override
  Future<void> verifyReleasedResources() => CallNetworkActivity._channel
      .invokeMethod<void>('verifyRetirement', {'token': token});
  @override
  Future<void> releaseAdmission() => CallNetworkActivity._channel
      .invokeMethod<void>('releaseRetirement', {'token': token});
}

final class CallNetworkRetirement {
  CallNetworkRetirement._(this._lifetime, this._native);
  final CallNetworkActivity _lifetime;
  final CallNetworkResourceRetirement _native;
  bool _released = false, _published = false;
  Future<void> verifyReleasedResources() => _native.verifyReleasedResources();
  Future<void> releaseNativeAdmission() async {
    if (_released) return;
    await _native.releaseAdmission();
    _released = true;
  }

  void verifyPublicationReady() {
    if (_published) return;
    if (!_released || !identical(CallNetworkActivity._current, _lifetime)) {
      throw StateError('network retirement unavailable');
    }
  }

  void publishFreshLifetime() {
    if (_published) return;
    verifyPublicationReady();
    CallNetworkActivity._current = CallNetworkActivity._platform();
    _published = true;
  }
}
