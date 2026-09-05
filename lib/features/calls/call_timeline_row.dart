import 'package:flutter/material.dart';

import '../../core/format.dart' show formatDateTime;
import '../../domain/call_log.dart';
import '../../l10n/app_localizations.dart';

/// A call, rendered where it happened in the conversation.
///
/// Centred and quiet, like the disappearing-window notice beside it: this is
/// something that HAPPENED in the chat, not something either side said, and a
/// bubble would claim otherwise. A missed one is tinted, because that is the
/// one a person opens the chat to find.
class CallTimelineRow extends StatelessWidget {
  const CallTimelineRow({super.key, required this.entry});

  final CallLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final missed = entry.outcome == CallLogOutcome.missed;
    final (icon, tint) = switch ((entry.outgoing, entry.outcome)) {
      (_, CallLogOutcome.missed) => (Icons.call_missed, scheme.error),
      (true, _) => (Icons.call_made, scheme.onSurfaceVariant),
      (false, _) => (Icons.call_received, scheme.onSurfaceVariant),
    };
    final what = switch (entry.outcome) {
      CallLogOutcome.completed => _duration(l, entry.durationSec),
      CallLogOutcome.missed => l.callOutcomeMissed,
      CallLogOutcome.declined => l.callOutcomeDeclined,
      CallLogOutcome.cancelled => l.callOutcomeCancelled,
      CallLogOutcome.busy => l.callOutcomeBusy,
      CallLogOutcome.failed => l.callOutcomeFailed,
    };
    final kind = entry.video ? l.callKindVideo : l.callKindVoice;
    final when = formatDateTime(
      DateTime.fromMillisecondsSinceEpoch(entry.atMs),
    );
    return Semantics(
      // One sentence for a screen reader, rather than four fragments read out
      // with nothing joining them.
      label: '$kind, $what, $when',
      child: ExcludeSemantics(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: missed
                    ? scheme.errorContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: missed ? scheme.onErrorContainer : tint,
                  ),
                  const SizedBox(width: 6),
                  if (entry.video) ...[
                    Icon(
                      Icons.videocam_outlined,
                      size: 15,
                      color: missed ? scheme.onErrorContainer : tint,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      '$what · $when',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: missed ? scheme.onErrorContainer : tint,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _duration(AppL10n l, int seconds) {
    final m = seconds ~/ 60, s = seconds % 60;
    return '${l.callOutcomeCompleted} $m:${s.toString().padLeft(2, '0')}';
  }
}
