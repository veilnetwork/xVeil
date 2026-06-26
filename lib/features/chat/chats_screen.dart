import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/messaging.dart';
import 'chat_actions.dart';
import '../../state/providers.dart';
import '../contacts/invite_exchange_sheet.dart';

class ChatsScreen extends ConsumerWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final convos = ref.watch(conversationsProvider);
    // Rebuild on identity switch; the active identity's anonymity then shows in
    // the app bar so the user can SEE they're on an anonymous (onion) identity.
    ref.watch(appControllerProvider.select((s) => s.activeIdentity));
    final anon = ref.read(appControllerProvider.notifier).activeIsAnonymous;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.navChats),
            if (anon) ...[
              const SizedBox(width: 8),
              Icon(Icons.shield_moon, size: 20, color: scheme.primary),
            ],
          ],
        ),
        bottom: anon
            ? PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Container(
                  width: double.infinity,
                  color: scheme.primaryContainer,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    l.settingsAnonymousRouting,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              )
            : null,
        actions: [
          // Dev-only affordance (debug builds): start a chat by raw node id or
          // a demo peer. Hidden in release so it can't ship to users.
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.science_outlined),
              tooltip: l.demoChatTooltip,
              onPressed: () => _newChat(context),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addByInvite(context, ref),
        child: const Icon(Icons.person_add_alt_1),
      ),
      body: convos.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) {
            return _EmptyState(l: l, onStart: () => _addByInvite(context, ref));
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (_, i) => _ConversationTile(conversation: list[i]),
          );
        },
      ),
    );
  }

  Future<void> _newChat(BuildContext context) async {
    final hex = await showDialog<String>(
      context: context,
      builder: (_) => const _NewChatDialog(),
    );
    if (hex == null || !context.mounted) return;
    context.push('/chat/$hex');
  }

  /// Add a contact by exchanging veil bootstrap invites. Persists the peer and
  /// opens the chat. (When the real veil stack is active this also redeems the
  /// invite via veilBootstrapJoin; in loopback it just records the contact.)
  Future<void> _addByInvite(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => InviteExchangeSheet(
        myInvite: ref.read(myInviteProvider),
        onAddContact: (invite) async {
          // Guard: redeeming your OWN invite would silently open a nonsensical
          // self-chat. Tell the user instead of pretending it worked.
          final me = ref.read(appControllerProvider).identity?.nodeId;
          if (me != null && invite.nodeId == me) {
            if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppL10n.of(context).inviteIsSelf)),
              );
            }
            return;
          }
          // In real mode, redeem the invite so our node can dial the peer
          // (a redeem failure, e.g. already known, must not block the flow).
          try {
            await ref.read(realStackProvider)?.addContact(invite);
          } catch (_) {}
          // No contact is recorded yet — opening the chat lets the user send a
          // connection request (the first message becomes the greeting).
          if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
          if (context.mounted) context.push('/chat/${invite.nodeId.hex}');
        },
        onImportPeers: (peers) async {
          // A `veil:peers?` entry-node share: add each as a bootstrap peer (it
          // carries a real transport, so addContact dials it) — NO contact, NO
          // chat. Failures (already known) must not block the rest.
          final stack = ref.read(realStackProvider);
          var added = 0;
          for (final p in peers) {
            try {
              await stack?.addContact(p);
              added++;
            } catch (_) {}
          }
          if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(AppL10n.of(context).peersImported(added))),
            );
          }
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.l, required this.onStart});
  final AppL10n l;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(l.chatsEmpty, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(l.chatsEmptyHint,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 24),
          FilledButton.tonal(onPressed: onStart, child: Text(l.chatNewMessageHint)),
        ],
      ),
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.conversation});
  final Conversation conversation;

  /// Long-press (touch) / right-click (desktop) → the SHARED conversation
  /// management sheet (rename / pin / mute / auto-delete / block / clear /
  /// delete) — the same actions as the in-chat menu, now reachable from the
  /// chats list. No onDeleted callback: the list just refreshes after a delete.
  void _showActions(BuildContext context, WidgetRef ref) {
    showConversationActions(context, ref, conversation.peer);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final last = conversation.lastMessage;
    final status = conversation.peer.status;

    final (String? hint, Color? hintColor) = switch (status) {
      ContactStatus.pendingIncoming => ('● wants to connect', scheme.primary),
      ContactStatus.pendingOutgoing => ('request sent', scheme.onSurfaceVariant),
      ContactStatus.blocked => ('blocked', scheme.error),
      ContactStatus.accepted => (null, null),
    };

    return GestureDetector(
      onSecondaryTap: () => _showActions(context, ref),
      child: ListTile(
        leading: CircleAvatar(
          child: Text(conversation.peer.label.characters.first.toUpperCase()),
        ),
        title: Row(
          children: [
            if (conversation.peer.pinned)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.push_pin,
                    size: 14, color: scheme.onSurfaceVariant),
              ),
            Flexible(
              child: Text(conversation.peer.label,
                  overflow: TextOverflow.ellipsis),
            ),
            if (conversation.peer.muted)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.notifications_off,
                    size: 14, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        subtitle: hint != null
            ? Text(hint, style: TextStyle(color: hintColor))
            : (last == null
                ? null
                : Text(last.body, maxLines: 1, overflow: TextOverflow.ellipsis)),
        trailing: status == ContactStatus.pendingIncoming
            ? Icon(Icons.fiber_new, color: scheme.primary)
            : (conversation.unread > 0
                ? Badge(label: Text('${conversation.unread}'))
                : null),
        onTap: () => context.push('/chat/${conversation.peer.nodeId.hex}'),
        onLongPress: () => _showActions(context, ref),
      ),
    );
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog();

  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    try {
      final id = NodeId.fromHex(text);
      Navigator.of(context).pop(id.hex);
    } catch (_) {
      setState(() => _error = 'Enter a 64-character node id (hex)');
    }
  }

  void _useDemoPeer() {
    // A random valid peer id — the loopback transport echoes replies from it.
    final rnd = Random.secure();
    final bytes = List.generate(32, (_) => rnd.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    Navigator.of(context).pop(hex);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(l.demoNewChat),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ctrl,
            decoration: InputDecoration(
              labelText: l.demoPeerNodeId,
              errorText: _error,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _useDemoPeer,
              icon: const Icon(Icons.smart_toy_outlined),
              label: Text(l.demoChatWith),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l.actionOpen)),
      ],
    );
  }
}
