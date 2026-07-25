import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/chat.dart' show SignaturePolicy;
import '../../domain/p2p_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/api_server.dart';
import '../../state/p2p_policy_controller.dart';
import '../../state/signature_policy_controller.dart';
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
  const PrivacySettingsScreen({super.key});

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
                '${t.readOnly ? ' · ${l.settingsApiReadOnly}' : ''}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_outlined),
                    tooltip: l.settingsApiCopyToken,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: t.token));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.settingsApiTokenCopied)),
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
