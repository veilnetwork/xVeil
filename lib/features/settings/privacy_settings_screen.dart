import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/clipboard_secret.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backup_exclusion.dart';
import '../../domain/chat.dart' show SignaturePolicy;
import '../../domain/p2p_policy.dart';
import '../../domain/screen_lock.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/api_server.dart';
import '../../state/p2p_policy_controller.dart';
import '../../state/screen_lock_controller.dart';
import '../../state/signature_policy_controller.dart';
import '../lock/screen_lock_overlay.dart' show screenLockTimeoutLabel;
import '../../state/messaging.dart' show messagingServiceProvider;

String p2pPolicyLabel(AppL10n l, P2PGlobalPolicy p) => switch (p) {
  P2PGlobalPolicy.allowAll => l.p2pPolicyAllowAll,
  P2PGlobalPolicy.contacts => l.p2pPolicyContacts,
  P2PGlobalPolicy.selected => l.p2pPolicySelected,
  P2PGlobalPolicy.denied => l.p2pPolicyDenied,
};

/// Settings → Privacy: cross-cutting policies about what leaves this device —
/// direct-P2P consent and authorship-signature requests.
class PrivacySettingsScreen extends ConsumerWidget {
  const PrivacySettingsScreen({super.key, this.pickDirectory});

  /// Injected by tests, which have no native folder picker to show.
  final Future<String?> Function()? pickDirectory;

  String _signaturePolicyLabel(AppL10n l, SignaturePolicy p) => switch (p) {
    SignaturePolicy.ask => l.signaturePolicyAsk,
    SignaturePolicy.auto => l.signaturePolicyAuto,
    SignaturePolicy.refuse => l.signaturePolicyRefuse,
  };

  Future<void> _pickP2PPolicy(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
    final current = ref.read(p2pPolicyProvider);
    final choice = await showDialog<P2PGlobalPolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.settingsP2PPolicy),
        children: [
          for (final p in P2PGlobalPolicy.values)
            ListTile(
              title: Text(p2pPolicyLabel(l, p)),
              trailing: current == p ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(p),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(p2pPolicyProvider.notifier).set(choice);
  }

  Future<void> _pickSignaturePolicy(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
    final current = ref.read(signaturePolicyProvider);
    final choice = await showDialog<SignaturePolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.settingsSignaturePolicy),
        children: [
          for (final p in SignaturePolicy.values)
            ListTile(
              title: Text(_signaturePolicyLabel(l, p)),
              trailing: current == p ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(p),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(signaturePolicyProvider.notifier).set(choice);
  }

  Future<void> _pickScreenLockTimeout(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
  ) async {
    final current = ref.read(screenLockProvider).timeout;
    final choice = await showDialog<ScreenLockTimeout>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.settingsScreenLock),
        children: [
          for (final value in ScreenLockTimeout.values)
            ListTile(
              title: Text(screenLockTimeoutLabel(l, value)),
              trailing: current == value ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(value),
            ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(screenLockProvider.notifier).setTimeout(choice);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.settingsCatPrivacy),
      ),
      body: ListView(
        children: [
          const BackupExclusionWarning(),
          Builder(
            builder: (_) {
              final p2p = ref.watch(p2pPolicyProvider);
              final anon = ref.read(p2pPolicyProvider.notifier).localAnonymous;
              return ListTile(
                leading: const Icon(Icons.link_outlined),
                title: Text(l.settingsCommunication),
                subtitle: Text(
                  anon
                      ? l.settingsP2PPolicyAnonymousHint
                      : l.settingsP2PPolicyHint,
                ),
                trailing: Text(p2pPolicyLabel(l, p2p)),
                onTap: () => _pickP2PPolicy(context, ref, l),
              );
            },
          ),
          // Manage the "Only selected" contact set. Shown only under that
          // policy — for the others the per-contact override in each chat is
          // the finer control (this screen just batches it).
          if (ref.watch(p2pPolicyProvider) == P2PGlobalPolicy.selected)
            ListTile(
              leading: const Icon(Icons.checklist_outlined),
              title: Text(l.p2pSelectedTitle),
              subtitle: Text(l.p2pSelectedHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/p2p-selected'),
            ),
          // Author-side answer to "please sign this message" requests from
          // peers: ask each time / sign automatically / always refuse.
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(l.settingsSignaturePolicy),
            subtitle: Text(l.settingsSignaturePolicyHint),
            trailing: Text(
              _signaturePolicyLabel(l, ref.watch(signaturePolicyProvider)),
            ),
            onTap: () => _pickSignaturePolicy(context, ref, l),
          ),
          const _RecommendationPrivacySwitch(),
          // The screen, not the volume: the container stays open behind the
          // prompt so messages keep arriving and notifications keep working.
          // The hint says so, because a lock that silently stopped delivery
          // would be discovered the hard way.
          Builder(
            builder: (_) {
              final timeout = ref.watch(
                screenLockProvider.select((s) => s.timeout),
              );
              return ListTile(
                key: const ValueKey('screen-lock-timeout'),
                leading: const Icon(Icons.lock_clock_outlined),
                title: Text(l.settingsScreenLock),
                subtitle: Text(l.settingsScreenLockHint),
                trailing: Text(screenLockTimeoutLabel(l, timeout)),
                onTap: () => _pickScreenLockTimeout(context, ref, l),
              );
            },
          ),
          const Divider(),
          // Local automation API (REST API epic): off by default; a permanently
          // open port is discoverable, so the user opts in here. When on it binds
          // 127.0.0.1 only and needs the bearer token shown below.
          _apiSection(context, ref, l),
        ],
      ),
    );
  }

