import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'space_discovery.dart';

const Duration kSpacePublicFeedRequestWindow = Duration(minutes: 2);
const int kSpacePublicFeedObjectMaxBytes = 1024 * 1024;
const int kSpacePublicFeedChunkMaxBytes = 1800;
const int kSpacePublicFeedChunkMaxCount =
    (kSpacePublicFeedObjectMaxBytes + kSpacePublicFeedChunkMaxBytes - 1) ~/
    kSpacePublicFeedChunkMaxBytes;

final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');

/// Short-lived, source-bound request for exactly one manifest or page hash.
///
/// The object hash must already be committed by a verified discovery
/// descriptor/manifest. The signature prevents a relayed request from charging
/// an unrelated authenticated source's quota.
class SpacePublicFeedObjectRequest {
  SpacePublicFeedObjectRequest({
    required this.spaceId,
    required this.descriptorHash,
    required this.manifestHash,
    required this.objectHash,
    required this.requester,
    required Uint8List requesterPublicKey,
    required this.nonce,
    required this.createdAtMs,
    Uint8List? signature,
  }) : requesterPublicKey = Uint8List.fromList(requesterPublicKey),
       signature = signature ?? Uint8List(0);

  final NodeId spaceId;
  final String descriptorHash;
  final String manifestHash;
  final String objectHash;
  final NodeId requester;
  final Uint8List requesterPublicKey;
  final String nonce;
  final int createdAtMs;
  final Uint8List signature;

  bool isStructurallyValidAt(int nowMs) =>
      _hashPattern.hasMatch(descriptorHash) &&
      _hashPattern.hasMatch(manifestHash) &&
      _hashPattern.hasMatch(objectHash) &&
      _hashPattern.hasMatch(nonce) &&
      requesterPublicKey.length == 32 &&
      signature.length == 64 &&
      createdAtMs >= 0 &&
      createdAtMs <= nowMs + kSpacePublicClockSkew.inMilliseconds &&
      nowMs - createdAtMs <= kSpacePublicFeedRequestWindow.inMilliseconds;

