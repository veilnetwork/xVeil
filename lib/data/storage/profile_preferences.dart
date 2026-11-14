import 'dart:async';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'profile_prefs_store.dart';

/// All application access uses a bound view, never the plugin singleton itself.
/// The plugin routes even an old object's setters through its current global
/// backend. A view from a retired lifetime must not adopt that backend.
Future<SharedPreferences> profilePreferences() =>
    ProfilePreferencesLifetime.current().preferences;

/// Owns accepted preference operations, including asynchronous cache reloads.
/// Retirement seals admission before returning and joins operations already in
/// flight. It proves quiescence, not successful persistence or file deletion.
/// A retired backend cannot be admitted again; cleanup/recovery must install a
/// new backend only after awaiting retirement and completing its own protocol.
class ProfilePreferencesLifetime {
  ProfilePreferencesLifetime._(this._backend, this._priorDrain);

  static final _lifetimes = Expando<ProfilePreferencesLifetime>();
  static ProfilePreferencesLifetime? _last;
  static _PreferenceDrain? _handover;

  static ProfilePreferencesLifetime current() {
    final backend = SharedPreferencesStorePlatform.instance;
    if (identical(_last?._backend, backend)) return _last!;
    final previous = _last;
    final waits = <Future<void>>[];
    final handover = _handover;
    if (handover != null && !handover.settled) waits.add(handover.future);
    if (previous != null) {
      final retired = previous.retire();
      if (!previous._drained) waits.add(retired);
    }
    // Keep the whole transition chain, including through a reinstated retired
    // backend. Do not turn an already quiescent lifetime into a new async wait.
    _handover = waits.isEmpty
        ? null
        : _PreferenceDrain(Future.wait<void>(waits));
    final owner = _lifetimes[backend] ??= ProfilePreferencesLifetime._(
      backend,
      _handover,
    );
    _last = owner;
    return owner;
  }

  final SharedPreferencesStorePlatform _backend;
  final _PreferenceDrain? _priorDrain;
  final _pending = <Future<void>>{};
  Future<SharedPreferences>? _ready;
  Future<void>? _retirement;
  bool _retired = false;
  bool _drained = false;

  void _requireActive() {
    if (_retired ||
        !identical(_backend, SharedPreferencesStorePlatform.instance)) {
      throw StateError('profile preferences lifetime has ended');
    }
  }

  Future<SharedPreferences> get preferences {
    try {
      _requireActive();
      final ready = _ready;
      if (ready != null) return ready;
      final loading = _track(_load);
      _ready = loading;
      unawaited(
        loading.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (identical(_ready, loading)) _ready = null;
          },
        ),
      );
      return loading;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<SharedPreferences> _load() async {
    // The plugin's cache is process-wide too. A previous accepted reload must
    // finish before this lifetime refreshes it, or its late result could undo
    // the refresh. No test-only singleton reset is used in production.
    final prior = _priorDrain;
    if (prior != null && !prior.settled) await prior.future;
    _requireActive();
    final raw = await SharedPreferences.getInstance();
    _requireActive();
    await raw.reload();
    _requireActive();
    return _BoundPreferences(this, raw);
  }

  Future<T> _track<T>(Future<T> Function() operation) {
    final Future<T> result;
    try {
      _requireActive();
      result = operation();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    // Observe settlement separately: a failed save is still quiescent, but
    // its original failure is returned unchanged to the caller.
    final settled = Completer<void>();
    _pending.add(settled.future);
    void settle() {
      _pending.remove(settled.future);
      settled.complete();
    }

    unawaited(
      result.then<void>(
        (_) => settle(),
        onError: (Object _, StackTrace _) => settle(),
      ),
    );
    return result;
  }

  Future<void> retire() {
    final pending = _retirement;
    if (pending != null) return pending;
    _retired = true;
    final waits = <Future<void>>[..._pending];
    final prior = _priorDrain;
    if (prior != null && !prior.settled) waits.add(prior.future);
    final backend = _backend;
    if (backend is ProfilePreferencesStore) waits.add(backend.retire());
    if (waits.isEmpty) {
      _drained = true;
      return _retirement = SynchronousFuture<void>(null);
    }
    return _retirement = Future.wait<void>(waits).then((_) {
      _drained = true;
    });
  }
}

class _PreferenceDrain {
  _PreferenceDrain(Future<void> pending) {
    future = pending.then((_) {
      settled = true;
    });
  }
  late final Future<void> future;
  bool settled = false;
}

class _BoundPreferences implements SharedPreferences {
  _BoundPreferences(this._owner, this._raw);

  final ProfilePreferencesLifetime _owner;
  final SharedPreferences _raw;

  T _read<T>(T Function() read) {
    _owner._requireActive();
    return read();
  }

  @override
  Set<String> getKeys() => _read(_raw.getKeys);
  @override
  Object? get(String key) => _read(() => _raw.get(key));
  @override
  bool? getBool(String key) => _read(() => _raw.getBool(key));
  @override
  int? getInt(String key) => _read(() => _raw.getInt(key));
  @override
  double? getDouble(String key) => _read(() => _raw.getDouble(key));
  @override
  String? getString(String key) => _read(() => _raw.getString(key));
  @override
  List<String>? getStringList(String key) =>
      _read(() => _raw.getStringList(key));
  @override
  bool containsKey(String key) => _read(() => _raw.containsKey(key));

  @override
  Future<bool> setBool(String key, bool value) =>
      _owner._track(() => _raw.setBool(key, value));
  @override
  Future<bool> setInt(String key, int value) =>
      _owner._track(() => _raw.setInt(key, value));
  @override
  Future<bool> setDouble(String key, double value) =>
      _owner._track(() => _raw.setDouble(key, value));
  @override
  Future<bool> setString(String key, String value) =>
      _owner._track(() => _raw.setString(key, value));
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _owner._track(() => _raw.setStringList(key, List<String>.of(value)));
  @override
  Future<bool> remove(String key) => _owner._track(() => _raw.remove(key));
  @override
  Future<bool> clear() => _owner._track(_raw.clear);
  @override
  Future<void> reload() => _owner._track(_raw.reload);
  @override
  Future<bool> commit() => _owner._track(() async => true);
}
