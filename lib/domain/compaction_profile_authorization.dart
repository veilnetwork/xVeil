import 'dart:typed_data';

import 'storage_locator.dart';
import 'storage_protection.dart';

typedef CompactionProfileSnapshot = ({
  Map<ManagedIdentityId, Uint8List> authorizations,
  Set<ManagedIdentityId> plaintextApproved,
});

/// Explicit, in-memory authority for every ENUMERABLE owner whose references
/// may need updating. It neither inventories nor authorizes hidden keep-sets.
/// Callers must independently prove hidden password/key coverage.
final class CompactionProfileAuthorization {
  CompactionProfileAuthorization(Iterable<ManagedStorageLocator> expected)
    : identities = List.unmodifiable(expected) {
    if (identities.length > 128 ||
        identities.map((entry) => entry.id).toSet().length !=
            identities.length) {
      throw StateError('invalid compaction owner inventory');
    }
  }

  final List<ManagedStorageLocator> identities;
  final _keys = <ManagedIdentityId, Uint8List>{};
  bool _disposed = false;

  bool get isComplete => !_disposed && _keys.length == identities.length;
  bool contains(ManagedStorageLocator identity) =>
      !_disposed &&
      identities.contains(identity) &&
      _keys.containsKey(identity.id);

  bool matchesInventory(Iterable<ManagedStorageLocator> current) {
    final entries = current.toList();
    return !_disposed &&
        entries.length == identities.length &&
        entries.toSet().length == entries.length &&
        entries.every(identities.contains);
  }

  /// Only accept keys from an explicitly selected, authenticated owner.
  /// Plaintext needs a distinct user action rather than an empty password.
  void authorize(
    ManagedStorageLocator identity,
    List<int> keys, {
    bool plaintextApproved = false,
  }) {
    if (_disposed ||
        !identities.contains(identity) ||
        keys.length != 64 ||
        keys.any((byte) => byte < 0 || byte > 255) ||
        (identity.protection == StorageProtection.unencrypted &&
            !plaintextApproved)) {
      throw StateError('invalid compaction owner authorization');
    }
    final owned = Uint8List.fromList(keys);
    final old = _keys[identity.id];
    old?.fillRange(0, old.length, 0);
    _keys[identity.id] = owned;
  }

  CompactionProfileSnapshot snapshot() {
    if (!isComplete) throw StateError('incomplete compaction owner authority');
    return (
      authorizations: {
        for (final entry in _keys.entries)
          entry.key: Uint8List.fromList(entry.value),
      },
      plaintextApproved: {
        for (final entry in identities)
          if (entry.protection == StorageProtection.unencrypted) entry.id,
      },
    );
  }

  void dispose() {
    _disposed = true;
    for (final key in _keys.values) {
      key.fillRange(0, key.length, 0);
    }
    _keys.clear();
  }
}
