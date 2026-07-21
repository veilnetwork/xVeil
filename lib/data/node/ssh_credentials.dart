import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';

/// SSH secrets for one managed node.
///
/// These values are persisted only through [SshCredentialsRepository], under
/// a per-node key in the already-open encrypted xVeil container. Keeping them
/// out of [ManagedNode]'s list record avoids copying every secret whenever an
/// unrelated node is edited and keeps each setting below the store's bounded
/// record size.
class SavedSshCredentials {
  const SavedSshCredentials({
    this.password,
    this.privateKeyPem,
    this.publicKeyOpenSsh,
  });

  final String? password;
  final String? privateKeyPem;

  /// One complete `authorized_keys` line (`ssh-ed25519 BASE64 comment`).
  final String? publicKeyOpenSsh;

  bool get hasPassword => password != null && password!.isNotEmpty;
  bool get hasKey =>
      privateKeyPem != null &&
      privateKeyPem!.isNotEmpty &&
      publicKeyOpenSsh != null &&
      publicKeyOpenSsh!.isNotEmpty;
  bool get isEmpty => !hasPassword && !hasKey;

  String encode() => jsonEncode({
    if (hasPassword) 'password': password,
    if (hasKey) 'privateKeyPem': privateKeyPem,
    if (hasKey) 'publicKeyOpenSsh': publicKeyOpenSsh,
  });

  factory SavedSshCredentials.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const SavedSshCredentials();
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        return const SavedSshCredentials();
      }
      final password = json['password'];
      final privateKey = json['privateKeyPem'];
      final publicKey = json['publicKeyOpenSsh'];
      return SavedSshCredentials(
        password: password is String && password.isNotEmpty ? password : null,
        privateKeyPem: privateKey is String && privateKey.isNotEmpty
            ? privateKey
            : null,
        publicKeyOpenSsh: publicKey is String && publicKey.isNotEmpty
            ? publicKey
            : null,
      );
    } catch (_) {
      return const SavedSshCredentials();
    }
  }
}

class GeneratedSshEd25519KeyPair {
  const GeneratedSshEd25519KeyPair({
    required this.privateKeyPem,
    required this.publicKeyOpenSsh,
  });

  final String privateKeyPem;
  final String publicKeyOpenSsh;
}

/// Generate an OpenSSH-compatible Ed25519 pair entirely on this device.
Future<GeneratedSshEd25519KeyPair> generateSshEd25519KeyPair({
  String comment = 'xveil',
}) async {
  final safeComment = comment
      .replaceAll(RegExp(r'[^A-Za-z0-9._@-]'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  final generated = await Ed25519().newKeyPair();
  final extracted = await generated.extract();
  final seed = Uint8List.fromList(extracted.bytes);
  final public = Uint8List.fromList(extracted.publicKey.bytes);
  final privateMaterial = Uint8List.fromList([...seed, ...public]);
  try {
    // OpenSSH stores Ed25519 private material as seed || public key (64 bytes).
    final pair = OpenSSHEd25519KeyPair(public, privateMaterial, safeComment);
    final publicLine =
        'ssh-ed25519 ${base64Encode(pair.toPublicKey().encode())} $safeComment';
    return GeneratedSshEd25519KeyPair(
      privateKeyPem: pair.toPem(),
      publicKeyOpenSsh: publicLine,
    );
  } finally {
    extracted.destroy();
    seed.fillRange(0, seed.length, 0);
    privateMaterial.fillRange(0, privateMaterial.length, 0);
  }
}
