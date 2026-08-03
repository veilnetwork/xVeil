import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/secret_wipe.dart';

void main() {
  group('wiping secrets before release (audit XV-22)', () {
    test('a Dart buffer is zeroed END TO END, not almost', () {
      // The whole value of a wipe is that it leaves NOTHING. A loop that stops
      // one short leaves the last byte of a key sitting in the heap and reads
      // as "wiped" to anyone glancing at the code.
      final secret = Uint8List.fromList(List.generate(64, (i) => i + 1));
      wipeSecretBytes(secret);
      expect(secret.every((b) => b == 0), isTrue);
      expect(secret.last, 0, reason: 'the tail is where an off-by-one hides');
      expect(secret.first, 0);
      expect(secret.length, 64, reason: 'wiped in place, not replaced');
    });

    test('null and empty are no-ops, not crashes', () {
      wipeSecretBytes(null);
      wipeSecretBytes(Uint8List(0));
    });

    test('a native buffer is zeroed before it can be freed', () {
      // This half IS exact: calloc memory does not move, so after the wipe the
      // plaintext is gone from that address and the allocator can hand the
      // block on. This is the case that matters — the node config carries the
      // Ed25519 private key and is copied into such a buffer on every compose,
      // sign and apply-config.
      const len = 48;
      final p = calloc<Uint8>(len);
      try {
        p.asTypedList(len).setAll(0, List.generate(len, (i) => 0xA0 + i % 16));
        expect(p.asTypedList(len).any((b) => b != 0), isTrue);

        wipeNativeSecret(p, len);

        expect(p.asTypedList(len).every((b) => b == 0), isTrue);
        expect(p.asTypedList(len).last, 0);
      } finally {
        calloc.free(p);
      }
    });

    test('a null pointer or a zero length does nothing', () {
      wipeNativeSecret(nullptr, 32);
      final p = calloc<Uint8>(1);
      try {
        wipeNativeSecret(p, 0);
      } finally {
        calloc.free(p);
      }
    });
  });
}
