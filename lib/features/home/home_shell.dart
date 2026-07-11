import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chats_screen.dart';
import '../chat/notification_binder.dart';
import '../chat/signature_ask_host.dart';

/// The main authenticated surface. Chats are the whole stage; Network and
/// Settings moved into the chats drawer (the Telegram-style app menu). The
/// bottom bar keeps the product's next big sections — Channels, Storage and
/// the menu-tiles panel — visible but stubbed until their epics land, so the
/// final navigation shape is already in place.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Alive for the whole authenticated session (stays mounted under pushed
    // chat routes), so OS notifications fire whenever a message arrives.
    return NotificationBinder(
      child: SignatureAskHost(
        child: Scaffold(
          body: const ChatsScreen(),
          bottomNavigationBar: NavigationBar(
            selectedIndex: 0,
            onDestinationSelected: (i) {
              if (i == 0) return;
              if (i == 1) {
                context.push('/groups'); // Channels = groups (phase 0)
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.comingSoon)),
              );
            },
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.chat_bubble_outline),
                selectedIcon: const Icon(Icons.chat_bubble),
                label: l.navChats,
              ),
              NavigationDestination(
                icon: const Icon(Icons.campaign_outlined),
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
