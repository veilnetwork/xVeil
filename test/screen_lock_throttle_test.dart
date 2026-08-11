// How often a wrong answer may be tried.//
// audit report10 X-05. The verifier is a deliberately cheap HMAC — correctly
// so, it lives in the same memory as the container keys — and there was no
// limit on attempts at all. UI automation could walk a four-digit PIN at the
// speed of the event loop.
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/screen_lock_controller.dart';


void main() {
  test('a slip costs nothing', () {
    // Fingers slip. Punishing the first mistype trains people to pick shorter
    // passwords, which is the opposite of the point.
    expect(ScreenLockController.throttleAfter(1), Duration.zero);
    expect(ScreenLockController.throttleAfter(2), Duration.zero);
  });

  test('persistence costs more each time', () {
    final third = ScreenLockController.throttleAfter(3);
    final fourth = ScreenLockController.throttleAfter(4);
    final fifth = ScreenLockController.throttleAfter(5);
    expect(third, greaterThan(Duration.zero));
    expect(fourth, greaterThan(third));
    expect(fifth, greaterThan(fourth));
  });

  test('but never more than thirty seconds', () {
    // The cap is the anti-denial-of-service half. An uncapped doubling locks a
    // person out of their own messenger for hours because a cat sat on the
    // keyboard.
    for (final n in [10, 20, 100, 1000]) {
      expect(
        ScreenLockController.throttleAfter(n),
        lessThanOrEqualTo(const Duration(seconds: 30)),
        reason: 'after $n failures the wait must still be survivable',
      );
    }
    expect(
      ScreenLockController.throttleAfter(1000),
      const Duration(seconds: 30),
      reason: 'and it must actually REACH the cap, not stop short of it',
    );
  });

  test('the delay grows fast enough to matter', () {
    // The property that makes this a defence rather than an annoyance: a
    // four-digit PIN is 10000 guesses, and at the cap that is over 80 hours.
    // Without this assertion a backoff of one millisecond would pass every
    // test above.
    expect(
      ScreenLockController.throttleAfter(12),
      greaterThanOrEqualTo(const Duration(seconds: 10)),
      reason: 'a dozen wrong answers must cost real time, not a token pause',
    );
  });
}
