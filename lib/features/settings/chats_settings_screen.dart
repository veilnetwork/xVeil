import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' show VeilBackground;

import '../../desktop/desktop_tray.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/background_node_controller.dart';
import '../../state/chat_page_size_controller.dart';
import '../../state/close_to_tray_controller.dart';
import '../../state/notifications.dart';
import '../../state/reactions_visibility_controller.dart';

/// Settings → Chats & notifications: how messages reach you (notifications,
/// background delivery, close-to-tray) and how a chat loads.
class ChatsSettingsScreen extends ConsumerWidget {
  const ChatsSettingsScreen({super.key});

  Future<void> _pickPreview(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
    final current = ref.read(notificationSettingsProvider).preview;
    final choice = await showDialog<NotificationPreview>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.notificationsPreview),
        children: [
          for (final entry in <(NotificationPreview, String)>[
            (NotificationPreview.hidden, l.notificationsPreviewHidden),
            (NotificationPreview.full, l.notificationsPreviewFull),
          ])
            ListTile(
              title: Text(entry.$2),
              trailing: current == entry.$1 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(entry.$1),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(notificationSettingsProvider.notifier).setPreview(choice);
  }

  Future<void> _pickChatPageSize(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
    final current = ref.read(chatPageSizeProvider);
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.settingsChatPageSize),
        children: [
          for (final n in kChatPageSizeChoices)
            ListTile(
              title: Text('$n'),
              trailing: current == n ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(n),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(chatPageSizeProvider.notifier).set(choice);
  }

  /// Toggle the keep-node-in-background service. On enable, also nudge the
  /// user to grant the Doze battery exemption (the foreground service alone is
  /// not enough on Doze + aggressive OEMs); when already ignoring
  /// optimisations, the request is a no-op. On disable, just stop the service.
  Future<void> _setKeepNodeBackground(WidgetRef ref, bool value) async {
    await ref.read(backgroundNodeProvider.notifier).set(value);
    if (!value) return;
    final exempt = await VeilBackground.isIgnoringBatteryOptimizations();
    if (!exempt) await VeilBackground.requestIgnoreBatteryOptimizations();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.settingsCatChats),
      ),
      body: ListView(
        children: [
          // Notifications: a deniability messenger defaults to HIDDEN previews
          // (no sender/text on the lock screen); the preview level is its own
          // row.
          Builder(
            builder: (_) {
              final ns = ref.watch(notificationSettingsProvider);
              return Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_outlined),
                    title: Text(l.notificationsEnabled),
                    value: ns.enabled,
                    onChanged: (v) => ref
                        .read(notificationSettingsProvider.notifier)
                        .setEnabled(v),
                  ),
                  if (ns.enabled)
                    ListTile(
                      leading: const Icon(Icons.visibility_off_outlined),
                      title: Text(l.notificationsPreview),
                      subtitle: Text(
                        ns.preview == NotificationPreview.full
                            ? l.notificationsPreviewFull
                            : l.notificationsPreviewHidden,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickPreview(context, ref, l),
                    ),
                ],
              );
            },
          ),
          // Desktop only: close the window to the tray (keep the node running)
          // vs quit. Hidden on mobile, where there is no desktop window.
          if (isDesktopTrayPlatform)
            SwitchListTile(
              secondary: const Icon(Icons.dock_outlined),
              title: Text(l.settingsCloseToTray),
              subtitle: Text(l.settingsCloseToTrayHint),
              isThreeLine: true,
              value: ref.watch(closeToTrayProvider),
              onChanged: (v) => ref.read(closeToTrayProvider.notifier).set(v),
            ),
          // Android only: keep the embedded node running when the app is
          // backgrounded / the screen is off. Runs a foreground service (wake
          // lock + persistent notification) and asks for the Doze battery
          // exemption. Off by default: the visible notification advertises the
          // app is running (a deniability trade-off).
          if (Platform.isAndroid)
            SwitchListTile(
              secondary: const Icon(Icons.cloud_sync_outlined),
              title: Text(l.settingsKeepNodeBackground),
              subtitle: Text(l.settingsKeepNodeBackgroundHint),
              isThreeLine: true,
              value: ref.watch(backgroundNodeProvider),
              onChanged: (v) => _setKeepNodeBackground(ref, v),
            ),
          // Reactions: a local display preference for 1:1 chats AND groups —
          // hides the chips under bubbles and the quick-react bar in the
          // message menu. Reactions keep syncing; toggling back restores them.
          SwitchListTile(
            secondary: const Icon(Icons.add_reaction_outlined),
            title: Text(l.settingsShowReactions),
            subtitle: Text(l.settingsShowReactionsHint),
            isThreeLine: true,
            value: ref.watch(showReactionsProvider),
            onChanged: (v) => ref.read(showReactionsProvider.notifier).set(v),
          ),
          // Chat pagination: how many recent messages a chat loads initially
          // (and the "load earlier" step). Bounds decrypt + list-build work.
          ListTile(
            leading: const Icon(Icons.format_list_numbered_outlined),
            title: Text(l.settingsChatPageSize),
            subtitle: Text(l.settingsChatPageSizeHint),
            trailing: Text(
              '${ref.watch(chatPageSizeProvider)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            onTap: () => _pickChatPageSize(context, ref, l),
          ),
        ],
      ),
    );
  }
}
