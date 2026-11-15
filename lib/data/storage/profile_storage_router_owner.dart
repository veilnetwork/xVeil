import 'dart:async';
import 'dart:typed_data';

import 'legacy_compaction_source.dart';

import 'profile_storage_router.dart';
import 'async_kv_log_store.dart';
import 'compaction_roster_remap.dart';
import '../../domain/storage_locator.dart';

/// Owns successive router lifetimes without redirecting old storage facades.
/// Suspension is synchronous; reopening requires a confirmed native close.
/// The normal opener still refuses an unfinished profile-erasure intent.
final class ProfileStorageRouterOwner {
  ProfileStorageRouterOwner(
    ProfileStorageRouter initial, {
    required Future<ProfileStorageRouter> Function() reopen,
  }) : _router = initial,
       _profile = initial.profileDirectory,
       _sourceName = initial.legacySourceName,
       _openReplacement = reopen;

  final String _profile, _sourceName;
  final Future<ProfileStorageRouter> Function() _openReplacement;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  ProfileStorageRouter? _router;
  ManagedLegacyCompactionWorker? _legacyCompaction;
  Future<void> _tail = Future.value();
  Future<void>? _suspending, _opening, _closing;
  bool _available = true, _disposed = false;
  int _epoch = 0;

  bool get isAvailable => _available && !_disposed;

  ProfileStorageRouter get router {
    if (!_available || _disposed) {
      throw StateError('storage router lifetime is unavailable');
    }
    return _router!;
  }

  Future<T> _enqueue<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _release() async {
    final maintenance = _legacyCompaction;
    if (maintenance != null) {
      await maintenance.close();
      _legacyCompaction = null;
    }
    final current = _router;
    if (current == null) return;
    // Retain a refused close, including an unpublished replacement, for retry.
    await current.close();
    _router = null;
  }

  Future<void> suspend() {
    if (_disposed) return Future.error(StateError('storage owner is closed'));
    final pending = _suspending;
    if (pending != null) return pending;
    _available = false;
    _epoch++;
    _router?.retireFacades();
    final result = _suspending = _enqueue(
      _release,
    ).whenComplete(() => _suspending = null);
    _changes.add(null);
    return result;
  }

  /// Explicit replacement after maintenance. This grants no OS-vault handoff:
  /// erasure callers must separately verify their exact release receipt.
  Future<void> reopen() {
    if (_disposed) return Future.error(StateError('storage owner is closed'));
    final pending = _opening;
    if (pending != null) return pending;
    if (_available) {
      return Future.error(StateError('suspend the storage owner first'));
    }
    final ticket = _epoch;
    return _opening = _enqueue(() async {
      if (_disposed ||
          ticket != _epoch ||
          _router != null ||
          _legacyCompaction != null) {
        throw StateError('storage router release is not confirmed');
      }
      final candidate = await _openReplacement();
      _router = candidate;
      if (_disposed ||
          ticket != _epoch ||
          (candidate.profileDirectory != _profile ||
              candidate.legacySourceName != _sourceName)) {
        await _release();
        throw StateError('storage router replacement superseded');
      }
      _available = true;
      _changes.add(null);
    }).whenComplete(() => _opening = null);
  }

