import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'content_manifest.dart';

/// A bearer link for one immutable cloud revision. All authority is in the URL
/// fragment: HTTP clients and ordinary web servers never receive it.
class CloudCapability {
  CloudCapability({
    required this.shareId,
    required this.key,
    required this.servicePublicKey,
    required this.appId,
    required this.endpointId,
    required this.expiresAtMs,
    required this.manifest,
    required this.revision,
    this.mime,
  });

  final Uint8List shareId;
  final Uint8List key;
  final Uint8List servicePublicKey;
  final Uint8List appId;
  final int endpointId;
  final int expiresAtMs;
  final ContentManifest manifest;
  final int revision;
  final String? mime;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch >= expiresAtMs;
}

/// A bearer link for one shared FOLDER. Same frame and authority model as
/// [CloudCapability]; the sealed payload names the folder instead of carrying
/// a content manifest. The holder fetches the CURRENT sealed listing through
/// the `listing` wire op, so one link stays valid while contents change.
class CloudFolderCapability {
  CloudFolderCapability({
    required this.shareId,
    required this.key,
    required this.servicePublicKey,
    required this.appId,
    required this.endpointId,
    required this.expiresAtMs,
    required this.folderName,
    required this.listingRevision,
  });

  final Uint8List shareId;
  final Uint8List key;
  final Uint8List servicePublicKey;
  final Uint8List appId;
  final int endpointId;
  final int expiresAtMs;
  final String folderName;

  /// The listing revision current when the link was minted. A client must
  /// treat it as a floor: an answer with a LOWER revision is a rollback and
  /// is rejected.
  final int listingRevision;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch >= expiresAtMs;
}

/// Discriminated result of parsing an `xveil://cloud` link.
sealed class ParsedCloudLink {}

class ParsedCloudFileLink extends ParsedCloudLink {
  ParsedCloudFileLink(this.capability);
  final CloudCapability capability;
}

class ParsedCloudFolderLink extends ParsedCloudLink {
  ParsedCloudFolderLink(this.capability);
  final CloudFolderCapability capability;
}

/// One row of a folder listing: a file entry carries its own bearer link;
/// a subfolder nests its entries inline.
class CloudFolderListingEntry {
  const CloudFolderListingEntry.file({
    required String this.name,
    required int this.size,
    required String this.link,
    this.mime,
  }) : entries = null;

  const CloudFolderListingEntry.folder({
    required String this.name,
    required List<CloudFolderListingEntry> this.entries,
  }) : size = null,
       mime = null,
       link = null;

  final String? name;
  final int? size;
  final String? mime;
  final String? link;
  final List<CloudFolderListingEntry>? entries;

  bool get isFolder => entries != null;

  Map<String, dynamic> toJson() => isFolder
      ? {
          't': 'd',
          'name': name,
          'entries': [for (final entry in entries!) entry.toJson()],
        }
      : {'t': 'f', 'name': name, 'size': size, 'link': link, 'mime': ?mime};

  static CloudFolderListingEntry? fromJson(Object? value, int depth) {
    if (value is! Map || depth > CloudFolderListing.maxDepth) return null;
    final name = value['name'];
    if (name is! String || name.isEmpty || name.length > 512) return null;
    switch (value['t']) {
      case 'f':
        final size = value['size'];
        final link = value['link'];
        final mime = value['mime'];
        if (size is! int ||
            size < 0 ||
            size > (1 << 50) ||
            link is! String ||
            link.isEmpty ||
            link.length > 8192 ||
            (mime != null && (mime is! String || mime.length > 255))) {
          return null;
        }
        return CloudFolderListingEntry.file(
          name: name,
          size: size,
          link: link,
          mime: mime as String?,
        );
      case 'd':
        final raw = value['entries'];
        if (raw is! List) return null;
        final children = <CloudFolderListingEntry>[];
        for (final child in raw) {
          final parsed = fromJson(child, depth + 1);
          if (parsed == null) return null;
          children.add(parsed);
        }
        return CloudFolderListingEntry.folder(name: name, entries: children);
      default:
        return null;
    }
  }
}

/// The live folder listing document exchanged through the `listing` wire op.
class CloudFolderListing {
  CloudFolderListing({
    required this.name,
    required this.revision,
    required List<CloudFolderListingEntry> entries,
  }) : entries = List.unmodifiable(entries);

