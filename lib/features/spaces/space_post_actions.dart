import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../domain/group_message.dart';
import '../../domain/space_abuse_report.dart';
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

Future<bool> confirmAndDeleteOwnSpacePostComment(
  BuildContext context,
  GroupService service,
  NodeId spaceId,
  SpacePostCommentView comment,
) async {
  final l = AppL10n.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.spacePostCommentDeleteTitle),
      content: Text(l.spacePostCommentDeleteBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-post-comment-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l.spacePostCommentDelete),
        ),
      ],
    ),
  );
  if (confirmed != true || comment.spacePostId == null) return false;
  final deleted = await service.deleteSpacePostComment(
    spaceId,
    comment.spacePostId!,
    comment.ref,
  );
  if (!deleted && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
  }
  return deleted;
}

Future<bool> promptAndModerateDeleteSpacePostComment(
  BuildContext context,
  GroupService service,
  NodeId spaceId,
  SpacePostCommentView comment,
) async {
  final l = AppL10n.of(context);
  var reasonDraft = '';
  final reason = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.spaceModerationDeleteComment),
      content: TextField(
        key: const ValueKey('space-post-comment-moderation-reason'),
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
          key: const ValueKey('space-post-comment-moderation-confirm'),
          onPressed: () {
            final value = reasonDraft.trim();
            if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
          },
          child: Text(l.spaceModerationDeleteComment),
        ),
      ],
    ),
  );
  if (reason == null) return false;
  final actionId = await service.moderateSpace(
    spaceId,
    kind: SpaceModerationKind.deleteMessage,
    target: comment.author,
    scope: SpaceModerationScope.posts,
    reason: reason,
    reference: SpaceModerationReference(
      kind: SpaceModerationReferenceKind.spacePostComment,
      author: comment.author,
      seq: comment.root.seq,
    ),
  );
  if (actionId == null && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
  }
  return actionId != null;
}

Future<bool> confirmAndBlockSpaceAuthor(
  BuildContext context,
  NodeId author,
  Future<void> Function(NodeId author) block,
) async {
  final l = AppL10n.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l.spacePostCommentBlockAuthorTitle),
      content: Text(l.spacePostCommentBlockAuthorBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: const ValueKey('space-post-comment-block-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l.spacePostCommentBlockAuthor),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    await block(author);
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
    return false;
  }
}

Future<bool> promptAndReportSpaceContent(
  BuildContext context,
  GroupService service,
  NodeId spaceId, {
  required String postId,
  String? commentRef,
}) async {
  final l = AppL10n.of(context);
  var category = SpaceAbuseCategory.spam;
  var detailsDraft = '';
  final result =
      await showDialog<({SpaceAbuseCategory category, String details})>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l.spaceAbuseReportDialogTitle),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<SpaceAbuseCategory>(
                    key: const ValueKey('space-abuse-report-category'),
                    initialValue: category,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l.spaceAbuseReportCategory,
                    ),
                    items: [
                      for (final value in SpaceAbuseCategory.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_spaceAbuseCategoryLabel(l, value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => category = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('space-abuse-report-details'),
                    minLines: 2,
                    maxLines: 6,
                    maxLength: kSpaceAbuseReportDetailsMaxBytes,
                    decoration: InputDecoration(
                      labelText: l.spaceAbuseReportDetails,
                      helperText: category == SpaceAbuseCategory.other
                          ? l.spaceAbuseReportDetailsRequired
                          : null,
                      alignLabelWithHint: true,
                    ),
                    onChanged: (value) {
                      detailsDraft = value;
                      if (category == SpaceAbuseCategory.other) {
                        setDialogState(() {});
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(l.actionCancel),
              ),
              FilledButton(
                key: const ValueKey('space-abuse-report-submit'),
                onPressed:
                    category == SpaceAbuseCategory.other &&
                        detailsDraft.trim().isEmpty
                    ? null
                    : () => Navigator.of(
                        dialogContext,
                      ).pop((category: category, details: detailsDraft.trim())),
                child: Text(l.spaceAbuseReportAction),
              ),
            ],
          ),
        ),
      );
  if (result == null) return false;
  final sent = await service.reportSpaceContent(
    spaceId,
    postId,
    commentRef: commentRef,
    category: result.category,
    details: result.details,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(sent ? l.spaceAbuseReportSent : l.spaceOperationFailed),
      ),
    );
  }
  return sent;
}

String _spaceAbuseCategoryLabel(
  AppL10n l,
  SpaceAbuseCategory category,
) => switch (category) {
  SpaceAbuseCategory.spam => l.spaceAbuseReportCategorySpam,
  SpaceAbuseCategory.harassment => l.spaceAbuseReportCategoryHarassment,
  SpaceAbuseCategory.violence => l.spaceAbuseReportCategoryViolence,
  SpaceAbuseCategory.sexualContent => l.spaceAbuseReportCategorySexualContent,
  SpaceAbuseCategory.illegalContent => l.spaceAbuseReportCategoryIllegalContent,
  SpaceAbuseCategory.misinformation => l.spaceAbuseReportCategoryMisinformation,
  SpaceAbuseCategory.other => l.spaceAbuseReportCategoryOther,
};

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