  /// Explicit mixed-profile maintenance; the ordinary legacy guard stays on.
  /// All credentials must already be collected, including plaintext consent.
  /// This scopes the entire native publisher, not merely its UI await. Source
  /// name must match the router's immutable binding. Recovery journals carry
  /// that leaf privately, so neither publication nor cold recovery guesses it.
  Future<ManagedLegacyCompactionResult> compactLegacy({
    required String legacyPath,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    required List<CompactionCredential> credentials,
    required Set<ManagedIdentityId> plaintextApproved,
    required Future<void> Function() beforePublication,
  }) async {
    if (_disposed ||
        !_available ||
        _router?.location is! LegacyStorageLocator) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
    }
    try {
      if (LegacyCompactionSource.nameForPath(_profile, legacyPath) !=
          _sourceName) {
        throw const FormatException('legacy source binding mismatch');
      }
    } on FormatException {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
    }
    final keys = <ManagedIdentityId, Uint8List>{};
    final keep = <CompactionCredential>[];
    try {
      for (final entry in authorizations.entries) {
        if (entry.value.length != 64) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        keys[entry.key] = Uint8List.fromList(entry.value);
      }
      for (final entry in credentials) {
        if (entry.password.isEmpty ||
            entry.oldSpaceKeys.length != 64 ||
            [
              ...entry.password,
              ...entry.oldSpaceKeys,
            ].any((b) => b < 0 || b > 255)) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        keep.add((
          password: Uint8List.fromList(entry.password),
          oldSpaceKeys: Uint8List.fromList(entry.oldSpaceKeys),
        ));
      }
      final approved = Set<ManagedIdentityId>.of(plaintextApproved);
      final location = _router!.location, access = _router!.access;
      _available = false;
      final ticket = ++_epoch;
      _router?.retireFacades();
      void check() {
        if (_disposed || ticket != _epoch) {
          throw StateError('compaction owner superseded');
        }
      }

      final operation = _enqueue(() async {
        check();
        await _release();
        ManagedLegacyCompactionResult? observed;
        ManagedLegacyCompactionFailure? failure;
        var released = true; // No native publisher exists before run admission.
        try {
          return await ManagedProfilePreferencesFile.withProfileReleased(
            _profile,
            () async {
              check();
              final worker = _legacyCompaction =
                  await ManagedLegacyCompactionWorker.open(
                    profileDirectory: _profile,
                    sourceName: _sourceName,
                    authorizations: keys,
                    credentials: keep,
                    plaintextApproved: approved,
                  );
              try {
                check();
                released = false;
                final result = await worker.run(
                  beforePublication: () async {
                    check();
                    await beforePublication();
                    check();
                  },
                );
                observed = result;
                return result;
              } finally {
                await worker.close();
                _legacyCompaction = null;
                released = true;
              }
            },
          );
        } catch (error) {
          if (error is ManagedLegacyCompactionFailure) failure = error;
          if (observed != null && error is! ManagedLegacyCompactionFailure) {
            failure = ManagedLegacyCompactionFailure(
              ManagedWorkerFailureKind.backend,
              mayHaveApplied: true,
              recovery: observed!.recovery,
            );
            throw failure;
          }
          rethrow;
        } finally {
          if (released && !_disposed && ticket == _epoch && _router == null) {
            try {
              final candidate = await _openReplacement();
              _router = candidate;
              if (candidate.profileDirectory != _profile ||
                  candidate.legacySourceName != _sourceName) {
                await _release();
                throw StateError('storage router replacement superseded');
              }
              if (candidate.access != access) await candidate.select(access);
              if (candidate.location != location) {
                await candidate.select(location, access: false);
              }
              if (_disposed ||
                  ticket != _epoch ||
                  (candidate.profileDirectory != _profile ||
                      candidate.legacySourceName != _sourceName)) {
                await _release();
                throw StateError('storage router replacement superseded');
              }
              _available = true;
              _changes.add(null);
            } catch (_) {
              throw ManagedLegacyCompactionFailure(
                ManagedWorkerFailureKind.backend,
                mayHaveApplied:
                    observed != null || (failure?.mayHaveApplied ?? false),
                recovery: observed?.recovery ?? failure?.recovery,
                warning: failure?.warning,
              );
            }
          }
        }
      });
      _changes.add(null);
      return await operation;
    } finally {
      for (final value in keys.values) {
        value.fillRange(0, value.length, 0);
      }
      for (final entry in keep) {
        entry.password.fillRange(0, entry.password.length, 0);
        entry.oldSpaceKeys.fillRange(0, entry.oldSpaceKeys.length, 0);
      }
    }
  }

  /// Dispose owns both the original router and any in-flight replacement.
  /// A failed close remains retryable and can never make this owner available.
  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    _disposed = true;
    _available = false;
    _epoch++;
    _router?.retireFacades();
    final result = _closing = _enqueue(() async {
      await _release();
      // A paused observer cannot hold up the native ownership release.
      unawaited(_changes.close());
    }).whenComplete(() => _closing = null);
    if (!_changes.isClosed) _changes.add(null);
    return result;
  }
}
