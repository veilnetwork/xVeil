import 'dart:async';
import 'dart:io';
import 'package:meta/meta.dart' show visibleForTesting;

// Public orchestration inputs stay descriptive without exposing private fields.
// ignore_for_file: prefer_initializing_formals

import '../../core/background_service_lifetime.dart';
import '../../core/capture_resource_lifetime.dart';
import '../../core/local_authentication.dart';
import '../../core/quick_unlock_vault.dart';
import 'async_kv_log_store.dart';
import 'legacy_profile_preferences.dart';
import 'managed_directory_catalog.dart';
import 'managed_profile_wipe.dart';
import 'profile_prefs_store.dart';

/// A startup-only owner, before ordinary providers, runtime directories or
/// profile preference files have been opened. It never creates an erasure plan.
/// Application intents were published only after the old application verified
/// node/VPN/runtime shutdown. Fresh platform retirement checks auto-restarted
/// foreground/capture/network activity without booting another profile.
final class ColdProfileErasureRecovery {
  ColdProfileErasureRecovery({
    required this.source,
    required QuickUnlockSecretStore secretStore,
    required LocalScreenAuthentication authentication,
    required Future<BackgroundResourceRetirement> Function() retireBackground,
  }) : _secretStore = secretStore,
       _authentication = authentication,
       _retireBackground = retireBackground {
    try {
      source.requireColdBootstrapSource();
      final base = File(
        source.preferencePath,
      ).parent.resolveSymbolicLinksSync();
      if (File(source.legacyPath).parent.resolveSymbolicLinksSync() != base) {
        throw const ManagedProfileWipeFailure();
      }
      _profileDirectory = '$base/visible-storage';
    } catch (_) {
      throw const ManagedProfileWipeFailure();
    }
  }

  /// Real native worker with an explicit fault/checkpoint boundary. Production
  /// startup cannot select this opener through preferences or environment.
  @visibleForTesting
  factory ColdProfileErasureRecovery.withWorkerOpenerForTesting({
    required LegacyProfilePreferences source,
    required QuickUnlockSecretStore secretStore,
    required LocalScreenAuthentication authentication,
    required Future<BackgroundResourceRetirement> Function() retireBackground,
    required Future<ManagedErasureWorker> Function(
      String,
      ManagedErasureBinding?,
    )
    openWorker,
  }) => ColdProfileErasureRecovery(
    source: source,
    secretStore: secretStore,
    authentication: authentication,
    retireBackground: retireBackground,
  ).._openForTesting = openWorker;

  Future<ManagedErasureWorker> Function(String, ManagedErasureBinding?)?
  _openForTesting;

  final LegacyProfilePreferences source;
  final QuickUnlockSecretStore _secretStore;
  final LocalScreenAuthentication _authentication;
  final Future<BackgroundResourceRetirement> Function() _retireBackground;
  final _captures = CaptureResourceLifetime.current();
  late final String _profileDirectory;
  BackgroundResourceRetirement? _background;
  CaptureResourceRetirement? _captureRetirement;
  ManagedErasureWorker? _worker;
  ManagedErasureBinding? _binding;
  QuickUnlockAbsenceWitness? _witness;
  QuickUnlockRetirement? _vault;
  LegacyProfilePreferencesRetirement? _legacy;
  LegacyProfilePreferencesColdRecovery? _readOnlyLegacy;
  ManagedErasureRelease? _receipt;
  bool _managedRemoved = false, _auxiliaryRemoved = false;
  bool _vaultAdmitted = false,
      _legacyAdmitted = false,
      _preferencesInstalled = false;
  bool _completed = false, _closed = false;
  bool _workerInspected = false, _backgroundReleased = false;
  Future<void>? _pending;

