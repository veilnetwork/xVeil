// Group chat (groups epic, phase 0, brick 5): the validated message list + a
// composer that posts (auto-fanned to members by the service). The member
// count sits in the app bar; an overflow menu opens the member sheet.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/group.dart';
import '../../domain/group_message.dart';
import '../../domain/group_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service.dart';
import '../../state/messaging.dart' show conversationsProvider;
import '../../state/providers.dart';
import '../../state/sticker_store.dart';
import '../../state/thumbnail.dart';
import '../chat/sticker_panel.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  const GroupChatScreen({super.key, required this.groupIdHex});
  final String groupIdHex;

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _input = TextEditingController();
  late final NodeId _gid = NodeId.fromHex(widget.groupIdHex);

  /// The message the composer is replying to, or null.
  GroupMessage? _replyTarget;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  String? _takeReplyRef() {
    final r = _replyTarget?.ref;
    if (_replyTarget != null) setState(() => _replyTarget = null);
    return r;
  }

  Future<void> _send(GroupService svc) async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await svc.postMessage(_gid, text, replyTo: _takeReplyRef());
  }

  /// A one-line preview of [m] for the reply bar / quote block.
  String _msgPreview(GroupMessage m, AppL10n l) {
    if (m.body.isNotEmpty) return m.body;
    final k = m.attachment?.kind;
    if (k == 'image') return '🖼 ${l.groupAttachImage}';
    if (k == 'sticker') return '😊 ${l.groupSendSticker}';
    return '…';
  }

  /// The "replying to …" bar shown above the composer.
  Widget _replyBar(BuildContext context, AppL10n l) {
    final t = _replyTarget!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.author.short,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.primary)),
                Text(_msgPreview(t, l),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTarget = null),
          ),
        ],
      ),
    );
  }

  /// Pick an image and post it inline (groups media brick 1). The picture is
  /// downscaled + size-capped into the signed message so every member renders
  /// it without a content fetch; any caption typed in the composer rides along.
  Future<void> _attachImage(GroupService svc) async {
    final l = AppL10n.of(context);
    final picked = await FilePicker.pickFiles();
    final file = picked?.files.firstOrNull;
    if (file == null) return; // cancelled
    if (!isImageFileName(file.name)) {
      if (mounted) _snack(l.groupImageOnly);
      return;
    }
    Uint8List? bytes = file.bytes;
    final path = file.path;
    if (bytes == null && path != null) {
      try {
        bytes = await File(path).readAsBytes();
      } catch (_) {/* fall through to the null check */}
    }
    if (bytes == null) return;
    final img = await makeInlineImageB64(bytes);
    if (img == null) {
      if (mounted) _snack(l.groupImageTooLarge);
      return;
    }
    final caption = _input.text.trim();
    _input.clear();
    await svc.postMessage(
      _gid,
      caption,
      replyTo: _takeReplyRef(),
      attachment: GroupAttachment(
        kind: 'image',
        dataB64: img.b64,
        w: img.w,
        h: img.h,
      ),
    );
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  /// Pick a sticker from the user's library and post it inline (kind='sticker'
  /// → borderless render). Reuses the 1:1 sticker sheet; a small static sticker
  /// fits the inline-attachment path (delta-broadcast, one-time chunk cost).
  Future<void> _attachSticker(GroupService svc) async {
    final picked = await showStickerPanel(context);
    if (picked == null || picked.startsWith('pack:')) return; // no pack-share
    final bytes =
        await ref.read(storageProvider).loadFile(stickerFileKey(picked));
    if (bytes == null) return;
    final img = await makeInlineImageB64(bytes);
    if (img == null) return;
    await svc.postMessage(
      _gid,
      '',
      attachment: GroupAttachment(
        kind: 'sticker',
        dataB64: img.b64,
        w: img.w,
        h: img.h,
      ),
    );
  }

  /// The member roster + management actions (add / mute / role / remove). Every
  /// action is gated by [canApply] against MY current role, so the UI only
  /// offers what the control-log would actually accept; the service re-checks on
  /// commit. The sheet is reactive (svc.changes) so it refreshes after an op.
  Future<void> _showMembers(GroupService svc) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AnimatedBuilder(
        animation: svc.changes,
        builder: (context, _) => FutureBuilder<GroupState?>(
          future: svc.stateOf(_gid),
          builder: (context, snap) {
            final l = AppL10n.of(context);
            final state = snap.data;
            if (state == null) {
              return const SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }
            final myRole = state.roleOf(svc.selfId);
            final canAdd = myRole != null &&
                canApply(
                    authorRole: myRole,
                    op: ControlOp.addMember,
                    newRole: GroupRole.member);
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(l.groupMembers(state.members.length),
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                        if (canAdd)
                          TextButton.icon(
                            onPressed: () => _addMember(svc, state),
                            icon: const Icon(Icons.person_add_alt),
                            label: Text(l.groupAddMember),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final m in state.members.values)
                          _memberTile(svc, myRole, m, l),
                      ],
                    ),
                  ),
                  if (myRole != null && myRole != GroupRole.owner)
                    ListTile(
                      leading: Icon(Icons.logout,
                          color: Theme.of(context).colorScheme.error),
                      title: Text(l.groupLeave,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                      onTap: () => _leaveGroup(svc),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Confirm + leave the group: closes the member sheet and returns to the list.
  Future<void> _leaveGroup(GroupService svc) async {
    final l = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.groupLeave),
        content: Text(l.groupLeaveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.groupLeave),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await svc.leaveGroup(_gid);
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop(); // close the member sheet
    nav.pop(); // return to the group list
  }

  Widget _memberTile(
      GroupService svc, GroupRole? myRole, GroupMember m, AppL10n l) {
    final isSelf = m.nodeId == svc.selfId;
    final actions = <PopupMenuEntry<String>>[];
    if (myRole != null && !isSelf) {
      final tr = m.role;
      if (canApply(
          authorRole: myRole,
          op: m.muted ? ControlOp.unmute : ControlOp.mute,
          targetRole: tr)) {
        actions.add(PopupMenuItem(
            value: m.muted ? 'unmute' : 'mute',
            child: Text(m.muted ? l.groupUnmute : l.groupMute)));
      }
      if (m.role == GroupRole.member &&
          canApply(
              authorRole: myRole,
              op: ControlOp.setRole,
              targetRole: tr,
              newRole: GroupRole.admin)) {
        actions
            .add(PopupMenuItem(value: 'promote', child: Text(l.groupPromote)));
      }
      if (m.role == GroupRole.admin &&
          canApply(
              authorRole: myRole,
              op: ControlOp.setRole,
              targetRole: tr,
              newRole: GroupRole.member)) {
        actions.add(PopupMenuItem(value: 'demote', child: Text(l.groupDemote)));
      }
      if (canApply(
          authorRole: myRole, op: ControlOp.removeMember, targetRole: tr)) {
        actions.add(PopupMenuItem(value: 'remove', child: Text(l.groupRemove)));
      }
    }
    return ListTile(
      dense: true,
      leading: Icon(m.role == GroupRole.owner
          ? Icons.star
          : (m.role == GroupRole.admin
              ? Icons.shield_outlined
              : Icons.person_outline)),
      title: Text(m.nodeId.short),
      subtitle: Text(m.role.name),
      trailing: actions.isEmpty
          ? (m.muted ? const Icon(Icons.volume_off, size: 16) : null)
          : PopupMenuButton<String>(
              itemBuilder: (_) => actions,
              onSelected: (v) => _memberAction(svc, m, v),
            ),
    );
  }

  Future<void> _memberAction(
      GroupService svc, GroupMember m, String action) async {
    switch (action) {
      case 'mute':
        await svc.addControlOp(_gid, ControlOp.mute, target: m.nodeId);
      case 'unmute':
        await svc.addControlOp(_gid, ControlOp.unmute, target: m.nodeId);
      case 'promote':
        await svc.addControlOp(_gid, ControlOp.setRole,
            target: m.nodeId, role: GroupRole.admin);
      case 'demote':
        await svc.addControlOp(_gid, ControlOp.setRole,
            target: m.nodeId, role: GroupRole.member);
      case 'remove':
        await svc.addControlOp(_gid, ControlOp.removeMember, target: m.nodeId);
    }
  }

  /// Pick an accepted contact not already in the group and add them as a member
  /// (a full snapshot broadcast syncs the whole history to the joiner).
  Future<void> _addMember(GroupService svc, GroupState state) async {
    final l = AppL10n.of(context);
    final convos =
        ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[];
    final candidates = [
      for (final c in convos)
        if (c.peer.status == ContactStatus.accepted &&
            !state.isMember(c.peer.nodeId))
          c.peer,
    ];
    if (candidates.isEmpty) {
      _snack(l.groupNoContactsToAdd);
      return;
    }
    final picked = await showModalBottomSheet<NodeId>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in candidates)
              ListTile(
                leading: CircleAvatar(
                  child: Text(((c.name?.isNotEmpty ?? false)
                          ? c.name!
                          : c.nodeId.short)
                      .characters
                      .first
                      .toUpperCase()),
                ),
                title: Text((c.name?.isNotEmpty ?? false)
                    ? c.name!
                    : c.nodeId.short),
                subtitle: Text(c.nodeId.short),
                onTap: () => Navigator.of(context).pop(c.nodeId),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await svc.addControlOp(_gid, ControlOp.addMember,
        target: picked, role: GroupRole.member);
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
                  final byRef = {for (final m in msgs) m.ref: m};
                  return ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final m = msgs[i];
                      final mine = m.author == svc.selfId;
                      return _GroupBubble(
                        message: m,
                        mine: mine,
                        quoted: m.replyTo == null ? null : byRef[m.replyTo],
                        onReply: () => setState(() => _replyTarget = m),
                      );
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTarget != null) _replyBar(context, l),
                  Row(
                children: [
                  IconButton(
                    onPressed: () => _attachImage(svc),
                    tooltip: l.groupAttachImage,
                    icon: const Icon(Icons.image_outlined),
                  ),
                  IconButton(
                    onPressed: () => _attachSticker(svc),
                    tooltip: l.groupSendSticker,
                    icon: const Icon(Icons.emoji_emotions_outlined),
                  ),
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
  const _GroupBubble({
    required this.message,
    required this.mine,
    this.quoted,
    this.onReply,
  });
  final GroupMessage message;
  final bool mine;

  /// The resolved message this one replies to (null if none / not held yet).
  final GroupMessage? quoted;

  /// Long-press to reply to this message.
  final VoidCallback? onReply;

  /// One-line preview of the quoted message for the in-bubble quote block.
  static String _preview(GroupMessage m) {
    if (m.body.isNotEmpty) return m.body;
    final k = m.attachment?.kind;
    if (k == 'image') return '🖼';
    if (k == 'sticker') return '😊';
    return '…';
  }

  Widget _quoteBlock(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = quoted!;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(q.author.short,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.primary)),
          Text(_preview(q),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final att = message.attachment;
    // A sticker renders BORDERLESS (no bubble background), like every messenger.
    if (att != null && att.kind == 'sticker' && message.body.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: onReply,
        child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!mine)
                Text(message.author.short,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.primary)),
              SizedBox(
                width: 140,
                height: 140,
                child: Image.memory(
                  base64Decode(att.dataB64),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                ),
              ),
            ],
          ),
        ),
      ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onReply,
      child: Align(
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
            if (quoted != null) _quoteBlock(context),
            if (message.attachment != null &&
                message.attachment!.kind == 'image')
              Padding(
                padding: EdgeInsets.only(bottom: message.body.isEmpty ? 0 : 6),
                child: ConstrainedBox(
                  // Keep an inline photo to a sensible size regardless of the
                  // (small) encoded resolution or a wide desktop bubble.
                  constraints: const BoxConstraints(
                      maxWidth: 240, maxHeight: 320),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: AspectRatio(
                      aspectRatio: message.attachment!.h == 0
                          ? 1
                          : message.attachment!.w / message.attachment!.h,
                      child: Image.memory(
                        base64Decode(message.attachment!.dataB64),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                ),
              ),
            if (message.body.isNotEmpty) Text(message.body),
          ],
        ),
      ),
    ),
    );
  }
}
