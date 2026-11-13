import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../settings/error_report.dart';

class IdentityEraseRecoveryScreen extends ConsumerStatefulWidget {
  const IdentityEraseRecoveryScreen({super.key});
  @override
  ConsumerState<IdentityEraseRecoveryScreen> createState() => _RecoveryState();
}

class _RecoveryState extends ConsumerState<IdentityEraseRecoveryScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    var completed = false;
    try {
      completed = await ref
          .read(appControllerProvider.notifier)
          .retryIdentityErasure();
    } catch (_) {
      // The controller retains the operation/owner. No raw exception reaches
      // the screen or clipboard; diagnostics use the existing allowlist.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted ||
        completed ||
        ref.read(appControllerProvider).phase !=
            AppPhase.identityEraseRecovery) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).identityEraseRecoveryFailed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
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
                    Icon(
                      Icons.pending_actions_outlined,
                      size: 56,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l.identityEraseRecoveryTitle,
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.identityEraseRecoveryBody,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const Key('identity-erase-retry'),
                      onPressed: _busy ? null : _retry,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(l.lockWipeRetry),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('identity-erase-lock'),
                      onPressed: () =>
                          ref.read(appControllerProvider.notifier).lock(),
                      icon: const Icon(Icons.lock_outline),
                      label: Text(l.identityEraseRecoveryLock),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l.identityEraseRecoveryHint,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                    const CopyErrorReportTile(phase: 'identityEraseRecovery'),
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
