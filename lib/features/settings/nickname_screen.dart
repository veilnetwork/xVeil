import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/nickname_controller.dart';
import '../../state/group_service_providers.dart';
import 'sovereign_secret_dialog.dart';

/// Settings → Identities & account → Nickname: claim a public @name for the
/// ACTIVE (sovereign) identity. Availability check → chunked PoW mining with
/// live progress (cancellable, resumable) → publish. Once owned, the name can
/// be reinforced (mine more weight) — the cumulative-PoW takeover defense.
///
/// The route is only reachable for non-anonymous identities (the settings
/// tile is hidden otherwise; the controller re-checks anyway).
class NicknameScreen extends ConsumerStatefulWidget {
  const NicknameScreen({super.key});

  @override
  ConsumerState<NicknameScreen> createState() => _NicknameScreenState();
}

class _NicknameScreenState extends ConsumerState<NicknameScreen> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// Unlock the identity's master key for the one signature a claim needs.
  ///
  /// A name belongs to the IDENTITY, so the identity's master signs it — no
  /// device subkey can, on any device. The prompt is raised here, at the
  /// moment of publishing, and the controller closes the signer straight
  /// after: the secret is never held across the mining run.
  Future<NativeSovereignGroupSigner?> _openSigner() async {
    final l = AppL10n.of(context);
    final svc = ref.read(groupServiceProvider);
    if (svc == null) return null;
    // Ask for the secret this identity actually uses: a certificate is
    // unlocked by a CODE, not by the recovery phrase.
    final usesCertificate = await svc.sovereignCredentialKind() == 'certificate';
    if (!mounted) return null;
    final secret = await showDialog<String>(
      context: context,
      builder: (dialog) => SovereignSecretDialog(
        title: l.nicknameClaim,
        confirmLabel: l.nicknameClaim,
        fieldLabel: usesCertificate ? l.devicesRecoveryCode : l.devicesPhrase,
        helperText: usesCertificate
            ? l.devicesRecoveryCodeHint
            : l.devicesPhraseHint,
      ),
    );
    if (secret == null || secret.isEmpty || !mounted) return null;
    return svc.openLocalSovereign(secret, createIfMissing: false);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final st = ref.watch(nicknameControllerProvider);
    final ctrl = ref.read(nicknameControllerProvider.notifier);
    final theme = Theme.of(context);

    // Surface controller errors as snackbars exactly once per change.
    ref.listen(nicknameControllerProvider.select((s) => s.error), (prev, err) {
      if (err != null && err != prev && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err)));
      }
    });
    // Celebrate a successful publish.
    ref.listen(nicknameControllerProvider.select((s) => s.ownedName), (
      prev,
      owned,
    ) {
      if (owned != null && owned != prev && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l.nicknameClaimed}: @$owned')),
        );
      }
    });

    final verdict = switch (st.availability) {
      NicknameAvailability.unknown => null,
      NicknameAvailability.free => (l.nicknameFree, theme.colorScheme.primary),
      NicknameAvailability.mine => (
        l.nicknameMineVerdict,
        theme.colorScheme.primary,
      ),
      NicknameAvailability.taken => (
        l.nicknameTakenWeight('${st.takenWeight}'),
        theme.colorScheme.error,
      ),
    };

    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.nicknameTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.nicknameIntro, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          if (st.ownedName != null) ...[
            Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: st.ownedTakenOver
                        ? Icon(
                            Icons.warning_amber_rounded,
                            color: theme.colorScheme.error,
                          )
                        : const Icon(Icons.alternate_email),
                    title: Text('@${st.ownedName}'),
                    subtitle: Text(
                      st.ownedTakenOver
                          ? l.nicknameOwnedTakenOver('${st.ownedWeight}')
                          : l.nicknameOwnedWeight('${st.ownedWeight}'),
                      style: st.ownedTakenOver
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                    trailing: st.busy
                        ? null
                        : TextButton(
                            onPressed: () => ctrl.topUp(openSigner: _openSigner),
                            child: Text(l.nicknameTopUp),
                          ),
                  ),
                  // What the number MEANS (user remark #5: "вес защиты — это
                  // что?"): the anti-takeover explanation lives right under it.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      l.nicknameWeightExplain,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _field,
            enabled: !st.busy,
            decoration: InputDecoration(
              prefixText: '@',
              labelText: l.nicknameFieldLabel,
              border: const OutlineInputBorder(),
              helperText: verdict?.$1,
              helperStyle: verdict == null
                  ? null
                  : TextStyle(color: verdict.$2, fontWeight: FontWeight.w600),
            ),
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: st.busy ? null : (v) => ctrl.check(v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: st.busy ? null : () => ctrl.check(_field.text),
                  icon: const Icon(Icons.search),
                  label: Text(l.nicknameCheck),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: st.busy
                      ? null
                      : () => ctrl.startClaim(
                          _field.text,
                          openSigner: _openSigner,
                        ),
                  icon: const Icon(Icons.gavel_outlined),
                  label: Text(l.nicknameClaim),
                ),
              ),
            ],
          ),
          if (st.phase == NicknamePhase.checking) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
          if (st.phase == NicknamePhase.mining) ...[
            const SizedBox(height: 24),
            Text(
              '${l.nicknameMiningLabel}  @${st.miningName ?? ''}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: st.progress),
            const SizedBox(height: 8),
            Text(
              l.nicknameMiningStats(
                '${st.minedWeight}',
                '${st.targetWeight}',
                '${st.hashesDone}',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: ctrl.cancel,
                child: Text(l.actionCancel),
              ),
            ),
          ],
          if (st.phase == NicknamePhase.publishing) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(l.nicknamePublishing),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
