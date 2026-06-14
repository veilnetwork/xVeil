import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/file_transfer.dart';

Uint8List _bytes(int n) {
  final r = Random(n);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _reassemble(List<FileChunk> chunks) {
  final r = FileReassembler();
  for (final c in chunks) {
    r.add(c);
  }
  return r.assemble();
}

void main() {
  test('round-trips for various sizes incl. boundaries and empty', () {
    for (final n in [0, 1, 8191, 8192, 8193, 20000]) {
      final data = _bytes(n);
      final chunks = chunkBytes(data, transferId: 't', maxChunk: 8192);
      expect(_reassemble(chunks), data, reason: 'size $n');
      // Every chunk is within the size cap.
      expect(chunks.every((c) => c.data.length <= 8192), isTrue);
      // total is consistent across chunks.
      expect(chunks.every((c) => c.total == chunks.length), isTrue);
    }
  });

  test('chunk count is correct', () {
    expect(chunkBytes(_bytes(0), transferId: 't', maxChunk: 100).length, 1);
    expect(chunkBytes(_bytes(100), transferId: 't', maxChunk: 100).length, 1);
    expect(chunkBytes(_bytes(101), transferId: 't', maxChunk: 100).length, 2);
    expect(chunkBytes(_bytes(250), transferId: 't', maxChunk: 100).length, 3);
  });

  test('reassembles out of order and is dedup-safe', () {
    final data = _bytes(5000);
    final chunks = chunkBytes(data, transferId: 't', maxChunk: 512);
    final shuffled = [...chunks, chunks.first]..shuffle(Random(1));
    expect(_reassemble(shuffled), data);
  });

  test('isComplete tracks progress; assemble throws while incomplete', () {
    final chunks = chunkBytes(_bytes(3000), transferId: 't', maxChunk: 1000);
    final r = FileReassembler();
    r.add(chunks[0]);
    expect(r.isComplete, isFalse);
    expect(r.received, 1);
    expect(r.assemble, throwsStateError);
    r.add(chunks[1]);
    r.add(chunks[2]);
    expect(r.isComplete, isTrue);
  });

  test('rejects non-positive maxChunk', () {
    expect(() => chunkBytes(_bytes(10), transferId: 't', maxChunk: 0),
        throwsArgumentError);
  });
}
