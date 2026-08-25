import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'file_names.dart';

/// A content-addressed, hash-verified file manifest — the "torrent file" of the
/// decentralized content layer. A file is split into fixed-size PIECES; each
/// piece has a SHA-256 hash, and the whole manifest hashes to a [contentId] that
/// SELF-AUTHENTICATES the file: anyone who knows the contentId can verify (a) the
/// manifest is intact (re-hash it → contentId) and (b) every received piece
/// against its listed hash — so pieces arrive in ANY order, over a lossy relayed
/// datagram path, and integrity of both each PIECE and the WHOLE is provable
/// without trusting the sender or the relays.
///
/// Two granularities: a PIECE ([pieceSize], the hash-verified unit, e.g. 256 KiB)
/// is transferred as many small wire CHUNKS (datagrams ≤ the auth_deliver cap);
/// the receiver reassembles a piece from its chunks, verifies its hash, and
/// re-requests only the chunks of pieces that fail or are missing (BitTorrent-
/// style). Identical name+content yields an identical contentId (dedup + swarm).
class ContentManifest {
  ContentManifest({
    required this.name,
    required this.size,
    required this.pieceSize,
    required this.pieceHashes,
    required this.contentId,
    this.chunkBytes = defaultChunkBytes,
    this.msgId,
    this.author,
    this.seq,
    this.ts,
    this.thumbB64,
  });

  /// Original file name (authenticated — folded into [contentId]).
  final String name;

  /// Total plaintext byte length.
  final int size;

  /// Bytes per piece (the last piece may be shorter). The hash-verified unit.
  final int pieceSize;

  /// SHA-256 of each piece, in order. `pieceHashes.length` == ceil(size/pieceSize).
  final List<Uint8List> pieceHashes;

  /// Hex SHA-256 over the canonical manifest encoding — the file's self-
  /// authenticating address. Recompute via [computeContentId] to verify.
  final String contentId;

  /// The WIRE chunk size: a piece is transferred as `chunkCount(piece)` chunks
  /// of this many bytes (the last chunk of a piece may be shorter). NOT folded
  /// into [contentId] — it's a transport hint, so the same file keeps one id
  /// regardless of chunking (swarm/dedup), and a tampered value only fails the
  /// transfer (pieces stay hash-verified). The receiver derives each piece's
  /// chunk count from it, so it can re-request specific MISSING chunks from the
  /// first round (without first receiving any chunk of the piece).
  final int chunkBytes;

  /// The sender's per-SEND message id (uuid) — the EVENT identity of this file
  /// post, decoupled from [contentId] (which addresses the BYTES). UNBOUND (not
  /// folded into contentId), so re-sending identical bytes yields the SAME
  /// contentId (blob dedup) but a DISTINCT msgId: a new filePost event that
  /// surfaces even if a prior identical send was deleted — "deleted never
  /// resurrects" binds the (author,seq) EVENT, not the byte-hash. Null only from
  /// a legacy sender, in which case the receiver falls back to the contentId path.
  final String? msgId;

  /// The sender's event author (node-id hex, R1) + per-(conv,author) gap-free
  /// [seq] for this file post — carried so the receiver folds the filePost as a
  /// first-class log event (surface/dedup/order by (author,seq)), exactly like
  /// the small-file fileMeta path already does. UNBOUND (not in contentId).
  final String? author;
  final int? seq;

  /// The sender's send-time (ms since epoch) for THIS file post — carried so the
  /// receiver folds it with the SAME timestamp on every device (convergent
  /// display order), mirroring fileMeta's `sentAtMs`. UNBOUND (not in contentId).
  final int? ts;

  /// Micro-thumbnail of an IMAGE file (base64 of a tiny PNG, budget-bound at
  /// send so the advert frame still fits one datagram) — renders on the
  /// receiver BEFORE the blob is downloaded. UNBOUND (not in contentId): the
  /// same bytes keep one contentId whether or not the sender attached a thumb,
  /// and a tampered thumb can only mislead a preview, never the verified blob.
  final String? thumbB64;

