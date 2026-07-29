import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';

/// A manifest is self-authenticating: it hashes to its own id. That proves the
/// author did not change their mind afterwards — it says NOTHING about whether
/// the numbers inside agree with each other, because the author computed the id
/// from those numbers.
///
/// Every case below is perfectly self-consistent and used to be accepted.
Uint8List _hash(int seed) => Uint8List.fromList(List.filled(32, seed));

/// Build the JSON an honest sender would emit, then let the caller break one
/// field — the id is recomputed either way, so nothing is rejected for the
/// wrong reason.
Map<String, dynamic> _json({
  required int size,
  required int pieceSize,
  required int hashCount,
  int chunkBytes = ContentManifest.defaultChunkBytes,
}) {
  final hashes = [for (var i = 0; i < hashCount; i++) _hash(i)];
  final m = ContentManifest(
    name: 'f.bin',
    size: size,
    pieceSize: pieceSize,
    chunkBytes: chunkBytes,
    pieceHashes: hashes,
    // Self-consistent by construction: the id is derived from exactly these
    // fields, which is the point — an attacker authoring a hostile manifest
    // computes it the same way.
    contentId: ContentManifest.computeContentId(
      name: 'f.bin',
      size: size,
      pieceSize: pieceSize,
      pieceHashes: hashes,
    ),
  );
  return m.toJson();
}

void main() {
  test('an honest manifest still parses', () {
    // The gate has to be a gate and not a wall: every assertion below is
    // worthless if the validator simply refuses everything.
    final j = _json(size: 1024 * 1024, pieceSize: 256 * 1024, hashCount: 4);
    final m = ContentManifest.fromJson(j);
    expect(m, isNotNull);
    expect(m!.pieceCount, 4);
  });

  test('a short hash list cannot claim a long file', () {
    // The one that matters. pieceCount IS pieceHashes.length and nothing else
    // decides completion, while `size` is what gets shown and written. A
    // manifest declaring 2 MiB in 256 KiB pieces with ONE hash reported 1/1
    // complete after 256 KiB — stored, and ACKed back to the sender as if the
    // whole file had arrived.
    final j = _json(size: 2 * 1024 * 1024, pieceSize: 256 * 1024, hashCount: 1);
    expect(ContentManifest.fromJson(j), isNull);
  });

  test('a long hash list cannot claim a short file either', () {
    final j = _json(size: 256 * 1024, pieceSize: 256 * 1024, hashCount: 9);
    expect(ContentManifest.fromJson(j), isNull);
  });

  test('an empty file carries no pieces', () {
    expect(
      ContentManifest.fromJson(
        _json(size: 0, pieceSize: 256 * 1024, hashCount: 1),
      ),
      isNull,
    );
    expect(
      ContentManifest.fromJson(
        _json(size: 0, pieceSize: 256 * 1024, hashCount: 0),
      ),
      isNotNull,
    );
  });

  test('a piece larger than the sender would ever cut is refused', () {
    // A piece is held whole while it is verified, so this is the largest
    // allocation one manifest can ask the receiver for.
    final huge = ContentManifest.maxPieceBytes + 1;
    expect(
      ContentManifest.fromJson(_json(size: huge, pieceSize: huge, hashCount: 1)),
      isNull,
    );
    expect(
      ContentManifest.fromJson(
        _json(
          size: ContentManifest.maxPieceBytes,
          pieceSize: ContentManifest.maxPieceBytes,
          hashCount: 1,
        ),
      ),
      isNotNull,
      reason: 'the sender itself emits pieces this big',
    );
  });

  test('a tiny chunk size cannot inflate the per-piece bitmap', () {
    // The missing-chunk bitmap is one bit per chunk. 1-byte chunks over a
    // 2 MiB piece is a 256 KiB bitmap per piece, chosen by the sender and paid
    // for by the receiver.
    final j = _json(
      size: 2 * 1024 * 1024,
      pieceSize: 2 * 1024 * 1024,
      hashCount: 1,
      chunkBytes: 1,
    );
    expect(ContentManifest.fromJson(j), isNull);
  });

  test('a chunk bigger than its own piece is nonsense', () {
    final j = _json(
      size: 256 * 1024,
      pieceSize: 256 * 1024,
      hashCount: 1,
      chunkBytes: 512 * 1024,
    );
    expect(ContentManifest.fromJson(j), isNull);
  });
}
