import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/crypto/sha256_backend.dart';

void main() {
  test(
    'SHA backend fallback preserves exact digests and fresh mutable bytes',
    () {
      final hash = Sha256Backend.dart();
      expect(hash.nativeEnabled, isFalse);
      for (final size in [0, 1, 55, 56, 63, 64, 65, 4097, 65536]) {
        final bytes = Uint8List.fromList(List.generate(size, (i) => i & 255));
        final before = Uint8List.fromList(bytes);
        final expected = crypto.sha256.convert(bytes).bytes;
        expect(hash.hash(bytes), expected);
        expect(
          hash.hashParts([
            Uint8List.sublistView(bytes, 0, size ~/ 2),
            Uint8List(0),
            Uint8List.sublistView(bytes, size ~/ 2),
          ]),
          expected,
        );
        expect(bytes, before);
        hash.hash(bytes)[0] ^= 1;
        expect(
          hash.hash(bytes),
          expected,
          reason: 'result storage is independent',
        );
        if (size > 0) {
          bytes[size ~/ 2] ^= 1;
          expect(hash.hash(bytes), crypto.sha256.convert(bytes).bytes);
          expect(hash.hash(bytes), isNot(expected));
        }
      }
    },
  );
}
