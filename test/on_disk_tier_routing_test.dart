import 'dart:io';
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
  late Directory blobDir;
  setUp(() async {
    blobDir = await Directory.systemTemp.createTemp('xveil-tier');
  });
  tearDown(() async {
    if (await blobDir.exists()) await blobDir.delete(recursive: true);
  });

  test('a large file routes to the ENCRYPTED on-disk tier (out-of-order pieces; '
      'ranged + whole reads); a small file stays in the volume', () async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    s.useOnDiskTier(blobDir, minBytes: 1000); // tiny threshold for the test

    const pieceSize = 1000;
    const total = 2500; // 3 pieces, >= minBytes → on-disk
    final whole = Uint8List.fromList(List.generate(total, (i) => i % 251));
    Uint8List piece(int idx) {
      final st = idx * pieceSize;
      final en = (st + pieceSize) <= total ? st + pieceSize : total;
      return Uint8List.sublistView(whole, st, en);
    }

    expect(await s.hasFile('big'), isFalse);
    await s.storeFilePiece('big', 0, 3, pieceSize, total, piece(0),
        name: 'movie.bin');
    expect(await s.hasFile('big'), isFalse, reason: '1/3 stored');
    await s.storeFilePiece('big', 2, 3, pieceSize, total, piece(2)); // reorder
    await s.storeFilePiece('big', 1, 3, pieceSize, total, piece(1));
    expect(await s.hasFile('big'), isTrue, reason: 'all 3 → complete');

    // Reads route to the on-disk tier and decrypt correctly.
    expect(await s.readFileRange('big', 800, 400),
        Uint8List.sublistView(whole, 800, 1200), reason: 'spans piece 0|1');
    expect(await s.loadFile('big'), whole, reason: 'whole-file reassembly');

    // The bytes live ON DISK as CIPHERTEXT, not in the volume.
    final files =
        blobDir.listSync(recursive: true).whereType<File>().toList();
    expect(files, isNotEmpty, reason: 'encrypted pieces written to the FS tier');
    expect(await files.first.readAsBytes(), isNot(equals(piece(0))),
        reason: 'on-disk bytes are sealed, not plaintext');
    final onDiskCount = files.length;

    // A SMALL file stays in the volume — it does NOT touch the on-disk tier.
    await s.storeFilePiece('small', 0, 1, 50, 50,
        Uint8List.sublistView(whole, 0, 50), name: 's.bin');
    expect(await s.hasFile('small'), isTrue);
    expect(await s.loadFile('small'), Uint8List.sublistView(whole, 0, 50));
    expect(blobDir.listSync(recursive: true).whereType<File>().length,
        onDiskCount, reason: 'small file did not write to the on-disk tier');
  });
}
