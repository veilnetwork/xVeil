import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'roster.dart';
import 'storage_locator.dart';

const kPendingIdentityErase = 'storage.pending_identity_erase.v1';

enum IdentityEraseFailureKind { invalid, conflict, lastIdentity, masterTarget }

/// Bounded category only: no labels, local IDs, paths or credentials.
final class IdentityEraseFailure implements Exception {
  const IdentityEraseFailure(this.kind);
  final IdentityEraseFailureKind kind;
  @override
  String toString() => 'IdentityEraseFailure(${kind.name})';
}

/// Sensitive authorization journal INSIDE the master, never public metadata.
/// Owns its decoded/copied target key buffer; callers must destroy it. Binding
/// to root AND master keys prevents copying a journal between hidden masters
/// that intentionally have the same legacy locator.
final class PendingIdentityErase {
  PendingIdentityErase._(
    this.root,
    this.target,
    this._masterDigest,
    this._keys,
  );
  final IdentityStorageLocator root, target;
  final Uint8List _masterDigest, _keys;
  bool _destroyed = false;
  static const maxEncodedBytes = 1024;

  factory PendingIdentityErase.authorized({
    required IdentityStorageLocator root,
    required Uint8List masterKeys,
    required RosterEntry target,
  }) {
    if (masterKeys.length != 64 || target.spaceKeys.length != 64) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.invalid);
    }
    final intent = PendingIdentityErase._(
      root,
      target.storageLocator,
      Uint8List.fromList(sha256.convert(masterKeys).bytes),
      Uint8List.fromList(target.spaceKeys),
    );
    try {
      intent.validate(root, masterKeys);
      return intent;
    } catch (_) {
      intent.destroy();
      rethrow;
    }
  }

  factory PendingIdentityErase.decode(String source) {
    if (source.length > maxEncodedBytes ||
        utf8.encode(source).length > maxEncodedBytes) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.invalid);
    }
    Uint8List? digest, keys;
    try {
      final raw = jsonDecode(source);
      if (raw is! Map<String, dynamic> ||
          raw.length != 5 ||
          raw['v'] is! int ||
          raw['v'] != 1 ||
          !raw.keys.toSet().containsAll({
            'v',
            'root',
            'target',
            'master',
            'keys',
          })) {
        throw const IdentityEraseFailure(IdentityEraseFailureKind.invalid);
      }
      Uint8List bytes(Object? text, int size) {
        if (text is! String) throw const FormatException();
        final result = base64.decode(text);
        if (result.length != size || base64.encode(result) != text) {
          result.fillRange(0, result.length, 0);
          throw const FormatException();
        }
        return result;
      }

      digest = bytes(raw['master'], 32);
      keys = bytes(raw['keys'], 64);
      return PendingIdentityErase._(
        IdentityStorageLocator.decode(raw['root']),
        IdentityStorageLocator.decode(raw['target']),
        digest,
        keys,
      );
    } catch (_) {
      digest?.fillRange(0, digest.length, 0);
      keys?.fillRange(0, keys.length, 0);
      throw const IdentityEraseFailure(IdentityEraseFailureKind.invalid);
    }
  }

  void _requireLive() {
    if (_destroyed) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.invalid);
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  void validate(IdentityStorageLocator actualRoot, Uint8List masterKeys) {
    _requireLive();
    if (root != actualRoot ||
        masterKeys.length != 64 ||
        !_same(_masterDigest, sha256.convert(masterKeys).bytes)) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.conflict);
    }
    if (_same(_keys, masterKeys) ||
        root is ManagedStorageLocator &&
            target is ManagedStorageLocator &&
            (root as ManagedStorageLocator).id ==
                (target as ManagedStorageLocator).id) {
      throw const IdentityEraseFailure(IdentityEraseFailureKind.masterTarget);
    }
  }

  bool matches(RosterEntry entry) {
    _requireLive();
    return entry.storageLocator == target && _same(entry.spaceKeys, _keys);
  }

  bool sameTarget(PendingIdentityErase other) {
    _requireLive();
    other._requireLive();
    return target == other.target && _same(_keys, other._keys);
  }

  RosterEntry copyTarget() {
    _requireLive();
    return RosterEntry(
      label: '',
      storageLocator: target,
      spaceKeys: Uint8List.fromList(_keys),
    );
  }

  String encode() {
    _requireLive();
    return jsonEncode({
      'v': 1,
      'root': root.encode(),
      'target': target.encode(),
      'master': base64.encode(_masterDigest),
      'keys': base64.encode(_keys),
    });
  }

  void destroy() {
    _keys.fillRange(0, _keys.length, 0);
    _masterDigest.fillRange(0, _masterDigest.length, 0);
    _destroyed = true;
  }
}
