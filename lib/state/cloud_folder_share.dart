import 'dart:async';
import 'dart:typed_data';

import '../domain/cloud_capability.dart';
import '../domain/content_manifest.dart';

/// Wire ops for a folder bearer share. A folder share reuses the file share's
/// piece/chunk transport (XCR1/XCP1) unchanged; it adds two ops:
///
///  * `listing` (XLR1 → XLP1): fetch the CURRENT sealed listing. The reply's
///    revision is authenticated in the listing AEAD, so a lying server cannot
///    forge a revision, and the client rejects anything below its link floor.
///  * folder-file (XFR1): a piece/chunk request that names the target
///    contentId. The host derives the per-file subkey, checks the request MAC
///    under it and refuses any contentId absent from the current listing, then
///    answers with an ordinary XCP1 sealed under the subkey. A wrong contentId
///    yields a wrong subkey and a silent MAC failure.
///
/// This layer is transport + crypto only: it never persists and never touches
/// the registry, so it is unit-testable against a fake network and storage.

/// Minimal storage surface the host needs — a subset of the app Storage.
abstract interface class CloudFolderShareStorage {
  Future<Uint8List?> readFileRange(String contentId, int offset, int length);
}

class _ListingRequest {
  const _ListingRequest({
    required this.shareId,
    required this.returnServicePublicKey,
    required this.returnAppId,
    required this.returnEndpointId,
    required this.nonce,
    required this.mac,
  });
  static const _tag = 'XLR1';
  static const _length = 4 + 32 + 32 + 32 + 2 + 16 + 32;
  final Uint8List shareId;
  final Uint8List returnServicePublicKey;
  final Uint8List returnAppId;
  final int returnEndpointId;
  final Uint8List nonce;
  final Uint8List mac;

  factory _ListingRequest.create({
    required CloudFolderCapability capability,
    required Uint8List returnServicePublicKey,
    required Uint8List returnAppId,
    required int returnEndpointId,
    required Uint8List nonce,
  }) => _ListingRequest(
    shareId: capability.shareId,
    returnServicePublicKey: returnServicePublicKey,
    returnAppId: returnAppId,
    returnEndpointId: returnEndpointId,
    nonce: nonce,
    mac: CloudCapabilityCodec.listingRequestMac(
      capability: capability,
      returnServicePublicKey: returnServicePublicKey,
      returnAppId: returnAppId,
      returnEndpointId: returnEndpointId,
      requestNonce: nonce,
    ),
  );

  Uint8List encode() {
    final wire = Uint8List(_length)..setAll(0, _tag.codeUnits);
    wire.setAll(4, shareId);
    wire.setAll(36, returnServicePublicKey);
    wire.setAll(68, returnAppId);
    ByteData.sublistView(wire).setUint16(100, returnEndpointId, Endian.big);
    wire.setAll(102, nonce);
    wire.setAll(118, mac);
    return wire;
  }

  static _ListingRequest? parse(Uint8List wire) {
    if (wire.length != _length ||
        String.fromCharCodes(wire.sublist(0, 4)) != _tag) {
      return null;
    }
    return _ListingRequest(
      shareId: Uint8List.fromList(wire.sublist(4, 36)),
      returnServicePublicKey: Uint8List.fromList(wire.sublist(36, 68)),
      returnAppId: Uint8List.fromList(wire.sublist(68, 100)),
      returnEndpointId: ByteData.sublistView(wire).getUint16(100, Endian.big),
      nonce: Uint8List.fromList(wire.sublist(102, 118)),
      mac: Uint8List.fromList(wire.sublist(118, 150)),
    );
  }
}

class _ListingResponse {
  const _ListingResponse({
    required this.shareId,
    required this.nonce,
    required this.revision,
    required this.sealed,
  });
  static const _tag = 'XLP1';
  static const _headerLength = 4 + 32 + 16 + 8 + 4;
  final Uint8List shareId;
  final Uint8List nonce;
  final int revision;
  final Uint8List sealed;

  Uint8List encode() {
    final header = Uint8List(_headerLength)..setAll(0, _tag.codeUnits);
    header.setAll(4, shareId);
    header.setAll(36, nonce);
    final data = ByteData.sublistView(header);
    data.setUint64(52, revision, Endian.big);
    data.setUint32(60, sealed.length, Endian.big);
    return (BytesBuilder(copy: false)
          ..add(header)
          ..add(sealed))
        .toBytes();
  }

