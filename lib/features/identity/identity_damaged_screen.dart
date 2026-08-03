import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../settings/error_report.dart';

/// Shown when a space opened but its identity record will not parse (audit
/// XV-13).
///
/// Deliberately a DEAD END with one way out. Before this screen existed the
/// same condition produced a fresh random identity and a normal-looking, empty
/// app — so someone whose identity had actually been damaged was shown a
/// working messenger and every reason to keep using it, which is exactly how
/// the remains of the old record get overwritten.
///
/// It offers NO repair action, because there is no repair to offer: nothing here
/// can reconstruct a record it cannot read. What it does offer is the truth
/// (your data is still in the container; this is not a wrong password), the
/// diagnostic report, and a door back to the lock screen — where the
/// destructive choices already live, behind their own confirmations.
class IdentityDamagedScreen extends ConsumerWidget {
  const IdentityDamagedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, size: 56, color: scheme.error),
              const SizedBox(height: 24),
              Text(
                l10n.identityDamagedTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.identityDamagedBody,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.identityDamagedUntouched,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: () =>
                    ref.read(appControllerProvider.notifier).lock(),
                child: Text(l10n.identityDamagedBack),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.bug_report_outlined),
                label: Text(l10n.settingsCopyErrors),
                onPressed: () =>
                    copyErrorReport(context, phase: 'identityDamaged'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
