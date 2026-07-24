import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/folder_panel_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show chatFoldersProvider;
import '../chat/chats_screen.dart';
import '../chat/notification_binder.dart';
import '../chat/signature_ask_host.dart';
import '../groups/group_tile.dart' show showCreateGroupDialog;
import '../spaces/space_feed_screen.dart';
import '../spaces/space_list_screen.dart';
import 'home_section_scaffold.dart';
import 'menu_tiles_screen.dart';

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
