import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/content_transfer.dart';

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// The chunk frames a sender would emit for [m]+[data] at a given wire chunk size.
List<({int p, int c, int n, Uint8List d})> _chunksFor(
    ContentManifest m, Uint8List data, int wire) {
  final out = <({int p, int c, int n, Uint8List d})>[];
  for (var p = 0; p < m.pieceCount; p++) {
    final pstart = p * m.pieceSize;
    final plen = m.pieceLength(p);
    final n = (plen + wire - 1) ~/ wire;
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
    final m = ContentManifest.fromBytes('f', data, pieceSize: 8192); // 3 pieces
    expect(m.pieceCount, 3);
    final ct = ContentTransfer(m);
    final chunks = _chunksFor(m, data, 4000)..shuffle(Random(9));
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
    final m = ContentManifest.fromBytes('f', data, pieceSize: 8192);
    final ct = ContentTransfer(m);
    final chunks = _chunksFor(m, data, 4000);
    // Deliver everything EXCEPT piece 1, chunk 1.
    final dropped = chunks.where((ch) => !(ch.p == 1 && ch.c == 1));
    for (final ch in dropped) {
      ct.addChunk(ch.p, ch.c, ch.n, ch.d);
    }
    expect(ct.isComplete, isFalse);
    expect(ct.missingPieces(), [1], reason: 'only piece 1 is unfinished');
    expect(ct.missingChunks(1), [1], reason: 'and only its chunk 1');
    expect(ct.missingChunks(0), isEmpty, reason: 'piece 0 has every chunk');
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
    final m = ContentManifest.fromBytes('f', data, pieceSize: 8192);
    final ct = ContentTransfer(m);
    final chunks = _chunksFor(m, data, 4000);
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
    expect(ct.missingChunks(2), isNull,
        reason: 'the bad piece was dropped wholesale → request it all again');
    // Honest re-delivery of piece 2 completes the transfer.
    for (final ch in chunks.where((c) => c.p == 2)) {
      ct.addChunk(ch.p, ch.c, ch.n, ch.d);
    }
    expect(ct.isComplete, isTrue);
    expect(ct.assemble(), data);
  });

  test('a piece arriving from another source with a wrong chunk-count is ignored',
      () {
    final data = _rnd(9000, 4);
    final m = ContentManifest.fromBytes('f', data, pieceSize: 8192); // 2 pieces
    final ct = ContentTransfer(m);
    // First-seen chunk for piece 0 declares 3 chunks.
    ct.addChunk(0, 0, 3, _rnd(4000, 5));
    // A peer lies with a different count → ignored, original buffer intact.
    ct.addChunk(0, 1, 99, _rnd(10, 6));
    expect(ct.missingChunks(0), [1, 2]);
  });
}