  bool verifyAt(
    int nowMs,
    NodeId authenticatedSource,
    SpacePublicSignatureVerifier verify,
  ) =>
      requester == authenticatedSource &&
      isStructurallyValidAt(nowMs) &&
      verify(
        signer: requester,
        publicKey: requesterPublicKey,
        message: canonicalBytes(),
        signature: signature,
      );

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'kind': 'xveil.space.public-feed-request',
        'space': spaceId.hex,
        'descriptorHash': descriptorHash,
        'manifestHash': manifestHash,
        'objectHash': objectHash,
        'requester': requester.hex,
        'requesterKey': base64Encode(requesterPublicKey),
        'nonce': nonce,
        'createdAt': createdAtMs,
      }),
    ),
  );

  SpacePublicFeedObjectRequest withSignature(Uint8List value) =>
      SpacePublicFeedObjectRequest(
        spaceId: spaceId,
        descriptorHash: descriptorHash,
        manifestHash: manifestHash,
        objectHash: objectHash,
        requester: requester,
        requesterPublicKey: requesterPublicKey,
        nonce: nonce,
        createdAtMs: createdAtMs,
        signature: value,
      );

  Map<String, dynamic> toJson() => {
    ...jsonDecode(utf8.decode(canonicalBytes())) as Map<String, dynamic>,
    'signature': base64Encode(signature),
  };

  static SpacePublicFeedObjectRequest? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'descriptorHash',
          'manifestHash',
          'objectHash',
          'requester',
          'requesterKey',
          'nonce',
          'createdAt',
          'signature',
        }) ||
        value['v'] != 1 ||
        value['kind'] != 'xveil.space.public-feed-request' ||
        value['space'] is! String ||
        value['descriptorHash'] is! String ||
        value['manifestHash'] is! String ||
        value['objectHash'] is! String ||
        value['requester'] is! String ||
        value['requesterKey'] is! String ||
        value['nonce'] is! String ||
        value['createdAt'] is! int ||
        value['signature'] is! String) {
      return null;
    }
    try {
      return SpacePublicFeedObjectRequest(
        spaceId: NodeId.fromHex(value['space'] as String),
        descriptorHash: value['descriptorHash'] as String,
        manifestHash: value['manifestHash'] as String,
        objectHash: value['objectHash'] as String,
        requester: NodeId.fromHex(value['requester'] as String),
        requesterPublicKey: Uint8List.fromList(
          base64Decode(value['requesterKey'] as String),
        ),
        nonce: value['nonce'] as String,
        createdAtMs: value['createdAt'] as int,
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// One live-only response slice. Authenticity comes from the authenticated
/// transport source and the pending request; completeness comes from the
/// requested owner/page hash after bounded reassembly.
class SpacePublicFeedObjectChunk {
  SpacePublicFeedObjectChunk({
    required this.spaceId,
    required this.manifestHash,
    required this.objectHash,
    required this.nonce,
    required this.index,
    required this.count,
    required this.totalBytes,
    required Uint8List data,
  }) : data = Uint8List.fromList(data);

  final NodeId spaceId;
  final String manifestHash;
  final String objectHash;
  final String nonce;
  final int index;
  final int count;
  final int totalBytes;
  final Uint8List data;

  bool get isStructurallyValid =>
      _hashPattern.hasMatch(manifestHash) &&
      _hashPattern.hasMatch(objectHash) &&
      _hashPattern.hasMatch(nonce) &&
      count > 0 &&
      count <= kSpacePublicFeedChunkMaxCount &&
      index >= 0 &&
      index < count &&
      totalBytes > 0 &&
      totalBytes <= kSpacePublicFeedObjectMaxBytes &&
      data.isNotEmpty &&
      data.length <= kSpacePublicFeedChunkMaxBytes &&
      (count == 1
          ? data.length == totalBytes
          : totalBytes > (count - 1) * kSpacePublicFeedChunkMaxBytes &&
                totalBytes <= count * kSpacePublicFeedChunkMaxBytes) &&
      (index < count - 1
          ? data.length == kSpacePublicFeedChunkMaxBytes
          : data.length ==
                totalBytes - (count - 1) * kSpacePublicFeedChunkMaxBytes);

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': 'xveil.space.public-feed-chunk',
    'space': spaceId.hex,
    'manifestHash': manifestHash,
    'objectHash': objectHash,
    'nonce': nonce,
    'index': index,
    'count': count,
    'totalBytes': totalBytes,
    'data': base64Encode(data),
  };

  static SpacePublicFeedObjectChunk? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'manifestHash',
          'objectHash',
          'nonce',
          'index',
          'count',
          'totalBytes',
          'data',
        }) ||
        value['v'] != 1 ||
        value['kind'] != 'xveil.space.public-feed-chunk' ||
        value['space'] is! String ||
        value['manifestHash'] is! String ||
        value['objectHash'] is! String ||
        value['nonce'] is! String ||
        value['index'] is! int ||
        value['count'] is! int ||
        value['totalBytes'] is! int ||
        value['data'] is! String) {
      return null;
    }
    try {
      final chunk = SpacePublicFeedObjectChunk(
        spaceId: NodeId.fromHex(value['space'] as String),
        manifestHash: value['manifestHash'] as String,
        objectHash: value['objectHash'] as String,
        nonce: value['nonce'] as String,
        index: value['index'] as int,
        count: value['count'] as int,
        totalBytes: value['totalBytes'] as int,
        data: Uint8List.fromList(base64Decode(value['data'] as String)),
      );
      return chunk.isStructurallyValid ? chunk : null;
    } catch (_) {
      return null;
    }
  }
}

Iterable<SpacePublicFeedObjectChunk> chunkSpacePublicFeedObject({
  required NodeId spaceId,
  required String manifestHash,
  required String objectHash,
  required String nonce,
  required Uint8List bytes,
}) sync* {
  if (bytes.isEmpty || bytes.length > kSpacePublicFeedObjectMaxBytes) {
    throw ArgumentError.value(bytes.length, 'bytes', 'outside object cap');
  }
  final count =
      (bytes.length + kSpacePublicFeedChunkMaxBytes - 1) ~/
      kSpacePublicFeedChunkMaxBytes;
  for (var index = 0; index < count; index++) {
    final start = index * kSpacePublicFeedChunkMaxBytes;
    final end = start + kSpacePublicFeedChunkMaxBytes < bytes.length
        ? start + kSpacePublicFeedChunkMaxBytes
        : bytes.length;
    yield SpacePublicFeedObjectChunk(
      spaceId: spaceId,
      manifestHash: manifestHash,
      objectHash: objectHash,
      nonce: nonce,
      index: index,
      count: count,
      totalBytes: bytes.length,
      data: Uint8List.sublistView(bytes, start, end),
    );
  }
}

bool _hasOnlyKeys(Map<dynamic, dynamic> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) return false;
  }
  return true;
}