  static const maxDepth = 32;
  static const maxTotalEntries = 512;
  static const maxSealedBytes = 256 * 1024;

  final String name;
  final int revision;
  final List<CloudFolderListingEntry> entries;

  int get totalEntries {
    var count = 0;
    void walk(List<CloudFolderListingEntry> rows) {
      for (final row in rows) {
        count++;
        if (row.isFolder) walk(row.entries!);
      }
    }

    walk(entries);
    return count;
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'name': name,
    'rev': revision,
    'entries': [for (final entry in entries) entry.toJson()],
  };

  static CloudFolderListing? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['name'] is! String ||
        (value['name'] as String).isEmpty ||
        (value['name'] as String).length > 512 ||
        value['rev'] is! int ||
        (value['rev'] as int) < 1 ||
        value['entries'] is! List) {
      return null;
    }
    final entries = <CloudFolderListingEntry>[];
    for (final raw in value['entries'] as List) {
      final parsed = CloudFolderListingEntry.fromJson(raw, 1);
      if (parsed == null) return null;
      entries.add(parsed);
    }
    final listing = CloudFolderListing(
      name: value['name'] as String,
      revision: value['rev'] as int,
      entries: entries,
    );
    return listing.totalEntries <= maxTotalEntries ? listing : null;
  }
}

/// Strict fixed-field codec. A binary layout avoids JSON duplicate-field
/// ambiguity at the authority boundary; only the AEAD-protected manifest uses
/// JSON, and it is parsed against a small exact schema after authentication.
class CloudCapabilityCodec {
  static const scheme = 'xveil';
  static const host = 'cloud';
  static const _version = 1;
  static const _fixedBytes = 4 + 32 + 32 + 32 + 32 + 2 + 8 + 12 + 4;
  static const _maxSealedManifestBytes = 1024 * 1024;
  static const publicChunkBytes = 2048;
  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static final Uint8List _magic = Uint8List.fromList(const [
    0x58,
    0x56,
    0x43,
    1,
  ]);

