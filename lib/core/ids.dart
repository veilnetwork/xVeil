import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A short, URL-safe random identifier (six characters).
///
/// Six random bytes encode to exactly eight base64url characters and no
/// padding, so there is nothing to trim but `=` — which cannot appear here at
/// all. The two copies this replaced also stripped `-` and `_`, which ARE
/// base64url characters: strip three or more and the string is shorter than
/// six, and `substring(0, 6)` throws. With 2 of 64 symbols eligible over eight
/// draws that landed at roughly one call in 585 — rare enough to survive
/// review twice and common enough to hit a real user minting a token.
String mintShortId([Random? random]) {
  final rng = random ?? Random.secure();
  return base64Url
      .encode(List<int>.generate(6, (_) => rng.nextInt(256)))
      .replaceAll('=', '')
      .substring(0, 6);
}

/// A 32-byte veil node identity (BLAKE3 of the signing public key).
///
/// Wrapped in a value type so equality/hashing work as map keys and the
/// hex/short representations live in one place.
class NodeId {
  /// Copies [bytes] and checks the length at RUNTIME.
  ///
  /// The length was an `assert`, which is compiled out of a release build, so
  /// a wrong-sized id became a NodeId in the shipped app and only surfaced
  /// later as a mismatched hex string or a lookup that never hit.
  ///
  /// The copy closes the other half: the buffer used to be retained as passed,
  /// so a caller that reused its scratch `Uint8List` — or mutated one after
  /// putting the id in a Map — changed a live key underneath the hash it was
  /// filed under, and the entry became unreachable without ever looking wrong.
  NodeId(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 32) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'node id must be 32 bytes',
      );
    }
  }

  final Uint8List bytes;

  factory NodeId.fromHex(String hex) {
    final clean = hex.replaceAll(' ', '');
    if (clean.length != 64) {
      throw ArgumentError('node id hex must be 64 chars, got ${clean.length}');
    }
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return NodeId(out);
  }

  String get hex {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// First 8 hex chars — enough to disambiguate in the UI.
  String get short => hex.substring(0, 8);

  @override
  bool operator ==(Object other) {
    if (other is! NodeId) return false;
    if (other.bytes.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (other.bytes[i] != bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // FNV-1a over the bytes — stable, cheap, good enough for map keys.
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h = (h ^ b) * 0x01000193;
      h &= 0xffffffff;
    }
    return h;
  }

  @override
  String toString() => 'NodeId($short…)';
}