  Future<void> resume() {
    if (_closed) return Future.error(const ManagedProfileWipeFailure());
    if (_completed) return Future.value();
    final pending = _pending;
    if (pending != null) return pending;
    _captures.sealAdmission();
    final done = Completer<void>();
    _pending = done.future; // Reserve before an adapter can reenter this owner.
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

  Future<void> _verifyResources() async {
    if (!_legacyAdmitted) source.requireOriginalBackendSelected();
    if (_background == null || _captureRetirement == null) {
      throw const ManagedProfileWipeFailure();
    }
    await _background!.verifyReleasedResources();
    await _captureRetirement!.verifyReleasedResources();
  }

  Future<void> _verifyExternalAbsence() async {
    await _verifyResources();
    if (_vault != null && _legacy != null) {
      await _vault!.verifyAbsent();
      await _legacy!.verifyAbsent();
    } else {
      final witness = _witness, legacy = _readOnlyLegacy;
      if (witness == null || legacy == null) {
        throw const ManagedProfileWipeFailure();
      }
      await witness.verifyAbsent(_secretStore);
      await legacy.verifyAbsent();
    }
    await _verifyResources();
  }

  Future<void> _openWorker() async {
    final current = _worker;
    if (current != null && !current.exitedUnexpectedly && _workerInspected) {
      return;
    }
    final binding = _binding;
    final worker = current != null && !current.exitedUnexpectedly
        ? current
        : _openForTesting != null
        ? await _openForTesting!(_profileDirectory, binding)
        : binding != null
        ? await ManagedErasureWorker.resumeBound(_profileDirectory, binding)
        : StorageProfileCoordinator.hasErasureIntent(
            _profileDirectory,
            includeApplicationJournal: false,
          )
        ? await ManagedErasureWorker.recover(_profileDirectory)
        : await ManagedErasureWorker.reconcileApplicationJournal(
            _profileDirectory,
          );
    _worker = worker; // Retain ownership even if subsequent inspection fails.
    _workerInspected = false;
    final snapshot = await worker.snapshot();
    if (!snapshot.isApplicationProfile ||
        !snapshot.erasesProfilePreferences ||
        (binding != null && !snapshot.binding.sameOperation(binding))) {
      throw const ManagedProfileWipeFailure();
    }
    _binding = snapshot.binding;
    final saved = snapshot.savedEntryWitness;
    if (saved != null) {
      final witness = QuickUnlockAbsenceWitness.decode(saved);
      if (witness.scopes.ids.first != source.scope ||
          (_witness != null && _witness!.encode() != witness.encode())) {
        throw const ManagedProfileWipeFailure();
      }
      _witness = witness;
    }
    if (snapshot.phase == ManagedRootErasurePhase.removing) {
      if (snapshot.unlockScopes.ids.first != source.scope) {
        throw const ManagedProfileWipeFailure();
      }
      _vault = QuickUnlockRetirement.forWorker(
        worker.scopeLease,
        _secretStore,
        _authentication,
        recoveryWitness: _witness,
      );
      _legacy = LegacyProfilePreferencesRetirement.forWorker(worker, source);
      _managedRemoved = _auxiliaryRemoved = false;
    } else {
      _managedRemoved = _auxiliaryRemoved = true;
      if (_vault == null || _legacy == null) {
        if (_witness == null) throw const ManagedProfileWipeFailure();
        _readOnlyLegacy ??= LegacyProfilePreferencesColdRecovery(
          snapshot: snapshot,
          profileDirectory: _profileDirectory,
          source: source,
        );
      }
    }
    _workerInspected = true;
  }

  Future<void> _resume() async {
    if (_receipt != null && _preferencesInstalled) {
      await _releaseResources();
      return;
    }
    if (!_legacyAdmitted) source.requireOriginalBackendSelected();
    _background ??= await _retireBackground();
    _captureRetirement ??= await _captures.retire();
    await _verifyResources();
    if (_receipt == null) {
      await _openWorker();
      final worker = _worker!;
      if (!_managedRemoved) {
        _witness ??= await _vault!.prepareAbsenceWitness();
        await worker.persistSavedEntryWitness(_witness!.encode());
      }
      Future<void> retire() async {
        await _verifyResources();
        await Future.wait<void>([
          _vault!.retire(
            persistWitness: (current) async {
              if (current.encode() != _witness!.encode()) {
                throw const ManagedProfileWipeFailure();
              }
            },
          ),
          _legacy!.retire(),
        ]);
        await _verifyResources();
      }

      if (!_managedRemoved) {
        await worker.removeManagedFiles(retireScopes: retire);
        _managedRemoved = true;
      }
      if (!_auxiliaryRemoved) {
        await worker.removeAuxiliaryFiles(retireScopes: retire);
        _auxiliaryRemoved = true;
      }
      await _verifyExternalAbsence();
      _receipt = await worker.finish(
        verifyOtherDataAbsent: _verifyExternalAbsence,
      );
    }
    final receipt = _receipt!;
    if (!_vaultAdmitted) {
      _vault?.admitFreshLifetime(receipt);
      _vaultAdmitted = true;
    }
    if (!_legacyAdmitted) {
      if (_legacy != null) {
        _legacy!.admitFreshLifetime(receipt);
      } else {
        _readOnlyLegacy!.admitFreshLifetime(receipt);
      }
      _legacyAdmitted = true;
    }
    if (!_preferencesInstalled) {
      Future<String> install(backend) => installProfilePreferences(
        supportDir: source.supportDirectory,
        args: ['--profile', source.profile],
        environment: {'XVEIL_STORE_PATH': source.legacyPath},
        legacyBackend: backend,
        openOwnedFile: ManagedProfilePreferencesFile.open,
        validateSelectedFile: (path) =>
            validateManagedPreferencesContainer(path, source.legacyPath),
      );
      if (_legacy != null) {
        await _legacy!.bootstrapFresh(receipt, install);
      } else {
        await _readOnlyLegacy!.bootstrapFresh(receipt, install);
      }
      _preferencesInstalled = true;
    }
    await _releaseResources();
  }

  Future<void> _releaseResources() async {
    if (!_backgroundReleased) {
      await _background!.releaseAdmission();
      _backgroundReleased = true;
    }
    _captureRetirement!.releaseAdmission();
    _completed = true;
  }

  Future<void> close() async {
    _closed = true;
    await _pending?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await _worker?.close();
  }
}
