import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/chat/chat_screen.dart';
import '../features/home/home_shell.dart';
import '../features/lock/lock_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/preparing/preparing_screen.dart';
import '../features/splash/splash_screen.dart';
import '../state/app_controller.dart';

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
    redirect: (context, state) {
      final phase = ref.read(appControllerProvider).phase;
      final loc = state.matchedLocation;
      switch (phase) {
        case AppPhase.bootstrapping:
          return loc == '/splash' ? null : '/splash';
        case AppPhase.onboarding:
          return loc == '/onboarding' ? null : '/onboarding';
        case AppPhase.locked:
          return loc == '/lock' ? null : '/lock';
        case AppPhase.preparingNode:
          return loc == '/preparing' ? null : '/preparing';
        case AppPhase.ready:
          // Bounce the gate screens to home; allow everything else (chat).
          if (loc == '/splash' ||
              loc == '/lock' ||
              loc == '/onboarding' ||
              loc == '/preparing') {
            return '/home';
          }
          return null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: '/onboarding',
        builder: (_, _) => const OnboardingScreen(),
      ),
      GoRoute(path: '/lock', builder: (_, _) => const LockScreen()),
      GoRoute(
        path: '/preparing',
        // No transition: the switch happens right before a brief CPU-bound
        // block (Argon2 container open), so an animated slide would freeze
        // half-way. Showing the screen instantly avoids a stuck half-transition.
        pageBuilder: (_, _) => const NoTransitionPage(child: PreparingScreen()),
      ),
      GoRoute(path: '/home', builder: (_, _) => const HomeShell()),
      GoRoute(
        path: '/chat/:peerHex',
        builder: (_, state) =>
            ChatScreen(peerHex: state.pathParameters['peerHex']!),
      ),
    ],
  );
});
