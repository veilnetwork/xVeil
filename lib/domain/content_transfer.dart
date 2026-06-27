import 'dart:typed_data';

import 'content_manifest.dart';

/// Receiver-side reassembly of a content transfer (the BitTorrent-style core).
/// Buffers the wire CHUNKS of each PIECE; when a piece is complete it is verified
/// against the manifest hash and kept, or — if the hash fails — dropped so it can
/// be re-requested. Tracks exactly which pieces (and which chunks within a piece)
/// are still missing, so the receiver re-requests only the gaps. Order- and
/// duplicate-tolerant. [assemble] returns the fully verified whole.
///
/// v1 holds verified pieces in memory (fine up to RAM-sized files); streaming
/// each verified piece straight to the on-disk blob store is a later optimization.
class ContentTransfer {
  ContentTransfer(this.manifest);

  final ContentManifest manifest;

  final Map<int, _PieceBuf> _pieces = {};
  final Set<int> _verified = {};

  int get pieceCount => manifest.pieceCount;
  int get verifiedCount => _verified.length;
  bool get isComplete => _verified.length == manifest.pieceCount;
  bool isVerified(int pieceIndex) => _verified.contains(pieceIndex);

  /// Ingest one received chunk. Returns true iff this chunk COMPLETED and
  /// VERIFIED its piece (so the caller can persist it / update progress).
  /// A chunk for an already-verified piece, an out-of-range index, or a
  /// chunk-count that disagrees with the piece's first-seen count is ignored.
  bool addChunk(int pieceIndex, int chunkIndex, int chunkCount, Uint8List data) {
    if (pieceIndex < 0 || pieceIndex >= manifest.pieceCount) return false;
    if (chunkCount < 1) return false;
    if (chunkIndex < 0 || chunkIndex >= chunkCount) return false;
    if (_verified.contains(pieceIndex)) return false; // already done

    final buf = _pieces.putIfAbsent(pieceIndex, () => _PieceBuf(chunkCount));
    if (buf.chunkCount != chunkCount) return false; // hostile/garbled disagreement
    buf.chunks[chunkIndex] = data;
    if (buf.chunks.length != chunkCount) return false; // piece still incomplete

    final piece = buf.assemble();
    if (manifest.verifyPiece(pieceIndex, piece)) {
      _verified.add(pieceIndex);
      buf.verified = piece;
      buf.chunks.clear(); // free the per-chunk buffers; keep the assembled piece
      return true;
    }
    // The reassembled piece doesn't match its hash (corruption / a lying peer).
    // Drop it entirely — it will be re-requested from scratch (or another peer).
    _pieces.remove(pieceIndex);
    return false;
  }

  /// Piece indices not yet verified — the re-request set (coarse).
  List<int> missingPieces() => [
        for (var i = 0; i < manifest.pieceCount; i++)
          if (!_verified.contains(i)) i,
      ];

  /// Chunk indices still missing for [pieceIndex] (fine-grained re-request).
  /// `null` means "nothing received for this piece yet" → request the whole piece.
  List<int>? missingChunks(int pieceIndex) {
    if (_verified.contains(pieceIndex)) return const []; // done → nothing missing
    final buf = _pieces[pieceIndex];
    if (buf == null) return null;
    return [
      for (var i = 0; i < buf.chunkCount; i++)
        if (!buf.chunks.containsKey(i)) i,
    ];
  }

  /// Assemble + verify the whole file. Throws if incomplete or (defensively) if
  /// the reassembled whole fails [ContentManifest.verifyWhole].
  Uint8List assemble() {
    if (!isComplete) {
      throw StateError('incomplete: $verifiedCount/${manifest.pieceCount} pieces');
    }
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < manifest.pieceCount; i++) {
      out.add(_pieces[i]!.verified!);
    }
    final bytes = out.toBytes();
    if (!manifest.verifyWhole(bytes)) {
      throw StateError('content ${manifest.contentId}: whole-file verify failed');
    }
    return bytes;
  }
}

class _PieceBuf {
  _PieceBuf(this.chunkCount);
  final int chunkCount;
  final Map<int, Uint8List> chunks = {};
  Uint8List? verified;

  Uint8List assemble() {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < chunkCount; i++) {
      out.add(chunks[i]!);
    }
    return out.toBytes();
  }
}
