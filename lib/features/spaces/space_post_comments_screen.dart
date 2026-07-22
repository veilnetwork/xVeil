import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/group_message.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import 'space_post_media.dart';

/// Member discussion for one Space publication. Comments share the signed,
/// encrypted and P2P-replicated message log, but this dedicated projection is
/// deliberately outside channel history and the Chats navigation surface.
class SpacePostCommentsScreen extends ConsumerStatefulWidget {
  const SpacePostCommentsScreen({
    super.key,
    required this.spaceIdHex,
    required this.postId,
  });

  final String spaceIdHex;
  final String postId;

  @override
  ConsumerState<SpacePostCommentsScreen> createState() =>
      _SpacePostCommentsScreenState();
}

class _SpacePostCommentsScreenState
    extends ConsumerState<SpacePostCommentsScreen> {
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  GroupService? _boundService;
  NodeId? _boundSpaceId;
  Future<_CommentsProjection>? _projection;
  GroupMessage? _replyTo;
  bool _sending = false;
  bool _followAfterLoad = true;
  int _renderedCommentCount = -1;

  @override
  void dispose() {
    _boundService?.changes.removeListener(_onServiceChanged);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
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
    _followAfterLoad = true;
  }

  Future<_CommentsProjection> _load(
    GroupService service,
    NodeId spaceId,
  ) async {
    final results = await Future.wait<Object?>([
      service.stateOf(spaceId),
      service.postsOf(spaceId),
    ]);
    final state = results[0] as GroupState?;
    final posts = results[1] as List<SpacePostView>;
    final post = posts
        .where((item) => item.postId == widget.postId)
        .firstOrNull;
    final comments = post == null
        ? const <GroupMessage>[]
        : await service.spacePostCommentsOf(spaceId, widget.postId);
    return _CommentsProjection(state: state, post: post, comments: comments);
  }

  bool get _nearTail =>
      !_scroll.hasClients ||
      _scroll.position.maxScrollExtent - _scroll.position.pixels < 160;

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

  bool get _tooLong =>
      utf8.encode(_composer.text.trim()).length > kSpacePostCommentMaxBytes;

  bool get _canSend =>
      !_sending && _composer.text.trim().isNotEmpty && !_tooLong;

  Future<void> _send() async {
    final service = _boundService;
    final spaceId = _boundSpaceId;
    final body = _composer.text.trim();
    if (service == null || spaceId == null || !_canSend) return;
    setState(() => _sending = true);
    final sent = await service.commentOnSpacePost(
      spaceId,
      widget.postId,
      body,
      replyTo: _replyTo?.ref,
    );
    if (!mounted) return;
    if (sent) {
      _composer.clear();
      _replyTo = null;
      _followAfterLoad = true;
      _projection = _load(service, spaceId);
    }
    setState(() => _sending = false);
    if (!sent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spacePostCommentFailed)),
      );
    }
  }

  void _reply(GroupMessage comment) {
    setState(() => _replyTo = comment);
    _composerFocus.requestFocus();
  }

  void _scheduleTail(int commentCount) {
    final firstProjection = _renderedCommentCount < 0;
    final grew = commentCount > _renderedCommentCount;
    _renderedCommentCount = commentCount;
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
      appBar: AppBar(title: Text(l.spacePostCommentsTitle)),
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
                          return _CommentBubble(
                            key: ValueKey('space-post-comment-${comment.ref}'),
                            comment: comment,
                            repliedComment: byRef[comment.replyTo],
                            isSelf: comment.author == service.selfId,
                            onReply: canWrite ? () => _reply(comment) : null,
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
                      sending: _sending,
                      canSend: _canSend,
                      tooLong: _tooLong,
                      onChanged: () => setState(() {}),
                      onCancelReply: () => setState(() => _replyTo = null),
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
  });

  final GroupState? state;
  final SpacePostView? post;
  final List<GroupMessage> comments;
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
            if (post.body.isNotEmpty) SelectionArea(child: Text(post.body)),
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
    required this.comment,
    required this.repliedComment,
    required this.isSelf,
    required this.onReply,
  });

  final GroupMessage comment;
  final GroupMessage? repliedComment;
  final bool isSelf;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final colors = Theme.of(context).colorScheme;
    final author = isSelf ? l.chatYou : comment.author.short;
    return Semantics(
      label: '$author, ${comment.body}',
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
                ],
              ),
              if (repliedComment != null) ...[
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
                    _preview(repliedComment!.body),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              const SizedBox(height: 5),
              SelectionArea(child: Text(comment.body)),
              if (onReply != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: ValueKey('space-post-comment-reply-${comment.ref}'),
                    onPressed: onReply,
                    icon: const Icon(Icons.reply, size: 16),
                    label: Text(l.spacePostCommentReply),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.replyTo,
    required this.sending,
    required this.canSend,
    required this.tooLong,
    required this.onChanged,
    required this.onCancelReply,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final GroupMessage? replyTo;
  final bool sending;
  final bool canSend;
  final bool tooLong;
  final VoidCallback onChanged;
  final VoidCallback onCancelReply;
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
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
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('space-post-comment-send'),
                    tooltip: l.spacePostCommentSend,
                    onPressed: canSend ? onSend : null,
                    icon: sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
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