  /// Default piece size: 256 KiB — keeps the manifest small (a 256 MiB file is
  /// 1024 × 32 B = 32 KiB of hashes) while bounding per-piece re-request cost.
  static const int defaultPieceSize = 256 * 1024;

  /// Default wire chunk size. Small on purpose: over a lossy onion path a chunk
  /// fragments into ceil(chunk/≈150 B) cells that must ALL arrive (no per-cell
  /// ARQ), so fewer cells per chunk ⇒ far higher per-chunk delivery odds, which
  /// is what lets a piece's chunks accumulate across re-request rounds.
  static const int defaultChunkBytes = 256;

  /// RAM-bounded piece sizing shared by chat and personal-cloud ingestion.
  /// Keep ordinary manifests at 256 KiB pieces, then widen only enough to cap
  /// the hash list near 4096 pieces, with a hard 32 MiB RAM ceiling per piece.
  /// Beyond that the piece count grows; a ~1 TiB object still has a manifest
  /// small enough for the deniable file store.
  /// Hard RAM ceiling for one piece. A piece is held whole while it is
  /// verified, so this is the largest allocation one manifest can ask a
  /// receiver for. Shared with [fromJson] deliberately: the value that bounds
  /// what WE send is the value that bounds what we accept, so the two cannot
  /// drift into a sender-generous/receiver-trusting pair.
  static const int maxPieceBytes = 32 * 1024 * 1024;

  /// The most wire chunks one piece may be cut into — what the sender's own
  /// pairing (32 MiB pieces, 256 B chunks) produces at its extreme. The
  /// per-piece missing-chunk bitmap is one bit per chunk, so this is also the
  /// bound on that allocation: without it a manifest declaring 1-byte chunks
  /// over a 32 MiB piece asks for a 4 MiB bitmap per piece, chosen entirely by
  /// whoever sent it.
  static const int maxChunksPerPiece = maxPieceBytes ~/ defaultChunkBytes;

  static int adaptivePieceSize(int size) {
    const maxPieces = 4096;
    final needed = (size + maxPieces - 1) ~/ maxPieces;
    if (needed <= defaultPieceSize) return defaultPieceSize;
    return needed > maxPieceBytes ? maxPieceBytes : needed;
  }

  int get pieceCount => pieceHashes.length;

  /// The plaintext length of piece [index] (the last piece may be short).
  int pieceLength(int index) {
    final start = index * pieceSize;
    final end = start + pieceSize;
    return (end <= size ? pieceSize : size - start);
  }

  /// Number of wire chunks piece [index] is split into.
  int chunkCount(int index) {
    final plen = pieceLength(index);
    return plen == 0 ? 0 : (plen + chunkBytes - 1) ~/ chunkBytes;
  }

