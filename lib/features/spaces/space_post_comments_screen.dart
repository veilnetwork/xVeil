import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/group.dart';
import '../../domain/group_message.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show messagingServiceProvider;
import '../../state/notifications.dart' show activeConversationProvider;
import '../chat/custom_emoji_controller.dart';
import '../chat/mention_composer.dart';
import '../chat/message_markdown.dart';
import '../chat/message_mentions.dart';
import 'space_post_body.dart';
import 'space_post_actions.dart';
import 'space_post_media.dart';

/// Member discussion for one Space publication. Comments share the signed,
/// encrypted and P2P-replicated message log, but this dedicated projection is
/// deliberately outside channel history and the Chats navigation surface.
class SpacePostCommentsScreen extends ConsumerStatefulWidget {
  const SpacePostCommentsScreen({
    super.key,
    required this.spaceIdHex,
    required this.postId,
    this.initialCommentRef,
    this.mediaPicker,
  });

  final String spaceIdHex;
  final String postId;
  final String? initialCommentRef;
  final Future<SpacePostMediaPickResult> Function(int remaining)? mediaPicker;

  @override
  ConsumerState<SpacePostCommentsScreen> createState() =>
      _SpacePostCommentsScreenState();
}

class _SpacePostCommentsScreenState
    extends ConsumerState<SpacePostCommentsScreen> {
  final CustomEmojiEditingController _composer = CustomEmojiEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final GlobalKey _initialCommentKey = GlobalKey();
  Timer? _highlightTimer;
  bool _initialJumpScheduled = false;
  String? _highlightCommentRef;

  GroupService? _boundService;
  NodeId? _boundSpaceId;
  Future<_CommentsProjection>? _projection;
  SpacePostCommentView? _replyTo;
  SpacePostCommentView? _editing;
  MediaObject? _media;
  String? _composerBeforeEdit;
  SpacePostCommentView? _replyBeforeEdit;
  MediaObject? _mediaBeforeEdit;
  bool _sending = false;
  bool _publiclyVisible = false;
  bool _followAfterLoad = true;
  int _renderedCommentCount = -1;
  StateController<String?>? _activeConversation;
  String? _previousActiveConversation;

  String get _conversationKey =>
      'space-comment:${widget.spaceIdHex}:${widget.postId}';

  @override
  void initState() {
    super.initState();
    _followAfterLoad = widget.initialCommentRef == null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activeConversation = ref.read(activeConversationProvider.notifier);
      _previousActiveConversation = _activeConversation!.state;
      _activeConversation!.state = _conversationKey;
    });
  }

  @override
  void dispose() {
    final activeConversation = _activeConversation;
    final previousActiveConversation = _previousActiveConversation;
    final conversationKey = _conversationKey;
    if (activeConversation?.state == conversationKey) {
      // Riverpod forbids provider mutations while Flutter finalizes a route's
      // widget tree. Restore the parent Space key after this synchronous frame.
      scheduleMicrotask(() {
        try {
          if (activeConversation!.state == conversationKey) {
            activeConversation.state = previousActiveConversation;
          }
        } catch (_) {
          // The ProviderScope may already be gone during test/app teardown.
        }
      });
    }
    _boundService?.changes.removeListener(_onServiceChanged);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _bind(GroupService service, NodeId spaceId) {
    if (identical(service, _boundService) &&
        spaceId.hex == _boundSpaceId?.hex) {
      return;
    }
    _boundService?.changes.removeListener(_onServiceChanged);
    _boundService = service;
    _boundSpaceId = spaceId;
    service.changes.addListener(_onServiceChanged);
    _projection = _load(service, spaceId);
    _renderedCommentCount = -1;
    _followAfterLoad = widget.initialCommentRef == null;
  }

  Future<_CommentsProjection> _load(
    GroupService service,
    NodeId spaceId,
  ) async {
    final results = await Future.wait<Object?>([
      service.stateOf(spaceId),
      service.postsOf(spaceId),
      service.publicSpacePostCommentRefs(spaceId, widget.postId),
    ]);
    final state = results[0] as GroupState?;
    final posts = results[1] as List<SpacePostView>;
    final post = posts
        .where((item) => item.postId == widget.postId)
        .firstOrNull;
    final comments = post == null
        ? const <SpacePostCommentView>[]
        : await service.spacePostCommentsOf(spaceId, widget.postId);
    return _CommentsProjection(
      state: state,
      post: post,
      comments: comments,
      publicCommentRefs: results[2] as Set<String>,
    );
  }

  bool get _nearTail =>
      !_scroll.hasClients ||
      _scroll.position.maxScrollExtent - _scroll.position.pixels < 160;

  void _scheduleInitialComment(List<SpacePostCommentView> comments) {
    final target = widget.initialCommentRef;
    if (_initialJumpScheduled || target == null) return;
    final index = comments.indexWhere((comment) => comment.ref == target);
    if (index < 0) return;
    _initialJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final fraction = comments.length <= 1 ? 1.0 : index / comments.length;
      _scroll.jumpTo(_scroll.position.maxScrollExtent * fraction);
      Future<void>.delayed(const Duration(milliseconds: 80), () async {
        if (!mounted) return;
        final targetContext = _initialCommentKey.currentContext;
        if (targetContext != null && targetContext.mounted) {
          await Scrollable.ensureVisible(
            targetContext,
            alignment: 0.45,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        }
        if (!mounted) return;
        setState(() => _highlightCommentRef = target);
        _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
          if (mounted) setState(() => _highlightCommentRef = null);
        });
      });
    });
  }

  void _onServiceChanged() {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    if (!mounted || service == null || spaceId == null) return;
    final follow = _nearTail;
    setState(() {
      _followAfterLoad = follow;
      _projection = _load(service, spaceId);
    });
  }

  Future<void> _refresh() async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    if (service == null || spaceId == null) return;
    await service.nudgeGroupSync(spaceId);
    if (!mounted) return;
    final next = _load(service, spaceId);
    setState(() => _projection = next);
    await next;
  }

  String get _composerWireBody => _composer.toWireValue().body;

  bool get _tooLong =>
      utf8.encode(_composerWireBody).length > kSpacePostCommentMaxBytes;

  bool get _canSend =>
      !_sending &&
      (_editing == null
          ? _composerWireBody.isNotEmpty || _media != null
          : (_composerWireBody.isNotEmpty || _editing!.attachment != null) &&
                _composerWireBody != _editing!.body) &&
      !_tooLong;

  Future<void> _pickMedia() async {
    if (_sending || _media != null) return;
    final SpacePostMediaPickResult result;
    try {
      result =
          await (widget.mediaPicker?.call(1) ??
              pickAndRegisterSpacePostMedia(ref, remaining: 1));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
      return;
    }
    if (!mounted) return;
    final picked = result.media.firstOrNull;
    setState(() {
      if (picked != null) _media = picked;
    });
    if (result.rejected > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spacePostMediaRejected)),
      );
    }
  }

  Future<void> _send() async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    final body = _composerWireBody;
    if (service == null || spaceId == null || !_canSend) return;
    setState(() => _sending = true);
    final editing = _editing;
    final sent = editing == null
        ? await service.commentOnSpacePost(
            spaceId,
            widget.postId,
            body,
            replyTo: _replyTo?.ref,
            media: _media,
            publiclyVisible: _publiclyVisible,
          )
        : await service.editSpacePostComment(
            spaceId,
            widget.postId,
            editing.ref,
            body,
          );
    if (!mounted) return;
    if (sent) {
      if (editing == null) {
        _composer.clearWithCustomEmoji();
        _replyTo = null;
        _media = null;
        _publiclyVisible = false;
      } else {
        _restoreComposerAfterEdit();
      }
      _followAfterLoad = true;
      _projection = _load(service, spaceId);
    }
    setState(() => _sending = false);
    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            editing == null
                ? AppL10n.of(context).spacePostCommentFailed
                : AppL10n.of(context).spacePostCommentEditFailed,
          ),
        ),
      );
    }
  }

  void _reply(SpacePostCommentView comment, Set<String> publicCommentRefs) {
    setState(() {
      if (_editing != null) _restoreComposerAfterEdit();
      _replyTo = comment;
      if (!publicCommentRefs.contains(comment.ref)) {
        _publiclyVisible = false;
      }
    });
    _composerFocus.requestFocus();
  }

  void _edit(SpacePostCommentView comment) {
    setState(() {
      if (_editing == null) {
        _composerBeforeEdit = _composerWireBody;
        _replyBeforeEdit = _replyTo;
        _mediaBeforeEdit = _media;
      }
      _replyTo = null;
      _media = null;
      _editing = comment;
      _composer.loadWireValue(comment.body, const []);
    });
    _composerFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(_restoreComposerAfterEdit);
  }

  Future<void> _deleteComment(SpacePostCommentView comment) async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    if (_sending || service == null || spaceId == null) return;
    final deleted = await confirmAndDeleteOwnSpacePostComment(
      context,
      service,
      spaceId,
      comment,
    );
    if (!mounted || !deleted) return;
    if (_editing?.ref == comment.ref) _restoreComposerAfterEdit();
    setState(() {
      _projection = _load(service, spaceId);
    });
  }

  Future<void> _moderateComment(SpacePostCommentView comment) async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    if (_sending || service == null || spaceId == null) return;
    final moderated = await promptAndModerateDeleteSpacePostComment(
      context,
      service,
      spaceId,
      comment,
    );
    if (!mounted || !moderated) return;
    setState(() {
      _projection = _load(service, spaceId);
    });
  }

  Future<void> _blockCommentAuthor(SpacePostCommentView comment) async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    if (_sending || service == null || spaceId == null) return;
    final blocked = await confirmAndBlockSpaceAuthor(
      context,
      comment.author,
      ref.read(messagingServiceProvider).blockContact,
    );
    if (!mounted || !blocked) return;
    setState(() {
      _projection = _load(service, spaceId);
    });
  }

  Future<void> _reportComment(SpacePostCommentView comment) async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    if (_sending || service == null || spaceId == null) return;
    await promptAndReportSpaceContent(
      context,
      service,
      spaceId,
      postId: widget.postId,
      commentRef: comment.ref,
    );
  }

  void _restoreComposerAfterEdit() {
    _editing = null;
    _composer.loadWireValue(_composerBeforeEdit ?? '', const []);
    _replyTo = _replyBeforeEdit;
    _media = _mediaBeforeEdit;
    _composerBeforeEdit = null;
    _replyBeforeEdit = null;
    _mediaBeforeEdit = null;
  }

  void _goBack() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/space/${widget.spaceIdHex}/posts');
  }

  void _scheduleTail(int commentCount) {
    final firstProjection = _renderedCommentCount < 0;
    final grew = commentCount > _renderedCommentCount;
    _renderedCommentCount = commentCount;
    if (firstProjection && widget.initialCommentRef != null) return;
    if (!firstProjection && !(grew && _followAfterLoad)) return;
    _followAfterLoad = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
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
    _bind(service, spaceId);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          key: const ValueKey('space-post-comments-back'),
          onPressed: _goBack,
        ),
        title: Text(l.spacePostCommentsTitle),
      ),
      body: FutureBuilder<_CommentsProjection>(
        future: _projection,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final projection = snapshot.data!;
          final state = projection.state;
          final post = projection.post;
          if (state == null || post == null) {
            return Center(child: Text(l.spaceOperationFailed));
          }
          final comments = projection.comments;
          _scheduleInitialComment(comments);
          _scheduleTail(comments.length);
          final byRef = {for (final comment in comments) comment.ref: comment};
          final canWrite = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.publishMessages);
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                children: [
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        key: const PageStorageKey('space-post-comments-list'),
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                        itemCount: comments.isEmpty ? 2 : comments.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return _PublicationHeader(
                              spaceId: spaceId,
                              post: post,
                              commentCount: comments.length,
                            );
                          }
                          if (comments.isEmpty) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 44),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.forum_outlined,
                                    size: 42,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(l.spacePostCommentsEmpty),
                                  const SizedBox(height: 4),
                                  Text(
                                    l.spacePostCommentsEmptyHint,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            );
                          }
                          final comment = comments[index - 1];
                          final isSelf = comment.author == service.selfId;
                          final canModerate =
                              !isSelf &&
                              SpaceAcl(state).allowsControl(
                                service.selfId,
                                ControlOp.moderate,
                                target: comment.author,
                                moderationTargetsRemovedContent: true,
                              );
                          return AnimatedContainer(
                            key: comment.ref == widget.initialCommentRef
                                ? _initialCommentKey
                                : null,
                            duration: const Duration(milliseconds: 400),
                            color: comment.ref == _highlightCommentRef
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.14)
                                : Colors.transparent,
                            child: _CommentBubble(
                              key: ValueKey(
                                'space-post-comment-${comment.ref}',
                              ),
                              spaceId: spaceId,
                              comment: comment,
                              repliedComment: byRef[comment.replyTo],
                              isSelf: isSelf,
                              onReply: canWrite
                                  ? () => _reply(
                                      comment,
                                      projection.publicCommentRefs,
                                    )
                                  : null,
                              onEdit: canWrite && isSelf
                                  ? () => _edit(comment)
                                  : null,
                              onDelete: isSelf
                                  ? () => _deleteComment(comment)
                                  : null,
                              onModerate: canModerate
                                  ? () => _moderateComment(comment)
                                  : null,
                              onBlock: !isSelf
                                  ? () => _blockCommentAuthor(comment)
                                  : null,
                              onReport: !isSelf
                                  ? () => _reportComment(comment)
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  if (canWrite)
                    _Composer(
                      controller: _composer,
                      focusNode: _composerFocus,
                      replyTo: _replyTo,
                      editing: _editing,
                      media: _media,
                      sending: _sending,
                      canSend: _canSend,
                      tooLong: _tooLong,
                      mentionTargets: state.members.values
                          .map((member) => member.nodeId)
                          .toList(growable: false),
                      allowPublic:
                          post.visibility == SpacePostVisibility.public &&
                          _editing == null &&
                          (_replyTo == null ||
                              projection.publicCommentRefs.contains(
                                _replyTo!.ref,
                              )),
                      publiclyVisible: _publiclyVisible,
                      onPublicChanged: (value) =>
                          setState(() => _publiclyVisible = value),
                      onChanged: () => setState(() {}),
                      onCancelReply: () => setState(() => _replyTo = null),
                      onCancelEdit: _cancelEdit,
                      onPickMedia: _pickMedia,
                      onRemoveMedia: () => setState(() => _media = null),
                      onSend: _send,
                    )
                  else
                    Material(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.lock_outline, size: 18),
                              const SizedBox(width: 8),
                              Flexible(child: Text(l.spacePostCommentReadOnly)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CommentsProjection {
  const _CommentsProjection({
    required this.state,
    required this.post,
    required this.comments,
    required this.publicCommentRefs,
  });

  final GroupState? state;
  final SpacePostView? post;
  final List<SpacePostCommentView> comments;
  final Set<String> publicCommentRefs;
}

class _PublicationHeader extends StatelessWidget {
  const _PublicationHeader({
    required this.spaceId,
    required this.post,
    required this.commentCount,
  });

  final NodeId spaceId;
  final SpacePostView post;
  final int commentCount;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (post.title.isNotEmpty)
              Text(post.title, style: Theme.of(context).textTheme.titleLarge),
            if (post.title.isNotEmpty && post.body.isNotEmpty)
              const SizedBox(height: 8),
            if (post.body.isNotEmpty) SpacePostBody(post.body),
            SpacePostMediaList(spaceId: spaceId, post: post),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.forum_outlined, size: 17),
                const SizedBox(width: 6),
                Text(
                  l.spacePostCommentsCount(commentCount),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentBubble extends StatelessWidget {
  const _CommentBubble({
    super.key,
    required this.spaceId,
    required this.comment,
    required this.repliedComment,
    required this.isSelf,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
    required this.onModerate,
    required this.onBlock,
    required this.onReport,
  });

  final NodeId spaceId;
  final SpacePostCommentView comment;
  final SpacePostCommentView? repliedComment;
  final bool isSelf;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onModerate;
  final VoidCallback? onBlock;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final colors = Theme.of(context).colorScheme;
    final author = isSelf ? l.chatYou : comment.author.short;
    final semanticBody = comment.body.isNotEmpty
        ? messageMentionsFallbackText(comment.body)
        : comment.attachment?.name ?? comment.attachment?.kind ?? '';
    return Semantics(
      label: '$author, $semanticBody',
      child: Align(
        alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
          decoration: BoxDecoration(
            color: isSelf
                ? colors.primaryContainer
                : colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(author, style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(width: 8),
                  Text(
                    _commentTime(context, comment.createdAtMs),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (comment.edited) ...[
                    const SizedBox(width: 6),
                    Text(
                      l.spacePostCommentEdited,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              if (comment.replyTo != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.52),
                    borderRadius: BorderRadius.circular(9),
                    border: Border(
                      left: BorderSide(color: colors.primary, width: 3),
                    ),
                  ),
                  child: Text(
                    repliedComment == null
                        ? l.spacePostCommentParentUnavailable
                        : _commentPreview(repliedComment!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              if (comment.body.isNotEmpty) ...[
                const SizedBox(height: 5),
                SelectionArea(child: FormattedText(comment.body)),
              ],
              if (comment.mediaHiddenByRetention)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    children: [
                      const Icon(Icons.hide_image_outlined, size: 17),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          l.spaceRetentionMediaExpired,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              if (comment.attachment != null)
                MediaObjectList(
                  spaceId: spaceId,
                  author: comment.author,
                  media: [comment.attachment!],
                  compact: true,
                ),
              if (onReply != null ||
                  onEdit != null ||
                  onDelete != null ||
                  onModerate != null ||
                  onBlock != null ||
                  onReport != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 4,
                    children: [
                      if (onEdit != null)
                        TextButton.icon(
                          key: ValueKey(
                            'space-post-comment-edit-${comment.ref}',
                          ),
                          onPressed: onEdit,
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(l.spacePostCommentEdit),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (onReply != null)
                        TextButton.icon(
                          key: ValueKey(
                            'space-post-comment-reply-${comment.ref}',
                          ),
                          onPressed: onReply,
                          icon: const Icon(Icons.reply, size: 16),
                          label: Text(l.spacePostCommentReply),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (onDelete != null ||
                          onModerate != null ||
                          onBlock != null ||
                          onReport != null)
                        PopupMenuButton<_CommentMenuAction>(
                          key: ValueKey(
                            'space-post-comment-menu-${comment.ref}',
                          ),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).showMenuTooltip,
                          icon: const Icon(Icons.more_horiz, size: 20),
                          onSelected: (action) {
                            switch (action) {
                              case _CommentMenuAction.delete:
                                onDelete?.call();
                              case _CommentMenuAction.moderate:
                                onModerate?.call();
                              case _CommentMenuAction.block:
                                onBlock?.call();
                              case _CommentMenuAction.report:
                                onReport?.call();
                            }
                          },
                          itemBuilder: (context) => [
                            if (onDelete != null)
                              PopupMenuItem(
                                value: _CommentMenuAction.delete,
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.delete_outline),
                                  title: Text(l.spacePostCommentDelete),
                                ),
                              ),
                            if (onModerate != null)
                              PopupMenuItem(
                                value: _CommentMenuAction.moderate,
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.gavel_outlined),
                                  title: Text(l.spaceModerationDeleteComment),
                                ),
                              ),
                            if (onBlock != null)
                              PopupMenuItem(
                                value: _CommentMenuAction.block,
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.block_outlined),
                                  title: Text(l.spacePostCommentBlockAuthor),
                                ),
                              ),
                            if (onReport != null)
                              PopupMenuItem(
                                value: _CommentMenuAction.report,
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.flag_outlined),
                                  title: Text(l.spaceAbuseReportAction),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _CommentMenuAction { delete, moderate, block, report }

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.replyTo,
    required this.editing,
    required this.media,
    required this.sending,
    required this.canSend,
    required this.tooLong,
    required this.mentionTargets,
    required this.allowPublic,
    required this.publiclyVisible,
    required this.onPublicChanged,
    required this.onChanged,
    required this.onCancelReply,
    required this.onCancelEdit,
    required this.onPickMedia,
    required this.onRemoveMedia,
    required this.onSend,
  });

  final CustomEmojiEditingController controller;
  final FocusNode focusNode;
  final SpacePostCommentView? replyTo;
  final SpacePostCommentView? editing;
  final MediaObject? media;
  final bool sending;
  final bool canSend;
  final bool tooLong;
  final Iterable<NodeId> mentionTargets;
  final bool allowPublic;
  final bool publiclyVisible;
  final ValueChanged<bool> onPublicChanged;
  final VoidCallback onChanged;
  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final VoidCallback onPickMedia;
  final VoidCallback onRemoveMedia;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Material(
      elevation: 3,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (allowPublic)
                SwitchListTile(
                  key: const ValueKey('space-post-comment-public'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: publiclyVisible,
                  secondary: const Icon(Icons.public, size: 20),
                  title: Text(l.spacePostCommentPublic),
                  subtitle: Text(l.spacePostCommentPublicHint),
                  onChanged: sending ? null : onPublicChanged,
                ),
              if (replyTo != null)
                Row(
                  children: [
                    const Icon(Icons.reply, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.spacePostCommentReplyingTo(replyTo!.author.short),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('space-post-comment-cancel-reply'),
                      tooltip: l.spacePostCommentCancelReply,
                      visualDensity: VisualDensity.compact,
                      onPressed: onCancelReply,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              if (editing != null)
                Row(
                  children: [
                    const Icon(Icons.edit_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(l.spacePostCommentEditing)),
                    IconButton(
                      key: const ValueKey('space-post-comment-cancel-edit'),
                      tooltip: l.spacePostCommentCancelEdit,
                      visualDensity: VisualDensity.compact,
                      onPressed: sending ? null : onCancelEdit,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              if (media != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    key: const ValueKey('space-post-comment-media'),
                    avatar: Icon(spacePostMediaIcon(media!.kind), size: 18),
                    label: Text(
                      media!.name ?? media!.kind,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: sending ? null : onRemoveMedia,
                    deleteButtonTooltipMessage: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    key: const ValueKey('space-post-comment-attach'),
                    tooltip: l.spacePostMediaAttach,
                    onPressed: sending || media != null || editing != null
                        ? null
                        : onPickMedia,
                    icon: const Icon(Icons.attach_file),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: MentionComposerRegion(
                      controller: controller,
                      focusNode: focusNode,
                      targets: mentionTargets,
                      onChanged: onChanged,
                      child: TextField(
                        key: const ValueKey('space-post-comment-composer'),
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 6,
                        maxLength: kSpacePostCommentMaxBytes,
                        onChanged: (_) => onChanged(),
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: l.spacePostCommentHint,
                          errorText: tooLong ? l.spacePostCommentTooLong : null,
                          counterText: '',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('space-post-comment-send'),
                    tooltip: editing == null
                        ? l.spacePostCommentSend
                        : l.spacePostCommentSaveEdit,
                    onPressed: canSend ? onSend : null,
                    icon: sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(editing == null ? Icons.send : Icons.check),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _preview(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized.length <= 120
      ? normalized
      : '${normalized.substring(0, 117)}…';
}

String _commentPreview(SpacePostCommentView comment) {
  final body = _preview(messageMentionsFallbackText(comment.body));
  if (body.isNotEmpty) return body;
  return comment.attachment?.name ?? comment.attachment?.kind ?? '';
}

String _commentTime(BuildContext context, int milliseconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  final material = MaterialLocalizations.of(context);
  final now = DateTime.now();
  final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(value));
  if (value.year == now.year &&
      value.month == now.month &&
      value.day == now.day) {
    return time;
  }
  return '${material.formatShortDate(value)} · $time';
}
