import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _bytes(int n) {
  final r = Random(n);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Deterministic, fast (no per-byte RNG) — for the multi-MiB cases.
Uint8List _patterned(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) % 256));

void main() {
  late FakeKvLogStore rawStore;
  late FileStore store;
  setUp(() {
    rawStore = FakeKvLogStore();
    store = FileStore(rawStore);
  });

  test(
    'stores and reloads files of various sizes (incl. multi-chunk/empty)',
    () {
      for (final n in [0, 1, 7999, 8000, 8001, 50000]) {
        final data = _bytes(n);
        final id = 'f$n';
        store.storeFile(id, data, name: 'pic$n.bin');
        expect(store.loadFile(id), data, reason: 'size $n');
        final meta = store.metadata(id)!;
        expect(meta.size, n);
        expect(meta.name, 'pic$n.bin');
      }
    },
  );

  test('multiple files do not overlap (sequential log ids)', () {
    final a = _bytes(12000);
    final b = _bytes(9000);
    store.storeFile('a', a);
    store.storeFile('b', b);
    expect(store.loadFile('a'), a);
    expect(store.loadFile('b'), b);
  });

  test('unknown file id returns null', () {
    expect(store.loadFile('nope'), isNull);
    expect(store.metadata('nope'), isNull);
  });

  test('legacy contiguous metadata remains readable and deletable', () {
    final data = _bytes(9000);
    store.storeFile('legacy', data, name: 'old.bin');
    rawStore.commit([
      PutOp(
        Ns.settings,
        Uint8List.fromList('file:legacy'.codeUnits),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'name': 'old.bin',
              'size': data.length,
              'base': 1,
              'count': 3,
            }),
          ),
        ),
      ),
    ]);
    expect(store.loadFile('legacy'), data);
    store.deleteFile('legacy');
    expect(store.loadFile('legacy'), isNull);
    for (var id = 1; id <= 3; id++) {
      expect(rawStore.readLog(Ns.fileChunks, id), isNull);
    }
  });

  test('empty at-rest file uses metadata only and no log id', () {
    store.storeFile('empty', Uint8List(0), name: 'empty.txt');
    expect(store.loadFile('empty'), Uint8List(0));
    expect(rawStore.count(Ns.fileChunks), 0);
    final raw = rawStore.get(
      Ns.settings,
      Uint8List.fromList('file:empty'.codeUnits),
    )!;
    expect((jsonDecode(utf8.decode(raw)) as Map)['segments'], isEmpty);
  });

  test('orphan collector preserves every metadata-referenced record', () {
    final live = _bytes(9000);
    store.storeFile('live', live); // ids 1..3
    rawStore.commit([
      AppendLogOp(Ns.fileChunks, 4, _bytes(10)),
      AppendLogOp(Ns.fileChunks, 5, Uint8List(0)),
      AppendLogOp(Ns.fileChunks, 6, _bytes(10)),
      PutOp(
        Ns.settings,
        Uint8List.fromList('filepiece:stream:0'.codeUnits),
        Uint8List.fromList(
          utf8.encode(jsonEncode({'base': 6, 'count': 1, 'len': 10})),
        ),
      ),
    ]);

    expect(store.reclaimOrphanedFileChunkIds(), 2);

    expect(store.loadFile('live'), live);
    expect(rawStore.readLog(Ns.fileChunks, 4), isNull);
    expect(rawStore.readLog(Ns.fileChunks, 5), isNull);
    expect(rawStore.readLog(Ns.fileChunks, 6), isNotNull);
    expect(store.reclaimOrphanedFileChunkIds(), 0, reason: 'idempotent');
  });

  test('orphan collector fails closed on malformed live metadata', () {
    rawStore.commit([
      AppendLogOp(Ns.fileChunks, 1, _bytes(10)),
      PutOp(
        Ns.settings,
        Uint8List.fromList('file:broken'.codeUnits),
        Uint8List.fromList(utf8.encode(jsonEncode({'segments': 'bad'}))),
      ),
    ]);

    expect(store.reclaimOrphanedFileChunkIds, throwsA(isA<FormatException>()));
    expect(rawStore.readLog(Ns.fileChunks, 1), isNotNull);
  });

  test('store automatically reclaims an aged near-capacity chunk index', () {
    for (var base = 1; base <= 12000; base += 512) {
      final end = base + 512 <= 12001 ? base + 512 : 12001;
      rawStore.commit([
        for (var id = base; id < end; id++)
          AppendLogOp(Ns.fileChunks, id, Uint8List(0)),
      ]);
    }
    expect(rawStore.count(Ns.fileChunks), 12000);

    final data = _bytes(100);
    store.storeFile('fresh', data);

    expect(store.loadFile('fresh'), data);
    expect(rawStore.count(Ns.fileChunks), 1);
  });

  test('stores + reloads a multi-MiB file (chunks split across many commits)', () {
    // ~3 MB ⇒ ~375 store-records. A single commit caps at ~1 MiB / 1024 records,
    // so before the multi-commit fix this overflowed one batch and the real
    // store threw PayloadTooLarge ("payload exceeds chunk capacity"). The blob
    // must round-trip identically once reassembled from every commit.
    final data = _patterned(3 * 1000 * 1000);
    store.storeFile('big', data, name: 'video.bin');
    expect(store.loadFile('big'), data);
    expect(store.metadata('big')!.size, data.length);
  });

  test(
    'rejects a file over the storage cap; a file exactly at the cap is fine',
    () {
      // The cap is the atomic-delete ceiling (≤1024 records × 8 KiB): a stored file
      // must be deletable in one commit so a deleted blob can't linger half-scrubbed.
      final tooBig = Uint8List(kMaxStoredFileBytes + 1);
      expect(
        () => store.storeFile('huge', tooBig),
        throwsA(isA<ArgumentError>()),
        reason: 'over-cap blob is rejected up-front, not stored',
      );
      final atCap = Uint8List(kMaxStoredFileBytes);
      store.storeFile('atcap', atCap);
      expect(store.loadFile('atcap')!.length, kMaxStoredFileBytes);
    },
  );
}
