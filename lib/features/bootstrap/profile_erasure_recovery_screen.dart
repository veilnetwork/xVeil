import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// The live retry boundary. Cold startup still uses the separate pending app
/// until its platform shutdown/recovery owner is qualified.
class ProfileErasureRecoveryScreen extends ConsumerWidget {
  const ProfileErasureRecoveryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(appControllerProvider.select((s) => s.erasureBusy));
    final l = AppL10n.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 56,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l.profileErasurePendingTitle,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Text(l.profileErasurePendingBody),
                  const SizedBox(height: 24),
                  if (busy)
                    const CircularProgressIndicator()
                  else
                    FilledButton.icon(
                      onPressed: () =>
                          ref.read(wipeReportProvider.notifier).runWipe(),
                      icon: const Icon(Icons.refresh),
                      label: Text(l.lockWipeRetry),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
