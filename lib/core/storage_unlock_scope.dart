import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../domain/storage_locator.dart';

/// Existing legacy vault names remain byte-identical. Managed credentials are
/// separated by profile/root, local ID and protection mode before any OS read.
String storageUnlockScope(
  String profile,
  String path,
  IdentityStorageLocator locator,
) {
  final material = switch (locator) {
    LegacyStorageLocator() => '$profile:$path',
    ManagedStorageLocator(:final id, :final protection) =>
      'xveil-managed-storage-v1\u0000$profile\u0000$path\u0000${protection.name}\u0000${id.value}',
  };
  return sha256.convert(utf8.encode(material)).toString();
}

/// Immutable public names of OS-vault scopes, never passwords or paths. Always
/// include the one legacy-container scope regardless of hidden-space presence.
/// Visible IDs/modes may be enumerated; no hidden-space roster is inspected.
final class StorageUnlockScopes {
  StorageUnlockScopes(Iterable<String> supplied) : ids = _validate(supplied);
  static const maxScopes = 129;
  final List<String> ids;
  static List<String> _validate(Iterable<String> supplied) {
    final list = supplied.take(maxScopes + 1).toList();
    if (list.isEmpty ||
        list.length > maxScopes ||
        list.toSet().length != list.length ||
        list.any((id) => !RegExp(r'^[0-9a-f]{64}$').hasMatch(id))) {
      throw const FormatException('Invalid saved sign-in scope set');
    }
    return List.unmodifiable(list);
  }

  factory StorageUnlockScopes.forProfile({
    required String profile,
    required String legacyPath,
    required String managedPath,
    required Iterable<ManagedStorageLocator> identities,
  }) => StorageUnlockScopes([
    storageUnlockScope(profile, legacyPath, const LegacyStorageLocator()),
    for (final identity in identities.take(maxScopes))
      storageUnlockScope(profile, managedPath, identity),
  ]);
}
