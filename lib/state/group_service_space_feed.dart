part of 'group_service.dart';

/// The aggregated Space feed: what appears in it, in what order, which of it
/// is unread, and the per-space preferences that shape it.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_PublicSubscriptions]. Every public entry point stays on
/// the owner, so nothing outside this library can tell the move happened.
class _SpaceFeed {
  _SpaceFeed(this._owner);

  final GroupService _owner;

  Future<void> setSpaceFeedEnabled(NodeId spaceId, bool enabled) async {
    await _owner.updateSpaceSubscription(spaceId, feedEnabled: enabled);
  }

  Future<void> setSpaceNotificationsEnabled(
    NodeId spaceId,
    bool enabled,
  ) async {
    await _owner.updateSpaceSubscription(
      spaceId,
      notificationsEnabled: enabled,
    );
  }

  Future<void> setSpaceCommentNotifications(
    NodeId spaceId,
    SpaceCommentNotificationMode mode,
  ) async {
    await _owner.updateSpaceSubscription(spaceId, commentNotifications: mode);
  }

  Future<void> setSpaceHiddenFromRecommendations(
    NodeId spaceId,
    bool hidden,
  ) async {
    await _owner.updateSpaceSubscription(
      spaceId,
      hiddenFromRecommendations: hidden,
    );
  }

