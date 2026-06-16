import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/routing/router.dart';
import 'package:xveil/state/app_controller.dart';

/// The routing SECURITY GATE: no screen may be reachable before unlock.
void main() {
  // Every protected location a deep link or stale route could point at.
  const protected = [
    '/home',
    '/chat/abc123',
    '/add-identity',
    '/decoy-master',
    '/splash',
    '/onboarding',
    '/pick-identity',
    '/preparing',
  ];

  test('locked: every location except /lock redirects to /lock', () {
    for (final loc in protected) {
      expect(redirectForPhase(AppPhase.locked, loc), '/lock',
          reason: '$loc must not be reachable while locked');
    }
    expect(redirectForPhase(AppPhase.locked, '/lock'), isNull);
  });

  test('onboarding/bootstrapping/picking/preparing each pin to their screen',
      () {
    expect(redirectForPhase(AppPhase.bootstrapping, '/home'), '/splash');
    expect(redirectForPhase(AppPhase.bootstrapping, '/splash'), isNull);
    expect(redirectForPhase(AppPhase.onboarding, '/chat/x'), '/onboarding');
    expect(redirectForPhase(AppPhase.onboarding, '/onboarding'), isNull);
    expect(redirectForPhase(AppPhase.pickingIdentity, '/home'), '/pick-identity');
    expect(redirectForPhase(AppPhase.pickingIdentity, '/pick-identity'), isNull);
    expect(redirectForPhase(AppPhase.preparingNode, '/home'), '/preparing');
    expect(redirectForPhase(AppPhase.preparingNode, '/preparing'), isNull);
  });

  test('ready: gate screens bounce to /home, app screens are allowed', () {
    for (final gate in ['/splash', '/lock', '/onboarding', '/pick-identity', '/preparing']) {
      expect(redirectForPhase(AppPhase.ready, gate), '/home',
          reason: '$gate should bounce to /home once ready');
    }
    for (final app in ['/home', '/chat/abc123', '/add-identity', '/decoy-master']) {
      expect(redirectForPhase(AppPhase.ready, app), isNull,
          reason: '$app should be allowed once ready');
    }
  });
}
