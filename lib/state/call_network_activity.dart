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

  bool heldBy(Object owner) => _active && _owners.contains(owner);

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<bool> acquire(Object owner) => _serialized(() async {
    if (!_active) {
      try {
        _active = await _setActive(true);
      } catch (_) {
        _active = false;
      }
    }
    // Failed/unsupported acquisition cannot retain a dead call controller.
    if (_active) _owners.add(owner);
    return _active;
  });

  Future<void> release(Object owner) => _serialized(() async {
    if (!_owners.remove(owner) || _owners.isNotEmpty) return;
    try {
      await _setActive(false);
    } catch (_) {
      // An absent platform plugin must not prevent media teardown.
    } finally {
      _active = false;
    }
  });
}
