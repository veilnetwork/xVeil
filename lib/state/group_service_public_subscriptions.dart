part of 'group_service.dart';

/// Following a public space without being in it: what a subscriber can read,
/// how a subscription is created, refreshed and dropped again.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_PublicFeedTransport]. Every public entry point stays on
/// the owner, so nothing outside this library can tell the move happened.
class _PublicSubscriptions {
  _PublicSubscriptions(this._owner);

  final GroupService _owner;

  /// The one place a stored subscription becomes something the app reads, so
  /// the one place the device-local publication order is attached. Everything
  /// that ranks, pages, counts or notifies on a followed public Space reaches
  /// its posts through `view.feed.posts`, and therefore through this.
  SpacePublicSubscriptionView _publicSubscriptionView(
    SpacePublicSubscriptionSnapshot snapshot,
    SpaceSubscription subscription,
  ) => SpacePublicSubscriptionView(
    subscription: subscription,
    descriptor: snapshot.package.descriptor,
    feed: snapshot.package.projection.withPostReceipts(snapshot.postReceipts),
    verifiedAtMs: snapshot.verifiedAtMs,
    stale: snapshot.isStaleAt(_owner._now()),
  );

  Future<SpacePublicSubscriptionView?> publicSpaceSubscription(
    NodeId spaceId,
  ) async {
    final index = await _owner._loadPublicSubscriptionIndex();
    if (!index.complete ||
        !index.ids.contains(spaceId.hex) ||
        await _owner._hasActiveSpaceMembership(spaceId)) {
      return null;
    }
    final snapshot = await _owner._loadPublicSubscriptionSnapshot(spaceId);
    if (snapshot == null) return null;
    final stored = await _owner._storedSpaceSubscription(spaceId);
    final subscription = stored?.publicOnly == true
        ? stored!
        : SpaceSubscription.publicDefault(spaceId);
    return _publicSubscriptionView(snapshot, subscription);
  }

  /// Return the author-signed public discussion for one subscribed post.
  ///
  /// The public snapshot has already passed its owner manifest gate. Folding
  /// here verifies every contributing author again and rejects broken chains,
  /// so UI callers never need access to the service's private signer.
  Future<List<SpacePublicCommentView>> publicSpacePostComments(
    NodeId spaceId,
    String postId,
  ) async {
    final view = await publicSpaceSubscription(spaceId);
    if (view == null || !view.feed.posts.any((post) => post.postId == postId)) {
      return const [];
    }
    final comments = view.feed.commentsFor(
      postId,
      _owner._signer.verifyDetached,
    );
    return _owner._withoutBlockedSpaceAuthors(
      comments,
      (comment) => comment.author,
    );
  }

  Future<SpacePublicReactions> publicSpacePostReactions(
    NodeId spaceId,
    String postId,
  ) async {
    final view = await publicSpaceSubscription(spaceId);
    if (view == null || !view.feed.posts.any((post) => post.postId == postId)) {
      return const {};
    }
    return view.feed.reactionsFor(postId, _owner._signer.verifyDetached);
  }

