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
    '/identity-erase-recovery',
    '/identity-setup-recovery',
  ];

  test('setup recovery pins deep links and ready leaves its screen', () {
    for (final path in [
      ...protected,
      '/settings',
      '/manage-identities',
      '/lock',
    ]) {
      expect(
        redirectForPhase(AppPhase.identitySetupRecovery, path),
        path == '/identity-setup-recovery' ? null : '/identity-setup-recovery',
      );
    }
    expect(
      redirectForPhase(AppPhase.ready, '/identity-setup-recovery'),
      '/home',
    );
  });

  test('erase recovery pins every route and ready leaves its screen', () {
    for (final path in [
      ...protected,
      '/settings',
      '/manage-identities',
      '/lock',
    ]) {
      if (path == '/identity-erase-recovery') continue;
      expect(
        redirectForPhase(AppPhase.identityEraseRecovery, path),
        '/identity-erase-recovery',
      );
    }
    expect(
      redirectForPhase(
        AppPhase.identityEraseRecovery,
        '/identity-erase-recovery',
      ),
      isNull,
    );
    expect(
      redirectForPhase(AppPhase.ready, '/identity-erase-recovery'),
      '/home',
    );
  });

  test('locked: every location except /lock redirects to /lock', () {
    for (final loc in protected) {
      expect(
        redirectForPhase(AppPhase.locked, loc),
        '/lock',
        reason: '$loc must not be reachable while locked',
      );
    }
    expect(redirectForPhase(AppPhase.locked, '/lock'), isNull);
  });

  test('onboarding/bootstrapping/picking/preparing each pin to their screen', () {
    expect(redirectForPhase(AppPhase.bootstrapping, '/home'), '/splash');
    expect(redirectForPhase(AppPhase.bootstrapping, '/splash'), isNull);
    expect(redirectForPhase(AppPhase.onboarding, '/chat/x'), '/onboarding');
    expect(redirectForPhase(AppPhase.onboarding, '/onboarding'), isNull);
    expect(
      redirectForPhase(AppPhase.pickingIdentity, '/home'),
      '/pick-identity',
    );
    expect(
      redirectForPhase(AppPhase.pickingIdentity, '/pick-identity'),
      isNull,
    );
    expect(redirectForPhase(AppPhase.preparingNode, '/home'), '/preparing');
    expect(redirectForPhase(AppPhase.preparingNode, '/preparing'), isNull);
    // Exception: the manage-identities screen stays mounted across the re-enter
    // its own roster ops trigger (it shows its own busy overlay).
    expect(
      redirectForPhase(AppPhase.preparingNode, '/manage-identities'),
      isNull,
    );
  });

  test('ready: gate screens bounce to /home, app screens are allowed', () {
    for (final gate in [
      '/splash',
      '/lock',
      '/onboarding',
      '/pick-identity',
      '/preparing',
    ]) {
      expect(
        redirectForPhase(AppPhase.ready, gate),
        '/home',
        reason: '$gate should bounce to /home once ready',
      );
    }
    for (final app in [
      '/home',
      '/chat/abc123',
      '/add-identity',
      '/decoy-master',
    ]) {
      expect(
        redirectForPhase(AppPhase.ready, app),
        isNull,
        reason: '$app should be allowed once ready',
      );
    }
  });

  test('leaving /preparing lands on home, never on a bare deep screen', () {
    // A node-restarting settings toggle bounces the user out of settings, and
    // the gate brings them back to HOME — not straight onto the settings page.
    // Restoring that page is the router's job and it PUSHES, because a
    // redirect REPLACES the stack: landing directly on /settings/account would
    // leave it with nothing below it, which the flat router renders without a
    // back affordance at all. See back_affordance_invariant_test.dart.
    expect(redirectForPhase(AppPhase.ready, '/preparing'), '/home');
    expect(redirectForPhase(AppPhase.ready, '/lock'), '/home');
    // The gate still pins the user to /preparing while the node restarts.
    expect(
      redirectForPhase(AppPhase.preparingNode, '/settings/account'),
      '/preparing',
    );
  });
}
