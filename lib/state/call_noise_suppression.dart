import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/storage.dart';
import 'providers.dart';

// Encrypted, local to this identity/device; not a synced identity preference.
const kCallNoiseSuppressionSetting = 'call.audio.noise_suppression.local';

/// Share intent across direct/group/rebuilt engines without rebuilding a live
/// call provider. A rejected native change or failed persistence is not success.
class CallNoiseSuppressionSettings extends ChangeNotifier {
  CallNoiseSuppressionSettings(this._storage) {
    ready = _load();
  }
  final Storage _storage;
  final _targets = <Object, bool Function(bool)>{};
  late final Future<void> ready;
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;
  int _busy = 0;
  // Live choice can lead the durable UI value while a write is pending. A
  // rebuilt engine must join that choice and any later rollback, too.
  bool _activeEnabled = true;
  bool enabled = true;
  bool loaded = false;
  bool get busy => _busy != 0;

  Future<void> _load() async {
    var value = true;
    try {
      value = await _storage.getSetting(kCallNoiseSuppressionSetting) != '0';
    } catch (_) {
      /* A missing/unreadable local choice uses the voice default. */
    }
    if (_disposed) return;
    if (_apply(value)) enabled = value;
    loaded = true;
    notifyListeners();
  }

  /// Call providers own these bindings. No engine pointer is retained here.
  VoidCallback bind(Object owner, bool Function(bool) apply) {
    if (_disposed) return () {};
    _targets[owner] = apply;
    apply(_activeEnabled);
    return () {
      if (identical(_targets[owner], apply)) _targets.remove(owner);
    };
  }

  bool _apply(bool value) {
    final before = _activeEnabled;
    final applied = <MapEntry<Object, bool Function(bool)>>[];
    for (final entry in _targets.entries.toList()) {
      if (!identical(_targets[entry.key], entry.value)) continue;
      applied.add(entry);
      var ok = false;
      try {
        ok = entry.value(value);
      } catch (_) {}
      if (!ok) {
        for (final previous in applied) {
          if (!identical(_targets[previous.key], previous.value)) continue;
          try {
            previous.value(before);
          } catch (_) {}
        }
        return false;
      }
    }
    _activeEnabled = value;
    return true;
  }

  Future<bool> set(bool value) {
    if (_disposed) return Future.value(false);
    ++_busy;
    notifyListeners();
    final result = _tail.then((_) async {
      await ready;
      if (_disposed) return false;
      final before = enabled;
      if (before == value) return true;
      if (!_apply(value)) return false;
      try {
        await _storage.putSetting(
          kCallNoiseSuppressionSetting,
          value ? '1' : '0',
        );
      } catch (_) {
        if (!_disposed) _apply(before);
        return false;
      }
      if (_disposed) return false;
      enabled = value;
      return true;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result.whenComplete(() {
      --_busy;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _targets.clear();
    super.dispose();
  }
}

// Plain Provider intentionally does not emit on ChangeNotifier updates: a
// setting change must not tear down the services that own the current call.
final callNoiseSuppressionProvider = Provider<CallNoiseSuppressionSettings>((
  ref,
) {
  final settings = CallNoiseSuppressionSettings(ref.watch(storageProvider));
  ref.onDispose(settings.dispose);
  return settings;
});
