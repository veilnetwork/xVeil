import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/on_disk_blob_store.dart';

Uint8List _seq(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

void main() {
  late Directory root;
  late OnDiskBlobStore store;
  final key = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 1) & 0xff));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('xveil-blob-test');
    store = OnDiskBlobStore(root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('pieces seal/store out of order; ranged + whole reads decrypt correctly',
      () async {
    const pieceSize = 1000;
    const total = 2500; // 3 pieces: 1000, 1000, 500
    final whole = _seq(total);
    Uint8List piece(int idx) {
      final start = idx * pieceSize;
      final end = (start + pieceSize) <= total ? start + pieceSize : total;
      return Uint8List.sublistView(whole, start, end);
    }

    expect(await store.exists('blobA'), isFalse);
    // Store OUT OF ORDER.
    await store.storePiece('blobA', key, 2, piece(2));
    await store.storePiece('blobA', key, 0, piece(0));
    await store.storePiece('blobA', key, 1, piece(1));
    expect(await store.exists('blobA'), isTrue);
    expect(await store.hasPiece('blobA', 1), isTrue);

    // Per-piece decrypt round-trips.
    expect(await store.readPiece('blobA', key, 0), piece(0));
    expect(await store.readPiece('blobA', key, 2), piece(2));

    // Ranged read spanning the piece-0|piece-1 boundary.
    expect(await store.readRange('blobA', key, 800, 400, pieceSize, total),
        Uint8List.sublistView(whole, 800, 1200));
    // A range inside the short last piece.
    expect(await store.readRange('blobA', key, 2200, 300, pieceSize, total),
        Uint8List.sublistView(whole, 2200, 2500));
    // Whole-file reassembly via a full-span range.
    expect(await store.readRange('blobA', key, 0, total, pieceSize, total), whole);
  });

  test('ciphertext is NOT the plaintext; wrong key + tamper fail closed',
      () async {
    final p = _seq(900);
    await store.storePiece('b', key, 0, p);
    // On-disk bytes are sealed, not the plaintext.
    final raw = await File('${root.path}/b/p0').readAsBytes();
    expect(raw, isNot(equals(p)), reason: 'stored ciphertext != plaintext');
    expect(raw.length, p.length + 16, reason: 'ciphertext + Poly1305 tag');

    // Wrong key → auth failure → null (not garbage).
    final wrong = Uint8List.fromList(List.filled(32, 9));
    expect(await store.readPiece('b', wrong, 0), isNull);

    // Flip a ciphertext byte → auth failure → null.
    raw[0] ^= 0xff;
    await File('${root.path}/b/p0').writeAsBytes(raw, flush: true);
    expect(await store.readPiece('b', key, 0), isNull);
  });

  test('delete removes the blob', () async {
    await store.storePiece('gone', key, 0, _seq(100));
    expect(await store.exists('gone'), isTrue);
    await store.delete('gone');
    expect(await store.exists('gone'), isFalse);
    expect(await store.readPiece('gone', key, 0), isNull);
  });

  test('a missing covering piece makes a ranged read return null', () async {
    const pieceSize = 1000;
    const total = 2000;
    await store.storePiece('part', key, 0, _seq(1000)); // piece 1 absent
    expect(await store.readRange('part', key, 0, 1000, pieceSize, total),
        isNotNull);
    expect(await store.readRange('part', key, 1500, 200, pieceSize, total),
        isNull, reason: 'piece 1 not stored');
  });
}
