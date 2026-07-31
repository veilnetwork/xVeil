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

  test('a stray high-index piece cannot stand in for a missing one', () async {
    // hasFile compares piecesPresent() with the recorded piece count using
    // `>=`, so any file that inflates the count reports the blob as complete.
    // Anyone able to write into the blob directory — or a peer that sent one
    // piece too many — could make a half-received file read as whole.
    const expected = 3;
    await store.storePiece('blobC', key, 0, _seq(10));
    await store.storePiece('blobC', key, 1, _seq(10));
    // p2 never arrives; p999 does.
    await store.storePiece('blobC', key, 999, _seq(10));

    expect(await store.piecesPresent('blobC', expected), 2,
        reason: 'p999 is not part of a 3-piece layout');
    expect(await store.piecesPresent('blobC', expected) >= expected, isFalse,
        reason: 'the blob is incomplete and must not report otherwise');

    await store.storePiece('blobC', key, 2, _seq(10));
    expect(await store.piecesPresent('blobC', expected), expected);
  });

  test('an oversized piece file is refused without being read', () async {
    // readPiece used to readAsBytes() first and sanity-check afterwards, so a
    // piece file claiming gigabytes committed the allocation before any MAC
    // was checked. The bound is the caller's declared layout.
    await store.storePiece('blobD', key, 0, _seq(4096));
    expect(await store.readPiece('blobD', key, 0, maxPlaintextBytes: 4096),
        isNotNull);
    expect(await store.readPiece('blobD', key, 0, maxPlaintextBytes: 16), isNull,
        reason: 'a piece larger than the layout allows must not be loaded');
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