  static _ListingResponse? parse(Uint8List wire) {
    if (wire.length < _headerLength ||
        String.fromCharCodes(wire.sublist(0, 4)) != _tag) {
      return null;
    }
    final data = ByteData.sublistView(wire);
    final sealedLength = data.getUint32(60, Endian.big);
    if (sealedLength < 16 || _headerLength + sealedLength != wire.length) {
      return null;
    }
    return _ListingResponse(
      shareId: Uint8List.fromList(wire.sublist(4, 36)),
      nonce: Uint8List.fromList(wire.sublist(36, 52)),
      revision: data.getUint64(52, Endian.big),
      sealed: Uint8List.fromList(wire.sublist(_headerLength)),
    );
  }
}

/// A folder-file request names the target contentId so the host can pick the
/// per-file subkey; the [mac] is a normal [CloudCapabilityCodec.requestMac]
/// over the SYNTHETIC per-file capability.
class _FolderFileRequest {
  const _FolderFileRequest({
    required this.shareId,
    required this.contentId,
    required this.returnServicePublicKey,
    required this.returnAppId,
    required this.returnEndpointId,
    required this.pieceIndex,
    required this.chunkIndex,
    required this.nonce,
    required this.mac,
  });
  static const _tag = 'XFR1';
  static const _length = 4 + 32 + 32 + 32 + 32 + 2 + 4 + 4 + 16 + 32;
  final Uint8List shareId;

  /// 32-byte content id (the 64-hex id decoded).
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
    wire.setAll(4, shareId);
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

