import 'dart:async';
import 'dart:typed_data';

import '../domain/cloud_capability.dart';
import '../domain/content_manifest.dart';
import 'cloud_folder_share.dart' show CloudFolderShareStorage;

/// Member-authorized content path for a shared (ACL) folder. Unlike a bearer
/// folder share, authority is the document's CURRENT epoch key: a request is
/// served only if its MAC verifies under a subkey derived from the current
/// epoch key. On revoke the owner rotates the epoch and calls [rekey]; a
/// removed member (who never receives the new epoch key) can no longer derive
/// a valid subkey, so its requests fall into the same silent denial as a bad
/// MAC — instant revocation of future byte pulls.
///
/// This layer is transport + crypto only: no persistence, no membership log.
/// The caller supplies the current epoch key and the set of servable manifests
/// (the files whose bytes this device physically holds).

class _MemberFileRequest {
  const _MemberFileRequest({
    required this.documentId,
    required this.contentId,
    required this.returnServicePublicKey,
    required this.returnAppId,
    required this.returnEndpointId,
    required this.pieceIndex,
    required this.chunkIndex,
    required this.nonce,
    required this.mac,
  });
  static const _tag = 'XMR1';
  static const _length = 4 + 32 + 32 + 32 + 32 + 2 + 4 + 4 + 16 + 32;
  final Uint8List documentId;
  final Uint8List contentId;
  final Uint8List returnServicePublicKey;
  final Uint8List returnAppId;
  final int returnEndpointId;
  final int pieceIndex;
  final int chunkIndex;
  final Uint8List nonce;
  final Uint8List mac;

  Uint8List encode() {
    final wire = Uint8List(_length)..setAll(0, _tag.codeUnits);
    wire.setAll(4, documentId);
    wire.setAll(36, contentId);
    wire.setAll(68, returnServicePublicKey);
    wire.setAll(100, returnAppId);
    final data = ByteData.sublistView(wire);
    data.setUint16(132, returnEndpointId, Endian.big);
    data.setUint32(134, pieceIndex, Endian.big);
    data.setUint32(138, chunkIndex, Endian.big);
    wire.setAll(142, nonce);
    wire.setAll(158, mac);
    return wire;
  }

  static _MemberFileRequest? parse(Uint8List wire) {
    if (wire.length != _length ||
        String.fromCharCodes(wire.sublist(0, 4)) != _tag) {
      return null;
    }
    final data = ByteData.sublistView(wire);
    return _MemberFileRequest(
      documentId: Uint8List.fromList(wire.sublist(4, 36)),
      contentId: Uint8List.fromList(wire.sublist(36, 68)),
      returnServicePublicKey: Uint8List.fromList(wire.sublist(68, 100)),
      returnAppId: Uint8List.fromList(wire.sublist(100, 132)),
      returnEndpointId: data.getUint16(132, Endian.big),
      pieceIndex: data.getUint32(134, Endian.big),
      chunkIndex: data.getUint32(138, Endian.big),
      nonce: Uint8List.fromList(wire.sublist(142, 158)),
      mac: Uint8List.fromList(wire.sublist(158, 190)),
    );
  }
}

Uint8List _memberChunkResponse({
  required Uint8List documentId,
  required Uint8List contentId,
  required int pieceIndex,
  required int chunkIndex,
  required Uint8List nonce,
  required Uint8List sealed,
}) {
  const tag = 'XMP1';
  final header = Uint8List(4 + 32 + 32 + 4 + 4 + 16 + 2)
    ..setAll(0, tag.codeUnits);
  header.setAll(4, documentId);
  header.setAll(36, contentId);
  final data = ByteData.sublistView(header);
  data.setUint32(68, pieceIndex, Endian.big);
  data.setUint32(72, chunkIndex, Endian.big);
  header.setAll(76, nonce);
  data.setUint16(92, sealed.length, Endian.big);
  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(sealed))
      .toBytes();
}

