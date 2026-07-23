import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../domain/space_moderation.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service.dart';

Future<bool> confirmAndDeleteOwnSpacePost(
  BuildContext context,
  GroupService service,
  NodeId spaceId,
  SpacePostView post,
) async {
  final l = AppL10n.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.spacePostDeleteTitle),
      content: Text(l.spacePostDeleteBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-post-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l.spacePostDelete),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  final deleted = await service.deleteSpacePost(spaceId, post.postId);
  if (!deleted && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
  }
  return deleted;
}

Future<bool> promptAndModerateDeleteSpacePost(
  BuildContext context,
  GroupService service,
  NodeId spaceId,
  SpacePostView post,
) async {
  final l = AppL10n.of(context);
  var reasonDraft = '';
  final reason = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.spaceModerationDeletePost),
      content: TextField(
        key: const ValueKey('space-post-moderation-reason'),
        autofocus: true,
        maxLength: kSpaceModerationReasonMax,
        decoration: InputDecoration(labelText: l.spaceModerationReason),
        onChanged: (value) => reasonDraft = value,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-post-moderation-confirm'),
          onPressed: () {
            final value = reasonDraft.trim();
            if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
          },
          child: Text(l.spaceModerationDeletePost),
        ),
      ],
    ),
  );
  if (reason == null) return false;
  final actionId = await service.moderateSpace(
    spaceId,
    kind: SpaceModerationKind.deletePost,
    target: post.author,
    scope: SpaceModerationScope.posts,
    reason: reason,
    reference: SpaceModerationReference(
      kind: SpaceModerationReferenceKind.spacePost,
      author: post.author,
      seq: post.seq,
    ),
  );
  if (actionId == null && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
  }
  return actionId != null;
}

Future<bool> updateSpacePostPinned(
  BuildContext context,
  GroupService service,
  NodeId spaceId,
  SpacePostView post,
  bool pinned,
) async {
  final updated = await service.setSpacePostPinned(
    spaceId,
    post.postId,
    pinned,
  );
  if (!updated && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
    );
  }
  return updated;
}
