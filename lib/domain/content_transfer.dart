import 'dart:typed_data';

import 'content_manifest.dart';

/// Receiver-side reassembly of a content transfer (the BitTorrent-style core).
/// Buffers the wire CHUNKS of each PIECE; when a piece is complete it is verified
/// against the manifest hash and kept, or — if the hash fails — dropped so it can
/// be re-requested. The MANIFEST is the authority for how many chunks each piece
/// has ([ContentManifest.chunkCount]), so the receiver knows exactly which chunks
/// are missing even before it has seen any chunk of a piece — enabling a precise,
/// CHUNK-granular re-request (only the gaps, not whole pieces) which is what lets
/// a transfer converge over a high-loss onion path. Order- and duplicate-tolerant.
/// [assemble] returns the fully verified whole.
///
/// v1 holds verified pieces in memory (fine up to RAM-sized files); streaming
/// each verified piece straight to the on-disk blob store is a later optimization.
class ContentTransfer {
  ContentTransfer(this.manifest);

  final ContentManifest manifest;

  /// pieceIndex → {chunkIndex: chunkBytes} for not-yet-verified pieces.
  final Map<int, Map<int, Uint8List>> _chunks = {};

  /// pieceIndex → the assembled, hash-verified piece bytes.
  final Map<int, Uint8List> _verifiedPieces = {};
  final Set<int> _verified = {};

  int get pieceCount => manifest.pieceCount;
  int get verifiedCount => _verified.length;
  bool get isComplete => _verified.length == manifest.pieceCount;
  bool isVerified(int pieceIndex) => _verified.contains(pieceIndex);

  /// Ingest one received chunk. Returns true iff this chunk COMPLETED and
  /// VERIFIED its piece (so the caller can update progress). The chunk's
  /// coordinates are validated against the MANIFEST (the chunk-count authority),
  /// so a garbled / hostile count, an out-of-range index, or a chunk for an
  /// already-verified piece is ignored.
  bool addChunk(int pieceIndex, int chunkIndex, int chunkCount, Uint8List data) {
    if (pieceIndex < 0 || pieceIndex >= manifest.pieceCount) return false;
    final expected = manifest.chunkCount(pieceIndex);
    if (chunkCount != expected) return false; // disagrees with the manifest
    if (chunkIndex < 0 || chunkIndex >= expected) return false;
    if (_verified.contains(pieceIndex)) return false; // already done

    final buf = _chunks.putIfAbsent(pieceIndex, () => {});
    buf[chunkIndex] = data;
    if (buf.length != expected) return false; // piece still incomplete

    final piece = _assemblePiece(expected, buf);
    if (manifest.verifyPiece(pieceIndex, piece)) {
      _verified.add(pieceIndex);
      _verifiedPieces[pieceIndex] = piece;
      _chunks.remove(pieceIndex); // free the per-chunk buffers; keep the piece
      return true;
    }
    // The reassembled piece doesn't match its hash (corruption / a lying chunk).
    // Drop it entirely — its chunks will be re-requested. Loss (not corruption)
    // is the common case on a lossy path, so this is rare.
    _chunks.remove(pieceIndex);
    return false;
  }

  /// Piece indices not yet verified — the coarse re-request set.
  List<int> missingPieces() => [
        for (var i = 0; i < manifest.pieceCount; i++)
          if (!_verified.contains(i)) i,
      ];

  /// Up to [max] not-yet-verified piece indices (lowest-first) — the re-request
  /// WINDOW. Focusing each round on a few pieces (rather than all of them at
  /// once) keeps the re-request small enough to itself survive the lossy path,
  /// and drives pieces to completion sooner (sequential-ish, BitTorrent-style).
  List<int> nextUnverifiedPieces(int max) {
    final out = <int>[];
    for (var i = 0; i < manifest.pieceCount && out.length < max; i++) {
      if (!_verified.contains(i)) out.add(i);
    }
    return out;
  }

  /// Chunk indices still missing for [pieceIndex] (fine-grained). A verified
  /// piece returns an empty list; an untouched piece returns ALL its chunk
  /// indices (the manifest tells us the count, so "nothing received" is still a
  /// precise gap list — no null sentinel needed).
  List<int> missingChunks(int pieceIndex) {
    if (_verified.contains(pieceIndex)) return const [];
    final cc = manifest.chunkCount(pieceIndex);
    final have = _chunks[pieceIndex];
    return [
      for (var c = 0; c < cc; c++)
        if (have == null || !have.containsKey(c)) c,
    ];
  }

  /// Bitmap of MISSING chunks for [pieceIndex]: bit `c` set ⇒ chunk `c` not yet
  /// received. Length = ceil(chunkCount/8). A verified piece → all-zero. The
  /// sender decodes this and serves exactly the set bits, so a re-request
  /// conveys an entire piece's gaps in a handful of bytes (vs. an index list).
  Uint8List missingChunkBitmap(int pieceIndex) {
    final cc = manifest.chunkCount(pieceIndex);
    final bm = Uint8List((cc + 7) >> 3);
    if (_verified.contains(pieceIndex)) return bm; // nothing missing
    final have = _chunks[pieceIndex];
    for (var c = 0; c < cc; c++) {
      if (have == null || !have.containsKey(c)) {
        bm[c >> 3] |= 1 << (c & 7);
      }
    }
    return bm;
  }

  /// Assemble + verify the whole file. Throws if incomplete or (defensively) if
  /// the reassembled whole fails [ContentManifest.verifyWhole].
  Uint8List assemble() {
    if (!isComplete) {
      throw StateError('incomplete: $verifiedCount/${manifest.pieceCount} pieces');
    }
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < manifest.pieceCount; i++) {
      out.add(_verifiedPieces[i]!);
    }
    final bytes = out.toBytes();
    if (!manifest.verifyWhole(bytes)) {
      throw StateError('content ${manifest.contentId}: whole-file verify failed');
    }
    return bytes;
  }

  Uint8List _assemblePiece(int chunkCount, Map<int, Uint8List> chunks) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < chunkCount; i++) {
      out.add(chunks[i]!);
    }
    return out.toBytes();
  }
}
