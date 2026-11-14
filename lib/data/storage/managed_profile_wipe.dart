import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;

// Keep descriptive public constructor parameters at this orchestration boundary.
// ignore_for_file: prefer_initializing_formals

import '../../core/local_authentication.dart';
import '../../core/background_service_lifetime.dart';
import '../../core/capture_resource_lifetime.dart';
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
    required Future<BackgroundResourceRetirement> Function() retireBackground,
    required Future<void> Function() quiesce,
    required Future<void> Function() verifyOtherDataAbsent,
  }) : _router = router,
       _preferences = preferences,
       _source = source,
       _secretStore = secretStore,
       _authentication = authentication,
       _retireBackground = retireBackground,
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

  /// A real worker with a deterministic fault boundary; never selected by
  /// application configuration or an environment variable.
  @visibleForTesting
  factory ManagedProfileWipe.withWorkerOpenerForTesting({
    required ProfileStorageRouterOwner router,
    required ProfilePreferencesLifetime preferences,
    required LegacyProfilePreferences source,
    required QuickUnlockSecretStore secretStore,
    required LocalScreenAuthentication authentication,
    required Future<BackgroundResourceRetirement> Function() retireBackground,
    required Future<void> Function() quiesce,
    required Future<void> Function() verifyOtherDataAbsent,
    required Future<ManagedErasureWorker> Function(
      ManagedProfileErasureRequest request,
      bool retry,
    )
    openWorker,
  }) => ManagedProfileWipe(
    router: router,
    preferences: preferences,
    source: source,
    secretStore: secretStore,
    authentication: authentication,
    retireBackground: retireBackground,
    quiesce: quiesce,
    verifyOtherDataAbsent: verifyOtherDataAbsent,
  ).._openForTesting = openWorker;

  Future<ManagedErasureWorker> Function(
    ManagedProfileErasureRequest request,
    bool retry,
  )?
  _openForTesting;
  final _request = ManagedProfileErasureRequest();
  bool _preparationAttempted = false;
  final ProfileStorageRouterOwner _router;
  final ProfilePreferencesLifetime _preferences;
  final LegacyProfilePreferences _source;
  final QuickUnlockSecretStore _secretStore;
  final LocalScreenAuthentication _authentication;
  final Future<BackgroundResourceRetirement> Function() _retireBackground;
  BackgroundResourceRetirement? _background;
  final _captures = CaptureResourceLifetime.current();
  CaptureResourceRetirement? _captureRetirement;
  bool _backgroundAdmitted = false;
  final Future<void> Function() _quiesce, _verifyOtherDataAbsent;
  late final String _profileDirectory;
  ManagedErasureWorker? _worker;
  ManagedErasureBinding? _binding;
  bool _recoveryNeedsAdoption = false;
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

  Future<void> _verifyExternalAbsence() async {
    final vault = _vault, legacy = _legacy, background = _background;
    if (vault == null ||
        legacy == null ||
        background == null ||
        _captureRetirement == null) {
      throw const ManagedProfileWipeFailure();
    }
    await Future.wait<void>([
      vault.verifyAbsent(),
      legacy.verifyAbsent(),
      background.verifyReleasedResources(),
      _captureRetirement!.verifyReleasedResources(),
      _verifyOtherDataAbsent(),
    ]);
  }

  Future<void> _verifyCaptureResources() async {
    if (_background == null || _captureRetirement == null) {
      throw const ManagedProfileWipeFailure();
    }
    await _background!.verifyReleasedResources();
    await _captureRetirement!.verifyReleasedResources();
  }

  Future<void> _resumeExitedWorker() async {
    var worker = _worker;
    if (_receipt != null || worker == null) return;
    if (worker.exitedUnexpectedly) {
      final binding = _binding;
      // The worker port joins all accepted callbacks before acquiring a new
      // exclusive native grant. Death alone is never release authorization.
      // A returned worker can die before this owner captures its binding; only
      // its original application request, never an unbound generic recovery,
      // may select that still-removing plan.
      worker = binding == null
          ? await ManagedErasureWorker.recoverApplicationRequest(
              _profileDirectory,
              _request,
            )
          : await ManagedErasureWorker.resumeBound(_profileDirectory, binding);
      _worker = worker; // Retain even if inspection/adoption fails next.
      _recoveryNeedsAdoption = true;
    }
    if (!_recoveryNeedsAdoption) return;
    final snapshot = await worker.snapshot();
    if (snapshot.phase != ManagedRootErasurePhase.removing) {
      // No roster can be reconstructed from a terminal or missing marker. The
      // exact live operation must retain its previously verified retirements.
      // New OS records are refused and preserved, never erased by this path.
      if (_vault == null || _legacy == null) {
        throw const ManagedProfileWipeFailure();
      }
      _managedRemoved = _auxiliaryRemoved = true;
    } else {
      // A lost removal reply may have committed any prefix. Re-run only the
      // original immutable inventory; new/changed objects still refuse.
      // Rebind mutation authority to this live worker. The retired scope state
      // retains pending biometric-slot witnesses across these wrappers.
      _vault = QuickUnlockRetirement.forWorker(
        worker.scopeLease,
        _secretStore,
        _authentication,
      );
      _legacy = LegacyProfilePreferencesRetirement.forWorker(worker, _source);
      _managedRemoved = _auxiliaryRemoved = false;
    }
    _recoveryNeedsAdoption = false;
  }

  Future<void> _resume() async {
    if (_freshRouter) {
      await _releaseBackground();
      return;
    }
    _captures.sealAdmission();
    _background ??= await _retireBackground();
    _captureRetirement ??= await _captures.retire();
    await _verifyCaptureResources();
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
    await _resumeExitedWorker();
    if (_worker == null) {
      final retry = _preparationAttempted;
      _preparationAttempted = true;
      _worker =
          await (_openForTesting?.call(_request, retry) ??
              (retry
                  ? ManagedErasureWorker.recoverApplicationRequest(
                      _profileDirectory,
                      _request,
                    )
                  : ManagedErasureWorker.beginApplicationProfile(
                      profileDirectory: _profileDirectory,
                      profileNamespace: _source.profile,
                      legacyPath: _source.legacyPath,
                      request: _request,
                    )));
    }
    final worker = _worker!;
    if (_receipt == null) {
      if (_binding == null) {
        final snapshot = worker.scopeLease.snapshot;
        if (!snapshot.isApplicationProfile) {
          throw const ManagedProfileWipeFailure();
        }
        _binding = snapshot.binding;
      }
      _vault ??= QuickUnlockRetirement.forWorker(
        worker.scopeLease,
        _secretStore,
        _authentication,
      );
      _legacy ??= LegacyProfilePreferencesRetirement.forWorker(worker, _source);
      Future<void> retire() async {
        await _verifyCaptureResources();
        await Future.wait<void>([_vault!.retire(), _legacy!.retire()]);
        await _verifyCaptureResources();
      }

      if (!_managedRemoved) {
        await worker.removeManagedFiles(retireScopes: retire);
        _managedRemoved = true;
      }
      if (!_auxiliaryRemoved) {
        await worker.removeAuxiliaryFiles(retireScopes: retire);
        _auxiliaryRemoved = true;
      }
      // A durable native terminal may skip its callback, even when the same
      // worker survived a failed final sync. Recheck external owners on EVERY
      // attempt, not only on a worker replacement. This check never deletes.
      await _verifyExternalAbsence();
      _receipt = await worker.finish(
        verifyOtherDataAbsent: _verifyExternalAbsence,
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
    await _releaseBackground();
  }

  Future<void> _releaseBackground() async {
    if (_backgroundAdmitted) return;
    if (!_freshRouter || _receipt == null || _background == null) {
      throw const ManagedProfileWipeFailure();
    }
    await _verifyOtherDataAbsent();
    // Native release itself must recheck resources or recognize this exact
    // owner's lost successful reply. A separate token probe could reject that
    // legitimate retry after native admission was already released.
    await _background!.releaseAdmission();
    _captureRetirement!.releaseAdmission();
    _backgroundAdmitted = true;
  }

  /// Accepted work is joined; a failed attempt remains an on-disk pending
  /// operation. Close never authorizes fresh UI or deletes anything itself.
  Future<void> close() async {
    _closed = true;
    await _pending?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await _worker?.close();
  }
}
