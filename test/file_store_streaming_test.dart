import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

void main() {
  test('streamed file: pieces store incrementally (out of order); hasFile '
      'completes only at the last piece; readFileRange reads across pieces; '
      'loadFile reassembles the whole', () async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);

    const pieceSize = 1000;
    const total = 2500; // 3 pieces: 1000, 1000, 500
    final whole = Uint8List.fromList(List.generate(total, (i) => i % 251));
    Uint8List piece(int idx) {
      final start = idx * pieceSize;
      final end = (start + pieceSize) <= total ? start + pieceSize : total;
      return Uint8List.sublistView(whole, start, end);
    }

    expect(await s.hasFile('cid'), isFalse);
    await s.storeFilePiece('cid', 0, 3, pieceSize, total, piece(0),
        name: 'big.bin');
    expect(await s.hasFile('cid'), isFalse, reason: '1/3 stored');
    await s.storeFilePiece('cid', 2, 3, pieceSize, total, piece(2)); // out of order
    expect(await s.hasFile('cid'), isFalse, reason: '2/3 stored');
    await s.storeFilePiece('cid', 1, 3, pieceSize, total, piece(1));
    expect(await s.hasFile('cid'), isTrue, reason: 'all 3 stored → complete');

    // ranged read spanning the piece-0|piece-1 boundary
    expect(await s.readFileRange('cid', 800, 400),
        Uint8List.sublistView(whole, 800, 1200));
    // a range inside the short last piece
    expect(await s.readFileRange('cid', 2200, 300),
        Uint8List.sublistView(whole, 2200, 2500));
    // whole-file reassembly (loadFile routes through the streamed pieces)
    expect(await s.loadFile('cid'), whole);

    // idempotent re-store of a piece does not corrupt or double-count.
    await s.storeFilePiece('cid', 1, 3, pieceSize, total, piece(1));
    expect(await s.loadFile('cid'), whole);
  });
}
