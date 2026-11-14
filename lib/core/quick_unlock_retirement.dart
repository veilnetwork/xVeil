import 'local_authentication.dart';
import 'quick_unlock_vault.dart';
import 'storage_unlock_scope.dart';

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
  ) : _vaults = List.unmodifiable([
        for (final scope in scopes.ids)
          QuickUnlockVault(store, scope, authentication),
      ]);
  final List<QuickUnlockVault> _vaults;
  Future<void>? _pending;

  Future<void> retire() {
    final pending = _pending;
    if (pending != null) return pending;
    // Invoke every scope synchronously before awaiting: a slow/refusing first
    // scope cannot leave later scopes accepting stale enrollment in the gap.
    final tasks = [for (final vault in _vaults) vault.retireForErasure()];
    return _pending = () async {
      try {
        // Wait for ALL tasks even if one fails. Every forget verifies absence;
        // soft UI opt-in flags are intentionally never consulted.
        await Future.wait(tasks);
      } catch (_) {
        throw const QuickUnlockRetirementFailure();
      } finally {
        _pending = null;
      }
    }();
  }
}
