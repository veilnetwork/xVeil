import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/crypto/verification_cache_digest.dart';
import 'package:xveil/data/native_libs.dart';

void main() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  test(
    'native and fallback cache digests agree across block boundaries',
    () {
      final library = DynamicLibrary.open(path!);
      final native = VerificationCacheDigest.forLibrary(library);
      final fallback = VerificationCacheDigest.dart();
      expect(native.nativeEnabled, isTrue, reason: 'native is required here');
      expect(VerificationCacheDigest.forLibrary(library), same(native));
      rememberNativeLib('veilclient_ffi', library);
      addTearDown(debugResetNativeLibHandles);
      // The GUI constructs its signer without an explicit library argument.
      // Qualify that ABI-checked default path too, not only the probe's handle.
      expect(VerificationCacheDigest.forLibrary(), same(native));
      final random = Random(31);
      for (final length in [
        0,
        1,
        31,
        32,
        55,
        56,
        63,
        64,
        65,
        127,
        128,
        1023,
        1024,
        1025,
        2047,
        2048,
        4097,
        65536,
        262144,
      ]) {
        final input = Uint8List.fromList(
          List.generate(length, (_) => random.nextInt(256)),
        );
        final before = Uint8List.fromList(input);
        final expected = crypto.sha256.convert(input).bytes;
        final actual = native.hash(input);
        expect(actual, expected, reason: 'native input length $length');
        expect(fallback.hash(input), actual);
        final middle = length ~/ 2;
        final parts = [
          Uint8List.sublistView(input, 0, middle),
          Uint8List(0),
          Uint8List.sublistView(input, middle),
        ];
        expect(native.hashParts(parts), expected);
        expect(fallback.hashParts(parts), expected);
        expect(input, before);
        actual[0] ^= 255;
        expect(native.hash(input), expected, reason: 'independent output');
        if (input.isNotEmpty) {
          input[length ~/ 2] ^= 1;
          expect(native.hash(input), crypto.sha256.convert(input).bytes);
          expect(native.hash(input), isNot(expected));
        }
      }
    },
    skip: path == null ? 'set VEIL_FFI_DYLIB' : false,
  );
}
