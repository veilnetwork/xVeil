part of 'quick_unlock_vault.dart';

/// Safe to report: no scope names, OS keys, backend messages or credential data.
final class QuickUnlockRetirementFailure implements Exception {
  const QuickUnlockRetirementFailure();
  @override
  String toString() => 'QuickUnlockRetirementFailure';
}

/// One owned erasure operation. Retain this owner until the profile intent is
/// finalized: all old wrappers/jobs for these backend/scope pairs stay sealed.
/// Same-backend accepted enrollment is joined, not merely deleted around.
/// Separate backend wrappers targeting the same OS store must share the actual
/// provider instance; this does not coordinate unrelated plugin isolates.
final class QuickUnlockRetirement {
  QuickUnlockRetirement(
    QuickUnlockSecretStore store,
    StorageUnlockScopes scopes,
    LocalScreenAuthentication authentication,
  ) : _binding = null,
      _requireOwner = null,
      _vaults = List.unmodifiable([
        for (final scope in scopes.ids)
          QuickUnlockVault(store, scope, authentication),
      ]);

  /// Capture the complete durable scope roster while the plan is readable.
  /// Admission later requires a released receipt for THIS exact intent, even
  /// if finalization was resumed by a different explicit recovery actor.
  QuickUnlockRetirement.forManagedErasure(
    ManagedRootErasure erasure,
    QuickUnlockSecretStore store,
    LocalScreenAuthentication authentication,
  ) : this._bound(
        erasure.retirementSnapshot(),
        store,
        authentication,
        requireOwner: () => erasure.retirementSnapshot(),
      );

  /// A live UI-side lease, not a retained progress snapshot, owns OS admission.
  QuickUnlockRetirement.forWorker(
    ManagedErasureScopeLease lease,
    QuickUnlockSecretStore store,
    LocalScreenAuthentication authentication,
  ) : this._bound(
        lease.snapshot,
        store,
        authentication,
        requireOwner: () => lease.snapshot,
      );

  QuickUnlockRetirement._bound(
    ManagedErasureSnapshot snapshot,
    QuickUnlockSecretStore store,
    LocalScreenAuthentication authentication, {
    required this._requireOwner,
  }) : _binding = snapshot.binding,
       _vaults = List.unmodifiable([
         for (final scope in snapshot.unlockScopes.ids)
           QuickUnlockVault(store, scope, authentication),
       ]);
  final ManagedErasureBinding? _binding;
  final void Function()? _requireOwner;
  bool _verified = false, _released = false;
  final List<QuickUnlockVault> _vaults;
  Future<void>? _pending;

  Future<void> retire() {
    if (_released) return Future.error(const QuickUnlockRetirementFailure());
    final pending = _pending;
    if (pending != null) return pending;
    try {
      _requireOwner?.call();
    } catch (_) {
      return Future.error(const QuickUnlockRetirementFailure());
    }
    // Invoke every scope synchronously before awaiting: a slow/refusing first
    // scope cannot leave later scopes accepting stale enrollment in the gap.
    _verified = false;
    final tasks = [
      for (final vault in _vaults)
        _requireOwner == null
            ? vault.retireForErasure()
            : vault._retireBoundForErasure(_requireOwner),
    ];
    return _pending = () async {
      try {
        // Wait for ALL tasks even if one fails. Every forget verifies absence;
        // soft UI opt-in flags are intentionally never consulted.
        await Future.wait(tasks);
        _requireOwner?.call();
        _verified = true;
      } catch (_) {
        throw const QuickUnlockRetirementFailure();
      } finally {
        _pending = null;
      }
    }();
  }

  /// Read-only reconciliation after a lost release reply; never deletes a
  /// newly appearing OS record or invents successful earlier retirement.
  Future<void> verifyAbsent() async {
    void requireQuiescent() {
      if (!_verified ||
          _released ||
          _pending != null ||
          _vaults.any(
            (vault) =>
                !vault._scopeState.retired ||
                vault._scopeState.detached ||
                vault._scopeState.pending != 0,
          )) {
        throw const QuickUnlockRetirementFailure();
      }
    }

    requireQuiescent();
    try {
      for (final vault in _vaults) {
        if (await vault.store.contains(vault._key)) {
          throw const QuickUnlockRetirementFailure();
        }
        for (final key in vault._scopeState.erasureBiometricKeys) {
          if (await vault.store.contains(key, biometric: true)) {
            throw const QuickUnlockRetirementFailure();
          }
        }
      }
      requireQuiescent();
    } catch (_) {
      throw const QuickUnlockRetirementFailure();
    }
  }

  /// Atomic UI-isolate handoff after the exact erasure has finalized and its
  /// native coordinator actually closed. No old state is un-retired: old
  /// wrappers remain sealed, including forget/repeated retirement. Providers
  /// must be invalidated separately before they can construct fresh wrappers.
  void admitFreshLifetime(ManagedErasureRelease receipt) {
    final binding = _binding;
    if (_released ||
        !_verified ||
        _pending != null ||
        binding == null ||
        !receipt.authorizes(binding)) {
      throw const QuickUnlockRetirementFailure();
    }
    // Validate ALL scopes before changing ANY registry entry. No await may
    // separate these checks from detaching the complete set.
    for (final vault in _vaults) {
      final state = vault._scopeState;
      if (!state.retired ||
          state.detached ||
          state.pending != 0 ||
          !identical(
            _QuickUnlockScopeState._backends[vault.store]?[vault.scope]?.target,
            state,
          )) {
        throw const QuickUnlockRetirementFailure();
      }
    }
    for (final vault in _vaults) {
      vault._scopeState.detached = true;
      vault._generation++;
      _QuickUnlockScopeState._backends[vault.store]!.remove(vault.scope);
    }
    _released = true;
  }
}
