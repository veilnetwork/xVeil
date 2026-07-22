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
import '../../state/notifications.dart' show activeConversationProvider;
import 'space_post_reactions.dart';

class SpacePostsScreen extends ConsumerStatefulWidget {
  const SpacePostsScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  @override
  ConsumerState<SpacePostsScreen> createState() => _SpacePostsScreenState();
}

class _SpacePostsScreenState extends ConsumerState<SpacePostsScreen> {
  StateController<String?>? _activeConversation;

  String get _conversationKey => 'space:${widget.spaceIdHex}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activeConversation = ref.read(activeConversationProvider.notifier);
      _activeConversation!.state = _conversationKey;
    });
  }

  @override
  void dispose() {
    if (_activeConversation?.state == _conversationKey) {
      _activeConversation!.state = null;
    }
    super.dispose();
  }

  Future<void> _compose(
    BuildContext context,
    WidgetRef ref,
    NodeId spaceId,
  ) async {
    final l = AppL10n.of(context);
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    final saved = await service.spacePostDraft(spaceId);
    if (!context.mounted) return;
    final draft = await showDialog<_PostComposerValue>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PostComposerDialog(
        initialTitle: saved?.title ?? '',
        initialBody: saved?.body ?? '',
        initialType: saved?.type ?? SpacePostType.post,
        onSaveDraft: (title, body, type) => service.saveSpacePostDraft(
          spaceId,
          title: title,
          body: body,
          type: type,
        ),
      ),
    );
    if (draft == null || !draft.hasContent) return;
    final post = await service.publishSpacePost(
      spaceId,
      title: draft.title,
      body: draft.body,
      type: draft.type,
    );
    if (post != null) {
      final cleared = await service.clearSpacePostDraft(spaceId);
      if (!cleared && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
      }
    } else if (context.mounted) {
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
    final draft = await showDialog<_PostComposerValue>(
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
          title: draft.title,
          body: draft.body,
          type: draft.type,
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
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    final NodeId spaceId;
    try {
      spaceId = NodeId.fromHex(widget.spaceIdHex);
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
                        ? Icons.dynamic_feed_outlined
                        : Icons.comments_disabled_outlined,
                  ),
                ),
              ],
            ),
            floatingActionButton: canPublish
                ? FloatingActionButton(
                    heroTag: 'xveil-space-post-${widget.spaceIdHex}',
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

class _PostComposerValue {
  const _PostComposerValue(this.title, this.body, this.type);

  final String title;
  final String body;
  final SpacePostType type;

  bool get hasContent => title.trim().isNotEmpty || body.trim().isNotEmpty;
}

class _PostComposerDialog extends StatefulWidget {
  const _PostComposerDialog({
    this.initialTitle = '',
    this.initialBody = '',
    this.initialType = SpacePostType.post,
    this.editing = false,
    this.onSaveDraft,
  });

  final String initialTitle;
  final String initialBody;
  final SpacePostType initialType;
  final bool editing;
  final Future<bool> Function(String title, String body, SpacePostType type)?
  onSaveDraft;

  @override
  State<_PostComposerDialog> createState() => _PostComposerDialogState();
}

class _PostComposerDialogState extends State<_PostComposerDialog> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late SpacePostType _type;
  Timer? _draftTimer;
  bool _draftSettled = false;
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle);
    _body = TextEditingController(text: widget.initialBody);
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (!widget.editing && !_draftSettled && widget.onSaveDraft != null) {
      final value = _value;
      unawaited(widget.onSaveDraft!(value.title, value.body, value.type));
    }
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  _PostComposerValue get _value =>
      _PostComposerValue(_title.text, _body.text, _type);

  void _scheduleDraft() {
    if (widget.editing || widget.onSaveDraft == null) {
      setState(() {});
      return;
    }
    setState(() => _saveFailed = false);
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 450), () async {
      final value = _value;
      final saved = await widget.onSaveDraft!(
        value.title,
        value.body,
        value.type,
      );
      if (mounted && !saved) setState(() => _saveFailed = true);
    });
  }

  Future<void> _finish({required bool publish}) async {
    if (_saving) return;
    final value = _value;
    if (publish && !value.hasContent) return;
    _draftTimer?.cancel();
    if (!widget.editing && widget.onSaveDraft != null) {
      setState(() => _saving = true);
      final saved = await widget.onSaveDraft!(
        value.title,
        value.body,
        value.type,
      );
      if (!mounted) return;
      if (!saved) {
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
        return;
      }
      _draftSettled = true;
    }
    if (mounted) Navigator.of(context).pop(publish ? value : null);
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
              onChanged: (_) => _scheduleDraft(),
              decoration: InputDecoration(hintText: l.spacePostTitleHint),
            ),
            TextField(
              key: const ValueKey('space-post-body-field'),
              controller: _body,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              maxLength: kSpacePostBodyMax,
              onChanged: (_) => _scheduleDraft(),
              decoration: InputDecoration(
                hintText: l.spacePostBodyHint,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SpacePostType>(
              key: const ValueKey('space-post-type-field'),
              initialValue: _type,
              items: [
                for (final type in SpacePostType.values)
                  DropdownMenuItem(
                    value: type,
                    child: Text(_postTypeLabel(l, type)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  _type = value;
                  _scheduleDraft();
                }
              },
            ),
            if (!widget.editing) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.lock_outline, size: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _saveFailed
                          ? l.spaceOperationFailed
                          : l.spacePostDraftHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _saveFailed
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => _finish(publish: false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          key: ValueKey(
            widget.editing ? 'space-post-save-edit' : 'space-post-publish',
          ),
          onPressed: _saving || !_value.hasContent
              ? null
              : () => _finish(publish: true),
          child: Text(widget.editing ? l.actionSave : l.spacePostPublish),
        ),
      ],
    );
  }
}

String _postTypeLabel(AppL10n l, SpacePostType type) => switch (type) {
  SpacePostType.post => l.spacePostTypePost,
  SpacePostType.article => l.spacePostTypeArticle,
  SpacePostType.video => l.spacePostTypeVideo,
  SpacePostType.shortVideo => l.spacePostTypeShortVideo,
  SpacePostType.audio => l.spacePostTypeAudio,
  SpacePostType.voiceMessage => l.spacePostTypeVoiceMessage,
};
