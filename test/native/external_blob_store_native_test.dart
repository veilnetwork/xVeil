import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/external_blob_store.dart';

/// Exercises the out-of-container encrypted blob store against the REAL veil
/// XChaCha20-Poly1305 FFI (veil_seal/veil_unseal). Needs the veil dylib loaded —
/// run with `VEIL_FFI_DYLIB=third_party/veil/target/debug/libveilclient_ffi.dylib
/// flutter test test/native/external_blob_store_native_test.dart`. Skipped
/// otherwise so CI without the dylib stays green.
void main() {
  final skip = (Platform.environment['VEIL_FFI_DYLIB'] ?? '').isEmpty
      ? 'set VEIL_FFI_DYLIB to the built libveilclient_ffi.dylib'
      : null;

  Uint8List rnd(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  test('multi-MiB incompressible blob round-trips through the encrypted store',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_blob_');
    try {
      final master = rnd(32, 1);
      final store = ExternalBlobStore(dir, master);
      final data = rnd(3 * 1024 * 1024 + 777, 42); // not a segment multiple

      // Stream it in irregular chunks (like a file read / a network stream).
      Stream<List<int>> src() async* {
        var i = 0;
        final r = Random(7);
        while (i < data.length) {
          final n = 1 + r.nextInt(70000);
          yield Uint8List.sublistView(
              data, i, (i + n) > data.length ? data.length : i + n);
          i += n;
        }
      }

      final written = await store.writeBlob('tid-1', src());
      expect(written, data.length);
      expect(await store.size('tid-1'), data.length);
      expect(await store.readBlobBytes('tid-1'), data,
          reason: 'decrypts byte-for-byte');

      // On-disk file is opaque ciphertext (not the plaintext anywhere).
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      final cipher = files.single.readAsBytesSync();
      expect(cipher.length, greaterThan(data.length)); // + per-segment tags
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('a DIFFERENT master key cannot open the blob (key is the container)',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_blob2_');
    try {
      final data = rnd(200000, 9);
      await ExternalBlobStore(dir, rnd(32, 1))
          .writeBlob('t', Stream.value(data));
      // Same dir, WRONG master key → the opaque name differs AND a forced read
      // would fail the AEAD. With the wrong key the blob id maps to a missing
      // file, so it simply isn't found.
      final attacker = ExternalBlobStore(dir, rnd(32, 2));
      expect(await attacker.readBlobBytes('t'), isNull);
      // The legit key reads it back.
      expect(await ExternalBlobStore(dir, rnd(32, 1)).readBlobBytes('t'), data);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('gcOrphans deletes blobs no message references', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_blob_gc_');
    try {
      final store = ExternalBlobStore(dir, rnd(32, 5));
      await store.writeBlob('keep-me', Stream.value(rnd(50000, 1)));
      await store.writeBlob('orphan', Stream.value(rnd(50000, 2)));
      expect(await store.exists('keep-me'), isTrue);
      expect(await store.exists('orphan'), isTrue);

      final removed = await store.gcOrphans({'keep-me'});
      expect(removed, 1, reason: 'only the unreferenced blob is swept');
      expect(await store.exists('keep-me'), isTrue);
      expect(await store.exists('orphan'), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);
}
