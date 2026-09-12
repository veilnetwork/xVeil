// When to say a device's delegation is running out — and when to stay silent.
//
// The delegation is a seven-day certificate that only the master can extend.
// When it runs out the device does not break: it goes QUIET, and others stop
// being able to reach it there. Nothing else says so, which is why this
// decision has to be right in both directions — a warning that never comes is
// a device that vanishes without explanation, and a warning that comes for the
// wrong reason is one nobody believes the day it matters.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/devices_screen.dart';

void main() {
  const window = kDelegationWindowSecs;
  const now = 1800000000;

  test('a fresh delegation says nothing', () {
    expect(
      delegationNotice(
        validUntilUnix: now + window,
        nowUnix: now,
        windowSecs: window,
      ),
      DelegationNotice.none,
    );
  });

  test('past half the window it asks to be renewed', () {
    // Half is where the runtime's own self-renewal starts for a standalone
    // device: earlier nags, later leaves no room to act.
    expect(
      delegationNotice(
        validUntilUnix: now + window ~/ 2,
        nowUnix: now,
        windowSecs: window,
      ),
      DelegationNotice.expiring,
      reason: 'exactly half must already warn, not warn one second later',
    );
    expect(
      delegationNotice(
        validUntilUnix: now + window ~/ 2 + 1,
        nowUnix: now,
        windowSecs: window,
      ),
      DelegationNotice.none,
    );
  });

  test('an expired delegation is its own state, not a louder warning', () {
    // The two differ in what has already happened: expiring costs nothing
    // yet, lapsed means others cannot reach this device right now.
    expect(
      delegationNotice(
        validUntilUnix: now,
        nowUnix: now,
        windowSecs: window,
      ),
      DelegationNotice.lapsed,
      reason: 'the moment it runs out it is out, not nearly out',
    );
    expect(
      delegationNotice(
        validUntilUnix: now - 1,
        nowUnix: now,
        windowSecs: window,
      ),
      DelegationNotice.lapsed,
    );
  });

  test('unknown is silence, never an alarm', () {
    // 0 is what a failed read reports. Treating it as expired would raise the
    // loudest warning in the app every time a node was still coming up.
    expect(
      delegationNotice(validUntilUnix: 0, nowUnix: now, windowSecs: window),
      DelegationNotice.none,
      reason: 'a warning raised by a failed read makes the real one worthless',
    );
  });
}
