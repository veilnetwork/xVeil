import 'dart:typed_data';

import '../core/ids.dart';
import '../crypto/blake3.dart';
import 'space_discovery.dart';

const int kSpaceDiscoveryCarrierVersion = 1;
const int kSpaceDiscoveryCarrierPayloadMaxBytes =
    kSpacePublicDiscoveryPayloadMaxBytes;
const Duration kSpaceDiscoveryCarrierLifetime = Duration(hours: 2);
const Duration kSpaceDiscoveryCarrierClockSkew = Duration(minutes: 5);

const List<int> _spaceDiscoveryMagic = <int>[0x58, 0x53]; // "XS"

enum SpaceDiscoveryCarrierRouteKind { direct, search }

/// An exact-Space or hashed public-search route carried in a native `XS`
/// record. The 32-byte body remains opaque to the DHT.
final class SpaceDiscoveryCarrierRoute {
  SpaceDiscoveryCarrierRoute(this.kind, Uint8List body)
    : body = Uint8List.fromList(body) {
    if (body.length != 32) {
      throw ArgumentError.value(body.length, 'body', 'must be 32 bytes');
    }
  }

  factory SpaceDiscoveryCarrierRoute.direct(NodeId spaceId) =>
      SpaceDiscoveryCarrierRoute(
        SpaceDiscoveryCarrierRouteKind.direct,
        spaceId.bytes,
      );

  factory SpaceDiscoveryCarrierRoute.search(Uint8List tokenHash) =>
      SpaceDiscoveryCarrierRoute(
        SpaceDiscoveryCarrierRouteKind.search,
        tokenHash,
      );

  final SpaceDiscoveryCarrierRouteKind kind;
  final Uint8List body;

  bool sameAs(SpaceDiscoveryCarrierRoute other) =>
      kind == other.kind && _bytesEqual(body, other.body);
}

/// Strict application-side codec for the native public-Space DHT carrier.
///
/// The native node independently verifies the same bytes before storing them.
/// Parsing and verifying them again here keeps a compromised or stale DHT
/// response from crossing into the public discovery projection.
final class SpaceDiscoveryCarrier {
  SpaceDiscoveryCarrier({
    required this.route,
    required this.spaceId,
    required this.holder,
    required Uint8List holderPublicKey,
    required this.issuedAtUnixMs,
    required this.expiresAtUnixMs,
    required Uint8List payload,
    required Uint8List signature,
  }) : holderPublicKey = Uint8List.fromList(holderPublicKey),
       payload = Uint8List.fromList(payload),
       signature = Uint8List.fromList(signature);

  final SpaceDiscoveryCarrierRoute route;
  final NodeId spaceId;
  final NodeId holder;
  final Uint8List holderPublicKey;
  final int issuedAtUnixMs;
  final int expiresAtUnixMs;
  final Uint8List payload;
  final Uint8List signature;

  Uint8List canonicalBytes() {
    final builder = BytesBuilder(copy: false)
      ..addByte(kSpaceDiscoveryCarrierVersion)
      ..addByte(route.kind.index)
      ..add(route.body)
      ..add(spaceId.bytes)
      ..add(holder.bytes)
      ..add(holderPublicKey)
      ..add(_u64le(issuedAtUnixMs))
      ..add(_u64le(expiresAtUnixMs))
      ..add(_u32le(payload.length))
      ..add(payload);
    return builder.toBytes();
  }

  Uint8List toBytes() {
    final builder = BytesBuilder(copy: false)
      ..add(_spaceDiscoveryMagic)
      ..add(canonicalBytes())
      ..add(signature);
    return builder.toBytes();
  }

  bool verifyAt(int nowMs, SpacePublicSignatureVerifier verify) {
    if (holderPublicKey.length != 32 ||
        signature.length != 64 ||
        payload.isEmpty ||
        payload.length > kSpaceDiscoveryCarrierPayloadMaxBytes ||
        expiresAtUnixMs <= issuedAtUnixMs ||
        expiresAtUnixMs - issuedAtUnixMs >
            kSpaceDiscoveryCarrierLifetime.inMilliseconds ||
        issuedAtUnixMs >
            nowMs + kSpaceDiscoveryCarrierClockSkew.inMilliseconds ||
        expiresAtUnixMs <= nowMs ||
        (route.kind == SpaceDiscoveryCarrierRouteKind.direct &&
            !_bytesEqual(route.body, spaceId.bytes)) ||
        !_bytesEqual(blake3Hash(holderPublicKey), holder.bytes) ||
        !verify(
          signer: holder,
          publicKey: holderPublicKey,
          message: canonicalBytes(),
          signature: signature,
        )) {
      return false;
    }
    final inner = SpacePublicDiscoveryPayload.fromBytes(payload);
    return inner != null &&
        inner.descriptor.spaceId == spaceId &&
        inner.holder.spaceId == spaceId &&
        inner.holder.holder == holder &&
        _bytesEqual(inner.holder.holderPublicKey, holderPublicKey) &&
        inner.verifyAt(nowMs, verify);
  }

