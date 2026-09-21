import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/async_error_view.dart';
import '../../domain/clear_request.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/messaging.dart';

/// Requests from other people to empty a conversation, waiting for an answer.
///
/// This screen is what makes the "ask me" policy honest. Without somewhere for
/// an unanswered request to be seen, "ask me" would behave exactly like
/// "never" while claiming to be a question — so the default only moved to
/// asking once this existed.
///
/// Nothing here tells the requester anything, whichever way it goes. That is
/// the same no-oracle rule the rest of the messaging layer keeps: a peer
/// learns whether its request was honoured only from the conversation itself,
/// never from an answer we send back.
class ClearRequestsScreen extends ConsumerWidget {
  const ClearRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final requests = ref.watch(pendingClearRequestsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.clearRequestsTitle),
      ),
      body: requests.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) =>
            AsyncErrorView(error: e, stack: st, where: 'clear-requests'),
        data: (list) {
          if (list.isEmpty) {
            return Center(child: Text(l.clearRequestsEmpty));
          }
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  l.clearRequestsHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final request in list)
                _ClearRequestTile(request: request, ref: ref),
            ],
          );
        },
      ),
    );
  }
}

class _ClearRequestTile extends StatelessWidget {
  const _ClearRequestTile({required this.request, required this.ref});

  final PendingClearRequest request;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final who = request.requesterHex.length > 8
        ? request.requesterHex.substring(0, 8)
        : request.requesterHex;
    return ListTile(
      isThreeLine: true,
      leading: const Icon(Icons.delete_sweep_outlined),
      title: Text(l.clearRequestsFrom(who)),
      subtitle: Text(l.clearRequestsBody),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            // Declining is the safe half — it keeps the messages — so it is
            // the one that needs no confirmation.
            onPressed: () => ref
                .read(messagingServiceProvider)
                .answerClearRequest(request, accept: false),
            child: Text(l.clearRequestsKeep),
          ),
          FilledButton.tonal(
            onPressed: () => _confirmErase(context, l),
            child: Text(l.clearRequestsErase),
          ),
        ],
      ),
    );
  }

  /// Saying yes is irreversible, so it is asked twice — the same standard the
  /// person's own clear is held to.
  Future<void> _confirmErase(BuildContext context, AppL10n l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.clearRequestsConfirmTitle),
        content: Text(l.clearRequestsConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l.clearRequestsErase),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(messagingServiceProvider)
        .answerClearRequest(request, accept: true);
  }
}
