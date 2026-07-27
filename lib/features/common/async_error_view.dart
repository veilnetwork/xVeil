import 'package:flutter/material.dart';

import '../../core/error_journal.dart';
import '../../l10n/app_localizations.dart';

/// What a person sees when a screen fails to load.
///
/// Painting `'$error'` is the obvious thing and the wrong one here. An
/// exception in this app routinely quotes a node id or a store path, and these
/// are the screens people keep open — so the raw text ends up in front of
/// whoever is looking over their shoulder, and in any screenshot they send
/// while asking for help. That is a poor trade in a messenger whose whole
/// premise is that its contents are deniable.
///
/// The detail is not lost: it goes to [errorJournal], which redacts it and
/// hands it over only when the person deliberately taps "Copy error report".
/// So the same information reaches whoever can act on it, by a route the
/// person chose.
class AsyncErrorView extends StatefulWidget {
  const AsyncErrorView({
    super.key,
    required this.error,
    required this.where,
    this.stack,
  });

  final Object error;

  /// Which screen failed — `chats`, `chat`, `spaces`. Recorded, not shown: it
  /// tells a reader where to look without telling a bystander anything.
  final String where;

  final StackTrace? stack;

  @override
  State<AsyncErrorView> createState() => _AsyncErrorViewState();
}

class _AsyncErrorViewState extends State<AsyncErrorView> {
  @override
  void initState() {
    super.initState();
    // Once per failure, not once per rebuild — an error view can rebuild on
    // every frame while it is on screen, and 50 copies of one failure would
    // push everything else out of the ring.
    errorJournal.record(
      kind: 'screen:${widget.where}',
      error: widget.error,
      stack: widget.stack,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 32, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              l.errorLoadFailed,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 6),
            Text(
              l.errorLoadFailedHint,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