  static SpaceDiscoveryCarrier sign({
    required SpaceDiscoveryCarrierRoute route,
    required SpacePublicDiscoveryPayload payload,
    required NodeId holder,
    required Uint8List holderPublicKey,
    required ({Uint8List signature, Uint8List publicKey}) Function(
      Uint8List message,
    )
    sign,
  }) {
    if (payload.holder.holder != holder ||
        !_bytesEqual(payload.holder.holderPublicKey, holderPublicKey) ||
        !_bytesEqual(blake3Hash(holderPublicKey), holder.bytes)) {
      throw ArgumentError('payload holder does not match carrier identity');
    }
    final unsigned = SpaceDiscoveryCarrier(
      route: route,
      spaceId: payload.descriptor.spaceId,
      holder: holder,
      holderPublicKey: holderPublicKey,
      issuedAtUnixMs: payload.holder.issuedAtMs,
      expiresAtUnixMs: payload.holder.expiresAtMs,
      payload: payload.toBytes(),
      signature: Uint8List(0),
    );
    if (unsigned.payload.length > kSpaceDiscoveryCarrierPayloadMaxBytes) {
      throw ArgumentError.value(
        unsigned.payload.length,
        'payload',
        'exceeds the 16 KiB discovery cap',
      );
    }
    final signed = sign(unsigned.canonicalBytes());
    if (!_bytesEqual(signed.publicKey, holderPublicKey) ||
        signed.signature.length != 64) {
      throw StateError('carrier signer returned a different identity');
    }
    return SpaceDiscoveryCarrier(
      route: route,
      spaceId: unsigned.spaceId,
      holder: holder,
      holderPublicKey: holderPublicKey,
      issuedAtUnixMs: unsigned.issuedAtUnixMs,
      expiresAtUnixMs: unsigned.expiresAtUnixMs,
      payload: unsigned.payload,
      signature: signed.signature,
    );
  }

  static SpaceDiscoveryCarrier? fromBytes(Uint8List bytes) {
    try {
      final reader = _CarrierReader(bytes);
      if (!_bytesEqual(reader.take(2), _spaceDiscoveryMagic) ||
          reader.u8() != kSpaceDiscoveryCarrierVersion) {
        return null;
      }
      final routeKind = switch (reader.u8()) {
        0 => SpaceDiscoveryCarrierRouteKind.direct,
        1 => SpaceDiscoveryCarrierRouteKind.search,
        _ => throw const FormatException('unsupported discovery route'),
      };
      final route = SpaceDiscoveryCarrierRoute(routeKind, reader.take(32));
      final spaceId = NodeId(reader.take(32));
      final holder = NodeId(reader.take(32));
      final holderPublicKey = reader.take(32);
      final issuedAtUnixMs = reader.u64();
      final expiresAtUnixMs = reader.u64();
      final payloadLength = reader.u32();
      if (payloadLength <= 0 ||
          payloadLength > kSpaceDiscoveryCarrierPayloadMaxBytes) {
        return null;
      }
      final payload = reader.take(payloadLength);
      final signature = reader.take(64);
      if (!reader.isDone) return null;
      return SpaceDiscoveryCarrier(
        route: route,
        spaceId: spaceId,
        holder: holder,
        holderPublicKey: holderPublicKey,
        issuedAtUnixMs: issuedAtUnixMs,
        expiresAtUnixMs: expiresAtUnixMs,
        payload: payload,
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }
}

Uint8List _u32le(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw RangeError.range(value, 0, 0xffffffff);
  }
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
  return bytes;
}

Uint8List _u64le(int value) {
  if (value < 0) throw RangeError.value(value);
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setUint64(0, value, Endian.little);
  return bytes;
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

final class _CarrierReader {
  _CarrierReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get isDone => offset == bytes.length;

  Uint8List take(int length) {
    final end = offset + length;
    if (length < 0 || end < offset || end > bytes.length) {
      throw const FormatException('truncated Space discovery carrier');
    }
    final result = Uint8List.fromList(bytes.sublist(offset, end));
    offset = end;
    return result;
  }

  int u8() => take(1).single;

  int u32() => ByteData.sublistView(take(4)).getUint32(0, Endian.little);

  int u64() => ByteData.sublistView(take(8)).getUint64(0, Endian.little);
}
