import 'dart:async';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import '../../core/storage_unlock_scope.dart';
import '../../core/saved_entry_addresses.dart';
import '../../domain/profile_preferences_layout.dart';
import '../../domain/storage_locator.dart';
import 'app_profile.dart';
import 'async_kv_log_store.dart';
import 'managed_directory_catalog.dart';
import 'profile_preferences_routing.dart';

/// No keys, values, paths, profile names or platform error text are exposed.
final class LegacyProfilePreferencesFailure implements Exception {
  const LegacyProfilePreferencesFailure();
  @override
  String toString() => 'LegacyProfilePreferencesFailure';
}

class _LegacyPreferenceLifetime {
  bool retired = false, detached = false;
  int readers = 0;
  Future<void>? pending;
  ManagedErasureBinding? operation;
  final retryKeys = <String>{};
}

/// Retains the ORIGINAL platform store before the application installs its file
/// backend. Never reconstruct that source from the current global backend.
/// This object grants read-only inspection, not deletion authority. Cooperating
/// application code no longer writes this backend after migration; unrelated
/// plugins/old binaries targeting the same OS store are not coordinated here.
final class LegacyProfilePreferences {
  LegacyProfilePreferences({
    required SharedPreferencesStorePlatform backend,
    required this.supportDirectory,
    required this.profile,
    required this.legacyPath,
  }) : _backend = backend {
    if (!AppProfiles.isValidName(profile) ||
        !Directory(supportDirectory).isAbsolute ||
        !File(legacyPath).isAbsolute ||
        supportDirectory.contains('\x00') ||
        legacyPath.contains('\x00')) {
      throw const LegacyProfilePreferencesFailure();
    }
    _state = (_sources[backend] ??= {})[scope] ??= _LegacyPreferenceLifetime();
  }
  static final _sources = Expando<Map<String, _LegacyPreferenceLifetime>>();
  final SharedPreferencesStorePlatform _backend;
  final String supportDirectory, profile, legacyPath;
  late final _LegacyPreferenceLifetime _state;
  String get _base => AppProfiles.directory(supportDirectory, profile);
  String get preferencePath => '$_base/${ProfilePreferencesLayout.file}';
  String get scope =>
      storageUnlockScope(profile, legacyPath, const LegacyStorageLocator());

  /// The cold recovery entrypoint runs before installing any profile backend.
  /// Reading this does not create a preference lifetime or migrate settings.
  void requireColdBootstrapSource() {
    requireOriginalBackendSelected();
    if (_state.retired || _state.pending != null || _state.operation != null) {
      throw const LegacyProfilePreferencesFailure();
    }
  }

  void requireOriginalBackendSelected() {
    _requireCurrent();
    if (!identical(SharedPreferencesStorePlatform.instance, _backend)) {
      throw const LegacyProfilePreferencesFailure();
    }
  }

  void _requireCurrent() {
    if (_state.detached || !identical(_sources[_backend]?[scope], _state)) {
      throw const LegacyProfilePreferencesFailure();
    }
  }

  Set<String> _knownProfiles() {
    final result = <String>{AppProfiles.defaultName, profile};
    final directory = Directory('$supportDirectory/profiles');
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return result;
    }
    // Refuse an unreadable roster instead of classifying other profiles' keys
    // as default-profile data. Only leaf names are read; no identities opened.
    for (final entry in directory.listSync(followLinks: false)) {
      final name = lastPathSegment(entry.path);
      if (AppProfiles.isValidName(name)) result.add(name);
    }
    return result;
  }

  bool _ownsKey(String key, Set<String> known) =>
      key.startsWith('flutter.') &&
      key != 'flutter.${AppProfiles.activePref}' &&
      routeLegacyKey(key.substring('flutter.'.length), known).owner == profile;

  Future<List<String>> _ownedKeys() async {
    _requireCurrent();
    final known = _knownProfiles();
    final all = await _backend.getAll();
    _requireCurrent();
    return [
      for (final key in all.keys)
        if (_ownsKey(key, known)) key,
    ]..sort();
  }

  /// Read-only cold-terminal/lost-reply inspection. It never creates a source,
  /// removes a newly appearing record or claims previous retirement succeeded.
  Future<void> verifyAbsent() async {
    _requireCurrent();
    if (_state.pending != null) throw const LegacyProfilePreferencesFailure();
    await _verifyOwnedAbsent();
    if (_state.pending != null) throw const LegacyProfilePreferencesFailure();
  }

  Future<void> _verifyOwnedAbsent() async {
    _requireCurrent();
    _state.readers++;
    try {
      if ((await _ownedKeys()).isNotEmpty) {
        throw const LegacyProfilePreferencesFailure();
      }
      _requireCurrent();
    } catch (_) {
      throw const LegacyProfilePreferencesFailure();
    } finally {
      _state.readers--;
    }
  }
}

