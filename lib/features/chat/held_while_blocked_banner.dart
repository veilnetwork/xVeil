import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../l10n/app_localizations.dart';
import '../../state/messaging_providers.dart';

/// "N messages arrived while this contact was blocked — Show / Delete".
///
/// A message from a blocked contact is kept aside, out of the chat, instead of
/// being re-driven by its sender until the block is lifted and then simply
/// appearing. The owner's decision (2026-09-27): after unblocking, the person
/// chooses. Shown on every device that holds some — including one whose
/// unblock came from a sibling, where nobody was there to ask at that moment.
class HeldWhileBlockedBanner extends ConsumerStatefulWidget {
  const HeldWhileBlockedBanner({super.key, required this.peer});

  final NodeId peer;

  @override
  ConsumerState<HeldWhileBlockedBanner> createState() =>
      _HeldWhileBlockedBannerState();
}

class _HeldWhileBlockedBannerState
    extends ConsumerState<HeldWhileBlockedBanner> {
  int _count = 0;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = ref
        .read(messagingServiceProvider)
        .changes
        .listen((_) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final n = await ref
        .read(messagingServiceProvider)
        .heldWhileBlocked(widget.peer);
    if (mounted && n != _count) setState(() => _count = n);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    final svc = ref.read(messagingServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('held-while-blocked'),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.mark_email_unread_outlined,
                size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(l.chatHeldWhileBlocked(_count))),
            TextButton(
              key: const ValueKey('held-discard'),
              onPressed: () async {
                await svc.discardHeldWhileBlocked(widget.peer);
                await _refresh();
              },
              child: Text(l.chatHeldDiscard),
            ),
            TextButton(
              key: const ValueKey('held-show'),
              onPressed: () async {
                await svc.releaseHeldWhileBlocked(widget.peer);
                await _refresh();
              },
              child: Text(l.chatHeldShow),
            ),
          ],
        ),
      ),
    );
  }
}
