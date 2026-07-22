import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chats_screen.dart';
import '../chat/notification_binder.dart';
import '../chat/signature_ask_host.dart';
import '../spaces/space_feed_screen.dart';
import '../spaces/space_list_screen.dart';
import 'menu_tiles_screen.dart';

/// The main authenticated surface. Chats and Communities are real tabs:
/// switching keeps the bottom bar and highlights the active destination —
/// pushing a route on top used to leave "Chats" lit while a different screen
/// showed). A community owns its text/voice channels; personal chats remain
/// separate. Personal cloud and the app-actions menu are the other tabs.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Alive for the whole authenticated session (stays mounted under pushed
    // chat routes), so OS notifications fire whenever a message arrives.
    return NotificationBinder(
      child: SignatureAskHost(
        child: Scaffold(
          // IndexedStack keeps the chats state (scroll, search, folders)
          // alive while the user peeks at another tab.
          body: IndexedStack(
            index: _tab,
            children: const [
              ChatsScreen(),
              SpaceListScreen(),
              SpaceFeedScreen(),
              MenuTilesScreen(),
            ],
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
