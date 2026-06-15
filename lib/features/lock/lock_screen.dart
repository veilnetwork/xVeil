import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ref.read(appControllerProvider.notifier).unlock(_ctrl.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _startOver() async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.lockStartOver),
        content: Text(l.lockStartOverBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.lockStartOver),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appControllerProvider.notifier).startOver();
    }
  }

  Future<void> _wipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _WipeConfirmDialog(),
    );
    if (confirmed == true) {
      await ref.read(appControllerProvider.notifier).wipeContainers();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasError = ref.watch(
      appControllerProvider.select((s) => s.unlockError),
    );
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.lock_outline, size: 56, color: scheme.primary),
              const SizedBox(height: 24),
              Text(
                l.lockTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _ctrl,
                obscureText: true,
                autofocus: true,
                onSubmitted: (_) => _unlock(),
                decoration: InputDecoration(
                  labelText: l.lockPasswordHint,
                  errorText: hasError ? l.lockWrong : null,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _unlock,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l.lockUnlock),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : _startOver,
                child: Text(l.lockStartOver),
              ),
              const Spacer(flex: 2),
              // Low-emphasis, corner-tucked destructive action (typed-phrase
              // gated) so it can't be hit by an accidental double-tap.
              Align(
                alignment: Alignment.bottomRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : _wipe,
                  icon: Icon(Icons.delete_forever_outlined,
                      size: 16, color: scheme.error.withValues(alpha: 0.7)),
                  label: Text(l.lockWipe,
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.error.withValues(alpha: 0.7))),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Irreversible-wipe confirmation gated behind typing an exact phrase, so an
/// accidental double-tap can't destroy the container. Owns its own controller
/// (disposed correctly) — pops `true` only once the phrase matches.
class _WipeConfirmDialog extends StatefulWidget {
  const _WipeConfirmDialog();

  @override
  State<_WipeConfirmDialog> createState() => _WipeConfirmDialogState();
}

class _WipeConfirmDialogState extends State<_WipeConfirmDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final phrase = l.lockWipePhrase;
    final matches = _typed.text.trim().toLowerCase() == phrase.toLowerCase();
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(l.lockWipe),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.lockWipeBody),
            const SizedBox(height: 16),
            Text(l.lockWipeTypePrompt,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('"$phrase"',
                style:
                    TextStyle(fontWeight: FontWeight.bold, color: scheme.error)),
            const SizedBox(height: 8),
            TextField(
              controller: _typed,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          // Disabled until the phrase is typed exactly.
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(l.lockWipeConfirm),
        ),
      ],
    );
  }
}
