import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/content_transfer.dart';

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// The chunk frames a sender would emit for [m]+[data] — the wire chunk size is
/// the MANIFEST's [ContentManifest.chunkBytes] (the receiver's chunk-count
/// authority), so the emitted `n` matches what the reassembler expects.
List<({int p, int c, int n, Uint8List d})> _chunksFor(
    ContentManifest m, Uint8List data) {
  final wire = m.chunkBytes;
  final out = <({int p, int c, int n, Uint8List d})>[];
  for (var p = 0; p < m.pieceCount; p++) {
    final pstart = p * m.pieceSize;
    final plen = m.pieceLength(p);
    final n = m.chunkCount(p);
    for (var c = 0; c < n; c++) {
      final cstart = pstart + c * wire;
      final cend = (c * wire + wire <= plen) ? cstart + wire : pstart + plen;
      out.add((p: p, c: c, n: n, d: Uint8List.sublistView(data, cstart, cend)));
    }
  }
  return out;
}

void main() {
  test('out-of-order, duplicate chunks reassemble + verify into the whole', () {
    final data = _rnd(20000, 1);
    final m = ContentManifest.fromBytes('f', data,
        pieceSize: 8192, chunkBytes: 4000); // 3 pieces
    expect(m.pieceCount, 3);
    final ct = ContentTransfer(m);
    final chunks = _chunksFor(m, data)..shuffle(Random(9));
    for (final ch in chunks) {
      ct.addChunk(ch.p, ch.c, ch.n, ch.d);
      ct.addChunk(ch.p, ch.c, ch.n, ch.d); // duplicate — harmless
    }
    expect(ct.isComplete, isTrue);
    expect(ct.assemble(), data, reason: 'verified whole == original');
  });

  test('a dropped chunk leaves exactly that piece+chunk missing for re-request',
      () {
    final data = _rnd(20000, 2);
    final m = ContentManifest.fromBytes('f', data,
        pieceSize: 8192, chunkBytes: 4000);
    final ct = ContentTransfer(m);
    final chunks = _chunksFor(m, data);
    // Deliver everything EXCEPT piece 1, chunk 1.
    final dropped = chunks.where((ch) => !(ch.p == 1 && ch.c == 1));
    for (final ch in dropped) {
      ct.addChunk(ch.p, ch.c, ch.n, ch.d);
    }
    expect(ct.isComplete, isFalse);
    expect(ct.missingPieces(), [1], reason: 'only piece 1 is unfinished');
    expect(ct.missingChunks(1), [1], reason: 'and only its chunk 1');
    expect(ct.missingChunks(0), isEmpty, reason: 'piece 0 has every chunk');
    // The missing-chunk bitmap for piece 1 marks only chunk 1.
    final bm = ct.missingChunkBitmap(1);
    expect(bm[0] & 0x01, 0, reason: 'chunk 0 present → bit clear');
    expect(bm[0] & 0x02, 0x02, reason: 'chunk 1 missing → bit set');
    // Re-deliver the missing chunk → complete.
    final miss = chunks.firstWhere((ch) => ch.p == 1 && ch.c == 1);
    expect(ct.addChunk(miss.p, miss.c, miss.n, miss.d), isTrue,
        reason: 'completing chunk verifies the piece');
    expect(ct.isComplete, isTrue);
    expect(ct.assemble(), data);
  });

  test('a corrupted chunk fails the piece hash → piece stays missing (re-fetch)',
      () {
    final data = _rnd(20000, 3);
    final m = ContentManifest.fromBytes('f', data,
        pieceSize: 8192, chunkBytes: 4000);
    final ct = ContentTransfer(m);
    final chunks = _chunksFor(m, data);
    for (final ch in chunks) {
      if (ch.p == 2 && ch.c == 0) {
        final bad = Uint8List.fromList(ch.d)..[0] ^= 0xff; // corrupt piece 2
        ct.addChunk(ch.p, ch.c, ch.n, bad);
      } else {
        ct.addChunk(ch.p, ch.c, ch.n, ch.d);
      }
    }
    expect(ct.isVerified(2), isFalse, reason: 'corrupt piece not accepted');
    expect(ct.missingPieces(), [2]);
    // The bad piece was dropped wholesale → ALL its chunks are missing again
    // (the manifest still tells us how many it has, so it's a precise list).
    expect(ct.missingChunks(2), [for (var c = 0; c < m.chunkCount(2); c++) c],
        reason: 'dropped piece → request all of its chunks again');
    // Honest re-delivery of piece 2 completes the transfer.
    for (final ch in chunks.where((c) => c.p == 2)) {
      ct.addChunk(ch.p, ch.c, ch.n, ch.d);
    }
    expect(ct.isComplete, isTrue);
    expect(ct.assemble(), data);
  });

  test('a chunk whose count disagrees with the manifest is ignored', () {
    final data = _rnd(9000, 4);
    final m = ContentManifest.fromBytes('f', data,
        pieceSize: 8192, chunkBytes: 4000); // 2 pieces; piece 0 = 3 chunks
    expect(m.chunkCount(0), 3);
    final ct = ContentTransfer(m);
    // A correct-count chunk for piece 0 is accepted.
    ct.addChunk(0, 0, 3, _rnd(4000, 5));
    // A peer lies with a different count → ignored, original buffer intact.
    ct.addChunk(0, 1, 99, _rnd(10, 6));
    expect(ct.missingChunks(0), [1, 2]);
  });
}
