import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';

Uint8List _bytes(int n) {
  final r = Random(n);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Deterministic, fast (no per-byte RNG) — for the multi-MiB cases.
Uint8List _patterned(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) % 256));

void main() {
  late FileStore store;
  setUp(() => store = FileStore(FakeKvLogStore()));

  test('stores and reloads files of various sizes (incl. multi-chunk/empty)',
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
  });

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

  test('stores + reloads a multi-MiB file (chunks split across many commits)',
      () {
    // ~3 MB ⇒ ~375 store-records. A single commit caps at ~1 MiB / 1024 records,
    // so before the multi-commit fix this overflowed one batch and the real
    // store threw PayloadTooLarge ("payload exceeds chunk capacity"). The blob
    // must round-trip identically once reassembled from every commit.
    final data = _patterned(3 * 1000 * 1000);
    store.storeFile('big', data, name: 'video.bin');
    expect(store.loadFile('big'), data);
    expect(store.metadata('big')!.size, data.length);
  });

  test('rejects a file over the storage cap; a file exactly at the cap is fine',
      () {
    // The cap is the atomic-delete ceiling (≤1024 records × 8 KiB): a stored file
    // must be deletable in one commit so a deleted blob can't linger half-scrubbed.
    final tooBig = Uint8List(kMaxStoredFileBytes + 1);
    expect(() => store.storeFile('huge', tooBig),
        throwsA(isA<ArgumentError>()),
        reason: 'over-cap blob is rejected up-front, not stored');
    final atCap = Uint8List(kMaxStoredFileBytes);
    store.storeFile('atcap', atCap);
    expect(store.loadFile('atcap')!.length, kMaxStoredFileBytes);
  });
}
