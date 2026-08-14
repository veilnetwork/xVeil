/// The three `[identity]` fields an invite is made of.
///
/// A restored device boots on a node key of its own, so the invite it hands out
/// must NOT come from that key. The address a contact writes down is the hash
/// of the key in the invite, and this device collects mail under the IDENTITY's
/// address — hand out the device key and contacts address somewhere nobody
/// listens.
///
/// So the invite is built from the phrase-derived config kept beside the
/// running one. Parsed rather than fetched through the FFI because the value is
/// three fields of a config THIS app composed a moment earlier, not a document
/// from the network — and because a parser can be tested on its own, which a
/// round trip through a dylib cannot.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What an invite needs: the key, its anti-sybil nonce, and the algorithm.
class IdentityConfigFields {
  const IdentityConfigFields({
    required this.publicKey,
    required this.nonce,
    required this.algo,
  });

  final Uint8List publicKey;
  final Uint8List nonce;
  final String algo;
}

/// Read them out of a composed node config, or null when it does not carry a
/// complete `[identity]`.
///
/// Null rather than a partial answer: an invite missing its nonce is not a
/// weaker invite, it is one the receiving side refuses, and the caller has a
/// correct fallback — the node's own invite — that a half-built one would
/// silently replace.
IdentityConfigFields? identityConfigFields(String toml) {
  // The section header is `[Identity]` in what veil composes and `[identity]`
  // in hand-written configs; both are the same section to a TOML reader, so
  // both are the same section here.
  final section = RegExp(r'^\[[Ii]dentity\]\s*$', multiLine: true);
  final start = section.firstMatch(toml);
  if (start == null) return null;
  // Up to the next table header, so a `public_key` belonging to some other
  // section cannot be read as this one's.
  final rest = toml.substring(start.end);
  final next = RegExp(r'^\[', multiLine: true).firstMatch(rest);
  final body = next == null ? rest : rest.substring(0, next.start);

  String? read(String key) {
    final m = RegExp(
      '^\\s*$key\\s*=\\s*"([^"]*)"\\s*\$',
      multiLine: true,
    ).firstMatch(body);
    return m?.group(1);
  }

  final pk = read('public_key');
  final nonce = read('nonce');
  final algo = read('algo');
  if (pk == null || nonce == null || algo == null) return null;
  if (pk.isEmpty || nonce.isEmpty || algo.isEmpty) return null;

  final Uint8List pkBytes;
  final Uint8List nonceBytes;
  try {
    pkBytes = base64.decode(pk);
    nonceBytes = base64.decode(nonce);
  } on FormatException {
    return null;
  }
  if (pkBytes.isEmpty || nonceBytes.isEmpty) return null;
  return IdentityConfigFields(
    publicKey: pkBytes,
    nonce: nonceBytes,
    algo: algo,
  );
}
