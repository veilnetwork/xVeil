import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../domain/storage_protection.dart';
import '../settings/error_report.dart';

class IdentitySetupRecoveryScreen extends ConsumerStatefulWidget {
  const IdentitySetupRecoveryScreen({super.key});
  @override
  ConsumerState<IdentitySetupRecoveryScreen> createState() =>
      _IdentitySetupRecoveryScreenState();
}

class _IdentitySetupRecoveryScreenState
    extends ConsumerState<IdentitySetupRecoveryScreen> {
  final _password = TextEditingController();
  bool _busy = false, _failed = false;
  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _replay() async {
    if (_busy ||
        !ref.read(appControllerProvider.notifier).canReplayIdentitySetup) {
      return;
    }
    final controller = ref.read(appControllerProvider.notifier);
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final ok = await controller.replayIdentitySetup(
        controller.setupRecoveryProtection == StorageProtection.unencrypted
            ? ''
            : _password.text,
      );
      if (mounted &&
          ref.read(appControllerProvider).phase ==
              AppPhase.identitySetupRecovery) {
        setState(() => _failed = !ok);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final canReplay = controller.canReplayIdentitySetup;
    final canCreate = controller.canResumeIdentitySetup;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.pending_actions_outlined, size: 56),
                    const SizedBox(height: 24),
                    Text(
                      l.identitySetupRecoveryTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      canReplay
                          ? l.identitySetupReplayBody
                          : canCreate
                          ? l.identitySetupRecoveryBlank
                          : l.identitySetupRecoveryPending,
                      textAlign: TextAlign.center,
                    ),
                    if (canReplay) ...[
                      const SizedBox(height: 24),
                      if (controller.setupRecoveryProtection !=
                          StorageProtection.unencrypted)
                        TextField(
                          key: const Key('identity-setup-password'),
                          controller: _password,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          enabled: !_busy,
                          decoration: InputDecoration(
                            labelText: l.lockPasswordHint,
                          ),
                          onSubmitted: (_) => _replay(),
                        ),
                      if (_failed)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            l.identitySetupReplayError,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: const Key('identity-setup-replay'),
                        onPressed: _busy ? null : _replay,
                        child: Text(l.identitySetupReplayAction),
                      ),
                    ],
                    if (canCreate) ...[
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const Key('identity-setup-resume'),
                        onPressed: controller.beginIdentitySetupRecovery,
                        child: Text(l.identitySetupRecoveryCreate),
                      ),
                      const SizedBox(height: 12),
                      ExpansionTile(
                        title: Text(l.identitySetupRecoveryMasterTitle),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(l.identitySetupRecoveryMasterBody),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      key: const Key('identity-setup-lock'),
                      onPressed: () async {
                        _password.clear();
                        await controller.lock();
                      },
                      icon: const Icon(Icons.lock_outline),
                      label: Text(l.identityEraseRecoveryLock),
                    ),
                    const SizedBox(height: 16),
                    const CopyErrorReportTile(phase: 'identitySetupRecovery'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
