import 'dart:convert';
import 'storage_unlock_scope.dart';

/// Bounded non-secret OS record addresses. This value grants no cleanup authority.
final class SavedEntryAddresses {
  SavedEntryAddresses({
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
      throw const FormatException('Invalid saved-entry addresses');
    }
    for (final key in keys) {
      final match = shape.firstMatch(key);
      if (match == null || !allowed.contains(match.group(1))) {
        throw const FormatException('Invalid saved-entry addresses');
      }
    }
    keys.sort();
    return List.unmodifiable(keys);
  }

  String encode() =>
      jsonEncode({'v': 1, 'scopes': scopes.ids, 'protected': protectedKeys});

  factory SavedEntryAddresses.decode(String encoded) {
    try {
      if (encoded.length > maxEncodedBytes ||
          utf8.encode(encoded).length > maxEncodedBytes) {
        throw const FormatException('Invalid saved-entry addresses');
      }
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value.length != 3 ||
          value['v'] is! int ||
          value['v'] != 1 ||
          value['scopes'] is! List ||
          value['protected'] is! List) {
        throw const FormatException('Invalid saved-entry addresses');
      }
      return SavedEntryAddresses(
        scopes: StorageUnlockScopes((value['scopes'] as List).cast<String>()),
        protectedKeys: (value['protected'] as List).cast<String>(),
      );
    } catch (_) {
      throw const FormatException('Invalid saved-entry addresses');
    }
  }
}
