import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/folder_panel_controller.dart';
import '../../state/locale_controller.dart';

/// Settings → Appearance: language and where the chat-folder navigation
/// lives. The future theme picker belongs here too.
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  String _languageLabel(AppL10n l, Locale? locale) =>
      switch (locale?.languageCode) {
        'ru' => l.languageRussian,
        'en' => l.languageEnglish,
        _ => l.languageSystem,
      };

  String _folderPanelLabel(AppL10n l, FolderPanelPosition p) => switch (p) {
    FolderPanelPosition.left => l.folderPanelLeft,
    FolderPanelPosition.right => l.folderPanelRight,
    FolderPanelPosition.top => l.folderPanelTop,
  };

  Future<void> _pickFolderPanel(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
    final current = ref.read(folderPanelPositionProvider);
    final choice = await showDialog<FolderPanelPosition>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.settingsFolderPanel),
        children: [
          for (final p in FolderPanelPosition.values)
            ListTile(
              title: Text(_folderPanelLabel(l, p)),
              trailing: current == p ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(p),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(folderPanelPositionProvider.notifier).set(choice);
  }

  Future<void> _pickLanguage(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
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
              trailing: current == entry.$1 ? const Icon(Icons.check) : null,
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
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsAppearance)),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.translate_outlined),
            title: Text(l.settingsLanguage),
            subtitle: Text(_languageLabel(l, locale)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickLanguage(context, ref, l),
          ),
          // Where the chat-folder navigation lives: collapsible left/right
          // drawer or the always-visible top chip bar.
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(l.settingsFolderPanel),
            subtitle: Text(l.settingsFolderPanelHint),
            trailing: Text(
              _folderPanelLabel(l, ref.watch(folderPanelPositionProvider)),
            ),
            onTap: () => _pickFolderPanel(context, ref, l),
          ),
        ],
      ),
    );
  }
}
