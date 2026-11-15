part of 'quick_unlock_vault.dart';

/// Only OS record addresses, never passwords, pattern material or decryption
/// keys. A decoded witness can inspect absence; it grants no deletion authority.
/// Hidden storage always contributes its one legacy scope, not hidden slots.
final class QuickUnlockAbsenceWitness {
  QuickUnlockAbsenceWitness({
    required StorageUnlockScopes scopes,
    required Iterable<String> protectedKeys,
  }) : scopes = scopes,
       protectedKeys = _validate(scopes, protectedKeys);

  static const maxProtectedKeys = 4096;
  static const maxEncodedBytes = 1024 * 1024;
  final StorageUnlockScopes scopes;
  final List<String> protectedKeys;

  static List<String> _validate(
    StorageUnlockScopes scopes,
    Iterable<String> supplied,
  ) {
    final keys = supplied.take(maxProtectedKeys + 1).toList();
    final allowed = scopes.ids.toSet();
    final shape = RegExp(
      r'^xveil\.quick\.v1\.([0-9a-f]{64})\.bio\.([A-Za-z0-9+/=_-]{1,64})$',
    );
    if (keys.length > maxProtectedKeys || keys.toSet().length != keys.length) {
      throw const QuickUnlockRetirementFailure();
    }
    for (final key in keys) {
      final match = shape.firstMatch(key);
      if (match == null || !allowed.contains(match.group(1))) {
        throw const QuickUnlockRetirementFailure();
      }
    }
    keys.sort();
    return List.unmodifiable(keys);
  }

  String encode() =>
      jsonEncode({'v': 1, 'scopes': scopes.ids, 'protected': protectedKeys});

  factory QuickUnlockAbsenceWitness.decode(String encoded) {
    try {
      if (encoded.length > maxEncodedBytes ||
          utf8.encode(encoded).length > maxEncodedBytes) {
        throw const QuickUnlockRetirementFailure();
      }
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value.length != 3 ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['scopes'] is! List ||
          value['protected'] is! List) {
        throw const QuickUnlockRetirementFailure();
      }
      return QuickUnlockAbsenceWitness(
        scopes: StorageUnlockScopes((value['scopes'] as List).cast<String>()),
        protectedKeys: (value['protected'] as List).cast<String>(),
      );
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
