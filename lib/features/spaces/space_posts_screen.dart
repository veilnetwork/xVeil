import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/group_policy.dart';
import '../../domain/group_reaction.dart';
import '../../domain/space_moderation.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import 'space_post_reactions.dart';

class SpacePostsScreen extends ConsumerWidget {
  const SpacePostsScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  Future<void> _compose(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
  ) async {
    final l = AppL10n.of(context);
    final draft = await showDialog<(String, String, SpacePostType)>(
      context: context,
      builder: (_) => const _PostComposerDialog(),
    );
    if (draft == null || (draft.$1.isEmpty && draft.$2.isEmpty)) return;
    final post = await ref
        .read(groupServiceProvider)
        ?.publishSpacePost(
          spaceId,
          title: draft.$1,
          body: draft.$2,
          type: draft.$3,
        );
    if (post == null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
  ) async {
    final l = AppL10n.of(context);
    final draft = await showDialog<(String, String, SpacePostType)>(
      context: context,
      builder: (_) => _PostComposerDialog(
        initialTitle: post.title,
        initialBody: post.body,
        initialType: post.type,
        editing: true,
      ),
    );
    if (draft == null) return;
    final updated = await ref
        .read(groupServiceProvider)
        ?.editSpacePost(
          spaceId,
          post.postId,
          title: draft.$1,
          body: draft.$2,
          type: draft.$3,
        );
    if (updated == null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
  ) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.spacePostDeleteTitle),
        content: Text(l.spacePostDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('space-post-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.spacePostDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final deleted =
        await ref
            .read(groupServiceProvider)
            ?.deleteSpacePost(spaceId, post.postId) ??
        false;
    if (!deleted && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
    }
  }

  Future<void> _moderateDelete(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
  ) async {
    final l = AppL10n.of(context);
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.spaceModerationDeletePost),
        content: TextField(
          key: const ValueKey('space-post-moderation-reason'),
          controller: controller,
          autofocus: true,
          maxLength: kSpaceModerationReasonMax,
          decoration: InputDecoration(labelText: l.spaceModerationReason),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
            },
            child: Text(l.spaceModerationDeletePost),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    final actionId = await ref
        .read(groupServiceProvider)
        ?.moderateSpace(
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
  }

  Future<void> _setPinned(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
    SpacePostView post,
    bool pinned,
  ) async {
    final updated =
        await ref
            .read(groupServiceProvider)
            ?.setSpacePostPinned(spaceId, post.postId, pinned) ??
        false;
    if (!updated && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final NodeId spaceId;
    try {
      spaceId = NodeId.fromHex(spaceIdHex);
    } catch (_) {
      return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
    }
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<int>(
      stream: service.changes.stream,
      builder: (context, _) => FutureBuilder<List<Object?>>(
        future: Future.wait<Object?>([
          service.stateOf(spaceId),
          service.postsOf(spaceId),
          service.isSpaceFeedEnabled(spaceId),
          service.spacePostReactionsOf(spaceId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data![0] as GroupState?;
          final posts = snapshot.data![1] as List<SpacePostView>;
          final enabled = snapshot.data![2] as bool;
          final reactions = snapshot.data![3] as Map<String, MessageReactions>;
          if (state == null) {
            return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
          }
          final canPublish = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.publishPosts);
          final canModerate = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.moderate);
          final canManagePosts = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.managePosts);
          final displayPosts = [
            ...posts.where((post) => !post.pinned),
            ...posts.where((post) => post.pinned).toList()..sort(
              (left, right) => (left.pinnedAtMs ?? left.publishedAtMs)
                  .compareTo(right.pinnedAtMs ?? right.publishedAtMs),
            ),
          ];
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(service.markSpaceFeedSeen(spaceId));
          });
          return Scaffold(
            appBar: AppBar(
              title: Text(l.spacePostsTitle),
              actions: [
                IconButton(
                  tooltip: enabled ? l.spaceFeedDisable : l.spaceFeedEnable,
                  onPressed: () =>
                      service.setSpaceFeedEnabled(spaceId, !enabled),
                  icon: Icon(
                    enabled
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                  ),
                ),
              ],
            ),
            floatingActionButton: canPublish
                ? FloatingActionButton(
                    heroTag: 'xveil-space-post-$spaceIdHex',
                    tooltip: l.spacePostCreateTitle,
                    onPressed: () => _compose(context, ref, spaceId),
                    child: const Icon(Icons.edit_outlined),
                  )
                : null,
            body: posts.isEmpty
                ? Center(child: Text(l.spacePostsEmpty))
                : ListView.separated(
                    reverse: true,
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    itemCount: displayPosts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final post = displayPosts[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        title: post.title.isEmpty ? null : Text(post.title),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (post.pinned)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.push_pin, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      l.spacePostPinned,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                              ),
                            if (post.body.isNotEmpty) Text(post.body),
                            if (post.edited)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  l.spacePostEdited,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            const SizedBox(height: 6),
                            SpacePostReactionBar(
                              postId: post.postId,
                              reactions: reactions[post.postId] ?? const {},
                              selfId: service.selfId,
                              onReact: (emoji) => service.reactToSpacePost(
                                spaceId,
                                post.postId,
                                emoji,
                              ),
                            ),
                          ],
                        ),
                        leading: Icon(
                          post.type == SpacePostType.article
                              ? Icons.article_outlined
                              : Icons.campaign_outlined,
                        ),
                        trailing:
                            post.author == service.selfId ||
                                canModerate ||
                                canManagePosts
                            ? PopupMenuButton<_PostAction>(
                                key: ValueKey('space-post-menu-${post.postId}'),
                                onSelected: (action) {
                                  switch (action) {
                                    case _PostAction.edit:
                                      unawaited(
                                        _edit(context, ref, spaceId, post),
                                      );
                                    case _PostAction.delete:
                                      unawaited(
                                        _delete(context, ref, spaceId, post),
                                      );
                                    case _PostAction.moderateDelete:
                                      unawaited(
                                        _moderateDelete(
                                          context,
                                          ref,
                                          spaceId,
                                          post,
                                        ),
                                      );
                                    case _PostAction.pin:
                                      unawaited(
                                        _setPinned(
                                          context,
                                          ref,
                                          spaceId,
                                          post,
                                          true,
                                        ),
                                      );
                                    case _PostAction.unpin:
                                      unawaited(
                                        _setPinned(
                                          context,
                                          ref,
                                          spaceId,
                                          post,
                                          false,
                                        ),
                                      );
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (canManagePosts)
                                    PopupMenuItem(
                                      value: post.pinned
                                          ? _PostAction.unpin
                                          : _PostAction.pin,
                                      child: Text(
                                        post.pinned
                                            ? l.spacePostUnpin
                                            : l.spacePostPin,
                                      ),
                                    ),
                                  if (post.author == service.selfId) ...[
                                    PopupMenuItem(
                                      value: _PostAction.edit,
                                      child: Text(l.spacePostEdit),
                                    ),
                                    PopupMenuItem(
                                      value: _PostAction.delete,
                                      child: Text(l.spacePostDelete),
                                    ),
                                  ] else if (canModerate)
                                    PopupMenuItem(
                                      value: _PostAction.moderateDelete,
                                      child: Text(l.spaceModerationDeletePost),
                                    ),
                                ],
                              )
                            : null,
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}

enum _PostAction { pin, unpin, edit, delete, moderateDelete }

class _PostComposerDialog extends StatefulWidget {
  const _PostComposerDialog({
    this.initialTitle = '',
    this.initialBody = '',
    this.initialType = SpacePostType.post,
    this.editing = false,
  });

  final String initialTitle;
  final String initialBody;
  final SpacePostType initialType;
  final bool editing;

  @override
  State<_PostComposerDialog> createState() => _PostComposerDialogState();
}

class _PostComposerDialogState extends State<_PostComposerDialog> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late SpacePostType _type;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _body = TextEditingController(text: widget.initialBody);
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      title: Text(widget.editing ? l.spacePostEdit : l.spacePostCreateTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('space-post-title-field'),
              controller: _title,
              maxLength: kSpacePostTitleMax,
              decoration: InputDecoration(hintText: l.spacePostTitleHint),
            ),
            TextField(
              key: const ValueKey('space-post-body-field'),
              controller: _body,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              decoration: InputDecoration(hintText: l.spacePostBodyHint),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SpacePostType>(
              initialValue: _type,
              items: [
                DropdownMenuItem(
                  value: SpacePostType.post,
                  child: Text(l.spacePostTypePost),
                ),
                DropdownMenuItem(
                  value: SpacePostType.article,
                  child: Text(l.spacePostTypeArticle),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _type = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: ValueKey(
            widget.editing ? 'space-post-save-edit' : 'space-post-publish',
          ),
          onPressed: () => Navigator.of(
            context,
          ).pop((_title.text.trim(), _body.text.trim(), _type)),
          child: Text(widget.editing ? l.actionSave : l.spacePostPublish),
        ),
      ],
    );
  }
}
