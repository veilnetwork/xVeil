import 'dart:async';
import 'dart:io';

// Keep descriptive public constructor parameters at this orchestration boundary.
// ignore_for_file: prefer_initializing_formals

import '../../core/local_authentication.dart';
import '../../core/quick_unlock_vault.dart';
import 'async_kv_log_store.dart';
import 'legacy_profile_preferences.dart';
import 'managed_directory_catalog.dart';
import 'profile_preferences.dart';
import 'profile_prefs_store.dart';
import 'profile_storage_router_owner.dart';
import 'storage.dart';

/// Safe for UI/error reports: backend messages, names and paths stay private.
final class ManagedProfileWipeFailure implements Exception {
  const ManagedProfileWipeFailure();
  @override
  String toString() => 'ManagedProfileWipeFailure';
}

/// One explicitly requested full-profile wipe. Retain this owner on failure.
/// Ordinary UI/admission must stay sealed until resume() completes. The caller
/// supplies real lifecycle drain and read-only checks for runtime data outside
/// the native inventory, and never reuses the legacy best-effort wipe path.
final class ManagedProfileWipe {
  ManagedProfileWipe({
    required ProfileStorageRouterOwner router,
    required ProfilePreferencesLifetime preferences,
    required LegacyProfilePreferences source,
    required QuickUnlockSecretStore secretStore,
    required LocalScreenAuthentication authentication,
    required Future<void> Function() quiesce,
    required Future<void> Function() verifyOtherDataAbsent,
  }) : _router = router,
       _preferences = preferences,
       _source = source,
       _secretStore = secretStore,
       _authentication = authentication,
       _quiesce = quiesce,
       _verifyOtherDataAbsent = verifyOtherDataAbsent {
    try {
      _profileDirectory = router.router.profileDirectory;
      final base = Directory(
        _profileDirectory,
      ).parent.resolveSymbolicLinksSync();
      if (router.router.storage is! StorageRetirementOwner ||
          !identical(preferences.legacyPreferences, source) ||
          File(source.preferencePath).parent.resolveSymbolicLinksSync() !=
              base ||
          File(source.legacyPath).parent.resolveSymbolicLinksSync() != base) {
        throw const ManagedProfileWipeFailure();
      }
    } catch (_) {
      throw const ManagedProfileWipeFailure();
    }
  }
  final ProfileStorageRouterOwner _router;
  final ProfilePreferencesLifetime _preferences;
  final LegacyProfilePreferences _source;
  final QuickUnlockSecretStore _secretStore;
  final LocalScreenAuthentication _authentication;
  final Future<void> Function() _quiesce, _verifyOtherDataAbsent;
  late final String _profileDirectory;
  ManagedErasureWorker? _worker;
  QuickUnlockRetirement? _vault;
  LegacyProfilePreferencesRetirement? _legacy;
  ManagedErasureRelease? _receipt;
  bool _quiesced = false, _suspended = false, _preferencesReleased = false;
  bool _managedRemoved = false, _auxiliaryRemoved = false;
  bool _vaultAdmitted = false, _legacyAdmitted = false;
  bool _freshPreferences = false, _freshRouter = false, _closed = false;
  Future<void>? _pending;

  Future<void> resume() {
    if (_closed) return Future.error(const ManagedProfileWipeFailure());
    final pending = _pending;
    if (pending != null) return pending;
    final done = Completer<void>();
    _pending = done.future;
    unawaited(() async {
      try {
        await _resume();
        done.complete();
      } catch (_) {
        done.completeError(const ManagedProfileWipeFailure());
      } finally {
        _pending = null;
      }
    }());
    return done.future;
  }

  Future<void> _resume() async {
    if (_freshRouter) return;
    if (!_quiesced) {
      await _quiesce();
      await _verifyOtherDataAbsent();
      _quiesced = true;
    }
    if (!_suspended) {
      await _router.suspend();
      _suspended = true;
    }
    if (!_preferencesReleased) {
      await _preferences.releaseFile();
      _preferencesReleased = true;
    }
    final worker = _worker ??= await ManagedErasureWorker.begin(
      profileDirectory: _profileDirectory,
      profileNamespace: _source.profile,
      legacyPath: _source.legacyPath,
      auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: _source.legacyPath),
    );
    if (_receipt == null) {
      _vault ??= QuickUnlockRetirement.forWorker(
        worker.scopeLease,
        _secretStore,
        _authentication,
      );
      _legacy ??= LegacyProfilePreferencesRetirement.forWorker(worker, _source);
      Future<void> retire() =>
          Future.wait<void>([_vault!.retire(), _legacy!.retire()]);
      if (!_managedRemoved) {
        await worker.removeManagedFiles(retireScopes: retire);
        _managedRemoved = true;
      }
      if (!_auxiliaryRemoved) {
        await worker.removeAuxiliaryFiles(retireScopes: retire);
        _auxiliaryRemoved = true;
      }
      _receipt = await worker.finish(
        verifyOtherDataAbsent: () async {
          await Future.wait<void>([
            _vault!.verifyAbsent(),
            _legacy!.verifyAbsent(),
            _verifyOtherDataAbsent(),
          ]);
        },
      );
    }
    final receipt = _receipt!;
    // These synchronous handoffs do not un-retire any old wrapper. No ordinary
    // providers are released until BOTH handoffs and fresh installation finish.
    if (!_vaultAdmitted) {
      _vault!.admitFreshLifetime(receipt);
      _vaultAdmitted = true;
    }
    if (!_legacyAdmitted) {
      _legacy!.admitFreshLifetime(receipt);
      _legacyAdmitted = true;
    }
    if (!_freshPreferences) {
      await _legacy!.bootstrapFresh(
        receipt,
        (backend) => installProfilePreferences(
          supportDir: _source.supportDirectory,
          args: ['--profile', _source.profile],
          environment: {'XVEIL_STORE_PATH': _source.legacyPath},
          legacyBackend: backend,
          openOwnedFile: ManagedProfilePreferencesFile.open,
          validateSelectedFile: (path) =>
              validateManagedPreferencesContainer(path, _source.legacyPath),
        ),
      );
      _freshPreferences = true;
    }
    if (!_freshRouter) {
      await _router.reopen();
      _freshRouter = true;
    }
  }

  /// Accepted work is joined; a failed attempt remains an on-disk pending
  /// operation. Close never authorizes fresh UI or deletes anything itself.
  Future<void> close() async {
    _closed = true;
    await _pending?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await _worker?.close();
  }
}
