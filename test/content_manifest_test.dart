import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';

Uint8List _rnd(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  test('manifest verifies every piece + the whole; content id is self-consistent',
      () {
    final data = _rnd(700000, 1); // ~2.7 pieces at 256 KiB (a short last piece)
    final m = ContentManifest.fromBytes('clip.bin', data);
    expect(m.size, data.length);
    expect(m.pieceCount, (data.length + m.pieceSize - 1) ~/ m.pieceSize);
    expect(m.isSelfConsistent, isTrue);
    expect(m.verifyWhole(data), isTrue);
    // Every piece verifies against its own slice.
    for (var i = 0; i < m.pieceCount; i++) {
      final start = i * m.pieceSize;
      final end = start + m.pieceLength(i);
      expect(m.verifyPiece(i, Uint8List.sublistView(data, start, end)), isTrue);
    }
  });

  test('a flipped byte fails the affected piece AND the whole', () {
    final data = _rnd(300000, 2);
    final m = ContentManifest.fromBytes('x', data);
    expect(m.pieceCount, 2); // 256 KiB piece 0 + a short piece 1
    final tampered = Uint8List.fromList(data);
    tampered[270000] ^= 0xff; // inside piece 1 (>= pieceSize 262144)
    expect(m.verifyWhole(tampered), isFalse, reason: 'whole-file integrity');
    final p1start = m.pieceSize;
    final p1 = Uint8List.sublistView(tampered, p1start, p1start + m.pieceLength(1));
    expect(m.verifyPiece(1, p1), isFalse, reason: 'the corrupt piece is pinpointed');
    // Piece 0 (untouched) still verifies — re-request only piece 1.
    final p0 = Uint8List.sublistView(tampered, 0, m.pieceLength(0));
    expect(m.verifyPiece(0, p0), isTrue);
  });

  test('content id binds name + content (dedup / swarm address)', () {
    final data = _rnd(50000, 3);
    final a = ContentManifest.fromBytes('a.bin', data);
    final b = ContentManifest.fromBytes('a.bin', data);
    final c = ContentManifest.fromBytes('b.bin', data); // different name
    final d = ContentManifest.fromBytes('a.bin', _rnd(50000, 4)); // different bytes
    expect(a.contentId, b.contentId, reason: 'same name+content → same address');
    expect(a.contentId, isNot(c.contentId), reason: 'name is bound');
    expect(a.contentId, isNot(d.contentId), reason: 'content is bound');
  });

  test('json round-trips; a tampered manifest is rejected (not self-consistent)',
      () {
    final m = ContentManifest.fromBytes('doc.pdf', _rnd(400000, 5));
    final back = ContentManifest.fromJson(m.toJson());
    expect(back, isNotNull);
    expect(back!.contentId, m.contentId);
    expect(back.verifyWhole, isNotNull);
    // Forge a piece hash but keep the original id → fromJson must reject it.
    final j = m.toJson();
    final ph = (j['ph'] as String);
    j['ph'] = '00${ph.substring(2)}'; // flip the first hash byte
    expect(ContentManifest.fromJson(j), isNull,
        reason: 'fields no longer hash to the declared id → untrusted');
  });

  test('empty + single-byte files are well-formed', () {
    final empty = ContentManifest.fromBytes('e', Uint8List(0));
    expect(empty.pieceCount, 0);
    expect(empty.verifyWhole(Uint8List(0)), isTrue);
    expect(empty.isSelfConsistent, isTrue);
    final one = ContentManifest.fromBytes('o', Uint8List.fromList([7]));
    expect(one.pieceCount, 1);
    expect(one.verifyWhole(Uint8List.fromList([7])), isTrue);
    expect(one.verifyWhole(Uint8List.fromList([8])), isFalse);
  });
}
