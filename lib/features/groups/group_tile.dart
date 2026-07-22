// Shared group-chat tile. Group chats are shown beside 1:1 conversations in
// Chats, while Spaces have their own Communities surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/chat.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../chat/chat_actions.dart';

class GroupTile extends ConsumerWidget {
  const GroupTile({super.key, required this.entry});

  final GroupListEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = entry;
    final scheme = Theme.of(context).colorScheme;
    final service = ref.read(groupServiceProvider);
    final notificationMode = group.notificationMode;
    final notificationPolicy = NotificationMutePolicy(
      mode: notificationMode,
      until: group.notificationUntil,
    );
    return ListTile(
      leading: CircleAvatar(
        child: Text(
          group.name.isEmpty ? '#' : group.name.characters.first.toUpperCase(),
        ),
      ),
      title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        group.preview.isEmpty ? group.groupId.short : group.preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(
              Icons.group_outlined,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (notificationMode != NotificationMuteMode.all)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: notificationMuteModeIndicator(
                context,
                notificationMode,
                key: ValueKey(
                  'group-notification-${notificationMode.name}-${group.groupId.hex}',
                ),
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (group.unread > 0)
            CircleAvatar(
              radius: 12,
              backgroundColor: group.muted
                  ? scheme.surfaceContainerHighest
                  : scheme.primary,
              child: Text(
                group.unread > 999 ? '999+' : '${group.unread}',
                style: TextStyle(
                  fontSize: 11,
                  color: group.muted
                      ? scheme.onSurfaceVariant
                      : scheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
      onTap: () => context.push('/group/${group.groupId.hex}'),
      onLongPress: service == null
          ? null
          : () => showNotificationPolicySheet(
              context,
              notificationPolicy,
              onChanged: (mode, until) => service.setGroupNotificationPolicy(
                group.groupId,
                mode,
                until,
              ),
            ),
    );
  }
}

/// Creates a group chat and opens its group-wide conversation.
Future<void> showCreateGroupDialog(
  BuildContext context,
  GroupService? service, {
  VoidCallback? onCreated,
}) async {
  final l = AppL10n.of(context);
  if (service == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.groupOperationFailed)));
    return;
  }
  var draft = '';
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.groupCreateTitle),
      content: TextField(
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(hintText: l.groupNameHint),
        onChanged: (value) => draft = value,
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(draft.trim()),
          child: Text(l.groupCreateAction),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  try {
    final groupId = await service.createGroup(name);
    onCreated?.call();
    if (context.mounted) context.push('/group/${groupId.hex}');
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.groupOperationFailed)));
    }
  }
}
