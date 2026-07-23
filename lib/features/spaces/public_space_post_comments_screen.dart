import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/space_post.dart';
import '../../domain/space_public_discussion.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/notifications.dart' show activeConversationProvider;
import '../chat/message_markdown.dart';
import '../chat/message_mentions.dart';
import 'space_post_body.dart';
import 'space_post_media.dart';
import 'space_post_reactions.dart';

/// Read-only, author-verified public discussion for one publication.
///
/// This surface never opens the encrypted member log. Every row came from the
/// separate public record chain explicitly signed by its author.
class PublicSpacePostCommentsScreen extends ConsumerStatefulWidget {
  const PublicSpacePostCommentsScreen({
    super.key,
    required this.spaceIdHex,
    required this.postId,
    this.initialCommentRef,
  });

  final String spaceIdHex;
  final String postId;
  final String? initialCommentRef;

  @override
  ConsumerState<PublicSpacePostCommentsScreen> createState() =>
      _PublicSpacePostCommentsScreenState();
}

class _PublicSpacePostCommentsScreenState
    extends ConsumerState<PublicSpacePostCommentsScreen> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _initialCommentKey = GlobalKey();
  StateController<String?>? _activeConversation;
  String? _previousActiveConversation;
  bool _initialJumpQueued = false;
  bool _refreshing = false;

  String get _conversationKey =>
      'space-public-comment:${widget.spaceIdHex}:${widget.postId}';

  @override
  void initState() {
    super.initState();
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
    final previous = _previousActiveConversation;
    final key = _conversationKey;
    if (activeConversation?.state == key) {
      scheduleMicrotask(() {
        try {
          if (activeConversation!.state == key) {
            activeConversation.state = previous;
          }
        } catch (_) {}
      });
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<_PublicCommentsProjection?> _load(
    GroupService service,
    NodeId spaceId,
  ) async {
    final values = await Future.wait<Object?>([
      service.publicSpaceSubscription(spaceId),
      service.publicSpacePostComments(spaceId, widget.postId),
      service.publicSpacePostReactions(spaceId, widget.postId),
    ]);
    final subscription = values[0] as SpacePublicSubscriptionView?;
    if (subscription == null) return null;
    final post = subscription.feed.posts
        .where((item) => item.postId == widget.postId)
        .firstOrNull;
    if (post == null) return null;
    return _PublicCommentsProjection(
      subscription: subscription,
      post: post,
      comments: values[1] as List<SpacePublicCommentView>,
      reactions: values[2] as SpacePublicReactions,
    );
  }

  void _scheduleInitialJump(List<SpacePublicCommentView> comments) {
    final ref = widget.initialCommentRef;
    if (_initialJumpQueued ||
        ref == null ||
        !comments.any((comment) => comment.ref == ref)) {
      return;
    }
    _initialJumpQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _initialCommentKey.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.4,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  Future<void> _refresh(GroupService service, NodeId spaceId) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await service.refreshPublicSpaceSubscription(spaceId);
    if (mounted) setState(() => _refreshing = false);
  }

  void _goBack() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(
      '/space/${widget.spaceIdHex}/public-posts?post='
      '${Uri.encodeQueryComponent(widget.postId)}',
    );
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
      initialData: service.changes.value,
      builder: (context, _) => FutureBuilder<_PublicCommentsProjection?>(
        future: _load(service, spaceId),
        builder: (context, snapshot) {
          final projection = snapshot.data;
          if (!snapshot.hasData) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return Scaffold(
              appBar: AppBar(
                leading: BackButton(
                  key: const ValueKey('public-space-comments-back'),
                  onPressed: _goBack,
                ),
              ),
              body: Center(child: Text(l.spaceOperationFailed)),
            );
          }
          if (projection == null) {
            return Scaffold(
              appBar: AppBar(
                leading: BackButton(
                  key: const ValueKey('public-space-comments-back'),
                  onPressed: _goBack,
                ),
              ),
              body: Center(child: Text(l.spaceOperationFailed)),
            );
          }
          final comments = projection.comments;
          final byRef = {for (final comment in comments) comment.ref: comment};
          _scheduleInitialJump(comments);
          return Scaffold(
            appBar: AppBar(
              leading: BackButton(
                key: const ValueKey('public-space-comments-back'),
                onPressed: _goBack,
              ),
              title: Text(l.spacePostCommentsTitle),
              actions: [
                IconButton(
                  key: const ValueKey('public-space-comments-refresh'),
                  onPressed: _refreshing
                      ? null
                      : () => _refresh(service, spaceId),
                  icon: _refreshing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: RefreshIndicator(
                  onRefresh: () => _refresh(service, spaceId),
                  child: ListView(
                    key: const PageStorageKey(
                      'public-space-post-comments-list',
                    ),
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                    children: [
                      _PublicPublicationHeader(
                        spaceId: spaceId,
                        post: projection.post,
                        reactions: projection.reactions,
                        selfId: service.selfId,
                        commentCount: comments.length,
                      ),
                      Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.verified_user_outlined,
                                size: 19,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  l.spacePostPublicDiscussionReadOnly,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (comments.isEmpty)
                        Padding(
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
                            ],
                          ),
                        )
                      else
                        for (final comment in comments)
                          _PublicCommentBubble(
                            key: comment.ref == widget.initialCommentRef
                                ? _initialCommentKey
                                : ValueKey(
                                    'public-space-comment-${comment.ref}',
                                  ),
                            spaceId: spaceId,
                            comment: comment,
                            repliedComment: byRef[comment.replyTo],
                            isSelf: comment.author == service.selfId,
                          ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PublicCommentsProjection {
  const _PublicCommentsProjection({
    required this.subscription,
    required this.post,
    required this.comments,
    required this.reactions,
  });

  final SpacePublicSubscriptionView subscription;
  final SpacePostView post;
  final List<SpacePublicCommentView> comments;
  final SpacePublicReactions reactions;
}

class _PublicPublicationHeader extends StatelessWidget {
  const _PublicPublicationHeader({
    required this.spaceId,
    required this.post,
    required this.reactions,
    required this.selfId,
    required this.commentCount,
  });

  final NodeId spaceId;
  final SpacePostView post;
  final SpacePublicReactions reactions;
  final NodeId selfId;
  final int commentCount;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
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
          SpacePostMediaList(spaceId: spaceId, post: post, publicOnly: true),
          if (reactions.isNotEmpty) ...[
            const SizedBox(height: 10),
            SpacePostReactionBar(
              postId: post.postId,
              reactions: reactions,
              selfId: selfId,
              onReact: null,
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.forum_outlined, size: 17),
              const SizedBox(width: 6),
              Text(AppL10n.of(context).spacePostCommentsCount(commentCount)),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PublicCommentBubble extends StatelessWidget {
  const _PublicCommentBubble({
    super.key,
    required this.spaceId,
    required this.comment,
    required this.repliedComment,
    required this.isSelf,
  });

  final NodeId spaceId;
  final SpacePublicCommentView comment;
  final SpacePublicCommentView? repliedComment;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final colors = Theme.of(context).colorScheme;
    final author = isSelf ? l.chatYou : comment.author.short;
    return Semantics(
      label: '$author, ${messageMentionsFallbackText(comment.body)}',
      child: Align(
        alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
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
                  const Icon(Icons.verified_outlined, size: 15),
                  const SizedBox(width: 5),
                  Text(author, style: Theme.of(context).textTheme.labelMedium),
                  const SizedBox(width: 8),
                  Text(
                    _publicCommentTime(context, comment.createdAtMs),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (comment.edited) ...[
                    const SizedBox(width: 6),
                    Text(
                      l.spacePostCommentEdited,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
              if (repliedComment != null) ...[
                const SizedBox(height: 7),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(9),
                    border: Border(
                      left: BorderSide(color: colors.primary, width: 3),
                    ),
                  ),
                  child: Text(
                    messageMentionsFallbackText(repliedComment!.body),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              if (comment.body.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectionArea(child: FormattedText(comment.body)),
              ],
              if (comment.media != null)
                MediaObjectList(
                  spaceId: spaceId,
                  author: comment.author,
                  media: [comment.media!],
                  compact: true,
                  publicOnly: true,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _publicCommentTime(BuildContext context, int milliseconds) {
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
