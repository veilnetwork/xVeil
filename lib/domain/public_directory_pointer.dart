import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../crypto/blake3.dart';
import 'space_discovery.dart' show SpacePublicSignatureVerifier;
import 'space_discovery_carrier.dart';

/// A public file directory published under an identity.
///
/// The owner signs a small pointer record that carries a bearer
/// folder-capability link and a display title, and publishes it on the DHT
/// under a per-identity search route. Anyone who knows the owner's nodeId (via
/// their nickname) can fetch and verify it, then open the folder with the
/// ordinary folder-share client. This deliberately BINDS the folder to the
/// owner's identity — it is the opposite of an anonymous bearer link, so the
/// UI must warn before publishing.
///
/// Wire reuse: the outer record is the native Space-discovery carrier byte
/// layout (the daemon verifies the same holder-binding + Ed25519 signature +
/// short lifetime before storing), routed under a domain-separated search
/// token so it never collides with real Space discovery records. Only the
/// opaque inner payload is ours (`XPD1`).

const int kPublicDirectoryPayloadVersion = 1;
const int _kMaxTitleBytes = 256;
const int _kMaxLinkBytes = 4096;
const List<int> _xpd1Magic = <int>[0x58, 0x50, 0x44, 0x31]; // "XPD1"

/// The search route a directory for [owner] is published/resolved under.
/// Domain-separated from Space search tokens by the version-tagged prefix.
SpaceDiscoveryCarrierRoute publicDirectoryRoute(NodeId owner) {
  final token = blake3Hash(
    (BytesBuilder(copy: false)
          ..add(utf8.encode('xveil.public.dir.v1'))
          ..add(owner.bytes))
        .toBytes(),
  );
  return SpaceDiscoveryCarrierRoute.search(token);
}

/// The verified contents of a resolved public directory pointer.
class PublicDirectoryPointer {
  const PublicDirectoryPointer({
    required this.owner,
    required this.title,
    required this.link,
    required this.issuedAtUnixMs,
    required this.expiresAtUnixMs,
  });

  final NodeId owner;
  final String title;

  /// A bearer `xveil://cloud/...` folder-capability link.
  final String link;
  final int issuedAtUnixMs;
  final int expiresAtUnixMs;
}

/// Encode + sign a directory pointer into a publishable record. [sign] returns
/// the Ed25519 detached signature and the identity public key (its BLAKE3 must
/// equal [owner]); it signs the outer carrier's canonical bytes.
Uint8List signPublicDirectoryRecord({
  required NodeId owner,
  required Uint8List ownerPublicKey,
  required String title,
  required String link,
  required int issuedAtUnixMs,
  required int expiresAtUnixMs,
  required ({Uint8List signature, Uint8List publicKey}) Function(Uint8List)
  sign,
}) {
  final payload = _encodePayload(title: title, link: link);
  final unsigned = SpaceDiscoveryCarrier(
    route: publicDirectoryRoute(owner),
    // A directory has no Space id; bind the field to the owner so the record
    // is self-describing and a Direct-route confusion is impossible.
    spaceId: owner,
    holder: owner,
    holderPublicKey: ownerPublicKey,
    issuedAtUnixMs: issuedAtUnixMs,
    expiresAtUnixMs: expiresAtUnixMs,
    payload: payload,
    signature: Uint8List(0),
  );
  final signed = sign(unsigned.canonicalBytes());
  if (!_bytesEqual(signed.publicKey, ownerPublicKey) ||
      signed.signature.length != 64 ||
      !_bytesEqual(blake3Hash(ownerPublicKey), owner.bytes)) {
    throw StateError('directory signer returned a different identity');
  }
  return SpaceDiscoveryCarrier(
    route: unsigned.route,
    spaceId: unsigned.spaceId,
    holder: owner,
    holderPublicKey: ownerPublicKey,
    issuedAtUnixMs: issuedAtUnixMs,
    expiresAtUnixMs: expiresAtUnixMs,
    payload: payload,
    signature: signed.signature,
  ).toBytes();
}

