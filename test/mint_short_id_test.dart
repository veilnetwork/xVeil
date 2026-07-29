import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';

/// Two copies of this minted an API-token id by base64url-encoding six random
/// bytes and then stripping `[=_-]`. `-` and `_` ARE base64url characters, so
/// three or more of them left a string shorter than six and `substring(0, 6)`
/// threw RangeError — about one call in 585, which is rare enough to pass
/// review twice and common enough to meet a real user creating a token.
void main() {
  test('a short id is always six characters', () {
    // Enough draws that the old implementation would have thrown with
    // overwhelming probability (1 - (1 - 1/585)^20000 is indistinguishable
    // from 1), and fast enough to keep in the suite.
    for (var i = 0; i < 20000; i++) {
      expect(mintShortId().length, 6);
    }
  });

  test('it survives the byte pattern that produced the crash', () {
    // Every byte 0xFF encodes to '/' in base64 and '_' in base64url, so the
    // whole eight-character encoding was stripped away and substring(0, 6) had
    // nothing to cut. A seeded generator pins the case rather than waiting for
    // it to come up by chance.
    final id = mintShortId(_AllOnes());
    expect(id.length, 6);
    expect(id, '______');
  });
}

/// Yields 0xFF for every byte.
class _AllOnes implements Random {
  @override
  int nextInt(int max) => max - 1;
  @override
  bool nextBool() => true;
  @override
  double nextDouble() => 1.0;
}
