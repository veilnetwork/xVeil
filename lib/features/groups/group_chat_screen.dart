// Group chat (groups epic, phase 0, brick 5): the validated message list + a
// composer that posts (auto-fanned to members by the service). The member
// count sits in the app bar; an overflow menu opens the member sheet.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/group.dart';
import '../../domain/group_message.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  const GroupChatScreen({super.key, required this.groupIdHex});
  final String groupIdHex;

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _input = TextEditingController();
  late final NodeId _gid = NodeId.fromHex(widget.groupIdHex);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send(GroupService svc) async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await svc.postMessage(_gid, text);
  }

  Future<void> _showMembers(GroupService svc) async {
    final state = await svc.stateOf(_gid);
    if (!mounted || state == null) return;
    final l = AppL10n.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l.groupMembers(state.members.length),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final m in state.members.values)
              ListTile(
                dense: true,
                leading: Icon(
                  m.role == GroupRole.owner
                      ? Icons.star
                      : (m.role == GroupRole.admin
                          ? Icons.shield_outlined
                          : Icons.person_outline),
                ),
                title: Text(m.nodeId.short),
                subtitle: Text(m.role.name),
                trailing: m.muted ? const Icon(Icons.volume_off, size: 16) : null,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final svc = ref.watch(groupServiceProvider);
    if (svc == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: FutureBuilder<List<GroupManifest>>(
          future: svc.listGroups(),
          builder: (context, snap) {
            final g = (snap.data ?? const [])
                .where((m) => m.groupId == _gid)
                .cast<GroupManifest?>()
                .firstWhere((_) => true, orElse: () => null);
            return Text(g?.name ?? l.navChannels);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: l.groupMembersTooltip,
            onPressed: () => _showMembers(svc),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: svc.changes,
              builder: (context, _) => FutureBuilder<List<GroupMessage>>(
                future: svc.messagesOf(_gid),
                builder: (context, snap) {
                  final msgs = snap.data ?? const [];
                  if (msgs.isEmpty) {
                    return Center(child: Text(l.groupNoMessages));
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final m = msgs[i];
                      final mine = m.author == svc.selfId;
                      return _GroupBubble(message: m, mine: mine);
                    },
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(hintText: l.chatRequestHint),
                      onSubmitted: (_) => _send(svc),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: () => _send(svc),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupBubble extends StatelessWidget {
  const _GroupBubble({required this.message, required this.mine});
  final GroupMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Text(
                message.author.short,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.primary),
              ),
            Text(message.body),
          ],
        ),
      ),
    );
  }
}
