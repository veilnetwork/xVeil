import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/ids.dart';

/// Copy/paste wrapper around the native binary XVRC credential. The encrypted
/// private material remains opaque; only the AEAD-bound sovereign node id in
/// the public header is exposed for human comparison.
/// The native writer's ceiling, shared by the length check and the header
/// reader so the two cannot drift apart.
const int _maxCertificateBytes = 16 * 1024;

class SovereignRecoveryCertificate {
  SovereignRecoveryCertificate._(this.bytes, this.nodeId);

  final Uint8List bytes;
  final NodeId nodeId;

  static const _prefix = 'xveil-recovery:v1:';
  static const _maxBytes = _maxCertificateBytes;
  static const _maxText = 24 * 1024;

  factory SovereignRecoveryCertificate.fromBytes(Uint8List bytes) {
    if (bytes.length < 38 || bytes.length > _maxBytes) {
      throw const FormatException('invalid recovery certificate size');
    }
    if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'XVRC' ||
        bytes[4] != 1) {
      throw const FormatException('not an XVRC v1 certificate');
    }
    return SovereignRecoveryCertificate._(
      Uint8List.fromList(bytes),
      NodeId(Uint8List.fromList(bytes.sublist(6, 38))),
    );
  }

  /// Accepts the certificate as it ARRIVES, not only as it was written.
  ///
  /// A certificate is offered with a copy button beside the save button, so a
  /// copied one is as ordinary as a downloaded one — and a copy comes back
  /// through whatever carried it. A chat wraps it across lines; a notes app
  /// adds a label in front of it; a mail client puts a period after it. All of
  /// those used to be "that file is not an xVeil recovery certificate", which
  /// is how someone concludes their backup is worthless while holding a
  /// perfectly good one.
  ///
  /// Nothing is loosened by this. The prefix still has to be there, and the
  /// bytes still have to carry the XVRC magic and version 1 — what is dropped
  /// is only the packaging around them: surrounding text before the prefix,
  /// whitespace inside the body, and anything after the base64url run ends.
  factory SovereignRecoveryCertificate.parse(String text) {
    if (text.length > _maxText) {
      throw const FormatException('not an xVeil recovery certificate');
    }
    final start = text.indexOf(_prefix);
    if (start < 0) {
      throw const FormatException('not an xVeil recovery certificate');
    }
    final value = text.substring(start);
    try {
      // Whitespace first — a wrapped paste has newlines INSIDE the body, so
      // the run has to be measured after they are gone, not before.
      final body = value
          .substring(_prefix.length)
          .replaceAll(RegExp(r'\s'), '');
      final run = RegExp(r'^[A-Za-z0-9_-]+').firstMatch(body);
      if (run == null) {
        throw const FormatException('not an xVeil recovery certificate');
      }
      final raw = run.group(0)!;
      // WHERE THE CERTIFICATE ENDS IS IN THE CERTIFICATE. Removing whitespace
      // is what lets a wrapped paste through, and it is also what would glue a
      // following sentence onto the body — "keep the code separately" is made
      // of base64url characters like everything else. The damage is not a
      // refusal, which is survivable; it is a SILENTLY WRONG certificate that
      // carries the magic, names the right address, and fails later as if the
      // code were wrong.
      //
      // So the header is read first, from a bounded prefix, and it says how
      // long the whole thing is. Cutting at the CHARACTER level and not after
      // decoding, because trailing text also breaks base64 outright — the
      // decode has to be given the right substring, not corrected afterwards.
      final declared = _declaredLength(_decode(raw, _headerProbeChars));
      final exact = declared == null
          ? raw
          : raw.substring(0, min(raw.length, (declared * 4 + 2) ~/ 3));
      return SovereignRecoveryCertificate.fromBytes(
        _decode(exact, exact.length),
      );
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('invalid recovery certificate');
    }
  }

  String toText() => '$_prefix${base64Url.encode(bytes).replaceAll('=', '')}';
}

/// The length an XVRC header declares for itself, or null when the header is
/// not one this can read.
///
/// Layout, as `sovereign_bundle.rs` writes it: magic(4) version(1) kdf(1)
/// node_id(32) m_cost(4) t_cost(4) p_cost(1) salt_len(1) salt nonce_len(1)
/// nonce ct_len(4) ciphertext.
///
/// Deliberately conservative: it answers only for a header that looks like the
/// real writer's — Argon2id, a 16-byte salt, a 12-byte nonce, a non-empty
/// ciphertext that fits. Anything else returns null and the bytes are taken as
/// they came, which is what keeps this from trimming a credential some future
/// version writes differently, or a synthetic one a test builds by hand.
int? _declaredLength(Uint8List bytes) {
  const headerBeforeSalt = 48; // through salt_len
  if (bytes.length < headerBeforeSalt) return null;
  if (bytes.length < 4 ||
      bytes[0] != 0x58 ||
      bytes[1] != 0x56 ||
      bytes[2] != 0x52 ||
      bytes[3] != 0x43) {
    return null;
  }
  if (bytes[5] != 1) return null; // KDF_ARGON2ID
  final saltLen = bytes[47];
  if (saltLen != 16) return null;
  final nonceLenAt = headerBeforeSalt + saltLen;
  if (bytes.length < nonceLenAt + 1) return null;
  final nonceLen = bytes[nonceLenAt];
  if (nonceLen != 12) return null;
  final ctLenAt = nonceLenAt + 1 + nonceLen;
  if (bytes.length < ctLenAt + 4) return null;
  final ctLen =
      (bytes[ctLenAt] << 24) |
      (bytes[ctLenAt + 1] << 16) |
      (bytes[ctLenAt + 2] << 8) |
      bytes[ctLenAt + 3];
  if (ctLen <= 0 || ctLen > _maxCertificateBytes) return null;
  return ctLenAt + 4 + ctLen;
}

/// Enough base64url to carry the fixed part of the header (81 bytes) with room
/// to spare, and nowhere near enough to matter if the rest is nonsense.
const int _headerProbeChars = 132;

/// Decode at most [take] characters of a base64url run, padding as needed.
Uint8List _decode(String run, int take) {
  // To a multiple of 4 DOWNWARD when the run is longer than asked for: a
  // prefix cut mid-group cannot be padded into a valid group.
  final want = min(run.length, take);
  final usable = run.length > want ? want - (want % 4) : want;
  final slice = run.substring(0, usable);
  return Uint8List.fromList(
    base64Url.decode(slice.padRight((slice.length + 3) ~/ 4 * 4, '=')),
  );
}
