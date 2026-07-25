import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:go_router/go_router.dart';

import '../../core/ids.dart';
import '../../domain/space_public_discussion.dart';
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/group_service_providers.dart';
import '../../state/notifications.dart' show activeConversationProvider;
import 'space_post_actions.dart';
import 'space_post_body.dart';
import 'space_post_media.dart';
import 'space_post_reactions.dart';

/// Read-only publication surface for a verified public subscription.
///
/// It has no member actions. Public comments and reactions shown here are
/// independent author-signed records and never expose the membership log.
class PublicSpacePostsScreen extends ConsumerStatefulWidget {
  const PublicSpacePostsScreen({
    super.key,
    required this.spaceIdHex,
    this.initialPostId,
  });

  final String spaceIdHex;
  final String? initialPostId;

  @override
  ConsumerState<PublicSpacePostsScreen> createState() =>
      _PublicSpacePostsScreenState();
}

class _PublicSpacePostsScreenState
    extends ConsumerState<PublicSpacePostsScreen> {
  final GlobalKey _initialPostKey = GlobalKey();
  StateController<String?>? _activeConversation;
  bool _initialJumpQueued = false;
  bool _refreshing = false;

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
    final activeConversation = _activeConversation;
    final conversationKey = _conversationKey;
    if (activeConversation?.state == conversationKey) {
      // Riverpod forbids provider mutations while Flutter finalizes a route's
      // widget tree. Clear the marker after the synchronous navigation frame.
      scheduleMicrotask(() {
        try {
          if (activeConversation!.state == conversationKey) {
            activeConversation.state = null;
          }
        } catch (_) {
          // The ProviderScope may already be gone during app/test teardown.
        }
      });
    }
    super.dispose();
  }

  void _scheduleInitialJump(List<SpacePostView> posts) {
    if (_initialJumpQueued ||
        widget.initialPostId == null ||
        !posts.any((post) => post.postId == widget.initialPostId)) {
      return;
    }
    _initialJumpQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _initialPostKey.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.12,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _goBack() => goBackOrHome(context);

  Future<void> _refresh(
    GroupService service,
    NodeId spaceId, {
    bool showFailure = false,
  }) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final refreshed = await service.refreshPublicSpaceSubscription(spaceId);
    if (mounted) {
      setState(() => _refreshing = false);
      if (refreshed == null && showFailure) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
        );
      }
    }
  }

  Future<void> _join(
    GroupService service,
    SpacePublicSubscriptionView view,
  ) async {
    final ok = await service.requestToJoinSpace(view.descriptor.joinCode);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? AppL10n.of(context).spaceJoinRequestSent
              : AppL10n.of(context).spaceOperationFailed,
        ),
      ),
    );
  }

  Future<void> _unsubscribe(GroupService service, NodeId spaceId) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.spacePublicUnsubscribe),
        content: Text(l.spacePublicUnsubscribeConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            key: const ValueKey('public-space-unsubscribe-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.spacePublicUnsubscribe),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await service.unsubscribeFromPublicSpace(spaceId);
    if (!mounted) return;
    if (removed) {
      if (context.canPop()) {
        context.pop();
      } else {
        // A standalone '/spaces' would itself have no back affordance (flat
        // router, empty stack) — anchor at home instead of another dead end.
        context.go('/home');
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.spaceOperationFailed)));
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
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(
            key: const ValueKey('public-space-posts-back'),
            onPressed: _goBack,
          ),
        ),
        body: Center(child: Text(l.spaceOperationFailed)),
      );
    }
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<int>(
      stream: service.changes.stream,
      initialData: service.changes.value,
      builder: (context, _) => FutureBuilder<SpacePublicSubscriptionView?>(
        future: service.publicSpaceSubscription(spaceId),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return Scaffold(
              appBar: AppBar(
                leading: BackButton(
                  key: const ValueKey('public-space-posts-back'),
                  onPressed: _goBack,
                ),
              ),
              body: Center(child: Text(l.spaceOperationFailed)),
            );
          }
          final view = snapshot.data!;
          final posts = view.feed.posts;
          _scheduleInitialJump(posts);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(service.markSpaceFeedSeen(spaceId));
          });
          return Scaffold(
            appBar: AppBar(
              leading: BackButton(
                key: const ValueKey('public-space-posts-back'),
                onPressed: _goBack,
              ),
              title: Text(view.descriptor.name),
              actions: [
                IconButton(
                  key: const ValueKey('public-space-refresh'),
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).refreshIndicatorSemanticLabel,
                  onPressed: _refreshing
                      ? null
                      : () => _refresh(service, spaceId, showFailure: true),
                  icon: _refreshing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
                IconButton(
                  key: const ValueKey('public-space-feed-toggle'),
                  tooltip: view.subscription.feedEnabled
                      ? l.spaceFeedDisable
                      : l.spaceFeedEnable,
                  onPressed: () => service.setSpaceFeedEnabled(
                    spaceId,
                    !view.subscription.feedEnabled,
                  ),
                  icon: Icon(
                    view.subscription.feedEnabled
                        ? Icons.dynamic_feed_outlined
                        : Icons.comments_disabled_outlined,
                  ),
                ),
                IconButton(
                  key: const ValueKey('public-space-notifications-toggle'),
                  tooltip: l.spaceNotificationsSetting,
                  onPressed: () => service.setSpaceNotificationsEnabled(
                    spaceId,
                    !view.subscription.notificationsEnabled,
                  ),
                  icon: Icon(
                    view.subscription.notificationsEnabled
                        ? Icons.notifications_outlined
                        : Icons.notifications_off_outlined,
                  ),
                ),
                IconButton(
                  key: const ValueKey('public-space-join'),
                  tooltip: l.spaceJoinAction,
                  onPressed: () => _join(service, view),
                  icon: const Icon(Icons.how_to_reg_outlined),
                ),
                PopupMenuButton<String>(
                  onSelected: (_) => _unsubscribe(service, spaceId),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'unsubscribe',
                      child: Row(
                        children: [
                          const Icon(Icons.remove_circle_outline),
                          const SizedBox(width: 12),
                          Text(l.spacePublicUnsubscribe),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: () => _refresh(service, spaceId),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Material(
                      color: view.stale
                          ? Theme.of(context).colorScheme.tertiaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              view.stale
                                  ? Icons.cloud_off_outlined
                                  : Icons.public,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                view.stale
                                    ? l.spacePublicSnapshotStale
                                    : l.spacePublicReadOnly,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (posts.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text(l.spacePostsEmpty)),
                    )
                  else
                    SliverList.separated(
                      itemCount: posts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final post = posts[index];
                        final initial = post.postId == widget.initialPostId;
                        final published = MaterialLocalizations.of(context)
                            .formatShortDate(
                              DateTime.fromMillisecondsSinceEpoch(
                                post.publishedAtMs,
                              ),
                            );
                        return KeyedSubtree(
                          key: initial ? _initialPostKey : null,
                          child: Card(
                            key: ValueKey('public-space-post-${post.postId}'),
                            margin: const EdgeInsets.symmetric(horizontal: 12),
                            color: initial
                                ? Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.verified_outlined,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          post.author.short,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelMedium,
                                        ),
                                      ),
                                      Text(
                                        published,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      if (post.author != service.selfId)
                                        PopupMenuButton<String>(
                                          key: ValueKey(
                                            'public-space-post-menu-${post.postId}',
                                          ),
                                          onSelected: (_) => unawaited(
                                            promptAndReportSpaceContent(
                                              context,
                                              service,
                                              spaceId,
                                              postId: post.postId,
                                            ),
                                          ),
                                          itemBuilder: (_) => [
                                            PopupMenuItem(
                                              value: 'report',
                                              child: ListTile(
                                                contentPadding: EdgeInsets.zero,
                                                leading: const Icon(
                                                  Icons.flag_outlined,
                                                ),
                                                title: Text(
                                                  l.spaceAbuseReportAction,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                  if (post.pinned) ...[
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        const Icon(Icons.push_pin, size: 15),
                                        const SizedBox(width: 5),
                                        Text(l.spacePostPinned),
                                      ],
                                    ),
                                  ],
                                  if (post.title.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      post.title,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                  ],
                                  if (post.body.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    SpacePostBody(post.body),
                                  ],
                                  SpacePostMediaList(
                                    spaceId: spaceId,
                                    post: post,
                                    publicOnly: true,
                                  ),
                                  if (post.edited) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      l.spacePostEdited,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                  ],
                                  FutureBuilder<List<Object>>(
                                    future: Future.wait<Object>([
                                      service.publicSpacePostComments(
                                        spaceId,
                                        post.postId,
                                      ),
                                      service.publicSpacePostReactions(
                                        spaceId,
                                        post.postId,
                                      ),
                                    ]),
                                    builder: (context, discussionSnapshot) {
                                      final values = discussionSnapshot.data;
                                      final comments = values == null
                                          ? const <SpacePublicCommentView>[]
                                          : values[0]
                                                as List<SpacePublicCommentView>;
                                      final reactions = values == null
                                          ? const <String, List<NodeId>>{}
                                          : values[1] as SpacePublicReactions;
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (reactions.isNotEmpty) ...[
                                            const SizedBox(height: 10),
                                            SpacePostReactionBar(
                                              postId: post.postId,
                                              reactions: reactions,
                                              selfId: service.selfId,
                                              onReact: null,
                                            ),
                                          ],
                                          TextButton.icon(
                                            key: ValueKey(
                                              'public-space-comments-${post.postId}',
                                            ),
                                            onPressed: () => context.push(
                                              '/space/${spaceId.hex}/public-comments?post='
                                              '${Uri.encodeQueryComponent(post.postId)}',
                                            ),
                                            icon: const Icon(
                                              Icons.forum_outlined,
                                              size: 18,
                                            ),
                                            label: Text(
                                              l.spacePostCommentsCount(
                                                comments.length,
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
