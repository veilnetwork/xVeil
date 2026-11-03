import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/crypto/sovereign_signature_cache.dart';
import 'package:xveil/crypto/verification_cache_digest.dart';

void main() {
  test('exact checks reuse verdicts; every field and boundary is bound', () {
    var calls = 0;
    final cache = SovereignSignatureCache(
      digest: VerificationCacheDigest.dart(),
      verify:
          ({
            required algorithm,
            required nodeId,
            required publicKey,
            required message,
            required signature,
          }) => ++calls == 1,
    );
    final node = Uint8List(32);
    final key = Uint8List.fromList([1, 2]);
    final message = Uint8List.fromList([3, 4]);
    final signature = Uint8List.fromList([5, 6]);
    bool check({
      String algorithm = 'ed25519',
      Uint8List? n,
      Uint8List? k,
      Uint8List? m,
      Uint8List? s,
    }) => cache.verify(
      algorithm: algorithm,
      nodeId: n ?? node,
      publicKey: k ?? key,
      message: m ?? message,
      signature: s ?? signature,
    );
    expect(check(), isTrue);
    expect(check(), isTrue);
    expect(calls, 1);
    // Byte-identical fresh objects must hit too (each load reparses rows).
    expect(
      check(
        n: Uint8List.fromList(node),
        k: Uint8List.fromList(key),
        m: Uint8List.fromList(message),
        s: Uint8List.fromList(signature),
      ),
      isTrue,
    );
    expect(calls, 1);
    expect(check(algorithm: 'falcon512'), isFalse);
    expect(check(n: Uint8List.fromList([1, ...node.skip(1)])), isFalse);
    expect(check(k: Uint8List.fromList([9, 2])), isFalse);
    expect(check(m: Uint8List.fromList([9, 4])), isFalse);
    expect(check(s: Uint8List.fromList([9, 6])), isFalse);
    // Concatenation alone would alias each of these with the accepted tuple.
    expect(
      check(k: Uint8List.fromList([1]), m: Uint8List.fromList([2, 3, 4])),
      isFalse,
    );
    expect(
      check(m: Uint8List.fromList([3]), s: Uint8List.fromList([4, 5, 6])),
      isFalse,
    );
    expect(calls, 8);
    expect(check(), isTrue);
    expect(calls, 8);
    key[0] = 9;
    expect(check(), isFalse, reason: 'mutable input is rehashed');
    expect(calls, 8, reason: 'the exact negative result is cached too');
  });

  test(
    'bounded FIFO, fixed verifier ownership and throws are never verdicts',
    () {
      var calls = 0;
      var fail = true;
      final error = StateError('private native failure');
      final cache = SovereignSignatureCache(
        maxEntries: 2,
        digest: VerificationCacheDigest.dart(),
        verify:
            ({
              required algorithm,
              required nodeId,
              required publicKey,
              required message,
              required signature,
            }) {
              calls++;
              if (fail) throw error;
              return message.single == 0;
            },
      );
      bool check(int value) => cache.verify(
        algorithm: 'ed25519',
        nodeId: Uint8List(32),
        publicKey: Uint8List(32),
        message: Uint8List.fromList([value]),
        signature: Uint8List(64),
      );
      expect(() => check(0), throwsA(same(error)));
      expect(() => check(0), throwsA(same(error)));
      expect(calls, 2);
      fail = false;
      expect(check(0), isTrue);
      expect(check(0), isTrue);
      expect(check(1), isFalse);
      expect(check(1), isFalse);
      expect(calls, 4);
      expect(check(2), isFalse);
      expect(check(0), isTrue, reason: 'oldest entry was evicted');
      expect(calls, 6);
    },
  );
}
