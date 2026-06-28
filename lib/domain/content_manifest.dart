import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

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

  /// Default piece size: 256 KiB — keeps the manifest small (a 256 MiB file is
  /// 1024 × 32 B = 32 KiB of hashes) while bounding per-piece re-request cost.
  static const int defaultPieceSize = 256 * 1024;

  /// Default wire chunk size. Small on purpose: over a lossy onion path a chunk
  /// fragments into ceil(chunk/≈150 B) cells that must ALL arrive (no per-cell
  /// ARQ), so fewer cells per chunk ⇒ far higher per-chunk delivery odds, which
  /// is what lets a piece's chunks accumulate across re-request rounds.
  static const int defaultChunkBytes = 256;

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
    if (pieceSize <= 0) throw ArgumentError.value(pieceSize, 'pieceSize', '> 0');
    if (chunkBytes <= 0) throw ArgumentError.value(chunkBytes, 'chunkBytes', '> 0');
    final count = bytes.isEmpty ? 0 : (bytes.length + pieceSize - 1) ~/ pieceSize;
    final hashes = <Uint8List>[
      for (var i = 0; i < count; i++)
        _hash(Uint8List.sublistView(
            bytes, i * pieceSize,
            (i * pieceSize + pieceSize) <= bytes.length
                ? i * pieceSize + pieceSize
                : bytes.length)),
    ];
    final id = computeContentId(
        name: name, size: bytes.length, pieceSize: pieceSize, pieceHashes: hashes);
    return ContentManifest(
      name: name,
      size: bytes.length,
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
  ContentManifest withEvent(
          {String? msgId, String? author, int? seq, int? ts}) =>
      ContentManifest(
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
          pieceHashes: pieceHashes) ==
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
      if (!verifyPiece(i, Uint8List.sublistView(bytes, start, end))) return false;
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
      };

  /// Parse + validate a manifest. Returns null if malformed or NOT self-
  /// consistent (its fields don't hash to its declared id) — never trust an
  /// inconsistent manifest.
  static ContentManifest? fromJson(Map<String, dynamic> j) {
    try {
      final id = j['id'] as String;
      final name = j['name'] as String;
      final size = j['size'] as int;
      final ps = j['ps'] as int;
      // chunkBytes is a transport hint (not in contentId); tolerate an older
      // sender that omits it by falling back to the default. Reject a nonsense
      // value so chunk indexing can't divide by zero.
      final cb = (j['cb'] as int?) ?? defaultChunkBytes;
      if (cb <= 0) return null;
      final blob = _unhex(j['ph'] as String);
      if (blob.length % 32 != 0) return null;
      final hashes = <Uint8List>[
        for (var i = 0; i < blob.length; i += 32)
          Uint8List.sublistView(blob, i, i + 32),
      ];
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
          ts: j['mts'] as int?);
      return m.isSelfConsistent ? m : null;
    } catch (_) {
      return null;
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────
  /// SHA-256 (32 B) over any-length input — content addressing. (The bundled
  /// blake3.dart is single-chunk only and can't hash multi-KiB pieces.)
  static Uint8List _hash(Uint8List b) =>
      Uint8List.fromList(crypto.sha256.convert(b).bytes);

  static Uint8List _concatHashes(List<Uint8List> hs) {
    final out = Uint8List(hs.length * 32);
    for (var i = 0; i < hs.length; i++) {
      out.setRange(i * 32, i * 32 + 32, hs[i]);
    }
    return out;
  }

  static Uint8List _u32le(int v) =>
      Uint8List.fromList([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

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