/// Read-only terminal recovery. A serialized address set never grants removal
/// of OS preferences; this owner can only inspect absence and consume the exact
/// native release for a fresh installer using the ORIGINAL platform backend.
final class LegacyProfilePreferencesColdRecovery {
  LegacyProfilePreferencesColdRecovery({
    required ManagedErasureSnapshot snapshot,
    required String profileDirectory,
    required LegacyProfilePreferences source,
  }) : _source = source,
       _binding = snapshot.binding,
       _bootstrapBackend = SharedPreferencesStorePlatform.instance {
    try {
      final encoded = snapshot.savedEntryWitness;
      if (!snapshot.isApplicationProfile ||
          !snapshot.erasesProfilePreferences ||
          encoded == null ||
          SavedEntryAddresses.decode(encoded).scopes.ids.first !=
              source.scope ||
          Directory(profileDirectory).parent.resolveSymbolicLinksSync() !=
              Directory(source._base).resolveSymbolicLinksSync()) {
        throw const LegacyProfilePreferencesFailure();
      }
      source.requireColdBootstrapSource();
    } catch (_) {
      throw const LegacyProfilePreferencesFailure();
    }
  }
  final LegacyProfilePreferences _source;
  final ManagedErasureBinding _binding;
  final SharedPreferencesStorePlatform _bootstrapBackend;
  bool _verified = false, _released = false;
  bool _installing = false, _installed = false;
  Future<void>? _checking;

  Future<void> verifyAbsent() {
    if (_released) return Future.error(const LegacyProfilePreferencesFailure());
    final checking = _checking;
    if (checking != null) return checking;
    _verified = false;
    final done = Completer<void>();
    _checking = done.future;
    unawaited(() async {
      try {
        _source.requireColdBootstrapSource();
        await _source.verifyAbsent();
        _source.requireColdBootstrapSource();
        _verified = true;
        done.complete();
      } catch (_) {
        done.completeError(const LegacyProfilePreferencesFailure());
      } finally {
        _checking = null;
      }
    }());
    return done.future;
  }

  void admitFreshLifetime(ManagedErasureRelease release) {
    _source.requireColdBootstrapSource();
    if (!_verified ||
        _released ||
        _checking != null ||
        _source._state.readers != 0 ||
        !release.authorizes(_binding)) {
      throw const LegacyProfilePreferencesFailure();
    }
    _source._state.detached = true;
    LegacyProfilePreferences._sources[_source._backend]!.remove(_source.scope);
    _released = true;
  }

  Future<T> bootstrapFresh<T>(
    ManagedErasureRelease release,
    Future<T> Function(SharedPreferencesStorePlatform backend) install,
  ) async {
    if (!_released ||
        !release.authorizes(_binding) ||
        _installing ||
        _installed ||
        !identical(
          SharedPreferencesStorePlatform.instance,
          _bootstrapBackend,
        )) {
      throw const LegacyProfilePreferencesFailure();
    }
    _installing = true;
    try {
      final result = await install(_source._backend);
      _installed = true;
      return result;
    } finally {
      _installing = false;
    }
  }
}

/// One namespace retirement, bound to a live exclusive worker operation.
/// Keep it through retry/lost reply. Receipt admission detaches old contexts.
final class LegacyProfilePreferencesRetirement {
  LegacyProfilePreferencesRetirement._(
    this._lease,
    this._source,
    this._binding,
  );

