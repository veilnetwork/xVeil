// Shared group-chat tile (nav redesign NAV1): the chats list inlines group
// chats next to 1:1 conversations, so the tile — avatar, name, last-message
// preview, mute glyph, unread badge, long-press mute sheet — lives here and
// is used by both the chats list and any group-only surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';

class GroupTile extends ConsumerWidget {
  const GroupTile({super.key, required this.entry});

  final GroupListEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = entry;
    final scheme = Theme.of(context).colorScheme;
    final svc = ref.read(groupServiceProvider);
    return ListTile(
      leading: CircleAvatar(
        child: Text(
          g.name.isEmpty ? '#' : g.name.characters.first.toUpperCase(),
        ),
      ),
      title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        g.preview.isEmpty ? g.groupId.short : g.preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Group marker — distinguishes a group row inside the mixed chats
          // list without inventing a second visual language.
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(
              Icons.group_outlined,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (g.muted)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.volume_off,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (g.unread > 0)
            CircleAvatar(
              radius: 12,
              backgroundColor: g.muted
                  ? scheme.surfaceContainerHighest
                  : scheme.primary,
              child: Text(
                g.unread > 999 ? '999+' : '${g.unread}',
                style: TextStyle(
                  fontSize: 11,
                  color: g.muted ? scheme.onSurfaceVariant : scheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
      onTap: () => context.push('/group/${g.groupId.hex}'),
      onLongPress: svc == null
          ? null
          : () async {
              final l10n = AppL10n.of(context);
              final muted = g.muted;
              await showModalBottomSheet<void>(
                context: context,
                builder: (sheet) => SafeArea(
                  child: ListTile(
                    leading: Icon(
                      muted
                          ? Icons.volume_up_outlined
                          : Icons.volume_off_outlined,
                    ),
                    title: Text(muted ? l10n.chatMenuUnmute : l10n.chatMenuMute),
                    onTap: () {
                      Navigator.of(sheet).pop();
                      svc.setGroupMuted(g.groupId, !muted);
                    },
                  ),
                ),
              );
            },
    );
  }
}

/// The create-group dialog, shared by the drawer menu item (and any future
/// surface). Navigates into the fresh group on success.
Future<void> showCreateGroupDialog(BuildContext context, WidgetRef ref) async {
  final l = AppL10n.of(context);
  final ctrl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.groupCreateTitle),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: l.groupNameHint),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
          child: Text(l.groupCreateAction),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  final svc = ref.read(groupServiceProvider);
  if (svc == null) return;
  try {
    final gid = await svc.createGroup(name);
    if (context.mounted) context.push('/group/${gid.hex}');
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.groupOperationFailed)),
      );
    }
  }
}
