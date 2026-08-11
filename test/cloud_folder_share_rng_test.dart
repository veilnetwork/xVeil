// The nonce source a caller gets when it does not pass one.
//
// audit report10 X-11. It used to be `Uint8List(count)` — zeros. The
// production caller passes a CSPRNG, so nothing was broken; the SHAPE was. An
// optional parameter that silently degrades to a constant hands the next
// caller repeated nonces, correlation across requests and a replay window,
// with nothing anywhere to notice it by.
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/cloud_folder_share.dart';

void main() {
  test('the default nonce source is not a buffer of zeros', () {
    final first = debugDefaultShareRandom(32);
    expect(first.length, 32);
    expect(
      first.every((b) => b == 0),
      isFalse,
      reason: 'an omitted generator must not mean "no randomness"',
    );
  });

  test('two draws differ', () {
    // The positive control for the one above: a source that returned a fixed
    // NON-zero pattern would pass "not all zeros" and still repeat every nonce.
    final a = debugDefaultShareRandom(32);
    final b = debugDefaultShareRandom(32);
    expect(a, isNot(equals(b)));
  });
}
