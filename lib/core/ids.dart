import 'dart:typed_data';

/// A 32-byte veil node identity (BLAKE3 of the signing public key).
///
/// Wrapped in a value type so equality/hashing work as map keys and the
/// hex/short representations live in one place.
class NodeId {
  NodeId(this.bytes)
      : assert(bytes.length == 32, 'node id must be 32 bytes');

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
