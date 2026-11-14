part of 'managed_directory_catalog.dart';

/// Explicit recovery of a lost final release reply. Caller retained the exact
/// original operation binding and owns a READ-ONLY external absence verifier.
/// No missing marker is treated as proof of completed cleanup on its own.
final class ManagedErasureReconciliation {
  ManagedErasureReconciliation._(this._gate, this.binding);
  final StorageProfileCoordinator _gate;
  final ManagedErasureBinding binding;
  bool _operating = false, _verified = false;

  static ManagedErasureReconciliation open(
    String profileDirectory,
    ManagedErasureBinding binding, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final gate = StorageProfileCoordinator.openExisting(
      profileDirectory,
      exclusive: true,
      fs: fs,
    );
    if (gate == null) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    try {
      final result = ManagedErasureReconciliation._(gate, binding);
      result._validate();
      return result;
    } catch (_) {
      gate.close();
      rethrow;
    }
  });

  void _validate() {
    _gate.requireHeld(exclusive: true); // Also refuses either pending marker.
    _ErasureCompletion.requireRootAbsent(_gate);
    binding._auxiliaryScope?.requireAbsent(_gate);
    if (binding._profile != _gate._profileWitness.identity ||
        binding._coordinator != _gate._directoryWitness.identity) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
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
      if (!_verified) {
        _validate();
        await verifyOtherDataAbsent();
        _validate();
        // Confirm the absent terminal entry even if the old reply was lost
        // around its final unlink/sync. Observation alone is not durability.
        _gate._fs.syncDirectory(_gate.directory);
        _verified = true;
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
    if (_operating) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _gate.close();
  }
}