  /// Stable public root refs known to an active member. The composer uses this
  /// to prevent accidentally marking a reply public when its parent was
  /// members-only (which would otherwise be rejected by the service).
  Future<Set<String>> publicSpacePostCommentRefs(
    NodeId spaceId,
    String postId,
  ) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return const {};
    }
    return {
      for (final comment in foldSpacePublicComments(
        comments: bundle.publicComments,
        spaceId: spaceId,
        postId: postId,
        verifySignature: _owner._signer.verifyDetached,
      ))
        comment.ref,
    };
  }

  Future<List<SpacePublicSubscriptionView>> publicSpaceSubscriptions() async {
    final index = await _owner._loadPublicSubscriptionIndex();
    if (!index.complete) return const [];
    final views = <SpacePublicSubscriptionView>[];
    for (final hex in index.ids) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        continue;
      }
      if (await _owner._hasActiveSpaceMembership(spaceId)) continue;
      final snapshot = await _owner._loadPublicSubscriptionSnapshot(spaceId);
      if (snapshot == null) continue;
      final stored = await _owner._storedSpaceSubscription(spaceId);
      final subscription = stored?.publicOnly == true
          ? stored!
          : SpaceSubscription.publicDefault(spaceId);
      views.add(_publicSubscriptionView(snapshot, subscription));
    }
    views.sort((left, right) {
      final name = left.descriptor.name.compareTo(right.descriptor.name);
      return name != 0
          ? name
          : left.descriptor.spaceId.hex.compareTo(right.descriptor.spaceId.hex);
    });
    return List<SpacePublicSubscriptionView>.unmodifiable(views);
  }

  /// Activate or refresh a read-only public subscription from one exact,
  /// currently verified descriptor/feed pair.
  ///
  /// The snapshot and preference are written before the compact index. The
  /// index is the sole activation point, so a crash cannot expose a preference
  /// whose signed bytes are absent. Existing snapshots also impose monotonic
  /// descriptor and feed revisions to reject a validly signed rollback.
  Future<SpacePublicSubscriptionView?> subscribeToPublicSpace(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders,
  ) => _owner._serializeSpaceFeedPreferences(() async {
    final nowMs = _owner._now();
    if (!descriptor.verifyAt(nowMs, _owner._signer.verifyDetached) ||
        descriptor.genesisManifest.visibility != SpaceVisibility.public ||
        await _owner._hasActiveSpaceMembership(descriptor.spaceId)) {
      return null;
    }
    final exactHolders = <String, SpacePublicHolderAnnouncement>{};
    for (final holder in holders) {
      if (holder.holder == _owner.selfId ||
          holder.spaceId != descriptor.spaceId ||
          holder.descriptorHash != descriptor.descriptorHash ||
          holder.publicFeedManifestHash != descriptor.publicFeedManifestHash ||
          !holder.verifyAt(nowMs, _owner._signer.verifyDetached)) {
        continue;
      }
      exactHolders[holder.holder.hex] = holder;
    }
    if (exactHolders.isEmpty) return null;

    final index = await _owner._loadPublicSubscriptionIndex();
    if (!index.complete ||
        (!index.ids.contains(descriptor.spaceId.hex) &&
            index.ids.length >= GroupService._kMaxPublicSubscriptions)) {
      return null;
    }
    final prior = index.ids.contains(descriptor.spaceId.hex)
        ? await _owner._loadPublicSubscriptionSnapshot(descriptor.spaceId)
        : null;
    if (prior != null) {
      final current = prior.package.descriptor;
      final authorityOrder = descriptor.authorityGeneration.compareTo(
        current.authorityGeneration,
      );
      final sameGeneration = authorityOrder == 0;
      final authorityForkOrder = descriptor.authorityHash.compareTo(
        current.authorityHash,
      );
      if (authorityOrder < 0 ||
          (sameGeneration && authorityForkOrder < 0) ||
          (sameGeneration &&
              authorityForkOrder == 0 &&
              (descriptor.revision < current.revision ||
                  descriptor.publicFeedRevision < current.publicFeedRevision ||
                  descriptor.publicFeedUpdatedAtMs <
                      current.publicFeedUpdatedAtMs))) {
        return null;
      }
    }

    SpacePublicFeedProjection? feed;
    final cached = await _owner._loadVerifiedPublicFeed(
      descriptor.spaceId,
      descriptor.publicFeedManifestHash,
    );
    if (cached != null &&
        cached.descriptor.descriptorHash == descriptor.descriptorHash) {
      feed = cached.feed;
    }
    feed ??= await _owner.fetchVerifiedPublicSpaceFeed(
      descriptor,
      exactHolders.values,
    );
    if (feed == null) return null;
    final package = SpacePublicFeedPackage(
      descriptor: descriptor,
      projection: feed,
    );
    if (!package.verifyAt(
      nowMs: nowMs,
      verifySignature: _owner._signer.verifyDetached,
      verifyPost: _owner._signer.verifyPost,
    )) {
      return null;
    }
    if (prior != null &&
        prior.package.descriptor.descriptorHash == descriptor.descriptorHash &&
        prior.package.projection.manifest.manifestHash ==
            feed.manifest.manifestHash) {
      final stored = await _owner._storedSpaceSubscription(descriptor.spaceId);
      return _publicSubscriptionView(
        prior,
        stored?.publicOnly == true
            ? stored!
            : SpaceSubscription.publicDefault(descriptor.spaceId),
      );
    }
    // A stranger's Space is where a hostile `published` costs least, and the
    // publisher signs the whole page, so nothing in the package can contradict
    // it. The stamp is left exactly as signed — the page hashes and the
    // manifest cover it — and the one time this device actually knows is
    // recorded beside it instead.
    //
    // Carried forward from the prior snapshot and putIfAbsent: a subscription
    // is re-fetched on every refresh and re-verified against a clock that has
    // moved on, so only the first sighting may set the value, or the post
    // would walk down the Feed on each refresh — and the Feed pages on exactly
    // this order. Recorded for publication ROOTS only, which is all a Feed
    // cursor ever names.
    final postReceipts = <String, int>{...?prior?.postReceipts};
    for (final view in feed.posts) {
      final root = view.root;
      if (root.operation == SpacePostOperation.publish &&
          spacePostOrderAt(root.publishedAtMs, nowMs) != root.publishedAtMs) {
        postReceipts.putIfAbsent(spacePostReceiptKey(root), () => nowMs);
      }
    }
    final snapshot = SpacePublicSubscriptionSnapshot(
      verifiedAtMs: nowMs,
      package: package,
      postReceipts: postReceipts,
    );
    final snapshotBytes = snapshot.toBytes();
    if (snapshotBytes.length > kSpacePublicSubscriptionSnapshotMaxBytes) {
      return null;
    }

    final stored = index.ids.contains(descriptor.spaceId.hex)
        ? await _owner._storedSpaceSubscription(descriptor.spaceId)
        : null;
    final subscription =
        (stored?.publicOnly == true
                ? stored!
                : SpaceSubscription.publicDefault(descriptor.spaceId))
            .copyWith(publicOnly: true, updatedAtMs: nowMs);
    await _owner._storage.storeFile(
      _owner._publicSubscriptionSnapshotFileId(descriptor.spaceId),
      snapshotBytes,
      name: 'public-space-subscription',
    );
    await _owner._saveSpaceSubscription(subscription);
    await _owner._storage.putSetting(
      _owner._spaceFeedEnabledKey(descriptor.spaceId),
      '',
    );
    await _owner._savePublicSubscriptionIndex({
      ...index.ids,
      descriptor.spaceId.hex,
    });
    _owner._publicSubscriptionSnapshots[descriptor.spaceId.hex] = snapshot;
    _owner.changes.value++;
    _owner.feedAccessChanges.value++;
    if (prior != null) {
      final priorPostIds = {
        for (final post in prior.package.projection.posts) post.postId,
      };
      final priorCommentRefs = <String>{};
      for (final post in prior.package.projection.posts) {
        priorCommentRefs.addAll(
          prior.package.projection
              .commentsFor(post.postId, _owner._signer.verifyDetached)
              .map((comment) => comment.ref),
        );
      }
      for (final post in feed.posts) {
        if (post.author != _owner.selfId &&
            !priorPostIds.contains(post.postId)) {
          _owner._incomingPublicPostCtl.add((
            spaceId: descriptor.spaceId,
            post: post,
          ));
        }
        for (final comment in feed.commentsFor(
          post.postId,
          _owner._signer.verifyDetached,
        )) {
          if (comment.author != _owner.selfId &&
              !priorCommentRefs.contains(comment.ref)) {
            _owner._incomingPublicCommentCtl.add((
              spaceId: descriptor.spaceId,
              comment: comment,
            ));
          }
        }
      }
    }
    return _publicSubscriptionView(snapshot, subscription);
  });

  Future<SpacePublicSubscriptionView?> subscribeToPublicSpaceDiscovery(
    SpacePublicDiscoveryResult result,
  ) => subscribeToPublicSpace(result.descriptor, result.holders);

  Future<SpacePublicSubscriptionView?> refreshPublicSpaceSubscription(
    NodeId spaceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (await publicSpaceSubscription(spaceId) == null) return null;
    final discovery = await _owner.resolvePublicSpaceDiscovery(
      spaceId,
      timeout: timeout,
    );
    return discovery == null
        ? null
        : subscribeToPublicSpaceDiscovery(discovery);
  }

  /// Refresh the exact public descriptor/holders before opening a media grant.
  /// Stored bytes remain usable offline, but a new transfer never relies on an
  /// expired holder captured in a local snapshot.
  Future<bool> requestSubscribedPublicSpaceMedia(
    NodeId spaceId,
    String contentId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final current = await publicSpaceSubscription(spaceId);
    if (current == null ||
        !current.feed
            .verifiedReferencedContentIds(_owner._signer.verifyDetached)
            .contains(contentId)) {
      return false;
    }
    final discovery = await _owner.resolvePublicSpaceDiscovery(
      spaceId,
      timeout: timeout,
    );
    if (discovery == null) return false;
    final refreshed = await subscribeToPublicSpaceDiscovery(discovery);
    if (refreshed == null ||
        !refreshed.feed
            .verifiedReferencedContentIds(_owner._signer.verifyDetached)
            .contains(contentId)) {
      return false;
    }
    return _owner.requestPublicSpaceMedia(
      discovery.descriptor,
      discovery.holders,
      contentId,
    );
  }

  /// Deactivate first, then best-effort scrub the now-unreachable public
  /// snapshot. Shared downloaded media is reclaimed only by the global GC.
  Future<bool> unsubscribeFromPublicSpace(NodeId spaceId) =>
      _owner._serializeSpaceFeedPreferences(() async {
        final index = await _owner._loadPublicSubscriptionIndex();
        if (!index.complete || !index.ids.contains(spaceId.hex)) return false;
        final next = Set<String>.of(index.ids)..remove(spaceId.hex);
        await _owner._savePublicSubscriptionIndex(next);
        _owner._publicSubscriptionSnapshots.remove(spaceId.hex);
        try {
          await _owner._storage.putSetting(
            _owner._spaceSubscriptionKey(spaceId),
            '',
          );
          await _owner._storage.putSetting(
            _owner._spaceFeedSeenKey(spaceId),
            '',
          );
          await _owner._storage.deleteStoredFile(
            _owner._publicSubscriptionSnapshotFileId(spaceId),
          );
        } catch (_) {
          // The activation index is already authoritative. Any orphaned
          // public bytes are inert and can be scrubbed by later maintenance.
        }
        _owner.changes.value++;
        _owner.feedAccessChanges.value++;
        return true;
      });
}
