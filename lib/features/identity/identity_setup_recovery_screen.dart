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
  final _childPassword = TextEditingController();
  bool _busy = false, _failed = false;
  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _childPassword.clear();
    _childPassword.dispose();
    super.dispose();
  }

  Future<void> _replay() async {
    final controller = ref.read(appControllerProvider.notifier);
    if (_busy ||
        !(controller.canReplayIdentitySetup ||
            controller.canReplayMasterSetup)) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final password =
          controller.setupRecoveryProtection == StorageProtection.unencrypted
          ? ''
          : _password.text;
      final ok = controller.canReplayMasterSetup
          ? await controller.replayMasterSetup(
              password,
              childPassword:
                  controller.setupRecoveryChildProtection ==
                      StorageProtection.unencrypted
                  ? ''
                  : _childPassword.text,
            )
          : await controller.replayIdentitySetup(password);
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
        _childPassword.clear();
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final isMaster = controller.canReplayMasterSetup;
    final canReplay = controller.canReplayIdentitySetup || isMaster;
    final needsChildPassword =
        isMaster &&
        controller.setupRecoveryChildProtection != null &&
        controller.setupRecoveryChildProtection !=
            StorageProtection.unencrypted;
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
                      isMaster
                          ? controller.setupRecoveryIsMasterAppend
                                ? l.masterAppendReplayBody
                                : l.masterSetupReplayBody
                          : canReplay
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
                            labelText: isMaster
                                ? l.masterSetupReplayPassword
                                : l.lockPasswordHint,
                          ),
                          onSubmitted: (_) => _replay(),
                        ),
                      if (needsChildPassword) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('master-setup-child-password'),
                          controller: _childPassword,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          enabled: !_busy,
                          decoration: InputDecoration(
                            labelText: l.masterSetupReplayChildPassword,
                          ),
                          onSubmitted: (_) => _replay(),
                        ),
                      ],
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
                        _childPassword.clear();
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
