part of 'managed_directory_catalog.dart';

/// Explicit recovery of a lost final release reply. Caller retained the exact
/// original operation binding and owns a READ-ONLY external absence verifier.
/// No missing marker is treated as proof of completed cleanup on its own.
final class ManagedErasureReconciliation {
  ManagedErasureReconciliation._(this._gate, this.binding, this._journal);
  final StorageProfileCoordinator _gate;
  final ManagedErasureBinding binding;
  final _ApplicationErasureJournal? _journal;
  bool _operating = false, _verified = false;
  bool _releaseStarted = false;

  static ManagedErasureReconciliation open(
    String profileDirectory,
    ManagedErasureBinding binding, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final gate = StorageProfileCoordinator._openErasureRecovery(
      profileDirectory,
      fs,
    );
    try {
      final journal = _ApplicationErasureJournal.openIfPresent(gate, binding);
      final result = ManagedErasureReconciliation._(gate, binding, journal);
      result._validate();
      return result;
    } catch (_) {
      gate.close();
      rethrow;
    }
  });

  static ManagedErasureReconciliation openApplicationJournal(
    String profileDirectory, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final gate = StorageProfileCoordinator._openErasureRecovery(
      profileDirectory,
      fs,
    );
    try {
      final journal = _ApplicationErasureJournal.openForRecovery(gate);
      final result = ManagedErasureReconciliation._(
        gate,
        journal.binding,
        journal,
      );
      result._validate();
      return result;
    } catch (_) {
      gate.close();
      rethrow;
    }
  });

  void _validate() {
    _gate.requireHeld(exclusive: true);
    if (StorageProfileCoordinator.hasErasureIntent(
      _gate.profileDirectory,
      fs: _gate._fs,
      includeApplicationJournal: false,
    )) {
      throw const ManagedFsFailure(ManagedFsFailureKind.erasurePending);
    }
    _ErasureCompletion.requireRootAbsent(_gate);
    binding._auxiliaryScope?.requireAbsent(_gate);
    if (binding._profile != _gate._profileWitness.identity ||
        binding._coordinator != _gate._directoryWitness.identity) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    _journal?.validateForRelease(_gate);
  }

  ManagedErasureSnapshot snapshot() {
    if (!_gate._closed) _validate();
    return ManagedErasureSnapshot._(
      binding,
      _verified && _gate._closed
          ? ManagedRootErasurePhase.complete
          : ManagedRootErasurePhase.finishing,
      null,
      null,
      savedEntryWitness: _journal?.records.encode(),
    );
  }

  Future<ManagedErasureRelease> verifyAndRelease({
    required Future<void> Function() verifyOtherDataAbsent,
  }) async {
    if (_operating) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _operating = true;
    try {
      if (!_releaseStarted) {
        _validate();
        await verifyOtherDataAbsent();
        _validate();
        // Confirm the absent terminal entry even if the old reply was lost
        // around its final unlink/sync. Observation alone is not durability.
        _gate._fs.syncDirectory(_gate.directory);
        _journal?.removeAndSync(_gate);
        _verified = true;
        _releaseStarted = true;
      }
      // Retrying a failed consuming native close never reruns destructive work
      // or invents a successful release from isolate death.
      _gate.close();
      return ManagedErasureRelease._(binding);
    } on FileSystemException catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedFsFailure(ManagedFsFailureKind.io),
        trace,
      );
    } finally {
      _operating = false;
    }
  }

  void close() {
    if (_operating || (_journal?.unlinkPending ?? false)) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _gate.close();
  }
}
