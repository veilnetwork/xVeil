import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/locale_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  String _languageLabel(AppL10n l, Locale? locale) => switch (locale?.languageCode) {
        'ru' => l.languageRussian,
        'en' => l.languageEnglish,
        _ => l.languageSystem,
      };

  Future<void> _pickLanguage(
      BuildContext context, WidgetRef ref, AppL10n l) async {
    final current = ref.read(localeProvider) ?? #system;
    final choice = await showDialog<Object?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.settingsLanguage),
        children: [
          for (final entry in <(Object?, String)>[
            (#system, l.languageSystem),
            (const Locale('ru'), l.languageRussian),
            (const Locale('en'), l.languageEnglish),
          ])
            ListTile(
              title: Text(entry.$2),
              trailing:
                  current == entry.$1 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(entry.$1),
            ),
        ],
      ),
    );
    if (choice == null) return; // dismissed
    await ref
        .read(localeProvider.notifier)
        .setLocale(choice is Locale ? choice : null);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final locale = ref.watch(localeProvider);
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
            leading: const Icon(Icons.translate_outlined),
            title: Text(l.settingsLanguage),
            subtitle: Text(_languageLabel(l, locale)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context, ref, l),
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
            title: Text(l.settingsLockNow,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => ref.read(appControllerProvider.notifier).lock(),
          ),
        ],
      ),
    );
  }
}
