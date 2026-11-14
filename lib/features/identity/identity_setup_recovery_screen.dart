import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../settings/error_report.dart';

class IdentitySetupRecoveryScreen extends ConsumerWidget {
  const IdentitySetupRecoveryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final controller = ref.read(appControllerProvider.notifier);
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
                      canCreate
                          ? l.identitySetupRecoveryBlank
                          : l.identitySetupRecoveryPending,
                      textAlign: TextAlign.center,
                    ),
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
                      onPressed: controller.lock,
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
