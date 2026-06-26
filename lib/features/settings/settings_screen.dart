import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/keep_all_online_controller.dart';
import '../../state/locale_controller.dart';
import '../../state/notifications.dart';
import '../../state/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  String _languageLabel(AppL10n l, Locale? locale) => switch (locale?.languageCode) {
        'ru' => l.languageRussian,
        'en' => l.languageEnglish,
        _ => l.languageSystem,
      };

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  /// Storage maintenance: show the container size and (single-identity only)
  /// offer compaction to reclaim the log-structured store's dead padding.
  Future<void> _openStorage(
      BuildContext context, WidgetRef ref, AppL10n l) async {
    final ctrl = ref.read(appControllerProvider.notifier);
    final size = await ctrl.containerSizeBytes();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: Text(l.settingsStorage),
              subtitle:
                  Text(size == null ? '—' : _fmtBytes(size)),
            ),
            if (ctrl.canCompactStorage)
              ListTile(
                leading: const Icon(Icons.compress),
                title: Text(l.settingsStorageCompact),
                subtitle: Text(l.settingsStorageCompactBody),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _compact(context, ref, l);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _compact(
      BuildContext context, WidgetRef ref, AppL10n l) async {
    final pw = await _promptPassword(context, l);
    if (pw == null || pw.isEmpty) return;
    if (!context.mounted) return;
    // Capture the ROOT messenger BEFORE the await — compactStorage tears the
    // session down and re-opens (navigating away), so the settings context may
    // be unmounted by the time the result is ready.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref.read(appControllerProvider.notifier).compactStorage(pw);
      messenger.showSnackBar(SnackBar(
        content: Text(
            '${l.settingsStorageCompactDone}: ${_fmtBytes(r.before)} → ${_fmtBytes(r.after)}'),
      ));
    } catch (_) {
      messenger.showSnackBar(
          SnackBar(content: Text(l.settingsStorageCompactFailed)));
    }
  }

  Future<String?> _promptPassword(BuildContext context, AppL10n l) {
    // The dialog content is a StatefulWidget so its TextEditingController
    // is disposed in State.dispose() — which runs only when the route is
    // fully removed (AFTER the close transition completes). Disposing the
    // controller inline right after `showDialog` returns (the previous
    // approach) races the exit animation: the heavy teardown+reopen that
    // compaction triggers can rebuild the still-animating TextField
    // against the just-disposed controller, throwing "TextEditingController
    // used after being disposed" (and a cascading framework
    // `_dependents.isEmpty` assertion) — the transient red screen.
    return showDialog<String>(
      context: context,
      builder: (d) => _CompactPasswordDialog(
        title: l.settingsStorageCompact,
        hint: l.settingsStoragePasswordHint,
        confirmLabel: l.settingsStorageCompact,
        cancelLabel: l.actionCancel,
      ),
    );
  }

  Future<void> _pickPreview(
      BuildContext context, WidgetRef ref, AppL10n l) async {
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
          unread[label] = (await st.loadConversations())
              .fold<int>(0, (sum, c) => sum + c.unread);
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
                      child: Text(label.characters.first.toUpperCase())),
                  title: Text(label),
                  subtitle: ctrl.isIdentityAnonymous(label)
                      ? Text(l.settingsAnonymousRouting,
                          style: TextStyle(
                              color: Theme.of(ctx).colorScheme.primary))
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
                        icon: Icon(ctrl.isIdentityAnonymous(label)
                            ? Icons.shield_moon
                            : Icons.shield_moon_outlined),
                        color: ctrl.isIdentityAnonymous(label)
                            ? Theme.of(ctx).colorScheme.primary
                            : null,
                        onPressed: () async {
                          final next = !ctrl.isIdentityAnonymous(label);
                          final ok =
                              await ctrl.setIdentityAnonymous(label, next);
                          setSheetState(() {});
                          if (!ctx.mounted || !ok) return;
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
    final locale = ref.watch(localeProvider);
    final identity = ref.watch(appControllerProvider.select((s) => s.identity));
    final master = ref.watch(
        appControllerProvider.select((s) => (s.isMaster, s.activeIdentity)));
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
          // Anonymity toggle for the ACTIVE identity — the SAME control in single
          // and master modes (in master it routes the change to the active
          // identity). Reboots the node under the new routing; the home banner +
          // node id refresh when it returns.
          Builder(builder: (_) {
            final ctrl = ref.read(appControllerProvider.notifier);
            final isMaster = master.$1;
            final active = master.$2;
            final anon = isMaster
                ? (active != null && ctrl.isIdentityAnonymous(active))
                : ctrl.singleIdentityAnonymous;
            return SwitchListTile(
              secondary: const Icon(Icons.shield_moon_outlined),
              title: Text(l.settingsAnonymousRouting),
              subtitle: Text(anon
                  ? l.settingsAnonymousEnabledHint
                  : l.settingsAnonymousDisabledHint),
              isThreeLine: true,
              value: anon,
              onChanged: (isMaster && active == null)
                  ? null
                  : (v) => isMaster
                      ? ctrl.setIdentityAnonymous(active!, v)
                      : ctrl.setSingleIdentityAnonymous(v),
            );
          }),
          // Lazy-mining toggle — single-identity mode only. Default OFF (opt-in):
          // raising this identity's anti-sybil difficulty is a CPU-heavy
          // background grind that competes with the node's runtime, so it's gated
          // behind a setting. Reboots the node under the new preference.
          if (!master.$1)
            Builder(builder: (_) {
              final ctrl = ref.read(appControllerProvider.notifier);
              final on = ctrl.activeLazyMining;
              return SwitchListTile(
                secondary: const Icon(Icons.memory_outlined),
                title: Text(l.settingsLazyMining),
                subtitle: Text(on
                    ? l.settingsLazyMiningEnabledHint
                    : l.settingsLazyMiningDisabledHint),
                isThreeLine: true,
                value: on,
                onChanged: (v) => ctrl.setSingleLazyMining(v),
              );
            }),
          if (master.$1)
            ListTile(
              leading: const Icon(Icons.switch_account_outlined),
              title: Text(l.settingsSwitchIdentity),
              subtitle: master.$2 != null ? Text(master.$2!) : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _switchIdentity(context, ref),
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
              onChanged: (v) =>
                  ref.read(keepAllOnlineProvider.notifier).set(v),
            ),
          // Notifications: a deniability messenger defaults to HIDDEN previews
          // (no sender/text on the lock screen); the preview level is its own row.
          Builder(builder: (_) {
            final ns = ref.watch(notificationSettingsProvider);
            return Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_outlined),
                title: Text(l.notificationsEnabled),
                value: ns.enabled,
                onChanged: (v) =>
                    ref.read(notificationSettingsProvider.notifier).setEnabled(v),
              ),
              if (ns.enabled)
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: Text(l.notificationsPreview),
                  subtitle: Text(ns.preview == NotificationPreview.full
                      ? l.notificationsPreviewFull
                      : l.notificationsPreviewHidden),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pickPreview(context, ref, l),
                ),
            ]);
          }),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(l.settingsIdentity),
            trailing: const Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(l.settingsStorage),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openStorage(context, ref, l),
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

/// Password-entry dialog for storage compaction. A `StatefulWidget` so its
/// [TextEditingController] is owned by the element and disposed in
/// [State.dispose] — which runs only once the dialog route is fully removed
/// (after the close transition). This avoids the "TextEditingController used
/// after being disposed" / `_dependents.isEmpty` red screen that an
/// inline-disposed controller hits when the caller (compaction) tears the
/// widget tree down while the dialog is still animating out.
class _CompactPasswordDialog extends StatefulWidget {
  const _CompactPasswordDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.cancelLabel,
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final String cancelLabel;

  @override
  State<_CompactPasswordDialog> createState() => _CompactPasswordDialogState();
}

class _CompactPasswordDialogState extends State<_CompactPasswordDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctl,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.cancelLabel)),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(_ctl.text),
            child: Text(widget.confirmLabel)),
      ],
    );
  }
}