class _MemberChunkResponse {
  const _MemberChunkResponse({
    required this.documentId,
    required this.contentId,
    required this.pieceIndex,
    required this.chunkIndex,
    required this.nonce,
    required this.sealed,
  });
  static const _tag = 'XMP1';
  static const _headerLength = 4 + 32 + 32 + 4 + 4 + 16 + 2;
  final Uint8List documentId;
  final Uint8List contentId;
  final int pieceIndex;
  final int chunkIndex;
  final Uint8List nonce;
  final Uint8List sealed;

  static _MemberChunkResponse? parse(Uint8List wire) {
    if (wire.length < _headerLength ||
        String.fromCharCodes(wire.sublist(0, 4)) != _tag) {
      return null;
    }
    final data = ByteData.sublistView(wire);
    final sealedLength = data.getUint16(92, Endian.big);
    if (sealedLength < 16 || _headerLength + sealedLength != wire.length) {
      return null;
    }
    return _MemberChunkResponse(
      documentId: Uint8List.fromList(wire.sublist(4, 36)),
      contentId: Uint8List.fromList(wire.sublist(36, 68)),
      pieceIndex: data.getUint32(68, Endian.big),
      chunkIndex: data.getUint32(72, Endian.big),
      nonce: Uint8List.fromList(wire.sublist(76, 92)),
      sealed: Uint8List.fromList(wire.sublist(_headerLength)),
    );
  }
}

