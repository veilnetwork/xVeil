import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// Shown while the in-process node is provisioned post-unlock (mining the
/// identity on first run can take a few seconds). The heavy work runs off the
/// UI isolate, so this screen stays animated and the window no longer "hangs".
class PreparingScreen extends StatelessWidget {
  const PreparingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
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
                l10n.preparingTitle,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.preparingBody,
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
