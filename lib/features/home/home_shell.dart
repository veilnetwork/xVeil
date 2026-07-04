import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chats_screen.dart';
import '../chat/notification_binder.dart';
import '../chat/signature_ask_host.dart';
import '../network/network_screen.dart';
import '../settings/settings_screen.dart';

/// The active bottom-nav tab of [HomeShell] (0 chats, 1 network, 2 settings).
/// A provider (not local State) so the chats screen's Telegram-style drawer
/// can jump to Network/Settings from inside tab 0.
final homeTabProvider = StateProvider<int>((_) => 0);

/// The main authenticated surface. Messenger is the primary tab; network and
/// settings are secondary, per the "messenger-first" product direction.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final index = ref.watch(homeTabProvider);
    // Alive for the whole authenticated session (stays mounted under pushed
    // chat routes), so OS notifications fire whenever a message arrives.
    return NotificationBinder(
        child: SignatureAskHost(
        child: Scaffold(
      body: IndexedStack(
        index: index,
        children: const [
          ChatsScreen(),
          NetworkScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(homeTabProvider.notifier).state = i,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: l.navChats,
          ),
          NavigationDestination(
            icon: const Icon(Icons.hub_outlined),
            selectedIcon: const Icon(Icons.hub),
            label: l.navNetwork,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l.navSettings,
          ),
        ],
      ),
    )));
  }
}
