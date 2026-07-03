import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

/// Counts non-empty commits — asserts the padded-commit cost of a code path.
class _CountingStore implements KvLogStore {
  _CountingStore(this._inner);
  final FakeKvLogStore _inner;
  int commits = 0;

  @override
  int commit(List<KvLogOp> ops) {
    if (ops.isNotEmpty) commits++;
    return _inner.commit(ops);
  }

  @override
  Uint8List? get(int namespace, Uint8List key) => _inner.get(namespace, key);
  @override
  Uint8List? readLog(int namespace, int logId) =>
      _inner.readLog(namespace, logId);
  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) =>
      _inner.iterLogRange(
          namespace: namespace, start: start, end: end, limit: limit);
  @override
  int count(int namespace) => _inner.count(namespace);
  @override
  int eraseNamespace(int namespace) => _inner.eraseNamespace(namespace);
  @override
  void scrub() => _inner.scrub();
  @override
  Uint8List exportKeys() => _inner.exportKeys();
  @override
  void close() => _inner.close();
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

  NodeId id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

  /// Store a complete 2-piece on-disk blob under [cid], attached to a message
  /// in [peer]'s conversation; returns the message id.
  Future<String> storeOnDiskFileMessage(
    HiddenVolumeStorage s,
    NodeId peer,
    String cid,
  ) async {
    const pieceSize = 1000;
    const total = 2000;
    final bytes = Uint8List.fromList(List.generate(total, (i) => i % 251));
    await s.storeFilePiece(
        cid, 0, 2, pieceSize, total, Uint8List.sublistView(bytes, 0, 1000),
        name: 'big.bin');
    await s.storeFilePiece(
        cid, 1, 2, pieceSize, total, Uint8List.sublistView(bytes, 1000));
    expect(await s.hasFile(cid), isTrue);
    final m = await s.appendMessage(Message(
      id: 'msg-$cid',
      conversationId: peer.hex,
      direction: MessageDirection.incoming,
      body: 'file',
      timestamp: DateTime(2026, 7, 1),
      fileId: cid,
      fileName: 'big.bin',
    ));
    return m.id;
  }

  test(
      'deleting a large-file message scrubs the on-disk tier: key row gone '
      '(forward secrecy) AND ciphertext files removed', () async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    s.useOnDiskTier(blobDir, minBytes: 1000);
    final peer = id(0xAA);
    final msgId = await storeOnDiskFileMessage(s, peer, 'cid-del');
    expect(blobDir.listSync(recursive: true).whereType<File>(), isNotEmpty);

    await s.deleteMessage(peer.hex, msgId);

    expect(await s.hasFile('cid-del'), isFalse,
        reason: 'the ondisk: key row must be scrubbed with the tombstone');
    expect(await s.readFileRange('cid-del', 0, 100), isNull);
    expect(blobDir.listSync(recursive: true).whereType<File>(), isEmpty,
        reason: 'the ciphertext files must not linger after the key scrub');
  });

  test('clearing a conversation scrubs its on-disk blobs too', () async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    s.useOnDiskTier(blobDir, minBytes: 1000);
    final peer = id(0xBB);
    await storeOnDiskFileMessage(s, peer, 'cid-clear');

    await s.clearMessages(peer);

    expect(await s.hasFile('cid-clear'), isFalse);
    expect(blobDir.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test(
      'on-disk tier meta commits ONCE per file — pieces track via the FS, so '
      'piece count is unbounded and receiving N pieces costs N commits no more',
      () async {
    final counting = _CountingStore(FakeKvLogStore());
    final s = HiddenVolumeStorage(
      ({required password, required bool create}) => counting,
    );
    await s.open(password: 'p', createIfMissing: true);
    s.useOnDiskTier(blobDir, minBytes: 100);

    const pieceSize = 100;
    const pieces = 40; // would have been 40 growing meta rewrites before
    const total = pieceSize * pieces;
    final before = counting.commits;
    for (var i = 0; i < pieces; i++) {
      await s.storeFilePiece('many', i, pieces, pieceSize, total,
          Uint8List.fromList(List.filled(pieceSize, i)),
          name: 'many.bin');
    }
    expect(counting.commits, before + 1,
        reason: 'one constant-size meta row per file — NOT one padded commit '
            'per received piece');
    expect(await s.hasFile('many'), isTrue,
        reason: 'completeness comes from the atomic per-piece files on disk');
    // A missing piece file (crash mid-store) honestly reads as incomplete.
    final pieceFiles = blobDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'/p\d+$').hasMatch(f.path))
        .toList();
    await pieceFiles.first.delete();
    expect(await s.hasFile('many'), isFalse);
  });

  test('adaptive piece size scales but is CAPPED — a TB-scale file grows the '
      'piece COUNT, not the RAM-resident piece', () {
    const kib = 1024, mib = 1024 * 1024, gib = 1024 * mib;
    // Small files: the default piece.
    expect(MessagingService.adaptivePieceSize(8 * mib), 256 * kib);
    // Mid-size: pieces widen to keep the manifest at ~4096 hashes.
    expect(MessagingService.adaptivePieceSize(8 * gib), 2 * mib);
    // Huge: the piece caps at 32 MiB (it is held in RAM on every hop) and the
    // piece COUNT grows instead.
    expect(MessagingService.adaptivePieceSize(1024 * gib), 32 * mib);
    final pieces = (1024 * gib) ~/ MessagingService.adaptivePieceSize(1024 * gib);
    expect(pieces, 32768,
        reason: '1 TB ≈ 32 K piece hashes ≈ a ~3 MB manifest — still under '
            'the durable-manifest storeFile cap');
  });

  test('eraseSpace removes the whole on-disk tier directory', () async {
    final s = HiddenVolumeStorage(_mem());
    await s.open(password: 'p', createIfMissing: true);
    s.useOnDiskTier(blobDir, minBytes: 1000);
    await storeOnDiskFileMessage(s, id(0xCC), 'cid-erase');
    expect(blobDir.listSync(recursive: true).whereType<File>(), isNotEmpty);

    await s.eraseSpace();

    expect(await blobDir.exists(), isFalse,
        reason: 'an erased identity must not leave size-shaped blob traces');
  });
}
