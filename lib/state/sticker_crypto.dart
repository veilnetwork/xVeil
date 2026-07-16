// Sticker pack authorship (stickers epic, polish): binds a SHARED pack to the
// sender's native ed25519 identity, the same primitive groups use
// (group_crypto.dart). The signature travels inside the STKP v2 container and
// survives verbatim re-export, so provenance holds across hops; verification
// binds the author's public key to their node id (node_id == BLAKE3(pubKey))
// inside the native verifier, so a forged key cannot impersonate the author.
//
// Injectable (like GroupSigner) so store tests run without the native dylib.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/node/embedded_node.dart';
import 'app_controller.dart';
import 'providers.dart';
import 'sticker_message.dart';

/// Sign/verify surface the sticker store needs. Signing is best-effort: no
/// unlocked identity means packs go out as legacy v1 (unsigned) — sharing
/// must never hard-require crypto.
abstract class StickerPackCrypto {
  /// The local identity's 32-byte node id (the pack author), or null when
  /// signing is unavailable right now.
  Future<Uint8List?> authorId();

  /// Raw ed25519 over [message] with the local identity. Only called after
  /// [authorId] returned non-null; throws on a crypto failure (a bug in the
  /// share flow, not network input).
  Future<({Uint8List signature, Uint8List publicKey})> sign(Uint8List message);

  /// Verify a decoded SIGNED bundle: the signature over its covered bytes by
  /// the embedded key, node-id-bound. False on any mismatch — never throws
  /// (the blob is network input).
  Future<bool> verify(StickerPackBundle bundle);
}

/// Real crypto: the deniable identity TOML behind [EmbeddedNode] statics.
class NativeStickerPackCrypto implements StickerPackCrypto {
  NativeStickerPackCrypto(this._ref, {this.lib});

  final Ref _ref;
  final DynamicLibrary? lib;

  Future<String?> _identityToml() =>
      _ref.read(storageProvider).loadNodeConfig();

  @override
  Future<Uint8List?> authorId() async {
    final selfId = _ref.read(appControllerProvider).identity?.nodeId;
    if (selfId == null) return null;
    final toml = await _identityToml();
    if (toml == null) return null;
    try {
      // Probe: the identity must actually be ed25519-signable (mirrors
      // groupSignerProvider) — otherwise fall back to unsigned sharing.
      EmbeddedNode.signMessage(toml, Uint8List(0), lib: lib);
    } catch (_) {
      return null;
    }
    return selfId.bytes;
  }

  @override
  Future<({Uint8List signature, Uint8List publicKey})> sign(
    Uint8List message,
  ) async {
    final toml = await _identityToml();
    if (toml == null) throw StateError('no identity config to sign with');
    return EmbeddedNode.signMessage(toml, message, lib: lib);
  }

  @override
  Future<bool> verify(StickerPackBundle bundle) async {
    final id = bundle.authorId;
    final pk = bundle.authorPubKey;
    final sig = bundle.signature;
    final covered = bundle.signedBytes;
    if (id == null || pk == null || sig == null || covered == null) {
      return false;
    }
    try {
      return EmbeddedNode.verifyMessage(
        nodeId: id,
        publicKey: pk,
        message: covered,
        signature: sig,
        lib: lib,
      );
    } catch (_) {
      return false;
    }
  }
}

final stickerPackCryptoProvider =
    Provider<StickerPackCrypto>(NativeStickerPackCrypto.new);
