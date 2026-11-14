import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'storage_locator.dart';

const kIdentitySetupJournalFile = 'identity.setup.intent.v1';
const kIdentitySetupCredentialFile = 'identity.setup.credential.v1';

enum IdentitySetupFailureKind { invalid, conflict, unavailable }

final class IdentitySetupFailure implements Exception {
  const IdentitySetupFailure(this.kind);
  final IdentitySetupFailureKind kind;
  @override
  String toString() => 'IdentitySetupFailure(${kind.name})';
}

/// Sensitive creation intent, stored INSIDE the authenticated identity, never
/// in a catalog or preferences. A digest binds even a legacy locator to the
/// exact space. Owns its mutable buffers; destroy after every outcome.
final class IdentitySetupIntent {
  IdentitySetupIntent._({
    required this.root,
    required this._owner,
    required this.mode,
    required this.persistLegacyMode,
    required this.displayName,
    required this.phrase,
    required this.restoring,
    required this.joinExisting,
    required this.certificateOffered,
    required this.certificateSaved,
    required this.nodeConfig,
    required this.credentialLength,
    required this._credentialDigest,
  });

  static const maxMetadataBytes = 128 * 1024;
  static const maxCredentialBytes = 16 * 1024;
  final IdentityStorageLocator root;
  final StorageMode mode;
  final bool persistLegacyMode, restoring, joinExisting;
  final bool certificateOffered, certificateSaved;
  final String? displayName, phrase, nodeConfig;
  final int? credentialLength;
  final Uint8List _owner;
  final Uint8List? _credentialDigest;
  Uint8List? _credential;
  bool _destroyed = false;

  factory IdentitySetupIntent.create({
    required IdentityStorageLocator root,
    required Uint8List keys,
    required StorageMode mode,
    required bool persistLegacyMode,
    String? displayName,
    String? phrase,
    bool restoring = false,
    bool joinExisting = false,
    bool certificateOffered = false,
    bool certificateSaved = false,
    String? nodeConfig,
    Uint8List? credential,
  }) {
    if (keys.length != 64 ||
        credential != null &&
            (credential.isEmpty || credential.length > maxCredentialBytes)) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
    }
    final intent = IdentitySetupIntent._(
      root: root,
      owner: Uint8List.fromList(sha256.convert(keys).bytes),
      mode: mode,
      persistLegacyMode: persistLegacyMode,
      displayName: displayName,
      phrase: phrase,
      restoring: restoring,
      joinExisting: joinExisting,
      certificateOffered: certificateOffered,
      certificateSaved: certificateSaved,
      nodeConfig: nodeConfig == null || nodeConfig.trim().isEmpty
          ? null
          : nodeConfig,
      credentialLength: credential?.length,
      credentialDigest: credential == null
          ? null
          : Uint8List.fromList(sha256.convert(credential).bytes),
    );
    try {
      if (credential != null) intent.attachCredential(credential);
      final check = intent.encode();
      check.fillRange(0, check.length, 0);
      return intent;
    } catch (_) {
      intent.destroy();
      rethrow;
    }
  }

  void _live() {
    if (_destroyed) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.unavailable);
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

  bool get complete {
    _live();
    return credentialLength == null || _credential != null;
  }

  Uint8List? copyCredential() {
    _live();
    return _credential == null ? null : Uint8List.fromList(_credential!);
  }

  void attachCredential(Uint8List value) {
    _live();
    if (_credential != null ||
        value.length != credentialLength ||
        _credentialDigest == null ||
        !_same(_credentialDigest, sha256.convert(value).bytes)) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
    }
    _credential = Uint8List.fromList(value);
  }

  bool matchesCredential(Uint8List value) {
    _live();
    return credentialLength == value.length &&
        _credentialDigest != null &&
        _same(_credentialDigest, sha256.convert(value).bytes);
  }

  void validate(IdentityStorageLocator actualRoot, Uint8List keys) {
    _live();
    if (root != actualRoot ||
        keys.length != 64 ||
        !_same(_owner, sha256.convert(keys).bytes)) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
    }
  }

  Uint8List encode() {
    _live();
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'root': root.encode(),
          'owner': base64.encode(_owner),
          'mode': mode.name,
          'persist_mode': persistLegacyMode,
          'name': displayName,
          'phrase': phrase,
          'restore': restoring,
          'join': joinExisting,
          'offered': certificateOffered,
          'saved': certificateSaved,
          'config': nodeConfig,
          'credential_length': credentialLength,
          'credential_digest': _credentialDigest == null
              ? null
              : base64.encode(_credentialDigest),
        }),
      ),
    );
    if (bytes.length > maxMetadataBytes) {
      bytes.fillRange(0, bytes.length, 0);
      throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
    }
    return bytes;
  }

  factory IdentitySetupIntent.decode(Uint8List bytes) {
    Uint8List? owner, digest;
    try {
      if (bytes.isEmpty || bytes.length > maxMetadataBytes) {
        throw const FormatException();
      }
      final m = jsonDecode(utf8.decode(bytes));
      const fields = {
        'v',
        'root',
        'owner',
        'mode',
        'persist_mode',
        'name',
        'phrase',
        'restore',
        'join',
        'offered',
        'saved',
        'config',
        'credential_length',
        'credential_digest',
      };
      if (m is! Map<String, dynamic> ||
          m.length != fields.length ||
          !m.keys.every(fields.contains) ||
          m['v'] is! int ||
          m['v'] != 1 ||
          ![
            'persist_mode',
            'restore',
            'join',
            'offered',
            'saved',
          ].every((k) => m[k] is bool) ||
          ![
            'name',
            'phrase',
            'config',
          ].every((k) => m[k] == null || m[k] is String)) {
        throw const FormatException();
      }
      owner = base64.decode(m['owner'] as String);
      final len = m['credential_length'];
      digest = m['credential_digest'] == null
          ? null
          : base64.decode(m['credential_digest'] as String);
      if (owner.length != 32 ||
          (len == null
              ? digest != null
              : len is! int ||
                    len < 1 ||
                    len > maxCredentialBytes ||
                    digest?.length != 32)) {
        throw const FormatException();
      }
      final result = IdentitySetupIntent._(
        root: IdentityStorageLocator.decode(m['root']),
        owner: owner,
        mode: StorageMode.values.byName(m['mode'] as String),
        persistLegacyMode: m['persist_mode'] as bool,
        displayName: m['name'] as String?,
        phrase: m['phrase'] as String?,
        restoring: m['restore'] as bool,
        joinExisting: m['join'] as bool,
        certificateOffered: m['offered'] as bool,
        certificateSaved: m['saved'] as bool,
        nodeConfig: m['config'] as String?,
        credentialLength: len as int?,
        credentialDigest: digest,
      );
      owner = null;
      digest = null;
      return result;
    } catch (_) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
    } finally {
      owner?.fillRange(0, owner.length, 0);
      digest?.fillRange(0, digest.length, 0);
    }
  }

  void destroy() {
    _owner.fillRange(0, _owner.length, 0);
    _credentialDigest?.fillRange(0, _credentialDigest.length, 0);
    _credential?.fillRange(0, _credential!.length, 0);
    _credential = null;
    _destroyed = true;
  }
}