/// Parse and FULLY verify a record fetched from the DHT for [expectedOwner].
/// Returns null unless the holder binding, signature, lifetime, route and
/// payload all check out — the DHT is never trusted. Not `SpaceDiscoveryCarrier
/// .verifyAt`, which would insist the payload be a Space discovery payload.
PublicDirectoryPointer? parsePublicDirectoryRecord({
  required Uint8List bytes,
  required NodeId expectedOwner,
  required int nowMs,
  required SpacePublicSignatureVerifier verify,
}) {
  final carrier = SpaceDiscoveryCarrier.fromBytes(bytes);
  if (carrier == null) return null;
  final expectedRoute = publicDirectoryRoute(expectedOwner);
  if (carrier.holder != expectedOwner ||
      carrier.spaceId != expectedOwner ||
      !carrier.route.sameAs(expectedRoute) ||
      carrier.holderPublicKey.length != 32 ||
      carrier.signature.length != 64 ||
      carrier.expiresAtUnixMs <= carrier.issuedAtUnixMs ||
      carrier.expiresAtUnixMs - carrier.issuedAtUnixMs >
          kSpaceDiscoveryCarrierLifetime.inMilliseconds ||
      carrier.issuedAtUnixMs >
          nowMs + kSpaceDiscoveryCarrierClockSkew.inMilliseconds ||
      carrier.expiresAtUnixMs <= nowMs ||
      !_bytesEqual(blake3Hash(carrier.holderPublicKey), expectedOwner.bytes) ||
      !verify(
        signer: expectedOwner,
        publicKey: carrier.holderPublicKey,
        message: carrier.canonicalBytes(),
        signature: carrier.signature,
      )) {
    return null;
  }
  final decoded = _decodePayload(carrier.payload);
  if (decoded == null) return null;
  return PublicDirectoryPointer(
    owner: expectedOwner,
    title: decoded.title,
    link: decoded.link,
    issuedAtUnixMs: carrier.issuedAtUnixMs,
    expiresAtUnixMs: carrier.expiresAtUnixMs,
  );
}

Uint8List _encodePayload({required String title, required String link}) {
  final titleBytes = utf8.encode(title.trim());
  final linkBytes = utf8.encode(link.trim());
  if (linkBytes.isEmpty ||
      titleBytes.length > _kMaxTitleBytes ||
      linkBytes.length > _kMaxLinkBytes) {
    throw ArgumentError('directory title/link out of bounds');
  }
  final builder = BytesBuilder(copy: false)
    ..add(_xpd1Magic)
    ..addByte(kPublicDirectoryPayloadVersion)
    ..add(_u16(titleBytes.length))
    ..add(titleBytes)
    ..add(_u16(linkBytes.length))
    ..add(linkBytes);
  return builder.toBytes();
}

({String title, String link})? _decodePayload(Uint8List payload) {
  try {
    var offset = 0;
    Uint8List take(int n) {
      final end = offset + n;
      if (n < 0 || end < offset || end > payload.length) {
        throw const FormatException('truncated directory payload');
      }
      final out = Uint8List.sublistView(payload, offset, end);
      offset = end;
      return out;
    }

    if (!_bytesEqual(take(4), _xpd1Magic) ||
        take(1).single != kPublicDirectoryPayloadVersion) {
      return null;
    }
    final titleLen = _readU16(take(2));
    if (titleLen > _kMaxTitleBytes) return null;
    final title = utf8.decode(take(titleLen));
    final linkLen = _readU16(take(2));
    if (linkLen == 0 || linkLen > _kMaxLinkBytes) return null;
    final link = utf8.decode(take(linkLen));
    if (offset != payload.length) return null;
    return (title: title, link: link);
  } catch (_) {
    return null;
  }
}

Uint8List _u16(int value) {
  if (value < 0 || value > 0xffff) throw RangeError.range(value, 0, 0xffff);
  final bytes = Uint8List(2);
  ByteData.sublistView(bytes).setUint16(0, value, Endian.little);
  return bytes;
}

int _readU16(Uint8List bytes) =>
    ByteData.sublistView(bytes).getUint16(0, Endian.little);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
