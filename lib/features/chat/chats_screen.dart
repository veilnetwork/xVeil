import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/chat_folder.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/messaging.dart';
import 'chat_actions.dart';
import '../../state/folder_panel_controller.dart';
import '../../state/providers.dart';
import '../contacts/invite_exchange_sheet.dart';

/// The chat-list folder filter: null = "All", else a [ChatFolder.id]. A plain
/// StateProvider so switching folders survives list rebuilds. Reset to All if
/// the selected folder is later deleted (handled in the build).
final selectedFolderProvider = StateProvider<String?>((_) => null);

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
    // Folder state lives at Scaffold level so the drawer variants can render
    // it independently of the conversation list's async state.
    final panelPos = ref.watch(folderPanelPositionProvider);
    final folders = ref.watch(chatFoldersProvider).valueOrNull ?? const [];
    var selectedFolder = ref.watch(selectedFolderProvider);
    // If the selected folder was deleted, fall back to All.
    if (selectedFolder != null &&
        !folders.any((f) => f.id == selectedFolder)) {
      selectedFolder = null;
    }
    final folder = selectedFolder == null
        ? null
        : folders.firstWhere((f) => f.id == selectedFolder);
    final folderDrawer = _FolderDrawer(folders: folders, selected: selectedFolder);
    return Scaffold(
      // With a drawer placement the panel is collapsible: Scaffold puts the
      // hamburger in the app bar (leading for left, trailing for right).
      drawer: panelPos == FolderPanelPosition.left ? folderDrawer : null,
      endDrawer: panelPos == FolderPanelPosition.right ? folderDrawer : null,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // When filtered through a drawer (no always-visible chips), the
            // title is the only place that shows WHICH folder is active.
            Text(folder == null ? l.navChats : folder.name),
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
          // Filter to the selected folder's members (All = everything).
          final scoped = folder == null
              ? list
              : list
                  .where((c) => folder.contains(c.peer.nodeId.hex))
                  .toList(growable: false);
          // Archived conversations collapse into a section at the bottom —
          // they keep receiving messages (and unread badges) but stay out of
          // the main list until unarchived.
          final active =
              scoped.where((c) => !c.peer.archived).toList(growable: false);
          final archived =
              scoped.where((c) => c.peer.archived).toList(growable: false);
          return Column(
            children: [
              // Top placement only; drawer placements render the folders in
              // the Scaffold drawer above. Always shown there (even with zero
              // folders): the "+" chip is the way to create the FIRST folder —
              // hiding the bar until one existed made the feature
              // undiscoverable.
              if (panelPos == FolderPanelPosition.top)
                _FolderBar(folders: folders, selected: selectedFolder),
              Expanded(
                child: (active.isEmpty && archived.isEmpty)
                    ? Center(child: Text(l.chatsFolderEmpty))
                    : ListView(
            children: [
              for (final (i, c) in active.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 72),
                _ConversationTile(conversation: c),
              ],
              if (archived.isNotEmpty)
                ExpansionTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: Text(
                    '${l.chatsArchiveSection} (${archived.length})',
                  ),
                  children: [
                    for (final c in archived) _ConversationTile(conversation: c),
                  ],
                ),
            ],
          ),
              ),
            ],
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

/// Collapsible folder navigation for the drawer placements (left/right).
/// Same model as [_FolderBar]: "All" + one tile per folder + "new folder";
/// long-press / right-click a folder for rename/delete. Selecting closes the
/// drawer — the app-bar title then names the active folder.
class _FolderDrawer extends ConsumerWidget {
  const _FolderDrawer({required this.folders, required this.selected});
  final List<ChatFolder> folders;
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    void select(String? id) {
      ref.read(selectedFolderProvider.notifier).state = id;
      Navigator.of(context).pop(); // close the drawer
    }

    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l.chatMenuFolders,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: Text(l.chatsFolderAll),
              selected: selected == null,
              onTap: () => select(null),
            ),
            for (final f in folders)
              GestureDetector(
                onSecondaryTap: () => folderMenu(context, ref, f),
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f.name.isEmpty ? l.chatsFolderUnnamed : f.name),
                  selected: selected == f.id,
                  onTap: () => select(f.id),
                  onLongPress: () => folderMenu(context, ref, f),
                ),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(l.chatsFolderNew),
              onTap: () => createFolderDialog(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal folder selector under the app bar: "All" + one chip per folder,
/// plus a manage (⋯) chip. Tapping a chip switches the filter; long-press on a
/// folder chip opens its rename/delete menu.
class _FolderBar extends ConsumerWidget {
  const _FolderBar({required this.folders, required this.selected});
  final List<ChatFolder> folders;
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: ChoiceChip(
              label: Text(l.chatsFolderAll),
              selected: selected == null,
              onSelected: (_) =>
                  ref.read(selectedFolderProvider.notifier).state = null,
            ),
          ),
          for (final f in folders)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: GestureDetector(
                onLongPress: () => folderMenu(context, ref, f),
                onSecondaryTap: () => folderMenu(context, ref, f),
                child: ChoiceChip(
                  label: Text(f.name.isEmpty ? l.chatsFolderUnnamed : f.name),
                  selected: selected == f.id,
                  onSelected: (_) =>
                      ref.read(selectedFolderProvider.notifier).state = f.id,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: Text(l.chatsFolderNew),
              onPressed: () => createFolderDialog(context, ref),
            ),
          ),
        ],
      ),
    );
  }

}

/// Rename/delete menu for one folder. Shared by the chip bar and the drawer.
Future<void> folderMenu(
  BuildContext context,
  WidgetRef ref,
  ChatFolder f,
) async {
  final l = AppL10n.of(context);
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l.chatsFolderRename),
            onTap: () async {
              Navigator.of(sheet).pop();
              final name = await _promptFolderName(context, f.name);
              if (name != null) {
                await ref
                    .read(messagingServiceProvider)
                    .renameFolder(f.id, name);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l.chatsFolderDelete),
            onTap: () async {
              Navigator.of(sheet).pop();
              await ref.read(messagingServiceProvider).deleteFolder(f.id);
            },
          ),
        ],
      ),
    ),
  );
}

/// Prompt for a new folder name and create it. Shared with the "+" chip.
Future<void> createFolderDialog(BuildContext context, WidgetRef ref) async {
  final name = await _promptFolderName(context, '');
  if (name == null || name.isEmpty) return;
  await ref.read(messagingServiceProvider).createFolder(name);
}

Future<String?> _promptFolderName(BuildContext context, String initial) {
  final l = AppL10n.of(context);
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l.chatsFolderName),
      content: TextField(controller: ctl, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialog).pop(ctl.text.trim()),
          child: Text(l.actionSave),
        ),
      ],
    ),
  ).whenComplete(ctl.dispose);
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
