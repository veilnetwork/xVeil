import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/keep_all_online_controller.dart';
import '../../state/providers.dart';

/// Settings → Identities & account: everything about WHO you are on this
/// device — active identity anonymity, switching, adding/managing identities,
/// the decoy master and the all-online mode.
class AccountSettingsScreen extends ConsumerWidget {
  const AccountSettingsScreen({super.key});

  /// Bottom-sheet identity switcher (master mode). Tapping an identity calls
  /// switchIdentity — a fast view re-point in all-online mode, a node swap in
  /// one-active mode. The active identity is marked and a no-op.
  Future<void> _switchIdentity(BuildContext context, WidgetRef ref) async {
    final state = ref.read(appControllerProvider);
    // All-online: every identity's storage is open, so we can show each one's
    // unread total — the signal for which identity to switch to.
    final session = ref.read(sessionProvider);
    final unread = <String, int>{};
    if (session != null) {
      for (final label in state.identities) {
        final st = session.storageFor(label);
        if (st != null) {
          unread[label] = (await st.loadConversations()).fold<int>(
            0,
            (sum, c) => sum + c.unread,
          );
        }
      }
    }
    if (!context.mounted) return;
    final l = AppL10n.of(context);
    final ctrl = ref.read(appControllerProvider.notifier);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        // StatefulBuilder so an in-place anonymity toggle re-renders the row.
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final label in state.identities)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(label.characters.first.toUpperCase()),
                  ),
                  title: Text(label),
                  subtitle: ctrl.isIdentityAnonymous(label)
                      ? Text(
                          l.settingsAnonymousRouting,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                        )
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (label == state.activeIdentity)
                        const Icon(Icons.check)
                      else if ((unread[label] ?? 0) > 0)
                        Badge(label: Text('${unread[label]}')),
                      IconButton(
                        tooltip: l.settingsAnonymousRouting,
                        icon: Icon(
                          ctrl.isIdentityAnonymous(label)
                              ? Icons.shield_moon
                              : Icons.shield_moon_outlined,
                        ),
                        color: ctrl.isIdentityAnonymous(label)
                            ? Theme.of(ctx).colorScheme.primary
                            : null,
                        onPressed: () async {
                          final next = !ctrl.isIdentityAnonymous(label);
                          bool ok = false;
                          try {
                            ok = await ctrl.setIdentityAnonymous(label, next);
                          } catch (_) {
                            ok = false;
                          }
                          // The toggle reboots the node → flips to the
                          // preparing route → tears this modal sheet down.
                          // Guard mounted BEFORE touching setSheetState (a
                          // disposed StateSetter throws the _dependents red
                          // screen — same class as the password-dialog fix).
                          if (!ctx.mounted) return;
                          setSheetState(() {});
                          if (!ok) return;
                          final hint = next
                              ? l.settingsAnonymousEnabledHint
                              : l.settingsAnonymousDisabledHint;
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('$label — $hint')),
                          );
                        },
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    if (label != state.activeIdentity) {
                      ctrl.switchIdentity(label);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final master = ref.watch(
      appControllerProvider.select((s) => (s.isMaster, s.activeIdentity)),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsCatAccount)),
      body: ListView(
        children: [
          // Honest recovery-phrase status of the ACTIVE identity (phrase epic
          // P4). 'phrase' = derived from the phrase, so it restores it; 'mined'
          // or a legacy space without the marker = created without a phrase —
          // say so instead of letting the user assume their old written-down
          // words restore anything. Informational, not tappable.
          ref.watch(identityOriginProvider).maybeWhen(
                data: (origin) {
                  final backed = origin == 'phrase';
                  final scheme = Theme.of(context).colorScheme;
                  return ListTile(
                    leading: Icon(
                      backed ? Icons.password_outlined : Icons.key_off_outlined,
                      color: backed ? scheme.primary : Colors.amber,
                    ),
                    title: Text(l.settingsPhraseStatusTitle),
                    subtitle: Text(
                      backed
                          ? l.settingsPhraseBackedHint
                          : l.settingsPhraseNoneHint,
                    ),
                    isThreeLine: true,
                  );
                },
                orElse: () => const SizedBox.shrink(),
              ),
          Builder(
            builder: (_) {
              final ctrl = ref.read(appControllerProvider.notifier);
              final anonymous = master.$1
                  ? (master.$2 == null ||
                      ctrl.isIdentityAnonymous(master.$2!))
                  : ctrl.singleIdentityAnonymous;
              if (anonymous) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.devices_outlined),
                title: Text(l.settingsDevices),
                subtitle: Text(l.settingsDevicesHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/devices'),
              );
            },
          ),
          // Anonymity toggle for the ACTIVE identity — the SAME control in
          // single and master modes (in master it routes the change to the
          // active identity). Reboots the node under the new routing.
          Builder(
            builder: (_) {
              final ctrl = ref.read(appControllerProvider.notifier);
              final isMaster = master.$1;
              final active = master.$2;
              final anon = isMaster
                  ? (active != null && ctrl.isIdentityAnonymous(active))
                  : ctrl.singleIdentityAnonymous;
              return SwitchListTile(
                secondary: const Icon(Icons.shield_moon_outlined),
                title: Text(l.settingsAnonymousRouting),
                subtitle: Text(
                  anon
                      ? l.settingsAnonymousEnabledHint
                      : l.settingsAnonymousDisabledHint,
                ),
                isThreeLine: true,
                value: anon,
                onChanged: (isMaster && active == null)
                    ? null
                    : (v) => isMaster
                          ? ctrl.setIdentityAnonymous(active!, v)
                          : ctrl.setSingleIdentityAnonymous(v),
              );
            },
          ),
          // Lazy-mining toggle — single-identity mode only. Default OFF
          // (opt-in): raising this identity's anti-sybil difficulty is a
          // CPU-heavy background grind, so it's gated behind a setting.
          if (!master.$1)
            Builder(
              builder: (_) {
                final ctrl = ref.read(appControllerProvider.notifier);
                final on = ctrl.activeLazyMining;
                return SwitchListTile(
                  secondary: const Icon(Icons.memory_outlined),
                  title: Text(l.settingsLazyMining),
                  subtitle: Text(
                    on
                        ? l.settingsLazyMiningEnabledHint
                        : l.settingsLazyMiningDisabledHint,
                  ),
                  isThreeLine: true,
                  value: on,
                  onChanged: (v) => ctrl.setSingleLazyMining(v),
                );
              },
            ),
          if (master.$1)
            ListTile(
              leading: const Icon(Icons.switch_account_outlined),
              title: Text(l.settingsSwitchIdentity),
              subtitle: master.$2 != null ? Text(master.$2!) : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _switchIdentity(context, ref),
            ),
          // Nickname (public @name) — SOVEREIGN identities only: a public
          // name is a linkability signal, so the entry is hidden for an
          // anonymous active identity (same policy as the P2P gate).
          Builder(
            builder: (_) {
              final ctrl = ref.read(appControllerProvider.notifier);
              final isMaster = master.$1;
              final active = master.$2;
              final anon = isMaster
                  ? (active == null || ctrl.isIdentityAnonymous(active))
                  : ctrl.singleIdentityAnonymous;
              if (anon) return const SizedBox.shrink();
              return ListTile(
                leading: const Icon(Icons.alternate_email),
                title: Text(l.settingsNickname),
                subtitle: Text(l.settingsNicknameHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/nickname'),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_add_alt_1_outlined),
            title: Text(l.settingsAddIdentity),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/add-identity'),
          ),
          if (master.$1)
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: Text(l.settingsManageIdentities),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/manage-identities'),
            ),
          if (master.$1)
            ListTile(
              leading: const Icon(Icons.theater_comedy_outlined),
              title: Text(l.settingsDecoyMaster),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/decoy-master'),
            ),
          if (master.$1)
            SwitchListTile(
              secondary: const Icon(Icons.wifi_tethering_outlined),
              title: Text(l.settingsKeepAllOnline),
              subtitle: Text(l.settingsKeepAllOnlineHint),
              isThreeLine: true,
              value: ref.watch(keepAllOnlineProvider),
              onChanged: (v) => ref.read(keepAllOnlineProvider.notifier).set(v),
            ),
        ],
      ),
    );
  }
}