  static Future<String> create({
    required ContentManifest manifest,
    required int revision,
    required int expiresAtMs,
    required Uint8List servicePublicKey,
    required Uint8List appId,
    required int endpointId,
    String? mime,
    Random? random,
  }) async {
    if (!manifest.isSelfConsistent ||
        manifest.size < 0 ||
        manifest.size > (1 << 50)) {
      throw ArgumentError('invalid content manifest');
    }
    if (revision < 1 || expiresAtMs <= 0) {
      throw ArgumentError('invalid revision/expiry');
    }
    _require32(servicePublicKey, 'servicePublicKey');
    _require32(appId, 'appId');
    if (endpointId < 0 || endpointId > 0xffff) {
      throw ArgumentError.value(endpointId, 'endpointId');
    }
    final rng = random ?? Random.secure();
    final shareId = _randomBytes(rng, 32);
    final key = _randomBytes(rng, 32);
    final nonce = _randomBytes(rng, 12);
    final cleanManifest = ContentManifest(
      name: manifest.name,
      size: manifest.size,
      pieceSize: manifest.pieceSize,
      pieceHashes: manifest.pieceHashes,
      contentId: manifest.contentId,
      chunkBytes: manifest.chunkBytes,
    );
    final clear = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'manifest': cleanManifest.toJson(),
          'revision': revision,
          'mime': ?mime,
        }),
      ),
    );
    final aad = _aad(shareId, servicePublicKey, appId, endpointId, expiresAtMs);
    final box = await _aead.encrypt(
      clear,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    final sealed = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    if (sealed.length > _maxSealedManifestBytes) {
      throw ArgumentError('capability manifest is too large');
    }
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(shareId)
      ..add(key)
      ..add(servicePublicKey)
      ..add(appId)
      ..add(_u16(endpointId))
      ..add(_u64(expiresAtMs))
      ..add(nonce)
      ..add(_u32(sealed.length))
      ..add(sealed);
    final fragment = base64Url.encode(out.toBytes()).replaceAll('=', '');
    return '$scheme://$host/v$_version#$fragment';
  }

  /// Bearer link for a FOLDER: same frame, sealed payload names the folder
  /// and pins the mint-time listing revision as the holder's rollback floor.
  static Future<String> createFolder({
    required String folderName,
    required int listingRevision,
    required int expiresAtMs,
    required Uint8List servicePublicKey,
    required Uint8List appId,
    required int endpointId,
    Random? random,
  }) async {
    if (folderName.isEmpty || folderName.length > 512) {
      throw ArgumentError('invalid folder name');
    }
    if (listingRevision < 1 || expiresAtMs <= 0) {
      throw ArgumentError('invalid revision/expiry');
    }
    _require32(servicePublicKey, 'servicePublicKey');
    _require32(appId, 'appId');
    if (endpointId < 0 || endpointId > 0xffff) {
      throw ArgumentError.value(endpointId, 'endpointId');
    }
    final rng = random ?? Random.secure();
    final shareId = _randomBytes(rng, 32);
    final key = _randomBytes(rng, 32);
    final nonce = _randomBytes(rng, 12);
    final clear = Uint8List.fromList(
      utf8.encode(jsonEncode({'folder': folderName, 'lrev': listingRevision})),
    );
    final aad = _aad(shareId, servicePublicKey, appId, endpointId, expiresAtMs);
    final box = await _aead.encrypt(
      clear,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    final sealed = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(shareId)
      ..add(key)
      ..add(servicePublicKey)
      ..add(appId)
      ..add(_u16(endpointId))
      ..add(_u64(expiresAtMs))
      ..add(nonce)
      ..add(_u32(sealed.length))
      ..add(sealed);
    final fragment = base64Url.encode(out.toBytes()).replaceAll('=', '');
    return '$scheme://$host/v$_version#$fragment';
  }

  /// Backward-compatible file parse: a folder link fails closed here so
  /// pre-folder callers never mistake a listing for content.
  static Future<CloudCapability> parse(String value) async {
    switch (await parseLink(value)) {
      case ParsedCloudFileLink(:final capability):
        return capability;
      case ParsedCloudFolderLink():
        throw const FormatException('capability is a folder link');
    }
  }

  static Future<ParsedCloudLink> parseLink(String value) async {
    final frame = await _openFrame(value);
    final decoded = frame.decoded;
    try {
      if (decoded.containsKey('folder')) {
        final name = decoded['folder'];
        final listingRevision = decoded['lrev'];
        if (decoded.keys.any(
              (key) => !const {'folder', 'lrev'}.contains(key),
            ) ||
            name is! String ||
            name.isEmpty ||
            name.length > 512 ||
            listingRevision is! int ||
            listingRevision < 1) {
          throw const FormatException('invalid capability manifest');
        }
        return ParsedCloudFolderLink(
          CloudFolderCapability(
            shareId: frame.shareId,
            key: frame.key,
            servicePublicKey: frame.servicePublicKey,
            appId: frame.appId,
            endpointId: frame.endpointId,
            expiresAtMs: frame.expiresAtMs,
            folderName: name,
            listingRevision: listingRevision,
          ),
        );
      }
      if (decoded.keys.any(
            (key) => !const {'manifest', 'revision', 'mime'}.contains(key),
          ) ||
          decoded['manifest'] is! Map ||
          decoded['revision'] is! int ||
          (decoded.containsKey('mime') && decoded['mime'] is! String)) {
        throw const FormatException('invalid capability manifest');
      }
      final revision = decoded['revision'] as int;
      final mime = decoded['mime'] as String?;
      final manifest = ContentManifest.fromJson(
        Map<String, dynamic>.from(decoded['manifest'] as Map),
      );
      if (manifest == null ||
          revision < 1 ||
          manifest.size < 0 ||
          manifest.size > (1 << 50) ||
          manifest.name.length > 512 ||
          (mime?.length ?? 0) > 255) {
        throw const FormatException('invalid capability manifest');
      }
      return ParsedCloudFileLink(
        CloudCapability(
          shareId: frame.shareId,
          key: frame.key,
          servicePublicKey: frame.servicePublicKey,
          appId: frame.appId,
          endpointId: frame.endpointId,
          expiresAtMs: frame.expiresAtMs,
          manifest: manifest,
          revision: revision,
          mime: mime,
        ),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('invalid capability manifest');
    }
  }

  static Future<
    ({
      Uint8List shareId,
      Uint8List key,
      Uint8List servicePublicKey,
      Uint8List appId,
      int endpointId,
      int expiresAtMs,
      Map<dynamic, dynamic> decoded,
    })
  >
  _openFrame(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != scheme ||
        uri.host != host ||
        uri.path != '/v$_version' ||
        uri.query.isNotEmpty ||
        uri.fragment.isEmpty) {
      throw const FormatException('invalid cloud capability URL');
    }
    Uint8List raw;
    try {
      final fragment = uri.fragment;
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(fragment)) {
        throw const FormatException('invalid base64url');
      }
      raw = Uint8List.fromList(base64Url.decode(base64Url.normalize(fragment)));
    } catch (_) {
      throw const FormatException('invalid base64url');
    }
    if (raw.length < _fixedBytes + 16) {
      throw const FormatException('truncated capability');
    }
    var offset = 0;
    Uint8List take(int count) {
      if (count < 0 || offset + count > raw.length) {
        throw const FormatException('truncated capability');
      }
      final value = Uint8List.fromList(raw.sublist(offset, offset + count));
      offset += count;
      return value;
    }

    final magic = take(4);
    if (!_equal(magic, _magic)) throw const FormatException('wrong version');
    final shareId = take(32);
    final key = take(32);
    final servicePublicKey = take(32);
    final appId = take(32);
    final endpointId = _readU16(take(2));
    final expiresAtMs = _readU64(take(8));
    final nonce = take(12);
    final sealedLength = _readU32(take(4));
    if (sealedLength < 16 ||
        sealedLength > _maxSealedManifestBytes ||
        offset + sealedLength != raw.length) {
      throw const FormatException('invalid sealed manifest length');
    }
    final sealed = take(sealedLength);
    final cut = sealed.length - 16;
    final box = SecretBox(
      Uint8List.sublistView(sealed, 0, cut),
      nonce: nonce,
      mac: Mac(Uint8List.sublistView(sealed, cut)),
    );
    List<int> clear;
    try {
      clear = await _aead.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: _aad(shareId, servicePublicKey, appId, endpointId, expiresAtMs),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('capability authentication failed');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } catch (_) {
      throw const FormatException('invalid capability manifest');
    }
    if (decoded is! Map) {
      throw const FormatException('invalid capability manifest');
    }
    return (
      shareId: shareId,
      key: key,
      servicePublicKey: servicePublicKey,
      appId: appId,
      endpointId: endpointId,
      expiresAtMs: expiresAtMs,
      decoded: decoded,
    );
  }

  /// Seal the CURRENT listing for the `listing` wire op. The revision rides
  /// the AAD and derives the nonce, so a re-published listing never reuses a
  /// nonce under the share key and an answer cannot be replayed as a
  /// different revision.
  static Future<Uint8List> sealListing({
    required CloudFolderCapability capability,
    required CloudFolderListing listing,
  }) async {
    if (listing.revision < 1) throw ArgumentError('invalid listing revision');
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(listing.toJson())));
    final box = await _aead.encrypt(
      clear,
      secretKey: SecretKey(capability.key),
      nonce: _listingNonce(capability.shareId, listing.revision),
      aad: _listingAad(capability.shareId, listing.revision),
    );
    final sealed = Uint8List(box.cipherText.length + 16)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    if (sealed.length > CloudFolderListing.maxSealedBytes) {
      throw ArgumentError('folder listing is too large');
    }
    return sealed;
  }

  static Future<CloudFolderListing> openListing({
    required CloudFolderCapability capability,
    required int revision,
    required Uint8List sealed,
  }) async {
    if (revision < capability.listingRevision) {
      throw const FormatException('listing rollback rejected');
    }
    if (sealed.length < 16 ||
        sealed.length > CloudFolderListing.maxSealedBytes) {
      throw const FormatException('invalid sealed listing');
    }
    final cut = sealed.length - 16;
    List<int> clear;
    try {
      clear = await _aead.decrypt(
        SecretBox(
          Uint8List.sublistView(sealed, 0, cut),
          nonce: _listingNonce(capability.shareId, revision),
          mac: Mac(Uint8List.sublistView(sealed, cut)),
        ),
        secretKey: SecretKey(capability.key),
        aad: _listingAad(capability.shareId, revision),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('listing authentication failed');
    }
    CloudFolderListing? listing;
    try {
      listing = CloudFolderListing.fromJson(jsonDecode(utf8.decode(clear)));
    } catch (_) {
      listing = null;
    }
    if (listing == null || listing.revision != revision) {
      throw const FormatException('invalid folder listing');
    }
    return listing;
  }

  static Uint8List _listingNonce(Uint8List shareId, int revision) {
    final nonce = Uint8List(12)..setRange(0, 4, shareId);
    ByteData.sublistView(nonce).setUint64(4, revision, Endian.big);
    return nonce;
  }

  static Uint8List _listingAad(Uint8List shareId, int revision) =>
      (BytesBuilder(copy: false)
            ..add(utf8.encode('xveil.cloud.listing.v1'))
            ..add(shareId)
            ..add(_u64(revision)))
          .toBytes();

  /// Transcript-bound proof carried by every anonymous request.
  static Uint8List requestMac({
    required CloudCapability capability,
    required Uint8List returnServicePublicKey,
    required Uint8List returnAppId,
    required int returnEndpointId,
    required int pieceIndex,
    required int chunkIndex,
    required Uint8List requestNonce,
  }) {
    _require32(returnServicePublicKey, 'returnServicePublicKey');
    _require32(returnAppId, 'returnAppId');
    if (requestNonce.length != 16 || pieceIndex < 0 || chunkIndex < 0) {
      throw ArgumentError('invalid request nonce/piece');
    }
    final transcript = BytesBuilder(copy: false)
      ..add(utf8.encode('xveil.cloud.request.v1'))
      ..add(capability.shareId)
      ..add(returnServicePublicKey)
      ..add(returnAppId)
      ..add(_u16(returnEndpointId))
      ..add(_u32(pieceIndex))
      ..add(_u32(chunkIndex))
      ..add(requestNonce);
    return Uint8List.fromList(
      crypto.Hmac(
        crypto.sha256,
        capability.key,
      ).convert(transcript.toBytes()).bytes,
    );
  }

  static Future<Uint8List> sealPiece({
    required CloudCapability capability,
    required int pieceIndex,
    required Uint8List clear,
  }) async {
    if (!capability.manifest.verifyPiece(pieceIndex, clear)) {
      throw ArgumentError('piece does not match capability manifest');
    }
    final box = await _aead.encrypt(
      clear,
      secretKey: SecretKey(capability.key),
      nonce: _pieceNonce(capability.shareId, pieceIndex),
      aad: _pieceAad(capability, pieceIndex),
    );
    return Uint8List(box.cipherText.length + 16)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
  }

  static Future<Uint8List> openPiece({
    required CloudCapability capability,
    required int pieceIndex,
    required Uint8List sealed,
  }) async {
    if (pieceIndex < 0 ||
        pieceIndex >= capability.manifest.pieceCount ||
        sealed.length != capability.manifest.pieceLength(pieceIndex) + 16) {
      throw const FormatException('invalid sealed piece');
    }
    final cut = sealed.length - 16;
    try {
      final clear = await _aead.decrypt(
        SecretBox(
          Uint8List.sublistView(sealed, 0, cut),
          nonce: _pieceNonce(capability.shareId, pieceIndex),
          mac: Mac(Uint8List.sublistView(sealed, cut)),
        ),
        secretKey: SecretKey(capability.key),
        aad: _pieceAad(capability, pieceIndex),
      );
      final bytes = Uint8List.fromList(clear);
      if (!capability.manifest.verifyPiece(pieceIndex, bytes)) {
        throw const FormatException('piece hash mismatch');
      }
      return bytes;
    } on SecretBoxAuthenticationError {
      throw const FormatException('piece authentication failed');
    }
  }

  /// Datagram fallback unit. Manifest pieces may be tens of MiB, so the
  /// anonymous transport seals independently authenticated 2 KiB chunks and
  /// verifies the reassembled plaintext against the manifest piece hash.
  static Future<Uint8List> sealChunk({
    required CloudCapability capability,
    required int pieceIndex,
    required int chunkIndex,
    required Uint8List clear,
  }) async {
    final expected = chunkLength(capability, pieceIndex, chunkIndex);
    if (clear.length != expected) {
      throw ArgumentError('invalid clear chunk length');
    }
    final box = await _aead.encrypt(
      clear,
      secretKey: SecretKey(capability.key),
      nonce: _chunkNonce(capability.shareId, pieceIndex, chunkIndex),
      aad: _chunkAad(capability, pieceIndex, chunkIndex, expected),
    );
    return Uint8List(box.cipherText.length + 16)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
  }

  static Future<Uint8List> openChunk({
    required CloudCapability capability,
    required int pieceIndex,
    required int chunkIndex,
    required Uint8List sealed,
  }) async {
    final expected = chunkLength(capability, pieceIndex, chunkIndex);
    if (sealed.length != expected + 16) {
      throw const FormatException('invalid sealed chunk length');
    }
    final cut = sealed.length - 16;
    try {
      return Uint8List.fromList(
        await _aead.decrypt(
          SecretBox(
            Uint8List.sublistView(sealed, 0, cut),
            nonce: _chunkNonce(capability.shareId, pieceIndex, chunkIndex),
            mac: Mac(Uint8List.sublistView(sealed, cut)),
          ),
          secretKey: SecretKey(capability.key),
          aad: _chunkAad(capability, pieceIndex, chunkIndex, expected),
        ),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('chunk authentication failed');
    }
  }

  static int chunkCount(CloudCapability capability, int pieceIndex) {
    final length = capability.manifest.pieceLength(pieceIndex);
    return length == 0
        ? 0
        : (length + publicChunkBytes - 1) ~/ publicChunkBytes;
  }

  static int chunkLength(
    CloudCapability capability,
    int pieceIndex,
    int chunkIndex,
  ) {
    if (pieceIndex < 0 ||
        pieceIndex >= capability.manifest.pieceCount ||
        chunkIndex < 0) {
      throw ArgumentError('invalid piece/chunk index');
    }
    final pieceLength = capability.manifest.pieceLength(pieceIndex);
    final offset = chunkIndex * publicChunkBytes;
    if (offset >= pieceLength) throw ArgumentError('invalid chunk index');
    final remaining = pieceLength - offset;
    return remaining < publicChunkBytes ? remaining : publicChunkBytes;
  }

  static Uint8List _chunkNonce(
    Uint8List shareId,
    int pieceIndex,
    int chunkIndex,
  ) {
    final nonce = Uint8List(12)..setRange(0, 4, shareId);
    final data = ByteData.sublistView(nonce);
    data.setUint32(4, pieceIndex, Endian.big);
    data.setUint32(8, chunkIndex, Endian.big);
    return nonce;
  }

  static Uint8List _chunkAad(
    CloudCapability capability,
    int pieceIndex,
    int chunkIndex,
    int clearLength,
  ) =>
      (BytesBuilder(copy: false)
            ..add(utf8.encode('xveil.cloud.chunk.v1'))
            ..add(capability.shareId)
            ..add(_u32(capability.revision))
            ..add(_u32(pieceIndex))
            ..add(_u32(chunkIndex))
            ..add(_u32(clearLength))
            ..add(utf8.encode(capability.manifest.contentId)))
          .toBytes();

  static Uint8List _pieceNonce(Uint8List shareId, int index) {
    final nonce = Uint8List(12)..setRange(0, 4, shareId);
    ByteData.sublistView(nonce).setUint64(4, index, Endian.big);
    return nonce;
  }

  static Uint8List _pieceAad(CloudCapability capability, int pieceIndex) =>
      (BytesBuilder(copy: false)
            ..add(utf8.encode('xveil.cloud.piece.v1'))
            ..add(capability.shareId)
            ..add(_u32(capability.revision))
            ..add(_u32(pieceIndex))
            ..add(_u64(capability.manifest.size))
            ..add(utf8.encode(capability.manifest.contentId)))
          .toBytes();

  static Uint8List _aad(
    Uint8List shareId,
    Uint8List servicePublicKey,
    Uint8List appId,
    int endpointId,
    int expiresAtMs,
  ) =>
      (BytesBuilder(copy: false)
            ..add(_magic)
            ..add(shareId)
            ..add(servicePublicKey)
            ..add(appId)
            ..add(_u16(endpointId))
            ..add(_u64(expiresAtMs)))
          .toBytes();

  static Uint8List _randomBytes(Random random, int count) =>
      Uint8List.fromList([for (var i = 0; i < count; i++) random.nextInt(256)]);

  static void _require32(Uint8List bytes, String name) {
    if (bytes.length != 32) throw ArgumentError('$name must be 32 bytes');
  }

  static Uint8List _u16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);
  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);
  static Uint8List _u64(int value) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, value, Endian.big);
  static int _readU16(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint16(0, Endian.big);
  static int _readU32(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint32(0, Endian.big);
  static int _readU64(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint64(0, Endian.big);

  static bool _equal(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var diff = 0;
    for (var i = 0; i < left.length; i++) {
      diff |= left[i] ^ right[i];
    }
    return diff == 0;
  }
}
