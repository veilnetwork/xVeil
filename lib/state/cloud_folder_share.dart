import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
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
    int egressBudgetBytes = defaultEgressBudgetBytes,
    Duration egressWindow = defaultEgressWindow,
    int maxConcurrentServes = defaultMaxConcurrentServes,
    // ignore: prefer_initializing_formals
  }) : _send = send,
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _egressBudgetBytes = egressBudgetBytes,
       // ignore: prefer_initializing_formals
       _egressWindow = egressWindow,
       // ignore: prefer_initializing_formals
       _maxConcurrentServes = maxConcurrentServes {
    _ready = setListing(listing);
  }

  /// What one link may make this host EMIT, per window.
  ///
  /// A listing request is about 150 bytes and the reply is up to 256 KiB, so
  /// the listing op reflects roughly 1700 to 1. The MAC is no defence: it is
  /// keyed by the folder link, which every holder has and any of them may pass
  /// on, and the request names its own return endpoint — so the traffic lands
  /// wherever the requester says, and the host is the one sending it. Nothing
  /// counted, and nothing remembered a nonce, so one 150-byte datagram could
  /// be replayed as often as the attacker liked (audit XV-07).
  ///
  /// The report's remedy — bind the reply to an authenticated sender — is
  /// declined: a folder link is a BEARER capability on a deliberately
  /// anonymous path, and the identity that would make the reply attributable
  /// is exactly what that path exists not to have.
  ///
  /// The ceiling is set where legitimate use cannot reach it. Replies travel
  /// the anonymous onion path in 256-byte chunks over rendezvous circuits;
  /// 32 MiB a minute is around 2000 chunks a second, orders of magnitude
  /// beyond what that path delivers. A real download never notices this. A
  /// reflection tops out at roughly 128 listing replies a minute instead of
  /// however many the attacker cares to ask for.
  static const int defaultEgressBudgetBytes = 32 * 1024 * 1024;
  static const Duration defaultEgressWindow = Duration(minutes: 1);

  /// How many requests this host works on AT ONCE.
  ///
  /// The two defences above bound different things and neither bounds this
  /// one. The nonce cache stops a datagram being replayed; the egress budget
  /// stops a big reply being reflected. Many SMALL requests, each with a fresh
  /// nonce, pass both — and every one of them was started immediately by the
  /// endpoint listener, which fires them off unawaited. Each carries a
  /// container read, an AEAD seal and a send over an anonymous circuit, so
  /// tens of thousands can be in progress at once with the byte budget barely
  /// touched.
  ///
  /// Requests past the ceiling are DROPPED, not queued: this path is
  /// deliberately lossy and unattributable, a queue would be the same
  /// accumulation under another name, and a real client retries. Eight at once
  /// is far above what the onion path delivers to one share and far below what
  /// costs anything.
  static const int defaultMaxConcurrentServes = 8;

  /// Nonces of requests already ANSWERED, bounded FIFO — the shape the group
  /// content path uses (see `authorizeGroupContentRequest`). Only MAC-valid
  /// requests reach it, so an outsider cannot fill it to push a real client's
  /// nonce out.
  static const int maxSeenNonces = 512;

  /// Completes once the initial listing has been sealed, and FAILS if it could
  /// not be — the create path wants that failure. [serve] does not use this:
  /// see [_settled].
  Future<void> get ready => _ready;
  Future<void> _ready = Future.value();

  /// The gate [serve] waits on, ordered behind whatever seal is in flight.
  ///
  /// It never completes with an error, and that is the whole point. `serve`
  /// used to await the same future the caller did, so a listing that could not
  /// be sealed did not merely fail to publish — it left a REJECTED future in
  /// the serving path and the host stopped answering anything at all, the
  /// previously published listing included. A share that had been serving
  /// happily went silent because of a listing it never accepted (audit XV-18).
  Future<void> _settled = Future.value();

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

  final int _egressBudgetBytes;
  final Duration _egressWindow;
  final Set<String> _seenNonces = <String>{};
  DateTime? _windowStart;
  int _spentBytes = 0;

  int get revision => _listing.revision;

  /// Whether this nonce is new, remembering it if so.
  ///
  /// Called only after the MAC verifies, so what it bounds is a HOLDER
  /// replaying its own authentic request — the cheapest form of the
  /// reflection, since it costs the attacker nothing to produce.
  bool _freshNonce(Uint8List nonce) {
    final key = _contentIdHex(nonce);
    if (!_seenNonces.add(key)) return false;
    if (_seenNonces.length > maxSeenNonces) {
      _seenNonces.remove(_seenNonces.first);
    }
    return true;
  }

  /// Charge [bytes] against this share's egress budget, or refuse.
  ///
  /// A tumbling window rather than anything cleverer: the point is a ceiling
  /// that legitimate use cannot reach, not fair queueing.
  bool _charge(int bytes) {
    final now = _now();
    final start = _windowStart;
    if (start == null || now.difference(start) >= _egressWindow) {
      _windowStart = now;
      _spentBytes = 0;
    }
    if (_spentBytes + bytes > _egressBudgetBytes) return false;
    _spentBytes += bytes;
    return true;
  }

  /// Replace the served listing. The new revision must not go backwards.
  ///
  /// ALL OR NOTHING. Nothing about what this host serves moves until the new
  /// listing has actually been sealed: the size ceiling lives on the
  /// CIPHERTEXT, so a listing that passed every structural check can still be
  /// refused here. A refusal leaves the previously published revision in place
  /// and serving, and is reported to the caller through the returned future —
  /// never through the serving path.
  Future<void> setListing(CloudFolderListing listing) {
    final previous = _settled;
    // An immediately-invoked closure, NOT `Future(...)`: the latter defers the
    // body onto a timer, which a widget test's fake clock never fires — the
    // seal then never happened and every caller waited forever.
    final work = () async {
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
    // Registering the handler here also marks [work]'s error as handled, so a
    // caller that awaits it still sees the throw and one that does not cannot
    // raise an unhandled async error.
    _settled = work.then((_) {}, onError: (_) {});
    return _ready = work;
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
    // Admission first: the work below is what has to be bounded, and the
    // caller starts every MAC-valid datagram unawaited.
    if (_servesInFlight >= _maxConcurrentServes) return;
    _servesInFlight++;
    try {
      // An expired link is served the same silent denial as a bad MAC — the
      // holder has the folder key but the capability is no longer valid.
      if (_now().millisecondsSinceEpoch >= capability.expiresAtMs) return;
      // Answer against the latest published listing, never a half-sealed one.
      // [_settled] and not [ready]: a listing this host REFUSED must not take
      // the one it already publishes down with it.
      await _settled;
      final listing = _ListingRequest.parse(wire);
      if (listing != null) {
        await _serveListing(listing);
        return;
      }
      final file = _FolderFileRequest.parse(wire);
      if (file != null) await _serveFile(file);
    } catch (_) {
    } finally {
      _servesInFlight--;
    }
  }

  /// Requests being worked on right now — see [defaultMaxConcurrentServes].
  int get servesInFlight => _servesInFlight;
  int _servesInFlight = 0;
  final int _maxConcurrentServes;

  Future<void> _serveListing(_ListingRequest request) async {
    if (!_equal(request.shareId, capability.shareId)) return;
    // Nothing has ever been published here — a host restored over a stored
    // listing that would not seal. Silence is the honest answer; an empty
    // sealed body is not a listing and the client rejects it anyway.
    if (_sealedListing.isEmpty) return;
    final expected = CloudCapabilityCodec.listingRequestMac(
      capability: capability,
      returnServicePublicKey: request.returnServicePublicKey,
      returnAppId: request.returnAppId,
      returnEndpointId: request.returnEndpointId,
      requestNonce: request.nonce,
    );
    if (!_equal(expected, request.mac)) return;
    // Authenticated, and only now may it cost anything. A replay of a request
    // already answered gets the same silence as a bad MAC.
    if (!_freshNonce(request.nonce)) return;
    final response = _ListingResponse(
      shareId: capability.shareId,
      nonce: request.nonce,
      revision: _listing.revision,
      sealed: _sealedListing,
    ).encode();
    if (!_charge(response.length)) return;
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
    if (!_freshNonce(request.nonce)) return;
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
    final response = _folderChunkResponse(
      shareId: capability.shareId,
      contentId: request.contentId,
      pieceIndex: request.pieceIndex,
      chunkIndex: request.chunkIndex,
      nonce: request.nonce,
      sealed: sealed,
    );
    // A chunk reply is about the size of its request, so this op reflects
    // nothing — but it is egress from the same share, and a budget that only
    // watched the listing would be a budget an attacker walks around.
    if (!_charge(response.length)) return;
    await _send(
      servicePublicKey: request.returnServicePublicKey,
      targetAppId: request.returnAppId,
      targetEndpointId: request.returnEndpointId,
      data: response,
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

/// The default nonce source, exposed so a test can assert what an omitted
/// argument actually costs.
@visibleForTesting
Uint8List debugDefaultShareRandom(int count) =>
    CloudFolderShareClient._defaultRandom(count);

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

  /// Extra attempts per chunk. Two is what the member-content path measured as
  /// enough for the observed drop rate; a third only lengthened the failure.
  static const int _chunkRetries = 2;
  final Uint8List Function(int count) _randomBytes;

  // Default zero-filled nonce source; real callers pass a CSPRNG generator.
  /// The default source of nonces (audit report10 X-11).
  ///
  /// This used to return `Uint8List(count)` — a buffer of ZEROS. The
  /// production caller passes a CSPRNG, so nothing was broken; what was broken
  /// was the shape. A parameter that is optional and silently degrades to a
  /// constant hands the next caller repeated nonces, correlation across
  /// requests and a replay window, with nothing anywhere to notice it by.
  ///
  /// `Random.secure` is the floor, not the intent: callers should still pass
  /// the same generator the rest of the stack uses. But an omitted argument
  /// now costs a slightly different source of randomness rather than none.
  static Uint8List _defaultRandom(int count) {
    final rng = Random.secure();
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }

  /// The listing is exposed to the same silent drop as a chunk, and it is
  /// asked for first — so losing it loses the whole download before a single
  /// byte moves. Same budget per attempt, same reason to ask again.
  Future<CloudFolderListing> fetchListing() async {
    Object? lastError;
    for (var attempt = 0; attempt <= _chunkRetries; attempt++) {
      try {
        return await _attemptListing();
      } on TimeoutException catch (error) {
        lastError = error;
      }
    }
    throw lastError!;
  }

  Future<CloudFolderListing> _attemptListing() async {
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
        .first;
    // The matcher has to be listening before the request goes out, but the
    // budget must not start until it has: building the anonymous circuit is
    // part of the send, and charging the wait for a reply with the cost of
    // arranging one burned most of the window before anyone could answer.
    Object? sendError;
    try {
      await _send(request.encode());
    } catch (error) {
      sendError = error;
    }
    if (sendError != null) {
      unawaited(pending.timeout(_timeout).then((_) {}, onError: (_) {}));
      throw sendError;
    }
    final response = await pending.timeout(_timeout);
    return CloudCapabilityCodec.openListing(
      capability: capability,
      revision: response.revision,
      sealed: response.sealed,
    );
  }

  /// Fetch and verify one file named by a listing entry, returning all of it
  /// at once.
  ///
  /// Holds the whole file in memory. Prefer [fetchFileStreaming] for anything
  /// a person picked off a shared folder — the size is whatever the sharer
  /// says it is.
  Future<Uint8List> fetchFile(CloudFolderListingEntry entry) async {
    final assembled = BytesBuilder(copy: false);
    await fetchFileStreaming(entry, (_, bytes) async => assembled.add(bytes));
    return assembled.toBytes();
  }

  /// Stream the file, handing each piece to [onPiece] once its hash is
  /// verified, and return the total byte count.
  ///
  /// Nothing is retained here: peak memory is one piece plus whatever the sink
  /// keeps. The whole-file twin above grew to the size of the file before a
  /// single byte was persisted, so tapping Download on a large entry in a
  /// shared folder took the app out on a phone — and the only ceiling anywhere
  /// on the path is a 1 PiB sanity check in the manifest (report6 XV-08). The
  /// member-content client has had this shape for a while; the folder client
  /// was the one path still assembling.
  ///
  /// A piece is passed on only AFTER its hash is checked, so a sink may write
  /// it out immediately: unverified bytes never escape.
  Future<int> fetchFileStreaming(
    CloudFolderListingEntry entry,
    Future<void> Function(int pieceIndex, Uint8List bytes) onPiece, {
    void Function(int received, int total)? onProgress,
  }) async {
    final fileCapability = CloudCapabilityCodec.folderFileCapability(
      capability,
      entry,
    );
    final manifest = fileCapability.manifest;
    final contentIdBytes = _contentIdBytes(manifest.contentId);
    var received = 0;
    for (var piece = 0; piece < manifest.pieceCount; piece++) {
      final clearPiece = BytesBuilder(copy: false);
      final chunks = CloudCapabilityCodec.chunkCount(fileCapability, piece);
      for (var chunk = 0; chunk < chunks; chunk++) {
        final clear = await _fetchChunk(
          fileCapability,
          contentIdBytes,
          piece,
          chunk,
        );
        received += clear.length;
        clearPiece.add(clear);
        onProgress?.call(received, manifest.size);
      }
      final bytes = clearPiece.toBytes();
      if (!manifest.verifyPiece(piece, bytes)) {
        throw StateError('folder file piece hash mismatch');
      }
      await onPiece(piece, bytes);
    }
    return received;
  }

  /// One chunk, retried when the anonymous path drops the request.
  ///
  /// A send along that path occasionally never arrives, with no error to see.
  /// Without a retry a single drop discarded the whole file — every chunk
  /// already fetched included — which is a poor trade against asking twice.
  /// Each attempt is a fresh nonce, so a late reply to an abandoned attempt
  /// cannot be mistaken for the answer to this one.
  Future<Uint8List> _fetchChunk(
    CloudCapability fileCapability,
    Uint8List contentIdBytes,
    int piece,
    int chunk,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _chunkRetries; attempt++) {
      try {
        return await _attemptChunk(
          fileCapability,
          contentIdBytes,
          piece,
          chunk,
        );
      } on TimeoutException catch (error) {
        lastError = error;
      }
    }
    throw lastError!;
  }

  Future<Uint8List> _attemptChunk(
    CloudCapability fileCapability,
    Uint8List contentIdBytes,
    int piece,
    int chunk,
  ) async {
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
        .first;
    // Same reason as the listing above: the clock starts at the send.
    Object? sendError;
    try {
      await _send(request.encode());
    } catch (error) {
      sendError = error;
    }
    if (sendError != null) {
      // Nothing was asked for, so nothing will answer. Drain the matcher
      // so it cannot outlive this attempt as an unhandled error.
      unawaited(pending.timeout(_timeout).then((_) {}, onError: (_) {}));
      throw sendError;
    }
    final response = await pending.timeout(_timeout);
    return CloudCapabilityCodec.openChunk(
      capability: fileCapability,
      pieceIndex: piece,
      chunkIndex: chunk,
      sealed: response.sealed,
    );
  }
}
