import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

/// Shown after unlocking a MASTER space: the user picks which managed identity
/// to act as. Only one identity is active at a time (the container's exclusive
/// lock); choosing one opens it and boots its node.
class IdentityPickerScreen extends ConsumerStatefulWidget {
  const IdentityPickerScreen({super.key});

  @override
  ConsumerState<IdentityPickerScreen> createState() =>
      _IdentityPickerScreenState();
}

class _IdentityPickerScreenState extends ConsumerState<IdentityPickerScreen> {
  bool _busy = false;

  Future<void> _pick(String label) async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(appControllerProvider.notifier).pickIdentity(label);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final identities = ref.watch(appControllerProvider).identities;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.identityPickerTitle),
        actions: [
          IconButton(
            tooltip: l.settingsLockNow,
            icon: const Icon(Icons.lock_outline),
            onPressed: _busy
                ? null
                : () => ref.read(appControllerProvider.notifier).lock(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                l.identityPickerSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: identities.length,
                itemBuilder: (_, i) {
                  final label = identities[i];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(label.characters.first.toUpperCase()),
                    ),
                    title: Text(label),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy ? null : () => _pick(label),
                  );
                },
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}
