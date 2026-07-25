import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';

/// Settings root: the identity card + one tile per category (each a pushed
/// subpage), then About and the lock action. The categories own the actual
/// controls — see account/privacy/chats/storage/appearance_settings_screen.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final identity = ref.watch(appControllerProvider.select((s) => s.identity));
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.settingsTitle),
      ),
      body: ListView(
        children: [
          if (identity != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    radius: 26,
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(
                    identity.displayName ??
                        identity.username ??
                        'Node ${identity.nodeId.short}',
                  ),
                  subtitle: Text(
                    identity.nodeId.short,
                    style: const TextStyle(fontFeatures: []),
                  ),
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: Text(l.settingsCatAccount),
            subtitle: Text(l.settingsCatAccountHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/account'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_person_outlined),
            title: Text(l.settingsCatPrivacy),
            subtitle: Text(l.settingsCatPrivacyHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/privacy'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: Text(l.settingsCatChats),
            subtitle: Text(l.settingsCatChatsHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/chats'),
          ),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: Text(l.settingsCatData),
            subtitle: Text(l.settingsCatDataHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/storage'),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(l.settingsAppearance),
            subtitle: Text(l.settingsCatAppearanceHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/appearance'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l.settingsAbout),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'xVeil',
              applicationIcon: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.shield_moon, size: 36),
              ),
            ),
          ),
          // "Lock now" moved to the navigation drawer's bottom menu (user
          // request): locking is a session action, not a setting.
        ],
      ),
    );
  }
}
