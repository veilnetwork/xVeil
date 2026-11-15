part of 'quick_unlock_vault.dart';

/// Only OS record addresses. Decoding permits read-only absence checks, never
/// deletion, authentication bypass or a fresh-lifetime receipt.
final class QuickUnlockAbsenceWitness {
  QuickUnlockAbsenceWitness._(this.records);
  factory QuickUnlockAbsenceWitness({
    required StorageUnlockScopes scopes,
    required Iterable<String> protectedKeys,
  }) {
    try {
      return QuickUnlockAbsenceWitness._(
        SavedEntryAddresses(scopes: scopes, protectedKeys: protectedKeys),
      );
    } catch (_) {
      throw const QuickUnlockRetirementFailure();
    }
  }
  final SavedEntryAddresses records;
  static const maxProtectedKeys = SavedEntryAddresses.maxProtectedKeys;
  static const maxEncodedBytes = SavedEntryAddresses.maxEncodedBytes;
  StorageUnlockScopes get scopes => records.scopes;
  List<String> get protectedKeys => records.protectedKeys;
  String encode() => records.encode();
  factory QuickUnlockAbsenceWitness.decode(String encoded) {
    try {
      return QuickUnlockAbsenceWitness._(SavedEntryAddresses.decode(encoded));
    } catch (_) {
      throw const QuickUnlockRetirementFailure();
    }
  }

  /// Read-only, suitable for an enclosing cold-recovery owner after it has
  /// sealed platform writers. Reappearing records are preserved and refuse
  /// success; neither plaintext reads nor repair/deletion are used here.
  Future<void> verifyAbsent(QuickUnlockSecretStore store) async {
    try {
      for (final scope in scopes.ids) {
        if (await store.contains('xveil.quick.v1.$scope')) {
          throw const QuickUnlockRetirementFailure();
        }
      }
      for (final key in protectedKeys) {
        if (await store.contains(key, biometric: true)) {
          throw const QuickUnlockRetirementFailure();
        }
      }
    } catch (_) {
      throw const QuickUnlockRetirementFailure();
    }
  }
}