  /// Build a manifest from a file's full bytes.
  factory ContentManifest.fromBytes(
    String name,
    Uint8List bytes, {
    int pieceSize = defaultPieceSize,
    int chunkBytes = defaultChunkBytes,
  }) {
    if (pieceSize <= 0) {
      throw ArgumentError.value(pieceSize, 'pieceSize', '> 0');
    }
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', '> 0');
    }
    final count = bytes.isEmpty
        ? 0
        : (bytes.length + pieceSize - 1) ~/ pieceSize;
    final hashes = <Uint8List>[
      for (var i = 0; i < count; i++)
        _hash(
          Uint8List.sublistView(
            bytes,
            i * pieceSize,
            (i * pieceSize + pieceSize) <= bytes.length
                ? i * pieceSize + pieceSize
                : bytes.length,
          ),
        ),
    ];
    final id = computeContentId(
      name: name,
      size: bytes.length,
      pieceSize: pieceSize,
      pieceHashes: hashes,
    );
    return ContentManifest(
      name: name,
      size: bytes.length,
      pieceSize: pieceSize,
      pieceHashes: hashes,
      contentId: id,
      chunkBytes: chunkBytes,
    );
  }

  /// Build a manifest by reading the source piece-by-piece via [readRange] —
  /// never holding more than TWO pieces in RAM (the next read is prefetched
  /// while the current piece hashes). For files too large to fit in memory
  /// (the in-RAM [fromBytes] would OOM first). [readRange] returns exactly
  /// [length] bytes at byte [offset] of the source; [size] is its total length.
  ///
  /// Produces the SAME [contentId] as [fromBytes] for identical bytes — the id
  /// binds the per-PIECE hashes (not the raw bytes), and each piece is hashed the
  /// same way — so a streamed send and an in-RAM send of the same file dedup to
  /// one blob and one swarm address.
  static Future<ContentManifest> fromReader({
    required String name,
    required int size,
    required Future<Uint8List> Function(int offset, int length) readRange,
    int pieceSize = defaultPieceSize,
    int chunkBytes = defaultChunkBytes,
  }) async {
    if (pieceSize <= 0) {
      throw ArgumentError.value(pieceSize, 'pieceSize', '> 0');
    }
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', '> 0');
    }
    final count = size <= 0 ? 0 : (size + pieceSize - 1) ~/ pieceSize;
    final hashes = <Uint8List>[];
    int lengthAt(int i) {
      final start = i * pieceSize;
      return (start + pieceSize <= size) ? pieceSize : size - start;
    }

    // Prefetch the NEXT piece before hashing the current one, so the disk read
    // (async I/O off the isolate) overlaps the synchronous hash. Holds at most
    // TWO pieces in RAM. Serialized sources (veilSourceOpener's gate) just
    // queue the second read; the overlap with hashing is preserved either way.
    Future<Uint8List>? next = count > 0 ? readRange(0, lengthAt(0)) : null;
    try {
      for (var i = 0; i < count; i++) {
        final len = lengthAt(i);
        final piece = await next!;
        next = i + 1 < count
            ? readRange((i + 1) * pieceSize, lengthAt(i + 1))
            : null;
        if (piece.length != len) {
          throw StateError(
            'short read at piece $i: got ${piece.length}, want $len',
          );
        }
        hashes.add(_hash(piece));
      }
    } catch (_) {
      next?.ignore(); // orphaned prefetch must not surface as unhandled
      rethrow;
    }
    final id = computeContentId(
      name: name,
      size: size,
      pieceSize: pieceSize,
      pieceHashes: hashes,
    );
    return ContentManifest(
      name: name,
      size: size,
      pieceSize: pieceSize,
      pieceHashes: hashes,
      contentId: id,
      chunkBytes: chunkBytes,
    );
  }

  /// A copy stamped with the event-identity of ONE send (msgId/author/seq)
  /// WITHOUT re-hashing — [contentId] and [pieceHashes] are reused unchanged
  /// (those fields are unbound). Used by the send path to mint the manifest once
  /// (from bytes) then attach the (author,seq) the storage layer just allocated.
  ContentManifest withEvent({
    String? msgId,
    String? author,
    int? seq,
    int? ts,
    String? thumbB64,
  }) => ContentManifest(
    name: name,
    size: size,
    pieceSize: pieceSize,
    pieceHashes: pieceHashes,
    contentId: contentId,
    chunkBytes: chunkBytes,
    msgId: msgId ?? this.msgId,
    author: author ?? this.author,
    seq: seq ?? this.seq,
    ts: ts ?? this.ts,
    thumbB64: thumbB64 ?? this.thumbB64,
  );

  /// Canonical, deterministic content id: hex SHA-256 over
  /// `len(name)|name|size|pieceSize|count|hash0|hash1|…`. Any change to the name,
  /// length, chunking, or a single piece hash changes the id — so the id binds
  /// the entire file. (Length-prefixing the name prevents ambiguous concatenation.)
  static String computeContentId({
    required String name,
    required int size,
    required int pieceSize,
    required List<Uint8List> pieceHashes,
  }) {
    final nameBytes = utf8.encode(name);
    final out = BytesBuilder(copy: false);
    out.add(_u32le(nameBytes.length));
    out.add(nameBytes);
    out.add(_u64le(size));
    out.add(_u32le(pieceSize));
    out.add(_u32le(pieceHashes.length));
    for (final h in pieceHashes) {
      out.add(h);
    }
    return _hex(_hash(out.toBytes()));
  }

  /// Re-derive the content id from this manifest's fields — must equal
  /// [contentId] for the manifest to be trusted (tamper-evident).
  bool get isSelfConsistent =>
      computeContentId(
        name: name,
        size: size,
        pieceSize: pieceSize,
        pieceHashes: pieceHashes,
      ) ==
      contentId;

  /// True if [pieceBytes] is the genuine piece at [index] (length + hash match).
  bool verifyPiece(int index, Uint8List pieceBytes) {
    if (index < 0 || index >= pieceCount) return false;
    if (pieceBytes.length != pieceLength(index)) return false;
    final h = _hash(pieceBytes);
    final want = pieceHashes[index];
    if (h.length != want.length) return false;
    for (var i = 0; i < h.length; i++) {
      if (h[i] != want[i]) return false;
    }
    return true;
  }

  /// Verify a fully reassembled file: exact size + every piece hash. Definitive
  /// integrity of the WHOLE (a corrupt or substituted file is rejected even if
  /// each piece individually verified against a forged manifest — because the
  /// manifest itself is bound to [contentId]).
  bool verifyWhole(Uint8List bytes) {
    if (bytes.length != size) return false;
    for (var i = 0; i < pieceCount; i++) {
      final start = i * pieceSize;
      final end = start + pieceLength(i);
      if (!verifyPiece(i, Uint8List.sublistView(bytes, start, end))) {
        return false;
      }
    }
    return true;
  }

  /// JSON form for storage / the wire. Piece hashes are concatenated as one hex
  /// blob (32 B each) to keep it compact.
  Map<String, dynamic> toJson() => {
    'id': contentId,
    'name': name,
    'size': size,
    'ps': pieceSize,
    'cb': chunkBytes,
    'ph': _hex(_concatHashes(pieceHashes)),
    // Event-identity of THIS send (unbound — absent from contentId). Lets the
    // receiver fold a first-class filePost (author,seq) under a per-send msgId
    // so a re-send surfaces as a NEW message (A) while bytes dedup by contentId.
    if (msgId != null) 'mid': msgId,
    if (author != null) 'au': author,
    if (seq != null) 'sq': seq,
    if (ts != null) 'mts': ts,
    // Unbound micro-thumb (see [thumbB64]) — additive, ignored by old builds.
    if (thumbB64 != null) 'th': thumbB64,
  };

  /// Parse + validate a manifest. Returns null if malformed or NOT self-
  /// consistent (its fields don't hash to its declared id) — never trust an
  /// inconsistent manifest.
  static ContentManifest? fromJson(Map<String, dynamic> j) {
    try {
      final id = j['id'] as String;
      final name = j['name'] as String;
      // A DISPLAY name, and nothing else. It reaches `Message.fileName` and
      // from there the places that offer to save the file, one of which used
      // it as a path component and deleted that path's parent afterwards
      // (report14 X14-H1). The uses were fixed; this refuses the input as
      // well, because every sender in this project takes the last segment of
      // a path, so a name carrying a separator, a control character or a
      // directory alias is not something an honest peer produces.
      //
      // Refusing costs the whole transfer, which is the right price: the name
      // is bound into `contentId`, so it cannot be corrected here without
      // breaking the self-consistency check that makes the manifest
      // tamper-evident.
      if (!isSafeFileLabel(name)) return null;
      final size = j['size'] as int;
      final ps = j['ps'] as int;
      // chunkBytes is a transport hint (not in contentId); tolerate an older
      // sender that omits it by falling back to the default. Reject a nonsense
      // value so chunk indexing can't divide by zero — and the same for
      // pieceSize/size, which drive offset math and allocations downstream.
      final cb = (j['cb'] as int?) ?? defaultChunkBytes;
      if (cb <= 0 || ps <= 0 || size < 0) return null;
      // GEOMETRY. Self-consistency proves only that the manifest hashes to its
      // own id — which its author computed, so it says nothing about whether
      // the numbers agree with each other. They have to be checked here:
      //
      //  * `pieceCount` is `pieceHashes.length`, and that alone decides when a
      //    transfer is complete, while `size` is what the receiver shows and
      //    writes. Nothing tied them together, so a manifest declaring 2 MiB
      //    with 256 KiB pieces and ONE hash was accepted and the transfer
      //    reported 1/1 complete — stored and ACKed — after 256 KiB.
      //  * `pieceSize` and `chunkBytes` are chosen by the sender and drive
      //    receiver-side allocations: a whole piece in RAM, and a
      //    one-bit-per-chunk bitmap. Unbounded, they are a memory amplifier
      //    that costs the sender nothing to write down.
      //
      // The ceilings are the sender's own ([maxPieceBytes], and the chunk
      // count its default pairing produces), so nothing this project emits is
      // rejected — only manifests no honest sender here would author.
      if (ps > maxPieceBytes) return null;
      if (cb > ps || ps ~/ cb > maxChunksPerPiece) return null;
      // The content id encodes pieceSize and the hash count with _u32le, which
      // truncates silently. A value past 32 bits therefore does NOT appear in
      // the id it is supposed to bind, and two manifests differing by 2^32
      // share one canonical encoding without anyone breaking SHA-256.
      if (ps > 0xffffffff) return null;
      final blob = _unhex(j['ph'] as String);
      if (blob.length % 32 != 0) return null;
      final hashes = <Uint8List>[
        for (var i = 0; i < blob.length; i += 32)
          Uint8List.sublistView(blob, i, i + 32),
      ];
      if (hashes.length > 0xffffffff) return null;
      final expectedPieces = size == 0 ? 0 : (size + ps - 1) ~/ ps;
      if (hashes.length != expectedPieces) return null;
      final m = ContentManifest(
        name: name,
        size: size,
        pieceSize: ps,
        pieceHashes: hashes,
        contentId: id,
        chunkBytes: cb,
        // Unbound event-identity (a legacy sender omits these → null, and the
        // receiver falls back to the contentId-keyed path). NOT validated by
        // isSelfConsistent — they don't participate in contentId.
        msgId: j['mid'] as String?,
        author: j['au'] as String?,
        seq: j['sq'] as int?,
        ts: j['mts'] as int?,
        thumbB64: j['th'] as String?,
      );
      return m.isSelfConsistent ? m : null;
    } catch (_) {
      return null;
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────
  /// Pluggable SHA-256: the app injects the native FFI digest at startup
  /// (~30-50x the pure-Dart rate — with `package:crypto`'s ~35 MB/s a phone
  /// spent ~1.8 s hashing a 64 MiB file BEFORE its offer could even go out,
  /// the single largest fixed cost of a send). Tests and non-FFI contexts run
  /// on the pure-Dart default; both produce identical digests, so contentIds
  /// (and therefore dedup) are unaffected by which one hashed.
  static Uint8List Function(Uint8List)? sha256Override;

  /// SHA-256 (32 B) over any-length input — content addressing. (The bundled
  /// blake3.dart is single-chunk only and can't hash multi-KiB pieces.)
  static Uint8List _hash(Uint8List b) =>
      sha256Override?.call(b) ??
      Uint8List.fromList(crypto.sha256.convert(b).bytes);

  static Uint8List _concatHashes(List<Uint8List> hs) {
    final out = Uint8List(hs.length * 32);
    for (var i = 0; i < hs.length; i++) {
      out.setRange(i * 32, i * 32 + 32, hs[i]);
    }
    return out;
  }

  static Uint8List _u32le(int v) => Uint8List.fromList([
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);

  static Uint8List _u64le(int v) {
    final b = Uint8List(8);
    var x = v;
    for (var i = 0; i < 8; i++) {
      b[i] = x & 0xff;
      x >>= 8;
    }
    return b;
  }

  static String _hex(Uint8List b) {
    const d = '0123456789abcdef';
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(d[(x >> 4) & 0xf]);
      sb.write(d[x & 0xf]);
    }
    return sb.toString();
  }

  static Uint8List _unhex(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
