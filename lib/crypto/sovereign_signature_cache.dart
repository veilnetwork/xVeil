import 'dart:convert';
import 'dart:typed_data';

import 'verification_cache_digest.dart';

typedef SovereignSignatureCheck =
    bool Function({
      required String algorithm,
      required Uint8List nodeId,
      required Uint8List publicKey,
      required Uint8List message,
      required Uint8List signature,
    });

/// Only the timeless signature + full-key/node-id binding predicate.
/// Membership, revocation, document validity and retention are checked by the
/// caller on every read; none of their decisions belong in this cache.
final class SovereignSignatureCache {
  SovereignSignatureCache({
    required SovereignSignatureCheck verify,
    required VerificationCacheDigest digest,
    this.maxEntries = 512,
    // Public parameter names keep the verifier seam usable outside this library.
    // ignore: prefer_initializing_formals
  }) : _verify = verify,
       // ignore: prefer_initializing_formals
       _digest = digest {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  final SovereignSignatureCheck _verify;
  final VerificationCacheDigest _digest;
  final int maxEntries;
  final Map<String, bool> _verdicts = {};

  bool verify({
    required String algorithm,
    required Uint8List nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    // Fresh bytes on every call, including mutable NodeId/key/signature inputs.
    // Lengths prevent moving a byte between adjacent fields from reusing a
    // verdict. Retain only a digest and a bool, never signed plaintext or keys.
    final parts = [
      utf8.encode(algorithm),
      nodeId,
      publicKey,
      message,
      signature,
    ];
    final lengths = ByteData(parts.length * 8);
    for (var i = 0; i < parts.length; i++) {
      lengths.setUint64(i * 8, parts[i].length);
    }
    final key = base64Encode(
      _digest.hashParts([lengths.buffer.asUint8List(), ...parts]),
    );
    final cached = _verdicts[key];
    if (cached != null) return cached;
    // An exception is not a cryptographic verdict and must be retried later.
    final valid = _verify(
      algorithm: algorithm,
      nodeId: nodeId,
      publicKey: publicKey,
      message: message,
      signature: signature,
    );
    _verdicts[key] = valid;
    if (_verdicts.length > maxEntries) _verdicts.remove(_verdicts.keys.first);
    return valid;
  }
}