Uint8List _contentIdBytes(String hex) {
  if (hex.length != 64) throw ArgumentError('contentId must be 64 hex chars');
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _contentIdHex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Serves file chunks to authorized members of one shared folder document.
/// Only content ids present in [_servable] are served, and only under the
/// CURRENT epoch key — [rekey] atomically swaps both.
class CloudMemberContentHost {
  CloudMemberContentHost({
    required this.documentId,
    required this.servicePublicKey,
    required this.appId,
    required this.endpointId,
    required this.expiresAtMs,
    required this.storage,
    required Uint8List epochKey,
    required Iterable<ContentManifest> servable,
    required Future<void> Function({
      required Uint8List servicePublicKey,
      required Uint8List targetAppId,
      required int targetEndpointId,
      required Uint8List data,
    })
    send,
    DateTime Function()? now,
    // ignore: prefer_initializing_formals
  }) : _send = send,
       _now = now ?? DateTime.now,
       _epochKey = Uint8List.fromList(epochKey) {
    _setServable(servable);
  }

  final Uint8List documentId;
  final Uint8List servicePublicKey;
  final Uint8List appId;
  final int endpointId;
  final int expiresAtMs;
  final CloudFolderShareStorage storage;
  final DateTime Function() _now;
  final Future<void> Function({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  })
  _send;

  Uint8List _epochKey;
  final Map<String, ContentManifest> _servable = {};

  /// Content ids currently served — diagnostics only.
  List<String> get servableContentIds => _servable.keys.toList()..sort();

  int _requestsSeen = 0;
  int _requestsAnswered = 0;

  /// Requests this host was handed, and how many it answered — diagnostics
  /// only. Every denial in [serve] is deliberately silent, so without these a
  /// host that receives a request for content it does not hold is
  /// indistinguishable from one that never heard the request at all. That
  /// difference is exactly what tells "the network never reached us" from "we
  /// answered our own request with nothing".
  int get requestsSeen => _requestsSeen;
  int get requestsAnswered => _requestsAnswered;

  void _setServable(Iterable<ContentManifest> manifests) {
    _servable
      ..clear()
      ..addEntries(manifests.map((m) => MapEntry(m.contentId, m)));
  }

  /// Rotate to a new epoch key and served set in one step. After this, any
  /// request MAC'd under the old epoch key fails silently. The previous key
  /// buffer is zeroized before being dropped.
  void rekey(Uint8List epochKey, Iterable<ContentManifest> servable) {
    final old = _epochKey;
    _epochKey = Uint8List.fromList(epochKey);
    old.fillRange(0, old.length, 0);
    _setServable(servable);
  }

  /// Zeroize the held epoch key. Call on teardown; the host must not be used
  /// afterwards (every subsequent request fails the MAC gate silently).
  void wipe() {
    _epochKey.fillRange(0, _epochKey.length, 0);
  }

  CloudCapability _capabilityFor(ContentManifest manifest) =>
      CloudCapabilityCodec.memberFileCapability(
        documentId: documentId,
        epochKey: _epochKey,
        manifest: manifest,
        servicePublicKey: servicePublicKey,
        appId: appId,
        endpointId: endpointId,
        expiresAtMs: expiresAtMs,
      );

  Future<void> serve(Uint8List wire) async {
    _requestsSeen++;
    try {
      if (_now().millisecondsSinceEpoch >= expiresAtMs) return;
      final request = _MemberFileRequest.parse(wire);
      if (request == null || !_equal(request.documentId, documentId)) return;
      final contentId = _contentIdHex(request.contentId);
      final manifest = _servable[contentId];
      if (manifest == null) return;
      final capability = _capabilityFor(manifest);
      final expected = CloudCapabilityCodec.requestMac(
        capability: capability,
        returnServicePublicKey: request.returnServicePublicKey,
        returnAppId: request.returnAppId,
        returnEndpointId: request.returnEndpointId,
        pieceIndex: request.pieceIndex,
        chunkIndex: request.chunkIndex,
        requestNonce: request.nonce,
      );
      if (!_equal(expected, request.mac)) return;
      final length = CloudCapabilityCodec.chunkLength(
        capability,
        request.pieceIndex,
        request.chunkIndex,
      );
      final offset =
          request.pieceIndex * manifest.pieceSize +
          request.chunkIndex * CloudCapabilityCodec.publicChunkBytes;
      final clear = await storage.readFileRange(contentId, offset, length);
      if (clear == null || clear.length != length) return;
      final sealed = await CloudCapabilityCodec.sealChunk(
        capability: capability,
        pieceIndex: request.pieceIndex,
        chunkIndex: request.chunkIndex,
        clear: clear,
      );
      _requestsAnswered++;
      await _send(
        servicePublicKey: request.returnServicePublicKey,
        targetAppId: request.returnAppId,
        targetEndpointId: request.returnEndpointId,
        data: _memberChunkResponse(
          documentId: documentId,
          contentId: request.contentId,
          pieceIndex: request.pieceIndex,
          chunkIndex: request.chunkIndex,
          nonce: request.nonce,
          sealed: sealed,
        ),
      );
    } catch (_) {}
  }
}

/// Fetches one file's bytes from a member content host, proving membership
/// with the current epoch key and verifying every chunk + the manifest piece.
class CloudMemberContentClient {
  CloudMemberContentClient({
    required this.documentId,
    required this.epochKey,
    required this.servicePublicKey,
    required this.appId,
    required this.endpointId,
    required this.expiresAtMs,
    required this.returnServicePublicKey,
    required this.returnAppId,
    required this.returnEndpointId,
    required this.incoming,
    required Future<void> Function(Uint8List data) send,
    // Budget for BOTH legs of the anonymous onion round-trip (request-send
    // builds a ~5 s rendezvous circuit before the host's reply); 8 s left a
    // slow-but-delivered reply no room and every fetch timed out live.
    Duration timeout = const Duration(seconds: 30),
    required Uint8List Function(int count) randomBytes,
    // ignore: prefer_initializing_formals
  }) : _send = send,
       // ignore: prefer_initializing_formals
       _timeout = timeout,
       // ignore: prefer_initializing_formals
       _randomBytes = randomBytes;

  final Uint8List documentId;
  final Uint8List epochKey;
  final Uint8List servicePublicKey;
  final Uint8List appId;
  final int endpointId;
  final int expiresAtMs;
  final Uint8List returnServicePublicKey;
  final Uint8List returnAppId;
  final int returnEndpointId;
  final Stream<Uint8List> incoming;
  final Future<void> Function(Uint8List data) _send;
  final Duration _timeout;
  final Uint8List Function(int count) _randomBytes;

  /// Fetches the whole file into memory.
  ///
  /// Only safe for content that is known to be small; a shared folder can hold
  /// a multi-GB file, and this holds all of it at once. Prefer
  /// [fetchFileStreaming], which never accumulates.
  Future<Uint8List> fetchFile(ContentManifest manifest) async {
    final assembled = BytesBuilder(copy: false);
    await fetchFileStreaming(
      manifest,
      (_, bytes) async => assembled.add(bytes),
    );
    return assembled.toBytes();
  }

  /// Streams the file, handing each piece to [onPiece] once its hash is
  /// verified, and returns the total byte count.
  ///
  /// Nothing is retained here: peak memory is one piece plus whatever the sink
  /// keeps, so a few-GB shared file is bounded by disk rather than by RAM. A
  /// piece is only ever passed on AFTER [ContentManifest.verifyPiece] accepts
  /// it, so a sink may persist it immediately — unverified bytes never escape.
  Future<int> fetchFileStreaming(
    ContentManifest manifest,
    Future<void> Function(int pieceIndex, Uint8List bytes) onPiece,
  ) async {
    final capability = CloudCapabilityCodec.memberFileCapability(
      documentId: documentId,
      epochKey: epochKey,
      manifest: manifest,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
    );
    final contentIdBytes = _contentIdBytes(manifest.contentId);
    var total = 0;
    for (var piece = 0; piece < manifest.pieceCount; piece++) {
      final clearPiece = BytesBuilder(copy: false);
      final chunks = CloudCapabilityCodec.chunkCount(capability, piece);
      for (var chunk = 0; chunk < chunks; chunk++) {
        final nonce = _randomBytes(16);
        final mac = CloudCapabilityCodec.requestMac(
          capability: capability,
          returnServicePublicKey: returnServicePublicKey,
          returnAppId: returnAppId,
          returnEndpointId: returnEndpointId,
          pieceIndex: piece,
          chunkIndex: chunk,
          requestNonce: nonce,
        );
        final request = _MemberFileRequest(
          documentId: documentId,
          contentId: contentIdBytes,
          returnServicePublicKey: returnServicePublicKey,
          returnAppId: returnAppId,
          returnEndpointId: returnEndpointId,
          pieceIndex: piece,
          chunkIndex: chunk,
          nonce: nonce,
          mac: mac,
        );
        final pending = incoming
            .map(_MemberChunkResponse.parse)
            .where(
              (response) =>
                  response != null &&
                  _equal(response.documentId, documentId) &&
                  _equal(response.contentId, contentIdBytes) &&
                  response.pieceIndex == piece &&
                  response.chunkIndex == chunk &&
                  _equal(response.nonce, nonce),
            )
            .cast<_MemberChunkResponse>()
            .first
            .timeout(_timeout);
        await _send(request.encode());
        final response = await pending;
        clearPiece.add(
          await CloudCapabilityCodec.openChunk(
            capability: capability,
            pieceIndex: piece,
            chunkIndex: chunk,
            sealed: response.sealed,
          ),
        );
      }
      final bytes = clearPiece.toBytes();
      if (!manifest.verifyPiece(piece, bytes)) {
        throw StateError('member content piece hash mismatch');
      }
      total += bytes.length;
      await onPiece(piece, bytes);
    }
    // Checked after the fact rather than up front: the per-piece hashes already
    // pin the content, and this catches a host that returned the right pieces
    // for a manifest describing a different length.
    if (total != manifest.size) {
      throw StateError('member content size mismatch');
    }
    return total;
  }
}
