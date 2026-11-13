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