  /// Merge subscribed Space logs in descending chronological order. The
  /// signed `(publishedAt, spaceId, author, seq)` tuple is a stable cursor and
  /// the identity set prevents duplicates regardless of roles or sync paths.
  Future<List<SpaceFeedItem>> spaceFeed({
    SpaceFeedCursor? before,
    int limit = 50,
    Set<SpacePostType>? types,
    SpaceFeedFilter? filter,
    bool? pinned,
  }) async {
    final boundedLimit = limit.clamp(1, 200);
    var selectedFilter = filter ?? await _owner.spaceFeedFilter();
    if (types != null) selectedFilter = selectedFilter.copyWith(types: types);
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final items = <SpaceFeedItem>[];
    final seen = <String>{};
    final memberSpaceIds = <String>{};
    final hidden = await _owner._hiddenSpaceFeedPosts();
    final blockedAuthors = <String, Future<bool>>{};
    Future<bool> isBlockedAuthor(NodeId author) {
      if (author == _owner._signer.selfId) return Future<bool>.value(false);
      return blockedAuthors.putIfAbsent(
        author.hex,
        () async =>
            (await _owner._storage.getContact(author))?.status ==
            ContactStatus.blocked,
      );
    }

    for (final id in await _owner._index()) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(id);
      } catch (_) {
        continue;
      }
      if (selectedFilter.spaceIds.isNotEmpty &&
          !selectedFilter.spaceIds.contains(spaceId)) {
        continue;
      }
      final bundle = await _owner.load(spaceId);
      if (bundle == null || !bundle.manifest.isSpace) continue;
      final folded = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      );
      final state = folded.state;
      final acl = SpaceAcl(state);
      if (!acl.allows(_owner._signer.selfId, SpacePermission.view)) {
        continue;
      }
      memberSpaceIds.add(spaceId.hex);
      if (!await _owner.isSpaceFeedEnabled(spaceId)) continue;
      final canManagePosts = acl.allows(
        _owner._signer.selfId,
        SpacePermission.managePosts,
      );
      final visiblePosts = await _owner._postsOfBundle(
        bundle,
        applyLocalRetention: true,
      );
      final feedPosts = <SpacePostView>[];
      for (final post in visiblePosts) {
        if (hidden.containsKey(
              _owner._hiddenSpaceFeedPostKey(spaceId, post.postId),
            ) ||
            await isBlockedAuthor(post.author)) {
          continue;
        }
        feedPosts.add(post);
      }
      final reactions = await _owner._reactions.spacePostReactionsOfBundle(
        bundle,
        visiblePostIds: {for (final post in feedPosts) post.postId},
      );
      final commentsByPost = selectedFilter.mentionsOnly
          ? (await _owner.spacePostsAndCommentsOf(spaceId)).commentsByPost
          : const <String, List<SpacePostCommentView>>{};
      for (final post in feedPosts) {
        var relatedMention = false;
        if (selectedFilter.mentionsOnly) {
          for (final comment
              in commentsByPost[post.postId] ??
                  const <SpacePostCommentView>[]) {
            if (comment.author != _owner._signer.selfId &&
                messageMentionsNode(comment.body, _owner._signer.selfId) &&
                !await isBlockedAuthor(comment.author)) {
              relatedMention = true;
              break;
            }
          }
        }
        if (!selectedFilter.allowsPost(
          post,
          viewer: _owner._signer.selfId,
          nowMs: readAt,
          relatedMention: relatedMention,
        )) {
          continue;
        }
        if (pinned != null && post.pinned != pinned) continue;
        final cursor = SpaceFeedCursor.fromView(post);
        if (before != null && cursor.compareTo(before) >= 0) continue;
        if (!seen.add('${spaceId.hex}:${post.postId}')) continue;
        items.add(
          SpaceFeedItem(
            spaceId: spaceId,
            spaceName: state.name,
            post: post,
            reactions: reactions[post.postId] ?? const {},
            canDeletePost:
                post.author == _owner._signer.selfId &&
                state.isActive &&
                post.effective.lifecycleGeneration ==
                    state.lifecycleTransitionHash,
            canModeratePost:
                post.author != _owner._signer.selfId &&
                acl.allowsControl(
                  _owner._signer.selfId,
                  ControlOp.moderate,
                  target: post.author,
                  moderationTargetsRemovedContent: true,
                ),
            canManagePosts: canManagePosts,
          ),
        );
      }
    }
    for (final public in await _owner.publicSpaceSubscriptions()) {
      final spaceId = public.descriptor.spaceId;
      if (memberSpaceIds.contains(spaceId.hex) ||
          !public.subscription.feedEnabled ||
          (selectedFilter.spaceIds.isNotEmpty &&
              !selectedFilter.spaceIds.contains(spaceId))) {
        continue;
      }
      for (final post in public.feed.posts) {
        var relatedMention = false;
        if (selectedFilter.mentionsOnly) {
          for (final comment in public.feed.commentsFor(
            post.postId,
            _owner._signer.verifyDetached,
          )) {
            if (comment.author != _owner._signer.selfId &&
                messageMentionsNode(comment.body, _owner._signer.selfId) &&
                !await isBlockedAuthor(comment.author)) {
              relatedMention = true;
              break;
            }
          }
        }
        if (hidden.containsKey(
              _owner._hiddenSpaceFeedPostKey(spaceId, post.postId),
            ) ||
            await isBlockedAuthor(post.author) ||
            !selectedFilter.allowsPost(
              post,
              viewer: _owner._signer.selfId,
              nowMs: readAt,
              relatedMention: relatedMention,
            ) ||
            (pinned != null && post.pinned != pinned)) {
          continue;
        }
        final cursor = SpaceFeedCursor.fromView(post);
        if (before != null && cursor.compareTo(before) >= 0) continue;
        if (!seen.add('${spaceId.hex}:${post.postId}')) continue;
        items.add(
          SpaceFeedItem(
            spaceId: spaceId,
            spaceName: public.descriptor.name,
            post: post,
            reactions: public.feed.reactionsFor(
              post.postId,
              _owner._signer.verifyDetached,
            ),
            canDeletePost: false,
            canModeratePost: false,
            canManagePosts: false,
            publicOnly: true,
          ),
        );
      }
    }
    items.sort((left, right) {
      final order = SpaceFeedCursor.fromView(
        right.post,
      ).compareTo(SpaceFeedCursor.fromView(left.post));
      return order;
    });
    final result = items.length <= boundedLimit
        ? items
        : items.sublist(0, boundedLimit);
    _owner._observeSpace(
      SpaceObservationType.feedRead,
      result.isEmpty
          ? SpaceObservationOutcome.noOp
          : SpaceObservationOutcome.succeeded,
      amount: result.length,
    );
    return result;
  }

  Future<int> unreadSpacePosts(NodeId spaceId) async {
    return (await unreadSpacePostViews(spaceId)).length;
  }

  Future<List<SpacePostView>> _spaceFeedPostsForReadState(
    NodeId spaceId,
  ) async {
    if (await _owner._hasActiveSpaceMembership(spaceId)) {
      return _owner.postsOf(spaceId);
    }
    final public = await _owner.publicSpaceSubscription(spaceId);
    return public?.feed.posts ?? const [];
  }

  Future<List<SpacePostView>> unreadSpacePostViews(NodeId spaceId) async {
    final hidden = await _owner._hiddenSpaceFeedPosts();
    final seen = SpaceFeedCursor.decode(
      await _owner._storage.getSetting(_owner._spaceFeedSeenKey(spaceId)),
    );
    final posts = await _spaceFeedPostsForReadState(spaceId);
    final visible = <SpacePostView>[];
    for (final post in posts) {
      if (hidden.containsKey(
            _owner._hiddenSpaceFeedPostKey(spaceId, post.postId),
          ) ||
          post.author == _owner._signer.selfId ||
          (await _owner._storage.getContact(post.author))?.status ==
              ContactStatus.blocked ||
          (seen != null &&
              SpaceFeedCursor.fromView(post).compareTo(seen) <= 0)) {
        continue;
      }
      visible.add(post);
    }
    return List<SpacePostView>.unmodifiable(visible);
  }

  Future<void> markSpaceFeedSeen(NodeId spaceId) async {
    final posts = await _spaceFeedPostsForReadState(spaceId);
    if (posts.isEmpty) return;
    final latest = posts
        .map(SpaceFeedCursor.fromView)
        .reduce((left, right) => left.compareTo(right) >= 0 ? left : right);
    final prior = SpaceFeedCursor.decode(
      await _owner._storage.getSetting(_owner._spaceFeedSeenKey(spaceId)),
    );
    if (prior != null && prior.compareTo(latest) >= 0) return;
    await _owner._storage.putSetting(
      _owner._spaceFeedSeenKey(spaceId),
      latest.encode(),
    );
    _owner.changes.value++;
  }
}
