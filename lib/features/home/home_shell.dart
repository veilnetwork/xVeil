import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../channels/channels_screen.dart';
import '../chat/chats_screen.dart';
import '../chat/notification_binder.dart';
import '../chat/signature_ask_host.dart';
import '../storage/cloud_storage_screen.dart';

/// The main authenticated surface. Chats and Channels are REAL tabs (NAV1:
/// switching keeps the bottom bar and highlights the active destination —
/// pushing a route on top used to leave "Chats" lit while a different screen
/// showed). Group chats live inside the Chats list; the Channels tab waits
/// for the channels epic. Personal cloud is a real third tab; only the
/// menu-tiles panel remains a stub.
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
              ChannelsScreen(),
              CloudStorageScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              if (i <= 2) {
                setState(() => _tab = i);
                return;
              }
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(l.comingSoon)));
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
                label: l.navChannels,
              ),
              NavigationDestination(
                icon: const Icon(Icons.cloud_outlined),
                label: l.navStorage,
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
