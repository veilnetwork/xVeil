import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/calls/call_log_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat/mentions_screen.dart';
import '../features/groups/group_chat_screen.dart';
import '../features/home/home_shell.dart';
import '../features/identity/add_identity_screen.dart';
import '../features/identity/decoy_master_screen.dart';
import '../features/identity/identity_picker_screen.dart';
import '../features/identity/manage_identities_screen.dart';
import '../features/lock/lock_screen.dart';
import '../features/network/managed_nodes_screen.dart';
import '../features/network/network_screen.dart';
import '../features/network/peers_screen.dart';
import '../features/network/proxy_routing_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/preparing/preparing_screen.dart';
import '../features/settings/account_settings_screen.dart';
import '../features/settings/appearance_settings_screen.dart';
import '../features/settings/profile_screen.dart';
import '../features/settings/chats_settings_screen.dart';
import '../features/settings/devices_screen.dart';
import '../features/settings/file_settings_screen.dart';
import '../features/settings/nickname_screen.dart';
import '../features/settings/p2p_selected_screen.dart';
import '../features/settings/privacy_settings_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/storage_settings_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/spaces/public_space_posts_screen.dart';
import '../features/spaces/public_space_post_comments_screen.dart';
import '../features/spaces/space_list_screen.dart';
import '../features/spaces/space_moderation_screen.dart';
import '../features/spaces/space_post_comments_screen.dart';
import '../features/spaces/space_posts_screen.dart';
import '../features/spaces/space_screen.dart';
import '../features/spaces/space_rules_screen.dart';
import '../features/spaces/space_settings_screen.dart';
import '../features/storage/cloud_storage_screen.dart';
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
      // add-identity, decoy). Leaving /preparing lands on home too — restoring
      // the page a node-config change bounced the user out of is the ROUTER's
      // job, not the gate's, because that restore has to PUSH onto home rather
      // than replace it (see the redirect in [routerProvider]).
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

