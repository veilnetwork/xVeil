import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../common/shown_cause.dart';
import '../common/async_error_view.dart';
import '../../core/ids.dart';
import '../../data/transport/wire_envelope.dart' show isChatDeletedMarker;
import '../../domain/chat.dart';
import '../../domain/chat_folder.dart';
import '../../domain/space_recommendation.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import '../../state/messaging.dart';
import '../../state/nickname_peers.dart';
import 'chat_actions.dart';
import 'chat_search.dart';
import 'message_markdown.dart';
import '../../state/group_service_providers.dart';
import '../../state/folder_panel_controller.dart';
import '../../state/providers.dart';
import 'attachment_preview.dart';
import '../contacts/invite_exchange_sheet.dart';
import '../groups/group_tile.dart';
import '../home/home_section_scaffold.dart';

/// The chat-list folder filter: null = "All", else a [ChatFolder.id]. A plain
/// StateProvider so switching folders survives list rebuilds. Reset to All if
/// the selected folder is later deleted (handled in the build).
final selectedFolderProvider = StateProvider<String?>((_) => null);

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  // ── Search mode ───────────────────────────────────────────────────────────
  // The chats filter is instant (in-memory names); the message scan decrypts
  // conversation-by-conversation off the query debounce, appending hits
  // progressively. No on-disk index by design (ROADMAP: no plaintext-derived
  // artifacts) — a linear scan over the encrypted store.
  final _searchCtl = TextEditingController();
  Timer? _searchDebounce;
  bool _searching = false;
  String _query = '';
  List<(Conversation, Message)> _msgHits = const [];
  bool _scanning = false;
  int _scanGen = 0;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  void _enterSearch() => setState(() => _searching = true);

  void _exitSearch() {
    _scanGen++; // cancel any in-flight scan
    _searchDebounce?.cancel();
    _searchCtl.clear();
    setState(() {
      _searching = false;
      _query = '';
      _msgHits = const [];
      _scanning = false;
    });
  }

  void _onQueryChanged(String q) {
    setState(() => _query = q);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _scanMessages(q),
    );
  }

  /// Linear scan of every conversation's messages for [q]. Progressive: hits
  /// append per-conversation so first results show while the rest decrypts.
  /// A generation counter cancels superseded scans (typing, exit).
  Future<void> _scanMessages(String q) async {
    final gen = ++_scanGen;
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) {
      setState(() {
        _msgHits = const [];
        _scanning = false;
      });
      return;
    }
    setState(() {
      _scanning = true;
      _msgHits = const [];
    });
    final storage = ref.read(storageProvider);
    final convos =
        ref.read(conversationsProvider).value ?? const <Conversation>[];
    const cap = 100;
    final hits = <(Conversation, Message)>[];
    for (final c in convos) {
      if (gen != _scanGen || !mounted) return;
      List<Message> msgs;
      try {
        msgs = await storage.loadMessages(c.peer.nodeId.hex);
      } catch (_) {
        continue; // storage mid-switch — skip this conversation
      }
      for (final m in msgs) {
        if (messageMatchesQuery(m, needle)) hits.add((c, m));
        if (hits.length >= cap) break;
      }
      if (gen != _scanGen || !mounted) return;
      final sorted = List.of(hits)
        ..sort((a, b) => b.$2.timestamp.compareTo(a.$2.timestamp));
      setState(() => _msgHits = sorted);
      if (hits.length >= cap) break;
    }
    if (gen == _scanGen && mounted) setState(() => _scanning = false);
  }

  Widget _searchResults(
    AppL10n l,
    List<Conversation> convos,
    List<GroupListEntry> groups,
    ColorScheme scheme,
  ) {
    final needle = _query.trim().toLowerCase();
    final chatHits = filterConversationsByName(convos, needle);
    final groupHits = needle.isEmpty
        ? const <GroupListEntry>[]
        : groups
              .where((group) => group.name.toLowerCase().contains(needle))
              .toList(growable: false);
    final empty =
        chatHits.isEmpty && groupHits.isEmpty && _msgHits.isEmpty && !_scanning;
    return ListView(
      children: [
        if (_scanning) const LinearProgressIndicator(minHeight: 2),
        if (empty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(l.searchNoResults)),
          ),
        if (chatHits.isNotEmpty || groupHits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(l.navChats, style: TextStyle(color: scheme.primary)),
          ),
        for (final c in chatHits) _ConversationTile(conversation: c),
        for (final group in groupHits) GroupTile(entry: group),
        if (_msgHits.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              l.searchMessagesSection,
              style: TextStyle(color: scheme.primary),
            ),
          ),
        for (final (c, m) in _msgHits)
          ListTile(
            leading: CircleAvatar(
              child: Text(c.peer.label.characters.first.toUpperCase()),
            ),
            title: Text(c.peer.label),
            subtitle: Text(
              searchSnippet(
                messageSearchText(m).isNotEmpty
                    ? messageSearchText(m)
                    : (m.fileName ?? ''),
                needle,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => context.push('/chat/${c.peer.nodeId.hex}?msg=${m.id}'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final convos = ref.watch(conversationsProvider);
    final scheme = Theme.of(context).colorScheme;
    // Folder state lives at Scaffold level so the drawer variants can render
    // it independently of the conversation list's async state.
    final panelPos = ref.watch(folderPanelPositionProvider);
    final folders = ref.watch(chatFoldersProvider).value ?? const [];
    var selectedFolder = ref.watch(selectedFolderProvider);
    // If the selected folder was deleted, fall back to All.
    if (selectedFolder != null && !folders.any((f) => f.id == selectedFolder)) {
      selectedFolder = null;
    }
    final folder = selectedFolder == null
        ? null
        : folders.firstWhere((f) => f.id == selectedFolder);
    final folderDrawer = HomeNavigationDrawer(
      folders: folders,
      selected: selectedFolder,
      // The drawer is disposed as soon as it closes. Keep the dialog command
      // owned by ChatsScreen so its BuildContext and provider ref stay alive
      // while the user enters a name and the async create completes.
      onCreateGroup: () => showCreateGroupDialog(
        context,
        ref.read(groupServiceProvider),
        onCreated: () => ref.read(selectedFolderProvider.notifier).state = null,
      ),
    );
    final hasHomeNavigation = HomeNavigationScope.maybeOf(context) != null;
    return HomeSectionScaffold(
      // With a drawer placement the panel is collapsible: Scaffold puts the
      // hamburger in the app bar (leading for left, trailing for right).
      drawer: panelPos == FolderPanelPosition.left ? folderDrawer : null,
      endDrawer: panelPos == FolderPanelPosition.right ? folderDrawer : null,
      title: folder == null ? l.navChats : folder.name,
      searching: _searching,
      searchController: _searchCtl,
      searchHint: l.searchHint,
      onSearchStart: _enterSearch,
      onSearchClose: _exitSearch,
      onSearchChanged: _onQueryChanged,
      contextActions: [
        IconButton(
          key: const ValueKey('mentions-open'),
          icon: const Icon(Icons.alternate_email),
          tooltip: l.mentionsOpenTooltip,
          onPressed: () => context.push('/mentions'),
        ),
        // With the right-side placement the AppBar only auto-adds an
        // endDrawer toggle when it has NO other actions — so in debug builds
        // the panel used to be unopenable. Always provide the button.
        if (!hasHomeNavigation &&
            !_searching &&
            panelPos == FolderPanelPosition.right)
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.folder_open_outlined),
              tooltip: l.chatMenuFolders,
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
      ],
      floatingActionButton: _searching
          ? null
          : FloatingActionButton(
              heroTag: 'xveil-chats-add-contact',
              onPressed: () => showAddContactSheet(context, ref),
              child: const Icon(Icons.person_add_alt_1),
            ),
      body: _searching && _query.trim().isNotEmpty
          ? _searchResults(
              l,
              convos.value ?? const [],
              ref.watch(groupListProvider).value ?? const [],
              scheme,
            )
          : convos.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) =>
                  AsyncErrorView(error: e, stack: st, where: 'chats'),
              data: (list) {
                // Group chats share the Chats timeline with 1:1 chats. Custom
                // folders are peer-based for now, so they only affect 1:1 rows.
                final groups = folder == null
                    ? ref.watch(groupListProvider).value ??
                          const <GroupListEntry>[]
                    : const <GroupListEntry>[];
                if (list.isEmpty && groups.isEmpty) {
                  return _EmptyState(
                    l: l,
                    onStart: () => showAddContactSheet(context, ref),
                  );
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
                final active = scoped
                    .where((c) => !c.peer.archived)
                    .toList(growable: false);
                final archived = scoped
                    .where((c) => c.peer.archived)
                    .toList(growable: false);
                // One recency-ordered Chats stream: direct and group chats.
                final rows = <(int, Widget)>[
                  for (final c in active)
                    (
                      c.lastMessage?.timestamp.millisecondsSinceEpoch ?? 0,
                      _ConversationTile(conversation: c),
                    ),
                  for (final group in groups)
                    (group.lastTs, GroupTile(entry: group)),
                ]..sort((a, b) => b.$1.compareTo(a.$1));
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
                      child: (rows.isEmpty && archived.isEmpty)
                          ? Center(child: Text(l.chatsFolderEmpty))
                          : ListView(
                              children: [
                                for (final (i, r) in rows.indexed) ...[
                                  if (i > 0)
                                    const Divider(height: 1, indent: 72),
                                  r.$2,
                                ],
                                if (archived.isNotEmpty)
                                  ExpansionTile(
                                    leading: const Icon(Icons.archive_outlined),
                                    title: Text(
                                      '${l.chatsArchiveSection} (${archived.length})',
                                    ),
                                    children: [
                                      for (final c in archived)
                                        _ConversationTile(conversation: c),
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
}

/// Add a contact by exchanging veil bootstrap invites. Persists the peer and
/// opens the chat. (When the real veil stack is active this also redeems the
/// invite via veilBootstrapJoin; in loopback it just records the contact.)
/// Top-level so the FAB, the empty-state, AND the Telegram-style drawer menu
/// all open the same sheet.
Future<void> showAddContactSheet(BuildContext context, WidgetRef ref) async {
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
        // Counted only when the call actually happened (audit X-17). With
        // `stack?.addContact` the null case did nothing and still incremented,
        // so a user with no running stack was told "N peers imported" and
        // nothing had been. The loop is skipped entirely when there is no
        // stack, and the same "0 imported" message tells the truth.
        if (stack != null) {
          for (final p in peers) {
            try {
              await stack.addContact(p);
              added++;
            } catch (_) {}
          }
        }
        if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).peersImported(added))),
          );
        }
      },
      onAddNickname: (name) async {
        // `@name` → verified DHT resolve → the owner's node id becomes the
        // peer, the name→id binding is pinned (an owner change later WARNS,
        // never re-points), then the normal first-message consent flow.
        final l = AppL10n.of(context);
        if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
        void toast(String msg) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(msg)));
          }
        }

        try {
          final selfHex = await ref
              .read(messagingServiceProvider)
              .savedSelfHex();
          final self = NodeId.fromHex(selfHex).bytes;
          final norm = veil.normalizeNickname(name);
          final resolved = await veil.resolveNicknameAsync(
            selfNodeId: self,
            name: norm,
          );
          if (resolved == null) {
            toast(l.nicknameNotFound);
            return;
          }
          final ownerHex = NodeId(resolved.ownerNodeId).hex;
          if (ownerHex == selfHex) {
            toast(l.nicknameIsSelf);
            return;
          }
          await savePeerNickname(ref.read(storageProvider), ownerHex, norm);
          ref.invalidate(peerNicknameProvider(ownerHex));
          if (context.mounted) context.push('/chat/$ownerHex');
        } catch (e) {
          toast(shownCause(e, kind: 'nickname'));
        }
      },
    ),
  );
}

