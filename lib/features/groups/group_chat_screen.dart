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
import '../../domain/group.dart';
import '../../domain/group_message.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service.dart';
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
    final att = message.attachment;
    // A sticker renders BORDERLESS (no bubble background), like every messenger.
    if (att != null && att.kind == 'sticker' && message.body.isEmpty) {
      return Align(
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
      );
    }
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
    );
  }
}
