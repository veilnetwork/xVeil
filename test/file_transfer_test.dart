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

  test('hostile out-of-range index cannot fake completion or crash assemble',
      () {
    final r = FileReassembler();
    // total=5, but indices 0..3 then a bogus index 5 (slot 4 never filled).
    // Without validation _chunks.length would hit 5 == total and assemble
    // would null-crash on the missing slot.
    for (final i in [0, 1, 2, 3, 5]) {
      r.add(FileChunk(transferId: 't', index: i, total: 5, data: _bytes(10)));
    }
    expect(r.isComplete, isFalse, reason: 'out-of-range index is ignored');
    expect(r.received, 4);
    expect(r.assemble, throwsStateError);
    // Negative index and non-positive total are also ignored.
    r.add(FileChunk(transferId: 't', index: -1, total: 5, data: _bytes(10)));
    r.add(FileChunk(transferId: 't', index: 0, total: 0, data: _bytes(10)));
    expect(r.received, 4);
  });

  test('bufferedBytes tracks unique bytes and is dedup-accurate', () {
    final r = FileReassembler();
    r.add(FileChunk(transferId: 't', index: 0, total: 2, data: _bytes(100)));
    r.add(FileChunk(transferId: 't', index: 1, total: 2, data: _bytes(60)));
    expect(r.bufferedBytes, 160);
    // Re-adding index 0 (different bytes, same length) must not double-count.
    r.add(FileChunk(transferId: 't', index: 0, total: 2, data: _bytes(100)));
    expect(r.bufferedBytes, 160);
  });

  test('a total that disagrees mid-transfer is ignored', () {
    final r = FileReassembler();
    r.add(FileChunk(transferId: 't', index: 0, total: 2, data: _bytes(10)));
    // Attacker flips total to 1 to fake completion with a single slot.
    r.add(FileChunk(transferId: 't', index: 0, total: 1, data: _bytes(10)));
    expect(r.total, 2);
    expect(r.isComplete, isFalse);
  });

  test('a chunk count above the cap is rejected (memory-DoS guard)', () {
    final r = FileReassembler(maxChunks: 4);
    // A hostile sender declares a huge chunk count to balloon the chunk map
    // while staying under the byte budget — rejected outright, nothing stored.
    r.add(FileChunk(transferId: 't', index: 0, total: 1 << 30, data: _bytes(1)));
    expect(r.received, 0);
    expect(r.total, isNull, reason: 'an over-cap total never even sets _total');
    // A total exactly at the cap is allowed.
    for (var i = 0; i < 4; i++) {
      r.add(FileChunk(transferId: 't', index: i, total: 4, data: _bytes(10)));
    }
    expect(r.isComplete, isTrue);
    expect(r.received, 4);
  });

  test('the default cap matches kMaxIncomingFileChunks', () {
    final r = FileReassembler();
    r.add(FileChunk(
        transferId: 't',
        index: 0,
        total: kMaxIncomingFileChunks + 1,
        data: _bytes(1)));
    expect(r.received, 0, reason: 'one past the default cap is rejected');
  });
}
