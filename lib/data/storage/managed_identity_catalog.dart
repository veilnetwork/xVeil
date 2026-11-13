import 'dart:convert';
import 'dart:io';

import '../../domain/storage_protection.dart';

/// An opaque LOCAL locator, never a node address, key or recovery credential.
/// Strict syntax keeps catalog data from selecting paths outside its directory.
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

final class ManagedIdentityEntry {
  ManagedIdentityEntry({required this.id, required this.protection}) {
    if (!protection.hasPublicCatalogEntry) {
      throw ArgumentError('Hidden spaces must not enter a public catalog');
    }
  }

  final ManagedIdentityId id;
  final StorageProtection protection;
}

/// Public metadata for ENUMERABLE stores only. No key, password, display name,
/// public network address or reference to a hidden space belongs here.
///
/// Invalid data is rejected as a whole. Treating a malformed catalog as empty
/// would hide existing stores and let later onboarding forget their locators.
final class ManagedIdentityCatalog {
  ManagedIdentityCatalog(Iterable<ManagedIdentityEntry> identities)
    : identities = List.unmodifiable(identities) {
    if (this.identities.length > maxIdentities) {
      throw const FormatException('Managed identity catalog is too large');
    }
    final ids = <ManagedIdentityId>{};
    for (final entry in this.identities) {
      if (!ids.add(entry.id)) {
        throw const FormatException('Duplicate managed identity locator');
      }
    }
  }

  static const maxIdentities = 128;
  static const maxEncodedBytes = 32 * 1024;
  final List<ManagedIdentityEntry> identities;

  factory ManagedIdentityCatalog.decode(String encoded) {
    if (utf8.encode(encoded).length > maxEncodedBytes) {
      throw const FormatException('Managed identity catalog is too large');
    }
    final json = jsonDecode(encoded);
    if (json is! Map<String, dynamic> ||
        !_only(json, const {'version', 'identities'}) ||
        json['version'] != 1 ||
        json['identities'] is! List) {
      throw const FormatException('Invalid managed identity catalog');
    }
    final entries = json['identities'] as List;
    if (entries.length > maxIdentities) {
      throw const FormatException('Managed identity catalog is too large');
    }
    return ManagedIdentityCatalog([
      for (final raw in entries) _decodeEntry(raw),
    ]);
  }

  static ManagedIdentityEntry _decodeEntry(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        !_only(raw, const {'id', 'protection'}) ||
        raw['id'] is! String) {
      throw const FormatException('Invalid managed identity entry');
    }
    final protection = switch (raw['protection']) {
      'encrypted' => StorageProtection.encrypted,
      'unencrypted' => StorageProtection.unencrypted,
      _ => throw const FormatException('Invalid managed storage protection'),
    };
    return ManagedIdentityEntry(
      id: ManagedIdentityId(raw['id'] as String),
      protection: protection,
    );
  }

  static bool _only(Map<String, dynamic> json, Set<String> fields) =>
      json.length == fields.length && fields.every(json.containsKey);

  String encode() => jsonEncode({
    'version': 1,
    'identities': [
      for (final entry in identities)
        {'id': entry.id.value, 'protection': entry.protection.name},
    ],
  });
}

/// Managed stores and their blobs have separate directories. Legacy hidden
/// containers remain at their existing path and are never catalog candidates.
final class ManagedIdentityLayout {
  ManagedIdentityLayout(String profileDirectory)
    : _root = Directory(profileDirectory).absolute;

  final Directory _root;

  String get catalogPath =>
      File.fromUri(_root.uri.resolve('identities/catalog.sqlite3')).path;

  String directory(ManagedIdentityId id) =>
      File.fromUri(_root.uri.resolve('identities/${id.value}')).path;

  /// Plaintext identities use a single SQLite database. Encrypted identities
  /// instead own the three role-bound files below; no mode is inferred by
  /// trying these paths after an unlock fails.
  String dataPath(ManagedIdentityId id) => _file(id, 'data.store');
  String keyboxPath(ManagedIdentityId id) => _file(id, 'keybox.hv');
  String contentPath(ManagedIdentityId id) => _file(id, 'content.hv');
  String maintenancePath(ManagedIdentityId id) => _file(id, 'maintenance.hv');

  String _file(ManagedIdentityId id, String name) =>
      File.fromUri(Directory(directory(id)).uri.resolve(name)).path;

  String blobDirectory(ManagedIdentityId id) =>
      Directory.fromUri(Directory(directory(id)).uri.resolve('blobs/')).path;
}
