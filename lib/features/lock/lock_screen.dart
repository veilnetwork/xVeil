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

  /// Starts the wipe. Deliberately does NOT wait around for the verdict.
  ///
  /// `wipeContainers` checks by RE-STATING rather than by trusting `delete()`,
  /// and hands back what is still on disk. This screen used to raise the dialog
  /// for that list itself and a person whose container survived was shown
  /// nothing at all — which, in an app whose whole promise is deniability, is
  /// the worst direction for a silence to point: the one thing it hides is the
  /// thing that can convict you.
  ///
  /// Worth being exact about WHY, because the obvious reading is wrong. The
  /// suspect was the `if (!mounted) return` that stood here, on the theory that
  /// the wipe's last act — flipping the phase to onboarding — had the router
  /// unmount this widget first. It does not: the flip lands during an async
  /// gap, the router redirects on the NEXT FRAME, and `mounted` was measured
  /// true every time. The dialog really was raised.
  ///
  /// It was then destroyed. `showDialog` PUSHES A ROUTE, and a route pushed
  /// over a page-based one belongs to that page: when the redirect swapped
  /// `/lock` out, Flutter's navigator took the dialog with it, and the pending
  /// `showDialog` future completed with `null` as if the person had dismissed
  /// it. No exception, no log, nothing to see. So the depth matters — anything
  /// that answers this with a ROUTE, on any navigator, is the same bug wearing
  /// a different hat, including a post-frame push that merely races the
  /// redirect instead of losing to it outright.
  ///
  /// The answer is therefore published by [WipeReportController], which a route
  /// change cannot dispose, and painted by [WipeReportHost], which is a WIDGET
  /// above the router. All that is left here is to ask.
  Future<void> _runWipe() => ref.read(wipeReportProvider.notifier).runWipe();

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

/// Paints [WipeReportController]'s verdict over whatever the phase flip landed
/// on. Mounted in `MaterialApp.builder` (see `app.dart`), which is the one part
/// of the tree the router cannot take away.
///
/// A widget rather than a `showDialog`, and that is the whole of it — see
/// `_LockScreenState._runWipe` for the measurement. A dialog is a ROUTE, a
/// route pushed over a page goes when that page goes, and the wipe's own last
/// act is what takes the page away. Moving the same `showDialog` up to the root
/// navigator would only have made the failure quieter. This is painted above
/// the router instead, so it does not care what the router is doing and nothing
/// about it depends on winning a race with a redirect.
///
/// Still UNDER the screen-lock cover and the task-switcher shield, which wrap
/// this whole builder: what a wipe left behind is not something to show over a
/// locked screen or leak into the app-switcher snapshot.
class WipeReportHost extends ConsumerWidget {
  const WipeReportHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(wipeReportProvider);
    if (report == null) return const SizedBox.shrink();
    return Positioned.fill(
      // Nothing behind this is reachable while it is up — the same three
      // meanings of "unreachable" the screen lock spells out: the barrier eats
      // the pointer, and this drops what is underneath from the semantics tree
      // so a screen reader cannot read past it either.
      child: BlockSemantics(
        child: Stack(
          children: [
            // NOT dismissible by tapping outside. This is the outcome of the
            // one action in the app that cannot be undone, and an accidental
            // tap on the scrim must not be how it goes unread.
            const ModalBarrier(dismissible: false, color: Color(0x99000000)),
            _WipeLeftoverDialog(
              remaining: report.remaining,
              stopped: report.stopped,
              onDone: () => ref.read(wipeReportProvider.notifier).dismiss(),
              onRetry: () => ref.read(wipeReportProvider.notifier).runWipe(),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a wipe could not delete, named — and a Retry that runs it again.
///
/// Names the survivors rather than saying something went wrong: "the container
/// is still on this device" is a fact a person can act on (delete it, unmount
/// the volume, stop the backup agent), and "an error occurred" is not. The
/// second line is what makes the first bearable and is equally true: everything
/// else really is gone.
///
/// Answers through callbacks rather than by popping a route: it is rendered
/// directly by [WipeReportHost], which has no navigator of its own to pop.
class _WipeLeftoverDialog extends StatelessWidget {
  const _WipeLeftoverDialog({
    required this.remaining,
    required this.stopped,
    required this.onDone,
    required this.onRetry,
  });

  /// The person has read it; the report is cleared.
  final VoidCallback onDone;

  /// Run the whole wipe again. A user gesture with no bound on how many times
  /// it can be pressed, and each pass starts from a fresh call.
  final VoidCallback onRetry;

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
        TextButton(onPressed: onDone, child: Text(l.actionDone)),
        FilledButton(onPressed: onRetry, child: Text(l.lockWipeRetry)),
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
