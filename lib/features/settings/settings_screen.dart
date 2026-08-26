import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/storage/app_profile.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';
import 'app_update_tile.dart';
import 'error_report.dart';

/// Settings root: the identity card + one tile per category (each a pushed
/// subpage), then About and the lock action. The categories own the actual
/// controls — see account/privacy/chats/storage/appearance_settings_screen.
///
/// It also hides the profile switcher. Profiles are a maintenance tool, not a
/// feature to browse into: someone who has no reason to run two installations
/// should never meet a screen offering to split their data in half. Three taps
/// on the title reveal it, and the reveal is remembered so it is a one-time
/// gesture rather than a password.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _tapsToReveal = 3;

  /// Taps must be deliberate: a stray tap now and another next week should not
  /// add up to a reveal.
  static const _tapWindow = Duration(seconds: 2);

  bool _revealed = false;
  int _taps = 0;
  Timer? _tapReset;

  @override
  void initState() {
    super.initState();
    _loadRevealed();
  }

  @override
  void dispose() {
    _tapReset?.cancel();
    super.dispose();
  }

  Future<void> _loadRevealed() async {
    final prefs = await SharedPreferences.getInstance();
    final revealed = prefs.getBool(AppProfiles.revealedPref) ?? false;
    if (!mounted || !revealed) return;
    setState(() => _revealed = true);
  }

  Future<void> _tapTitle() async {
    if (_revealed) return;
    _tapReset?.cancel();
    _taps++;
    if (_taps < _tapsToReveal) {
      _tapReset = Timer(_tapWindow, () => _taps = 0);
      return;
    }
    _taps = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppProfiles.revealedPref, true);
    if (!mounted) return;
    setState(() => _revealed = true);
    final l = AppL10n.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.profileRevealed)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final identity = ref.watch(appControllerProvider.select((s) => s.identity));
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tapTitle,
          child: Text(l.settingsTitle),
        ),
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
          if (_revealed)
            ListTile(
              leading: const Icon(Icons.switch_account_outlined),
              title: Text(l.profileTitle),
              subtitle: Text(l.profileSettingsHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/profiles'),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              l.updateSectionTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const AppUpdateTile(),
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
          const CopyErrorReportTile(phase: 'settings'),
          // "Lock now" moved to the navigation drawer's bottom menu (user
          // request): locking is a session action, not a setting.
        ],
      ),
    );
  }
}