/// The router's root navigator. Exposed so widgets floated ABOVE the router
/// (the call overlay stack) can present dialogs on the real navigator — they
/// sit outside its subtree and have no Navigator ancestor of their own.
final rootNavigatorKey = GlobalKey<NavigatorState>();

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

  // The location a node-restarting settings change bounced the user OUT of
  // (→ /preparing). Restored on the next `ready` so a config toggle doesn't
  // dump the user into chats. SETTINGS pages only — they are identity-generic,
  // so resuming is safe even when the restart switched the active identity.
  String? resumeAfterPrepare;

  late final GoRouter router;
  router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final phase = ref.read(appControllerProvider).phase;
      final location = state.matchedLocation;
      if (phase == AppPhase.preparingNode && location.startsWith('/settings')) {
        resumeAfterPrepare = location; // about to be bounced to /preparing
      }
      if (phase == AppPhase.ready && location == '/preparing') {
        final resume = resumeAfterPrepare;
        resumeAfterPrepare = null; // consumed (or defaulted to /home)
        if (resume != null) {
          // Land on home FIRST, then push the settings page on top. A redirect
          // REPLACES the stack, so returning `resume` here would drop the user
          // onto a settings screen with nothing below it — and the flat router
          // turns that into a screen whose back arrow has nowhere to go. This
          // is the pattern notification taps and the comments fallback use.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              router.push(resume);
            } catch (_) {
              // An identity switch can tear the router down between the
              // redirect and the next frame. Losing the restore is fine;
              // being left on home is not a dead end.
            }
          });
          return '/home';
        }
      }
      return redirectForPhase(phase, location);
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      // Debug-only preview of the onboarding wizard from a READY session
      // (the real /onboarding is redirect-locked to the onboarding phase),
      // so the phrase/restore steps can be device-verified without wiping
      // an onboarded install. View-only by convention: finishing the wizard
      // here would re-run completeOnboarding.
      if (kDebugMode)
        GoRoute(
          path: '/onboarding-preview',
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
      GoRoute(path: '/mentions', builder: (_, _) => const MentionsScreen()),
      // Network and Settings are pushed from the drawer app-menu (they left
      // the bottom bar when it became Chats + reserved future sections).
      GoRoute(path: '/network', builder: (_, _) => const NetworkScreen()),
      GoRoute(path: '/calls', builder: (_, _) => const CallLogScreen()),
      GoRoute(path: '/spaces', builder: (_, _) => const SpaceListScreen()),
      GoRoute(path: '/storage', builder: (_, _) => const CloudStorageScreen()),
      GoRoute(
        path: '/space/:id',
        builder: (_, state) =>
            SpaceScreen(spaceIdHex: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/space/:id/channel/:channelId',
        builder: (_, state) => GroupChatScreen(
          groupIdHex: state.pathParameters['id']!,
          channelIdHex: state.pathParameters['channelId']!,
          initialJumpTo: state.uri.queryParameters['msg'],
        ),
      ),
      GoRoute(
        path: '/space/:id/posts',
        builder: (_, state) =>
            SpacePostsScreen(spaceIdHex: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/space/:id/public-posts',
        builder: (_, state) => PublicSpacePostsScreen(
          spaceIdHex: state.pathParameters['id']!,
          initialPostId: state.uri.queryParameters['post'],
        ),
      ),
      GoRoute(
        path: '/space/:id/comments',
        builder: (_, state) => SpacePostCommentsScreen(
          spaceIdHex: state.pathParameters['id']!,
          postId: state.uri.queryParameters['post'] ?? '',
          initialCommentRef: state.uri.queryParameters['comment'],
        ),
      ),
      GoRoute(
        path: '/space/:id/public-comments',
        builder: (_, state) => PublicSpacePostCommentsScreen(
          spaceIdHex: state.pathParameters['id']!,
          postId: state.uri.queryParameters['post'] ?? '',
          initialCommentRef: state.uri.queryParameters['comment'],
        ),
      ),
      GoRoute(
        path: '/space/:id/settings',
        builder: (_, state) =>
            SpaceSettingsScreen(spaceIdHex: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/space/:id/rules',
        builder: (_, state) =>
            SpaceRulesScreen(spaceIdHex: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/space/:id/moderation',
        builder: (_, state) =>
            SpaceModerationScreen(spaceIdHex: state.pathParameters['id']!),
      ),
      // Group chats live in the Chats surface; keep the old list deep-link
      // useful without conflating it with Communities.
      GoRoute(path: '/groups', redirect: (_, _) => '/home'),
      GoRoute(
        path: '/group/:id',
        builder: (_, state) => GroupChatScreen(
          groupIdHex: state.pathParameters['id']!,
          initialJumpTo: state.uri.queryParameters['msg'],
        ),
      ),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(
        path: '/settings/account',
        builder: (_, _) => const AccountSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/devices',
        builder: (_, _) => const DevicesScreen(),
      ),
      GoRoute(
        path: '/settings/privacy',
        builder: (_, _) => const PrivacySettingsScreen(),
      ),
      GoRoute(
        path: '/settings/nickname',
        builder: (_, _) => const NicknameScreen(),
      ),
      GoRoute(
        path: '/settings/p2p-selected',
        builder: (_, _) => const P2PSelectedScreen(),
      ),
      GoRoute(
        path: '/settings/chats',
        builder: (_, _) => const ChatsSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/storage',
        builder: (_, _) => const StorageSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/appearance',
        builder: (_, _) => const AppearanceSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/profiles',
        builder: (_, _) => const ProfileScreen(),
      ),
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
        builder: (_, state) => ChatScreen(
          peerHex: state.pathParameters['peerHex']!,
          // ?msg=<id>: land on a specific message (global-search hit).
          initialJumpTo: state.uri.queryParameters['msg'],
        ),
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
  return router;
});