  factory LegacyProfilePreferencesRetirement.forWorker(
    ManagedErasureWorker worker,
    LegacyProfilePreferences source,
  ) {
    try {
      final lease = worker.scopeLease, snapshot = lease.snapshot;
      if (!snapshot.erasesProfilePreferences ||
          snapshot.unlockScopes.ids.first != source.scope ||
          Directory(
                worker.profileDirectory,
              ).parent.resolveSymbolicLinksSync() !=
              Directory(source._base).resolveSymbolicLinksSync() ||
          File(source.legacyPath).parent.resolveSymbolicLinksSync() !=
              Directory(source._base).resolveSymbolicLinksSync()) {
        throw const LegacyProfilePreferencesFailure();
      }
      source._requireCurrent();
      final state = source._state, old = source._state.operation;
      if (old != null &&
          !old.sameOperation(snapshot.binding) &&
          state.pending != null) {
        throw const LegacyProfilePreferencesFailure();
      }
      state.operation = snapshot.binding;
      return LegacyProfilePreferencesRetirement._(
        lease,
        source,
        snapshot.binding,
      );
    } catch (_) {
      throw const LegacyProfilePreferencesFailure();
    }
  }
  final LegacyProfilePreferences _source;
  final SharedPreferencesStorePlatform _bootstrapBackend =
      SharedPreferencesStorePlatform.instance;
  final ManagedErasureScopeLease _lease;
  final ManagedErasureBinding _binding;
  Future<void>? _pending;
  bool _verified = false, _released = false;
  bool _bootstrapRunning = false, _bootstrapCompleted = false;

  void _requireBound() {
    _source._requireCurrent();
    if (_released ||
        !(_source._state.operation?.sameOperation(_binding) ?? false) ||
        !_lease.snapshot.binding.sameOperation(_binding)) {
      throw const LegacyProfilePreferencesFailure();
    }
  }

  Future<void> retire() {
    final pending = _pending;
    if (pending != null) return pending;
    try {
      _requireBound();
    } catch (_) {
      return Future.error(const LegacyProfilePreferencesFailure());
    }
    final state = _source._state;
    state.retired = true;
    _verified = false;
    final previous = state.pending;
    final completed = Completer<void>();
    _pending = state.pending = completed.future;
    unawaited(() async {
      try {
        if (previous != null) {
          await previous.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
        }
        _requireBound();
        state.retryKeys.addAll(await _source._ownedKeys());
        for (final key in state.retryKeys.toList()..sort()) {
          _requireBound();
          if (!_source._ownsKey(key, _source._knownProfiles())) {
            throw const LegacyProfilePreferencesFailure();
          }
          if (!await _source._backend.remove(key)) {
            throw const LegacyProfilePreferencesFailure();
          }
          state.retryKeys.remove(key);
        }
        _requireBound();
        await _source._verifyOwnedAbsent();
        _requireBound();
        _verified = true;
        completed.complete();
      } catch (_) {
        completed.completeError(const LegacyProfilePreferencesFailure());
      } finally {
        if (identical(state.pending, completed.future)) state.pending = null;
        _pending = null;
      }
    }());
    return completed.future;
  }

  Future<void> verifyAbsent() async {
    void quiescent() {
      _source._requireCurrent();
      final state = _source._state;
      if (!_verified ||
          !(state.operation?.sameOperation(_binding) ?? false) ||
          _released ||
          !state.retired ||
          state.pending != null ||
          state.retryKeys.isNotEmpty) {
        throw const LegacyProfilePreferencesFailure();
      }
    }

    quiescent();
    await _source.verifyAbsent();
    quiescent();
  }

  /// The original platform source is available to the fresh installer only
  /// after this exact erasure has released and detached its old lifetime.
  /// Never substitute the retired global file backend for the platform source.
  Future<T> bootstrapFresh<T>(
    ManagedErasureRelease release,
    Future<T> Function(SharedPreferencesStorePlatform backend) install,
  ) async {
    if (!_released ||
        !release.authorizes(_binding) ||
        _bootstrapRunning ||
        _bootstrapCompleted ||
        !identical(
          SharedPreferencesStorePlatform.instance,
          _bootstrapBackend,
        )) {
      throw const LegacyProfilePreferencesFailure();
    }
    _bootstrapRunning = true;
    try {
      final result = await install(_source._backend);
      _bootstrapCompleted = true;
      return result;
    } finally {
      _bootstrapRunning = false;
    }
  }

  void admitFreshLifetime(ManagedErasureRelease release) {
    final state = _source._state;
    _source._requireCurrent();
    if (!_verified ||
        !(state.operation?.sameOperation(_binding) ?? false) ||
        _released ||
        !state.retired ||
        state.pending != null ||
        state.readers != 0 ||
        state.retryKeys.isNotEmpty ||
        !release.authorizes(_binding)) {
      throw const LegacyProfilePreferencesFailure();
    }
    state.detached = true;
    LegacyProfilePreferences._sources[_source._backend]!.remove(_source.scope);
    _released = true;
  }
}
