import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// Shown while the in-process node is provisioned post-unlock. On the FIRST run
/// of an identity this includes a one-time identity proof-of-work (tens of
/// seconds) — the message says so explicitly so a switch doesn't read as "always
/// slow". The heavy work runs off the UI isolate, so this screen stays animated.
class PreparingScreen extends ConsumerWidget {
  const PreparingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final reason =
        ref.watch(appControllerProvider.select((s) => s.preparingReason));
    final (title, body) = switch (reason) {
      PreparingReason.unlocking => (l10n.preparingUnlockTitle, l10n.preparingUnlockBody),
      PreparingReason.firstRunMining => (l10n.preparingFirstRunTitle, l10n.preparingFirstRunBody),
      PreparingReason.node => (l10n.preparingTitle, l10n.preparingBody),
    };
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  width: 88,
                  height: 88,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.shield_moon_outlined,
                    size: 64,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 28),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