/// Telegram-style main drawer for the drawer placements (left/right):
/// identity header, then the FOLDERS (All + one tile per folder + new
/// folder; long-press / right-click a folder for rename/delete), then the
/// app MENU (add contact / network / settings). Selecting a folder closes
/// the drawer — the app-bar title then names the active folder.
class HomeNavigationDrawer extends ConsumerWidget {
  const HomeNavigationDrawer({
    super.key,
    required this.folders,
    required this.selected,
    required this.onCreateGroup,
  });
  final List<ChatFolder> folders;
  final String? selected;
  final Future<void> Function() onCreateGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final convos =
        ref.watch(conversationsProvider).value ?? const <Conversation>[];
    final app = ref.watch(appControllerProvider);
    final anon = ref.read(appControllerProvider.notifier).activeIsAnonymous;
    final label =
        app.activeIdentity ?? app.identity?.nodeId.short ?? l.navChats;
    void select(String? id) {
      ref.read(selectedFolderProvider.notifier).state = id;
      Navigator.of(context).pop(); // close the drawer
    }

    void go(String path) {
      Navigator.of(context).pop();
      context.push(path);
    }

    // Layout (user remark #4, 2026-07-10): header and SAVED MESSAGES pinned
    // at the top, the folder block alone scrolls when it outgrows the space,
    // and the app menu (add contact / network / settings) stays pinned at
    // the bottom — many folders must never push the menu off-screen.
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Identity header, Telegram-style: who am I right now (and
            // whether this identity routes anonymously).
            Container(
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    child: Text(
                      label.characters.first.toUpperCase(),
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (anon)
                    Icon(Icons.shield_moon, size: 20, color: scheme.primary),
                ],
              ),
            ),
            // Saved Messages — always first, always visible.
            Builder(
              builder: (_) {
                final myHex = ref
                    .watch(appControllerProvider)
                    .identity
                    ?.nodeId
                    .hex;
                if (myHex == null) return const SizedBox.shrink();
                return ListTile(
                  leading: const Icon(Icons.bookmark_outline),
                  title: Text(l.savedMessages),
                  onTap: () => go('/chat/$myHex'),
                );
              },
            ),
            const Divider(height: 1),
            // Folders — the chat filter this drawer replaces the chip bar
            // for. Each carries the sum of unread messages in its
            // conversations. This block alone scrolls.
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(l.chatsFolderAll),
                    selected: selected == null,
                    trailing: _badgeOrNull(folderUnreadCount(convos, null)),
                    onTap: () => select(null),
                  ),
                  for (final f in folders)
                    GestureDetector(
                      onSecondaryTap: () => folderMenu(context, ref, f),
                      child: ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(
                          f.name.isEmpty ? l.chatsFolderUnnamed : f.name,
                        ),
                        selected: selected == f.id,
                        trailing: _badgeOrNull(folderUnreadCount(convos, f)),
                        onTap: () => select(f.id),
                        onLongPress: () => folderMenu(context, ref, f),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.create_new_folder_outlined),
                    title: Text(l.chatsFolderNew),
                    onTap: () => createFolderDialog(context, ref),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // App menu — pinned to the bottom.
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: Text(l.inviteAddContact),
              onTap: () {
                Navigator.of(context).pop();
                showAddContactSheet(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: Text(l.groupCreateTitle),
              onTap: () {
                Navigator.of(context).pop();
                // Let the drawer finish its pop before presenting the dialog
                // from the still-mounted ChatsScreen owner.
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => unawaited(onCreateGroup()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.diversity_3_outlined),
              title: Text(l.navCommunities),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/spaces');
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_outlined),
              title: Text(l.navCalls),
              onTap: () => go('/calls'),
            ),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: Text(l.navNetwork),
              onTap: () => go('/network'),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(l.navSettings),
              onTap: () => go('/settings'),
            ),
            // Lock the app (moved here from settings — a session action, not a
            // setting). Error-tinted like other destructive/exit affordances.
            ListTile(
              leading: Icon(
                Icons.lock,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l.settingsLockNow,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => ref.read(appControllerProvider.notifier).lock(),
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
    final convos =
        ref.watch(conversationsProvider).value ?? const <Conversation>[];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: ChoiceChip(
              label: _chipLabel(
                l.chatsFolderAll,
                folderUnreadCount(convos, null),
              ),
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
                  label: _chipLabel(
                    f.name.isEmpty ? l.chatsFolderUnnamed : f.name,
                    folderUnreadCount(convos, f),
                  ),
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

/// Chip content for the folder bar: name + unread badge when non-zero.
Widget _chipLabel(String name, int unread) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(name),
    if (unread > 0) ...[const SizedBox(width: 6), _UnreadBadge(unread)],
  ],
);

Widget? _badgeOrNull(int count) => count == 0 ? null : _UnreadBadge(count);

/// Rounded unread counter shared by the folder drawer tiles and chip bar
/// (sum of unread MESSAGES in the folder, capped at "999+").
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge(this.count);
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        unreadBadgeText(count),
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
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
          Icon(
            Icons.forum_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(l.chatsEmpty, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(l.chatsEmptyHint, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 24),
          FilledButton.tonal(
            onPressed: onStart,
            child: Text(l.chatNewMessageHint),
          ),
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
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final last = conversation.lastMessage;
    final recommendation = last == null
        ? null
        : parseSpaceRecommendationMessage(last.body);
    final status = conversation.peer.status;
    // Saved Messages = the conversation with our own node id.
    final myHex = ref.watch(appControllerProvider).identity?.nodeId.hex;
    final isSaved = myHex != null && conversation.peer.nodeId.hex == myHex;
    final label = isSaved ? l.savedMessages : conversation.peer.label;
    final notificationMode = conversation.peer.notificationModeAt(
      DateTime.now(),
    );

    // Saved Messages is a chat with yourself — never a consent state, even if
    // an older build left a stale pendingIncoming self-contact behind.
    final (String? hint, Color? hintColor) = isSaved
        ? (null, null)
        : switch (status) {
            // These three were English in every build — the only user-visible
            // text in the app that never went through the ARB at all, which is
            // the mistake the reachability gate cannot see (it watches for
            // keys with no call site, not call sites with no key).
            ContactStatus.pendingIncoming => (
              '● ${l.chatListWantsToConnect}',
              scheme.primary,
            ),
            ContactStatus.pendingOutgoing => (
              l.chatListRequestSent,
              scheme.onSurfaceVariant,
            ),
            ContactStatus.blocked => (l.chatListBlocked, scheme.error),
            ContactStatus.accepted => (null, null),
          };

    return GestureDetector(
      onSecondaryTap: () => _showActions(context, ref),
      // The actions for a conversation are behind a long press and a
      // right-click, with nothing on screen saying so — and a screen reader
      // announced the row as a plain tap target, so for its users the actions
      // did not exist at all. `onLongPressHint` is what VoiceOver and
      // TalkBack read out for that gesture; the string for it was written and
      // never attached.
      child: Semantics(
        onLongPressHint: AppL10n.of(context).chatMoreActions,
        child: ListTile(
          leading: CircleAvatar(
            child: isSaved
                ? const Icon(Icons.bookmark_outline, size: 20)
                : Text(label.characters.first.toUpperCase()),
          ),
          title: Row(
            children: [
              if (conversation.peer.pinned)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.push_pin,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              if (notificationMode != NotificationMuteMode.all)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: notificationMuteModeIndicator(
                    context,
                    notificationMode,
                    key: ValueKey(
                      'chat-notification-${notificationMode.name}-${conversation.id}',
                    ),
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          subtitle: hint != null
              ? Text(hint, style: TextStyle(color: hintColor))
              : (last == null
                    ? null
                    : (last.isFile ||
                              isChatDeletedMarker(last.body) ||
                              recommendation != null
                          ? Text(
                              // Attachments render the shared human kind label
                              // (voice/video notes/stickers travel under opaque
                              // uuid container names — never show those); a
                              // chatDeleted farewell marker shows its system notice.
                              last.isFile
                                  ? messagePreviewText(l, last)
                                  : (isChatDeletedMarker(last.body)
                                        ? l.chatDeletedByPeer
                                        : (recommendation?.name ?? last.body)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : FormattedText(
                              last.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ))),
          trailing: (!isSaved && status == ContactStatus.pendingIncoming)
              ? Icon(Icons.fiber_new, color: scheme.primary)
              : (conversation.unread > 0
                    ? Badge(label: Text('${conversation.unread}'))
                    : null),
          onTap: () => context.push('/chat/${conversation.peer.nodeId.hex}'),
          onLongPress: () => _showActions(context, ref),
        ),
      ),
    );
  }
}
