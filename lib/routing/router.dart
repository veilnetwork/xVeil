import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/chat/chat_screen.dart';
import '../features/home/home_shell.dart';
import '../features/identity/add_identity_screen.dart';
import '../features/identity/decoy_master_screen.dart';
import '../features/identity/identity_picker_screen.dart';
import '../features/identity/manage_identities_screen.dart';
import '../features/lock/lock_screen.dart';
import '../features/network/managed_nodes_screen.dart';
import '../features/network/peers_screen.dart';
import '../features/network/proxy_routing_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/preparing/preparing_screen.dart';
import '../features/settings/file_settings_screen.dart';
import '../features/splash/splash_screen.dart';
import '../state/app_controller.dart';

/// The routing SECURITY GATE, as a pure function of (phase, current location):
/// returns null to stay put, or a path to redirect to. Each pre-`ready` phase
/// pins navigation to its single screen — so NO screen (home, chat, settings,
/// add-identity, decoy) is reachable before unlock: when `locked`, every
/// location except `/lock` redirects to `/lock`, and a deep link into `/chat`
/// while locked bounces to `/lock`. Extracted so this invariant is unit-testable
/// without pumping a full router.
String? redirectForPhase(AppPhase phase, String location) {
  switch (phase) {
    case AppPhase.bootstrapping:
      return location == '/splash' ? null : '/splash';
    case AppPhase.onboarding:
      return location == '/onboarding' ? null : '/onboarding';
    case AppPhase.locked:
      return location == '/lock' ? null : '/lock';
    case AppPhase.pickingIdentity:
      return location == '/pick-identity' ? null : '/pick-identity';
    case AppPhase.preparingNode:
      // The "manage identities" screen drives roster ops that re-enter the
      // session (passing through preparingNode); let it stay put and show its
      // own busy overlay so the user isn't bounced out mid-operation. It's a
      // post-unlock screen, so allowing it here doesn't weaken the lock gate.
      if (location == '/manage-identities') return null;
      return location == '/preparing' ? null : '/preparing';
    case AppPhase.ready:
      // Bounce the gate screens to home; allow everything else (chat, settings,
      // add-identity, decoy).
      if (location == '/splash' ||
          location == '/lock' ||
          location == '/onboarding' ||
          location == '/pick-identity' ||
          location == '/preparing') {
        return '/home';
      }
      return null;
  }
}

/// Builds the app router and gates navigation on [AppPhase]. A [ValueNotifier]
/// bridges Riverpod state changes into go_router's [refreshListenable] so
/// redirects re-run whenever the phase changes.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<AppPhase>(AppPhase.bootstrapping);
  ref.onDispose(refresh.dispose);
  ref.listen(
    appControllerProvider.select((s) => s.phase),
    (_, next) => refresh.value = next,
    fireImmediately: true,
  );

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) => redirectForPhase(
        ref.read(appControllerProvider).phase, state.matchedLocation),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: '/onboarding',
        builder: (_, _) => const OnboardingScreen(),
      ),
      GoRoute(path: '/lock', builder: (_, _) => const LockScreen()),
      GoRoute(
        path: '/pick-identity',
        builder: (_, _) => const IdentityPickerScreen(),
      ),
      GoRoute(
        path: '/preparing',
        // No transition: the switch happens right before a brief CPU-bound
        // block (Argon2 container open), so an animated slide would freeze
        // half-way. Showing the screen instantly avoids a stuck half-transition.
        pageBuilder: (_, _) => const NoTransitionPage(child: PreparingScreen()),
      ),
      GoRoute(path: '/home', builder: (_, _) => const HomeShell()),
      GoRoute(
        path: '/add-identity',
        builder: (_, _) => const AddIdentityScreen(),
      ),
      GoRoute(
        path: '/decoy-master',
        builder: (_, _) => const DecoyMasterScreen(),
      ),
      GoRoute(
        path: '/manage-identities',
        builder: (_, _) => const ManageIdentitiesScreen(),
      ),
      GoRoute(
        path: '/chat/:peerHex',
        builder: (_, state) =>
            ChatScreen(peerHex: state.pathParameters['peerHex']!),
      ),
      GoRoute(path: '/peers', builder: (_, _) => const PeersScreen()),
      GoRoute(path: '/route', builder: (_, _) => const ProxyRoutingScreen()),
      GoRoute(path: '/nodes', builder: (_, _) => const ManagedNodesScreen()),
      GoRoute(
        path: '/file-settings',
        builder: (_, _) => const FileSettingsScreen(),
      ),
    ],
  );
});
