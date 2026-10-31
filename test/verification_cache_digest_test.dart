import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/crypto/verification_cache_digest.dart';

void main() {
  final digest = VerificationCacheDigest.dart();

  test('fallback uses SHA-256, including empty input', () {
    expect(digest.nativeEnabled, isFalse);
    for (final length in [0, 1, 31, 32, 63, 64, 65, 1023, 1024, 2049, 65536]) {
      final input = Uint8List.fromList(
        List.generate(length, (index) => (index * 31 + 17) & 255),
      );
      final before = Uint8List.fromList(input);
      expect(digest.hash(input), crypto.sha256.convert(input).bytes);
      expect(input, before, reason: 'hashing must not alter a signed row');
    }
  });

  test('changed input is rehashed and outputs are not shared', () {
    final input = Uint8List.fromList(List.generate(4097, (i) => i & 255));
    final original = digest.hash(input);
    final independent = digest.hash(input);
    original[0] ^= 255;
    expect(digest.hash(input), independent);
    input[2048] ^= 1;
    expect(digest.hash(input), isNot(independent));
    expect(digest.hash(input), crypto.sha256.convert(input).bytes);
  });

  test('chunked fallback equals hashing concatenated bytes', () {
    final parts = [
      Uint8List(0),
      Uint8List.fromList([1]),
      Uint8List.fromList(List.generate(4097, (i) => i & 255)),
      Uint8List(0),
      Uint8List.fromList([2, 3]),
    ];
    expect(
      digest.hashParts(parts),
      crypto.sha256.convert(parts.expand((part) => part).toList()).bytes,
    );
    expect(digest.hashParts([]), digest.hash(Uint8List(0)));
  });
}