  static _FolderFileRequest? parse(Uint8List wire) {
    if (wire.length != _length ||
        String.fromCharCodes(wire.sublist(0, 4)) != _tag) {
      return null;
    }
    final data = ByteData.sublistView(wire);
    return _FolderFileRequest(
      shareId: Uint8List.fromList(wire.sublist(4, 36)),
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

/// Serves one folder share: answers listing requests with the current sealed
/// listing and folder-file requests with subkey-sealed chunks. Only contentIds
/// present in the CURRENT listing are served — a file removed from the folder
/// stops being reachable the moment the listing is replaced.
class CloudFolderShareHost {
  CloudFolderShareHost({
    required this.capability,
    required this.storage,
    required CloudFolderListing listing,
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
       _now = now ?? DateTime.now {
    _ready = setListing(listing);
  }

  /// Completes once the initial listing has been sealed. [serve] awaits the
  /// latest seal internally, so callers need this only to know the host is
  /// answering.
  Future<void> get ready => _ready;
  Future<void> _ready = Future.value();

  final CloudFolderCapability capability;
  final CloudFolderShareStorage storage;
  final DateTime Function() _now;
  final Future<void> Function({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  })
  _send;

  CloudFolderListing _listing = CloudFolderListing(
    name: '',
    revision: 1,
    entries: const [],
  );
  Uint8List _sealedListing = Uint8List(0);
  final Map<String, ContentManifest> _served = {};

  int get revision => _listing.revision;

  /// Replace the served listing. The new revision must not go backwards.
  Future<void> setListing(CloudFolderListing listing) {
    final previous = _ready;
    return _ready = () async {
      // Serialize behind any in-flight seal so a rapid re-publish cannot race.
      try {
        await previous;
      } catch (_) {}
      if (listing.revision < _listing.revision && _sealedListing.isNotEmpty) {
        throw ArgumentError('listing revision must not go backwards');
      }
      final sealed = await CloudCapabilityCodec.sealListing(
        capability: capability,
        listing: listing,
      );
      _listing = listing;
      _sealedListing = sealed;
      _served
        ..clear()
        ..addAll(_flattenFiles(listing.entries));
    }();
  }

  static Map<String, ContentManifest> _flattenFiles(
    List<CloudFolderListingEntry> entries,
  ) {
    final out = <String, ContentManifest>{};
    void walk(List<CloudFolderListingEntry> rows) {
      for (final row in rows) {
        if (row.isFolder) {
          walk(row.entries!);
        } else {
          out[row.manifest!.contentId] = row.manifest!;
        }
      }
    }

    walk(entries);
    return out;
  }

  /// Handle one inbound datagram. Every malformed, unauthorized or unavailable
  /// request follows the same silent path — never an existence oracle.
  Future<void> serve(Uint8List wire) async {
    try {
      // An expired link is served the same silent denial as a bad MAC — the
      // holder has the folder key but the capability is no longer valid.
      if (_now().millisecondsSinceEpoch >= capability.expiresAtMs) return;
      // Answer against the latest published listing, never a half-sealed one.
      try {
        await _ready;
      } catch (_) {
        return;
      }
      final listing = _ListingRequest.parse(wire);
      if (listing != null) {
        await _serveListing(listing);
        return;
      }
      final file = _FolderFileRequest.parse(wire);
      if (file != null) await _serveFile(file);
    } catch (_) {}
  }

  Future<void> _serveListing(_ListingRequest request) async {
    if (!_equal(request.shareId, capability.shareId)) return;
    final expected = CloudCapabilityCodec.listingRequestMac(
      capability: capability,
      returnServicePublicKey: request.returnServicePublicKey,
      returnAppId: request.returnAppId,
      returnEndpointId: request.returnEndpointId,
      requestNonce: request.nonce,
    );
    if (!_equal(expected, request.mac)) return;
    final response = _ListingResponse(
      shareId: capability.shareId,
      nonce: request.nonce,
      revision: _listing.revision,
      sealed: _sealedListing,
    ).encode();
    await _send(
      servicePublicKey: request.returnServicePublicKey,
      targetAppId: request.returnAppId,
      targetEndpointId: request.returnEndpointId,
      data: response,
    );
  }

  Future<void> _serveFile(_FolderFileRequest request) async {
    if (!_equal(request.shareId, capability.shareId)) return;
    final contentId = _contentIdHex(request.contentId);
    final manifest = _served[contentId];
    if (manifest == null) return;
    final fileCapability = CloudCapabilityCodec.folderFileCapability(
      capability,
      CloudFolderListingEntry.file(name: manifest.name, manifest: manifest),
    );
    final expected = CloudCapabilityCodec.requestMac(
      capability: fileCapability,
      returnServicePublicKey: request.returnServicePublicKey,
      returnAppId: request.returnAppId,
      returnEndpointId: request.returnEndpointId,
      pieceIndex: request.pieceIndex,
      chunkIndex: request.chunkIndex,
      requestNonce: request.nonce,
    );
    if (!_equal(expected, request.mac)) return;
    final length = CloudCapabilityCodec.chunkLength(
      fileCapability,
      request.pieceIndex,
      request.chunkIndex,
    );
    final offset =
        request.pieceIndex * manifest.pieceSize +
        request.chunkIndex * CloudCapabilityCodec.publicChunkBytes;
    final clear = await storage.readFileRange(contentId, offset, length);
    if (clear == null || clear.length != length) return;
    final sealed = await CloudCapabilityCodec.sealChunk(
      capability: fileCapability,
      pieceIndex: request.pieceIndex,
      chunkIndex: request.chunkIndex,
      clear: clear,
    );
    // Reuse the file wire response frame (XCP1) keyed by the file's shareId ==
    // the folder shareId; the client disambiguates by (contentId-derived key,
    // piece, chunk, nonce).
    await _send(
      servicePublicKey: request.returnServicePublicKey,
      targetAppId: request.returnAppId,
      targetEndpointId: request.returnEndpointId,
      data: _folderChunkResponse(
        shareId: capability.shareId,
        contentId: request.contentId,
        pieceIndex: request.pieceIndex,
        chunkIndex: request.chunkIndex,
        nonce: request.nonce,
        sealed: sealed,
      ),
    );
  }
}

/// XFP1: a folder-file chunk response. Carries the contentId so the client can
/// match it to the right in-flight file fetch.
Uint8List _folderChunkResponse({
  required Uint8List shareId,
  required Uint8List contentId,
  required int pieceIndex,
  required int chunkIndex,
  required Uint8List nonce,
  required Uint8List sealed,
}) {
  const tag = 'XFP1';
  final header = Uint8List(4 + 32 + 32 + 4 + 4 + 16 + 2)
    ..setAll(0, tag.codeUnits);
  header.setAll(4, shareId);
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

class _FolderChunkResponse {
  const _FolderChunkResponse({
    required this.shareId,
    required this.contentId,
    required this.pieceIndex,
    required this.chunkIndex,
    required this.nonce,
    required this.sealed,
  });
  static const _tag = 'XFP1';
  static const _headerLength = 4 + 32 + 32 + 4 + 4 + 16 + 2;
  final Uint8List shareId;
  final Uint8List contentId;
  final int pieceIndex;
  final int chunkIndex;
  final Uint8List nonce;
  final Uint8List sealed;

  static _FolderChunkResponse? parse(Uint8List wire) {
    if (wire.length < _headerLength ||
        String.fromCharCodes(wire.sublist(0, 4)) != _tag) {
      return null;
    }
    final data = ByteData.sublistView(wire);
    final sealedLength = data.getUint16(92, Endian.big);
    if (sealedLength < 16 || _headerLength + sealedLength != wire.length) {
      return null;
    }
    return _FolderChunkResponse(
      shareId: Uint8List.fromList(wire.sublist(4, 36)),
      contentId: Uint8List.fromList(wire.sublist(36, 68)),
      pieceIndex: data.getUint32(68, Endian.big),
      chunkIndex: data.getUint32(72, Endian.big),
      nonce: Uint8List.fromList(wire.sublist(76, 92)),
      sealed: Uint8List.fromList(wire.sublist(_headerLength)),
    );
  }
}

/// Client side: fetch the current listing, then reassemble one file's bytes
/// through the folder share, verifying every chunk and the manifest piece.
class CloudFolderShareClient {
  CloudFolderShareClient({
    required this.capability,
    required this.returnServicePublicKey,
    required this.returnAppId,
    required this.returnEndpointId,
    required this.incoming,
    required Future<void> Function(Uint8List data) send,
    // Budget for BOTH legs of the anonymous onion round-trip: our own
    // request-send builds a rendezvous circuit (~5 s) before the host's
    // reply (another circuit build + return traversal). 8 s left a
    // slow-but-delivered reply no room and every fetch timed out live.
    Duration timeout = const Duration(seconds: 30),
    Uint8List Function(int count)? randomBytes,
    // ignore: prefer_initializing_formals
  }) : _send = send,
       // ignore: prefer_initializing_formals
       _timeout = timeout,
       _randomBytes = randomBytes ?? _defaultRandom;

  final CloudFolderCapability capability;
  final Uint8List returnServicePublicKey;
  final Uint8List returnAppId;
  final int returnEndpointId;
  final Stream<Uint8List> incoming;
  final Future<void> Function(Uint8List data) _send;
  final Duration _timeout;
  final Uint8List Function(int count) _randomBytes;

  // Default zero-filled nonce source; real callers pass a CSPRNG generator.
  static Uint8List _defaultRandom(int count) => Uint8List(count);

  Future<CloudFolderListing> fetchListing() async {
    final nonce = _randomBytes(16);
    final request = _ListingRequest.create(
      capability: capability,
      returnServicePublicKey: returnServicePublicKey,
      returnAppId: returnAppId,
      returnEndpointId: returnEndpointId,
      nonce: nonce,
    );
    final pending = incoming
        .map(_ListingResponse.parse)
        .where(
          (response) =>
              response != null &&
              _equal(response.shareId, capability.shareId) &&
              _equal(response.nonce, nonce),
        )
        .cast<_ListingResponse>()
        .first
        .timeout(_timeout);
    await _send(request.encode());
    final response = await pending;
    return CloudCapabilityCodec.openListing(
      capability: capability,
      revision: response.revision,
      sealed: response.sealed,
    );
  }

  /// Fetch and verify one file named by a listing entry. Returns the plaintext
  /// bytes; the caller persists them.
  Future<Uint8List> fetchFile(CloudFolderListingEntry entry) async {
    final fileCapability = CloudCapabilityCodec.folderFileCapability(
      capability,
      entry,
    );
    final manifest = fileCapability.manifest;
    final contentIdBytes = _contentIdBytes(manifest.contentId);
    final assembled = BytesBuilder(copy: false);
    for (var piece = 0; piece < manifest.pieceCount; piece++) {
      final clearPiece = BytesBuilder(copy: false);
      final chunks = CloudCapabilityCodec.chunkCount(fileCapability, piece);
      for (var chunk = 0; chunk < chunks; chunk++) {
        final nonce = _randomBytes(16);
        final mac = CloudCapabilityCodec.requestMac(
          capability: fileCapability,
          returnServicePublicKey: returnServicePublicKey,
          returnAppId: returnAppId,
          returnEndpointId: returnEndpointId,
          pieceIndex: piece,
          chunkIndex: chunk,
          requestNonce: nonce,
        );
        final request = _FolderFileRequest(
          shareId: capability.shareId,
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
            .map(_FolderChunkResponse.parse)
            .where(
              (response) =>
                  response != null &&
                  _equal(response.shareId, capability.shareId) &&
                  _equal(response.contentId, contentIdBytes) &&
                  response.pieceIndex == piece &&
                  response.chunkIndex == chunk &&
                  _equal(response.nonce, nonce),
            )
            .cast<_FolderChunkResponse>()
            .first
            .timeout(_timeout);
        await _send(request.encode());
        final response = await pending;
        clearPiece.add(
          await CloudCapabilityCodec.openChunk(
            capability: fileCapability,
            pieceIndex: piece,
            chunkIndex: chunk,
            sealed: response.sealed,
          ),
        );
      }
      final bytes = clearPiece.toBytes();
      if (!manifest.verifyPiece(piece, bytes)) {
        throw StateError('folder file piece hash mismatch');
      }
      assembled.add(bytes);
    }
    return assembled.toBytes();
  }
}
