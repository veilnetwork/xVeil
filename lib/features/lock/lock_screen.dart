import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../core/error_journal.dart';
import '../settings/error_report.dart';

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
    if (_ctrl.text.trim().isEmpty) {
      return;
    }
    setState(() => _busy = true);
    await ref.read(appControllerProvider.notifier).unlock(_ctrl.text);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _startOver() async {
    final l = AppL10n.of(context);
    final choice = await showDialog<_StartOverChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.lockStartOver),
        content: Text(l.lockStartOverBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_StartOverChoice.cancel),
            child: Text(l.actionCancel),
          ),
          // Surface the irreversible delete right here: "start over" keeps the
          // container (deniability), so a user who actually wants a clean slate
          // would otherwise never find the corner-tucked wipe.
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(_StartOverChoice.delete),
            child: Text(l.lockWipe),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_StartOverChoice.keep),
            child: Text(l.lockStartOver),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _StartOverChoice.keep:
        await ref.read(appControllerProvider.notifier).startOver();
      case _StartOverChoice.delete:
        await _wipe(); // phrase-gated irreversible delete
      case _StartOverChoice.cancel:
      case null:
        break;
    }
  }

  Future<void> _wipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _WipeConfirmDialog(),
    );
    if (confirmed == true) await _runWipe();
  }

  /// Runs the wipe and says what it could not delete.
  ///
  /// `wipeContainers` checks by RE-STATING rather than by trusting `delete()`,
  /// and hands back what is still on disk — and this dropped that list on the
  /// floor, so a person whose container survived saw exactly what a person
  /// whose container was gone saw: the onboarding screen. In an app whose whole
  /// promise is deniability that is the worst direction for a silence to point,
  /// because the one thing it hides is the thing that can convict you.
  ///
  /// The phase flip stays inside the controller and stays unconditional, for
  /// the reason recorded there: parking someone on a lock screen for a
  /// container that may already be gone is its own disclosure. So this is a
  /// dialog raised OVER whatever the flip lands on, not a reason to stay put.
  ///
  /// A loop rather than recursion: Retry is a user gesture with no bound on how
  /// many times it can be pressed, and each pass must start from a fresh call.
  Future<void> _runWipe() async {
    while (true) {
      List<String> remaining = const [];
      var stopped = false;
      try {
        remaining = await ref
            .read(appControllerProvider.notifier)
            .wipeContainers();
      } catch (error, stack) {
        // There was NO handler here at all. A throw became an uncaught async
        // error, the dialog closed and the screen sat there — which reads as
        // "nothing happened" for the one action that cannot be undone.
        stopped = true;
        errorJournal.record(
          kind: 'wipe',
          error: error,
          stack: stack,
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      if (!mounted) return;
      if (!stopped && remaining.isEmpty) return; // everything really went
      final retry = await showDialog<bool>(
        context: context,
        builder: (ctx) => _WipeLeftoverDialog(
          remaining: remaining,
          stopped: stopped,
        ),
      );
      if (retry != true || !mounted) return;
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
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 48).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: IntrinsicHeight(
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l.lockUnlock),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _startOver,
                      child: Text(l.lockStartOver),
                    ),
                    const Spacer(flex: 2),
                    // The report belongs HERE and not only in Settings: an app
                    // that will not unlock is exactly the failure worth
                    // reporting, and Settings is on the other side of the lock.
                    // Shown only once something has actually gone wrong, so a
                    // working lock screen stays a lock screen.
                    Row(
                      children: [
                        if (hasError || errorJournal.entries.isNotEmpty)
                          Flexible(
                            child: TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => copyErrorReport(
                                      context,
                                      phase: 'locked',
                                    ),
                              icon: const Icon(
                                Icons.bug_report_outlined,
                                size: 16,
                              ),
                              label: Text(
                                l.settingsCopyErrors,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                            ),
                          ),
                        const Spacer(),
                        // Low-emphasis, corner-tucked destructive action
                        // (typed-phrase gated) so it can't be hit by an
                        // accidental double-tap.
                        Flexible(
                          child: TextButton.icon(
                            onPressed: _busy ? null : _wipe,
                            icon: Icon(
                              Icons.delete_forever_outlined,
                              size: 16,
                              color: scheme.error.withValues(alpha: 0.7),
                            ),
                            label: Text(
                              l.lockWipe,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.error.withValues(alpha: 0.7),
                              ),
                            ),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
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

/// Outcome of the "start over" dialog: keep the container (deniable reset),
/// delete it for good (routes to the phrase-gated wipe), or back out.
enum _StartOverChoice { keep, delete, cancel }

/// What a wipe could not delete, named — and a Retry that runs it again.
///
/// Names the survivors rather than saying something went wrong: "the container
/// is still on this device" is a fact a person can act on (delete it, unmount
/// the volume, stop the backup agent), and "an error occurred" is not. The
/// second line is what makes the first bearable and is equally true: everything
/// else really is gone.
///
/// Pops `true` for Retry, `false`/null for dismiss.
class _WipeLeftoverDialog extends StatelessWidget {
  const _WipeLeftoverDialog({required this.remaining, required this.stopped});

  /// The codes `wipeContainers` returns for what it re-stat'd and found still
  /// present. Kept as codes rather than sentences precisely so the sentence can
  /// be a translated one.
  final List<String> remaining;

  /// The wipe threw instead of returning. Nothing was verified, so this cannot
  /// claim the rest was destroyed — it says only what is honestly known.
  final bool stopped;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final container = remaining.contains('container');
    final files = remaining.contains('files');
    final String what;
    if (stopped || (!container && !files)) {
      what = l.lockWipeStopped;
    } else if (container && files) {
      what = l.lockWipeLeftBoth;
    } else if (container) {
      what = l.lockWipeLeftContainer;
    } else {
      what = l.lockWipeLeftFiles;
    }
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text(l.lockWipeLeftTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(what),
            // Only when the wipe ran to the end. After a throw nothing was
            // verified, so "everything else was destroyed" would be a guess
            // dressed as a reassurance.
            if (!stopped) ...[
              const SizedBox(height: 12),
              Text(
                l.lockWipeLeftRest,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.actionDone),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.lockWipeRetry),
        ),
      ],
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
            Text(
              l.lockWipeTypePrompt,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '"$phrase"',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: scheme.error,
              ),
            ),
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
