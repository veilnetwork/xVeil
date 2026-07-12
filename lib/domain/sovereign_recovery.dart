import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';

/// Copy/paste wrapper around the native binary XVRC credential. The encrypted
/// private material remains opaque; only the AEAD-bound sovereign node id in
/// the public header is exposed for human comparison.
class SovereignRecoveryCertificate {
  SovereignRecoveryCertificate._(this.bytes, this.nodeId);

  final Uint8List bytes;
  final NodeId nodeId;

  static const _prefix = 'xveil-recovery:v1:';
  static const _maxBytes = 16 * 1024;
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

  factory SovereignRecoveryCertificate.parse(String text) {
    final value = text.trim();
    if (value.length > _maxText || !value.startsWith(_prefix)) {
      throw const FormatException('not an xVeil recovery certificate');
    }
    try {
      final raw = value.substring(_prefix.length);
      final padded = raw.padRight((raw.length + 3) ~/ 4 * 4, '=');
      return SovereignRecoveryCertificate.fromBytes(
        Uint8List.fromList(base64Url.decode(padded)),
      );
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('invalid recovery certificate');
    }
  }

  String toText() => '$_prefix${base64Url.encode(bytes).replaceAll('=', '')}';
}
