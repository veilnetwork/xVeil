import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final identity = ref.watch(appControllerProvider.select((s) => s.identity));
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
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
                  title: Text(identity.displayName ?? identity.username ??
                      'Node ${identity.nodeId.short}'),
                  subtitle: Text(identity.nodeId.short,
                      style: const TextStyle(fontFeatures: [])),
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(l.settingsIdentity),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(l.settingsStorage),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: Text(l.settingsNetwork),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(l.settingsAppearance),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l.settingsAbout),
            trailing: const Icon(Icons.chevron_right),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.lock,
                color: Theme.of(context).colorScheme.error),
            title: Text('Lock now',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => ref.read(appControllerProvider.notifier).lock(),
          ),
        ],
      ),
    );
  }
}
