import 'dart:io';

import 'package:flutter/services.dart';

/// Owns platform activity only while call media is alive. Local platform
/// power policy never changes a packet, route, or relay scheduling class.
class CallNetworkActivity {
  CallNetworkActivity({required Future<bool> Function(bool) setActive})
    // Keep the injected setter public without exposing its stored field.
    // ignore: prefer_initializing_formals
    : _setActive = setActive;

  static const _channel = MethodChannel('xveil/call_network');
  static final shared = CallNetworkActivity(setActive: _setPlatformActive);

  static Future<bool> _setPlatformActive(bool active) async {
    if (!Platform.isAndroid && !Platform.isMacOS) return false;
    return await _channel.invokeMethod<bool>('setActive', {'active': active}) ==
        true;
  }

  final Future<bool> Function(bool) _setActive;
  final Set<Object> _owners = Set.identity();
  Future<void> _tail = Future.value();
  bool _active = false;
  // A rejected/lost acquire reply can still leave a native partial grant.
  // Desired call owners and unconfirmed native cleanup are separate facts.
  bool _cleanupPending = false;

  bool heldBy(Object owner) => _active && _owners.contains(owner);

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<bool> acquire(Object owner) => _serialized(() async {
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

  Future<void> release(Object owner) => _serialized(() async {
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
