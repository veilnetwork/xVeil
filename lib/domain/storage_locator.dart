import 'storage_protection.dart';

/// An opaque LOCAL ID, never a network address, path, key or recovery code.
final class ManagedIdentityId {
  ManagedIdentityId(String value) : value = _checked(value);

  final String value;

  static String _checked(String value) {
    if (value.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const FormatException('Invalid managed identity locator');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is ManagedIdentityId && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

/// A malformed locator never means "try the legacy container instead".
final class InvalidStorageLocator implements Exception {
  const InvalidStorageLocator();
  @override
  String toString() => 'InvalidStorageLocator';
}

/// A profile-relative storage choice, without paths or credentials. The legacy
/// locator names only the historical container: it cannot enumerate its hidden
/// spaces. A visible locator selects its ID AND mode before credential use.
sealed class IdentityStorageLocator {
  const IdentityStorageLocator();

  factory IdentityStorageLocator.decode(Object? raw) {
    if (raw is! Map<String, dynamic> || raw['v'] is! int || raw['v'] != 1) {
      throw const InvalidStorageLocator();
    }
    if (raw.length == 2 && raw['kind'] == 'legacy') {
      return const LegacyStorageLocator();
    }
    if (raw.length != 4 ||
        raw['kind'] != 'managed' ||
        raw['id'] is! String ||
        !raw.containsKey('protection')) {
      throw const InvalidStorageLocator();
    }
    final protection = switch (raw['protection']) {
      'encrypted' => StorageProtection.encrypted,
      'unencrypted' => StorageProtection.unencrypted,
      _ => throw const InvalidStorageLocator(),
    };
    try {
      return ManagedStorageLocator(
        id: ManagedIdentityId(raw['id'] as String),
        protection: protection,
      );
    } on FormatException {
      throw const InvalidStorageLocator();
    }
  }

  Map<String, Object> encode();
}

final class LegacyStorageLocator extends IdentityStorageLocator {
  const LegacyStorageLocator();
  @override
  Map<String, Object> encode() => {'v': 1, 'kind': 'legacy'};
  @override
  bool operator ==(Object other) => other is LegacyStorageLocator;
  @override
  int get hashCode => 0x4c454741;
}

final class ManagedStorageLocator extends IdentityStorageLocator {
  ManagedStorageLocator({required this.id, required this.protection}) {
    if (!protection.hasPublicCatalogEntry) {
      throw const InvalidStorageLocator();
    }
  }

  final ManagedIdentityId id;
  final StorageProtection protection;
  @override
  Map<String, Object> encode() => {
    'v': 1,
    'kind': 'managed',
    'id': id.value,
    'protection': protection.name,
  };
  @override
  bool operator ==(Object other) =>
      other is ManagedStorageLocator &&
      other.id == id &&
      other.protection == protection;
  @override
  int get hashCode => Object.hash(id, protection);
}