  Widget _apiSection(BuildContext context, WidgetRef ref, AppL10n l) {
    final cfg = ref.watch(apiServerControllerProvider);
    final ctrl = ref.read(apiServerControllerProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.api_outlined),
          title: Text(l.settingsApiTitle),
          subtitle: Text(
            cfg.enabled ? '127.0.0.1:$kApiPort' : l.settingsApiHint,
          ),
          value: cfg.enabled,
          onChanged: (v) async {
            if (v) {
              await ctrl.enable();
            } else {
              await ctrl.disable();
            }
          },
        ),
        if (cfg.enabled) ...[
          for (final t in cfg.tokens)
            ListTile(
              leading: Icon(
                t.readOnly ? Icons.visibility_outlined : Icons.key_outlined,
              ),
              title: Text(t.name),
              subtitle: Text(
                '${t.token.substring(0, 8)}…'
                '${t.readOnly ? ' · ${l.settingsApiReadOnly}' : ''}'
                '${t.fileRoots.isEmpty ? '' : ' · 📁${t.fileRoots.length}'}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Read-only tokens cannot POST at all, so there is no local
                  // file send for them to be granted.
                  if (!t.readOnly)
                    IconButton(
                      icon: const Icon(Icons.folder_outlined),
                      tooltip: l.settingsApiFileFolders,
                      onPressed: () => _editFileRoots(context, ref, l, t.id),
                    ),
                  IconButton(
                    icon: const Icon(Icons.copy_outlined),
                    tooltip: l.settingsApiCopyToken,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: t.token));
                      // A write-capable credential on the system-wide
                      // clipboard (audit report10 X-07). Taken back off after
                      // a bounded window, and the window is stated here rather
                      // than applied silently — something else copied inside
                      // it is lost, and that cost is only fair if the person
                      // knows about it before it starts.
                      unawaited(clearClipboardLater());
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              l.settingsApiTokenCopiedClears(
                                kClipboardSecretLifetime.inSeconds,
                              ),
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l.settingsApiRevoke,
                    onPressed: () => ctrl.revokeToken(t.id),
                  ),
                ],
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(l.settingsApiAddToken),
            onTap: () => _addToken(context, ref, l),
          ),
        ],
      ],
    );
  }

  Future<void> _addToken(BuildContext context, WidgetRef ref, AppL10n l) async {
    final nameCtrl = TextEditingController();
    var readOnly = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(l.settingsApiAddToken),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(hintText: l.settingsApiTokenName),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.settingsApiReadOnly),
                // What the switch REFUSES, which is the part worth knowing
                // before handing a token to a bot. "Read-only" alone leaves
                // the reader to guess whether it stops sending messages or
                // only stops changing settings; the string saying so was
                // written and then never attached to anything.
                subtitle: Text(l.settingsApiReadOnlyHint),
                value: readOnly,
                onChanged: (v) => setState(() => readOnly = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.settingsApiAddToken),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await ref
        .read(apiServerControllerProvider.notifier)
        .addToken(nameCtrl.text, readOnly: readOnly);
  }

  /// Grant/withdraw the folders one token may send local files from (audit
  /// XV-08). Lives OUTSIDE the API on purpose: a token that could widen its
  /// own reach would not be narrower than the one this replaces.
  Future<void> _editFileRoots(
    BuildContext context,
    WidgetRef ref,
    AppL10n l,
    String tokenId,
  ) async {
    final ctrl = ref.read(apiServerControllerProvider.notifier);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, dialogRef, _) {
          final token = dialogRef
              .watch(apiServerControllerProvider)
              .tokens
              .where((t) => t.id == tokenId)
              .firstOrNull;
          if (token == null) return const SizedBox.shrink();
          return AlertDialog(
            title: Text(l.settingsApiFileFolders),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.settingsApiFileFoldersHint,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (token.fileRoots.isEmpty)
                  Text(
                    l.settingsApiFileFoldersNone,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                for (final root in token.fileRoots)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(root, style: const TextStyle(fontSize: 12)),
                    trailing: IconButton(
                      // Removing a folder narrows what an API token may send.
                      // The icon alone never said which way it cut.
                      tooltip: AppL10n.of(ctx).actionRemove,
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => ctrl.setTokenFileRoots(tokenId, [
                        for (final other in token.fileRoots)
                          if (other != root) other,
                      ]),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final picked =
                      await (pickDirectory ?? FilePicker.getDirectoryPath)();
                  if (picked == null || picked.isEmpty) return;
                  if (token.fileRoots.contains(picked)) return;
                  await ctrl.setTokenFileRoots(tokenId, [
                    ...token.fileRoots,
                    picked,
                  ]);
                },
                child: Text(l.settingsApiAddFolder),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l.actionDone),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RecommendationPrivacySwitch extends ConsumerStatefulWidget {
  const _RecommendationPrivacySwitch();

  @override
  ConsumerState<_RecommendationPrivacySwitch> createState() =>
      _RecommendationPrivacySwitchState();
}

class _RecommendationPrivacySwitchState
    extends ConsumerState<_RecommendationPrivacySwitch> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    Future<void>(() async {
      final value = await ref
          .read(messagingServiceProvider)
          .spaceRecommendationsEnabled();
      if (mounted) setState(() => _enabled = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SwitchListTile(
      key: const ValueKey('space-recommendations-privacy'),
      secondary: const Icon(Icons.share_outlined),
      title: Text(l.spaceRecommendationReceive),
      subtitle: Text(l.spaceRecommendationReceiveHint),
      value: _enabled ?? true,
      onChanged: _enabled == null
          ? null
          : (value) async {
              setState(() => _enabled = value);
              await ref
                  .read(messagingServiceProvider)
                  .setSpaceRecommendationsEnabled(value);
            },
    );
  }
}

/// A warning shown when the device is NOT keeping xVeil's data out of its
/// backup.
///
/// Nothing more than a warning, on purpose. The audit's remedy for the same
/// finding was to block writes or block the unlock; that takes a working app
/// away from someone over a filesystem condition they cannot fix from inside
/// it, and the container is encrypted either way. What a backup actually costs
/// is deniability of its EXISTENCE, plus the chance to attack a copy of it at
/// leisure — which is worth saying plainly and letting the person act on.
///
/// Empty on every platform that does not answer the channel: Android seals the
/// same data with `allowBackup=false` and data-extraction rules in the
/// manifest, and no desktop has an OS backup service in this loop.
class BackupExclusionWarning extends StatefulWidget {
  const BackupExclusionWarning({super.key, this.exclusion});

  /// Injected by tests, which have no runner to answer the channel.
  final BackupExclusion? exclusion;

  @override
  State<BackupExclusionWarning> createState() => _BackupExclusionWarningState();
}

class _BackupExclusionWarningState extends State<BackupExclusionWarning> {
  String? _reason;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    final reason = await (widget.exclusion ?? const BackupExclusion()).problem();
    if (!mounted || reason == null) return;
    setState(() => _reason = reason);
  }

  @override
  Widget build(BuildContext context) {
    final reason = _reason;
    if (reason == null) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('backup-not-excluded'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.cloud_off_outlined, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.backupNotExcludedTitle,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.backupNotExcludedBody(reason),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
