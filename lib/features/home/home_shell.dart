import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_update_controller.dart';
import '../../state/whisper_model_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../state/folder_panel_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show chatFoldersProvider;
import '../chat/chats_screen.dart';
import '../chat/notification_binder.dart';
import '../chat/signature_ask_host.dart';
import '../groups/group_tile.dart' show showCreateGroupDialog;
import '../network/background_permission_offer.dart'
    show maybeOfferBackgroundPermission;
import '../onboarding/bundled_seeds_choice.dart' show maybeOfferBundledSeeds;
import '../spaces/space_feed_screen.dart';
import '../spaces/space_list_screen.dart';
import 'home_section_scaffold.dart';
import 'menu_tiles_screen.dart';
import '../settings/hardening_sync_notice.dart';

/// The main authenticated surface. Chats and Communities are real tabs:
/// switching keeps the bottom bar and highlights the active destination —
/// pushing a route on top used to leave "Chats" lit while a different screen
/// showed). A community owns its text/voice channels; personal chats remain
/// separate. Personal cloud and the app-actions menu are the other tabs.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    // The speech model is fetched here, once, when the session opens: nobody
    // should have to know it exists or go looking for it in Settings. It is a
    // background errand — no dialog, no spinner in the way, and a failure
    // leaves the deliberate offer in place rather than interrupting anyone.
    //
    // After the first frame, so a 57 MB errand cannot compete with drawing
    // the screen someone is waiting for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(whisperModelControllerProvider.notifier)
            .ensureDownloadedInBackground(),
      );
      // An identity that declined the shared entry nodes and never added one of
      // its own cannot send or receive anything. Said here, once the session is
      // actually open, rather than left as a messenger that quietly never
      // connects. Silent for everyone else — see [maybeOfferBundledSeeds].
      unawaited(maybeOfferBundledSeeds(context, ref));
      // The one hardening failure with something to do about it: the masking
      // writes behind a commit had not reached the disk. The other two kinds
      // are about a commit already past and wait on the storage screen, where
      // nobody is interrupted by news they cannot act on.
      unawaited(maybeWarnHardeningSync(context, ref));
      // The same argument, one layer down the stack. Without the battery
      // exemption Android stops the node as soon as the screen goes off, and
      // the app goes on reporting itself ready — so an install that never
      // grants it is a messenger that silently receives nothing whenever it is
      // not in front of you. Asked once, dismissible for good, and the body
      // says where the switch lives afterwards.
      unawaited(maybeOfferBackgroundPermission(context));
      // Once a day at most, and silent unless there is something to say. The
      // check itself decides whether to ask at all — see [checkIfDue] — so
      // calling it on every launch costs nothing on the days it declines.
      unawaited(_offerUpdateIfAny());
    });
  }

  /// Say that a newer release exists, where a person will actually see it.
  ///
  /// A banner rather than a dialog: an update is not urgent, and this is a
  /// messenger somebody opened to read something. It stays until dismissed
  /// instead of sliding away like a snackbar, because "there is a new version"
  /// is worth a decision rather than a glimpse.
  ///
  /// The app installs nothing itself. What it can honestly offer is the
  /// release page.
  Future<void> _offerUpdateIfAny() async {
    await ref.read(appUpdateProvider.notifier).checkIfDue();
    if (!mounted) return;
    final update = ref.read(appUpdateProvider);
    if (update == null) return;
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(l.updateAvailable(update.tag)),
        leading: const Icon(Icons.system_update_outlined),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              // Dismissing is "not now", not "never": the next check finds it
              // again, and the settings screen shows it in the meantime.
              ref.read(appUpdateProvider.notifier).dismiss();
            },
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              final uri = Uri.tryParse(update.url);
              if (uri != null) {
                unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
              }
            },
            child: Text(l.updateOpenRelease),
          ),
        ],
      ),
    );
  }

  void _openNavigation(bool atEnd) {
    final scaffold = _scaffoldKey.currentState;
    if (atEnd) {
      scaffold?.openEndDrawer();
    } else {
      scaffold?.openDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final panelPosition = ref.watch(folderPanelPositionProvider);
    final atEnd = panelPosition == FolderPanelPosition.right;
    final folders = ref.watch(chatFoldersProvider).value ?? const [];
    var selectedFolder = ref.watch(selectedFolderProvider);
    if (selectedFolder != null &&
        !folders.any((folder) => folder.id == selectedFolder)) {
      selectedFolder = null;
    }
    final drawer = HomeNavigationDrawer(
      folders: folders,
      selected: selectedFolder,
      onCreateGroup: () => showCreateGroupDialog(
        context,
        ref.read(groupServiceProvider),
        onCreated: () => ref.read(selectedFolderProvider.notifier).state = null,
      ),
    );
    // Alive for the whole authenticated session (stays mounted under pushed
    // chat routes), so OS notifications fire whenever a message arrives.
    return NotificationBinder(
      child: SignatureAskHost(
        child: Scaffold(
          key: _scaffoldKey,
          drawer: atEnd ? null : drawer,
          endDrawer: atEnd ? drawer : null,
          // IndexedStack keeps the chats state (scroll, search, folders)
          // alive while the user peeks at another tab.
          body: HomeNavigationScope(
            openNavigation: () => _openNavigation(atEnd),
            navigationAtEnd: atEnd,
            child: IndexedStack(
              index: _tab,
              children: const [
                ChatsScreen(),
                SpaceListScreen(),
                SpaceFeedScreen(),
                MenuTilesScreen(),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              setState(() => _tab = i);
            },
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.chat_bubble_outline),
                selectedIcon: const Icon(Icons.chat_bubble),
                label: l.navChats,
              ),
              NavigationDestination(
                icon: const Icon(Icons.campaign_outlined),
                selectedIcon: const Icon(Icons.campaign),
                label: l.navCommunities,
              ),
              NavigationDestination(
                icon: const Icon(Icons.dynamic_feed_outlined),
                selectedIcon: const Icon(Icons.dynamic_feed),
                label: l.navFeed,
              ),
              NavigationDestination(
                icon: const Icon(Icons.apps_outlined),
                label: l.navMenuTiles,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
