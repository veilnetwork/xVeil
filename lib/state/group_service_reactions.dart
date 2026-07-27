part of 'group_service.dart';

/// Reactions: toggling one, and folding the stored rows back into
/// `target -> emoji -> reactors`.
///
/// A collaborator rather than an extension, for the same reason as
/// [_LogCompaction] and [_ChannelKeyRotation]: extension members cannot be
/// overridden and dispatch statically, which breaks both a test subclass and
/// any dynamic call. The public entry points and the per-group lock stay on
/// the owner — the lock is the owner's — and this file holds the rules for
/// what a reaction is allowed to do and which stored rows survive folding.
///
/// The validators it leans on ([GroupService._validReactionFor],
/// [GroupService._materializeEncryptedReaction], the lifecycle helpers) stay
/// with the owner deliberately: they are shared with retention, the feed and
/// the public-comment path, so the boundary of this slice is "the reaction
/// operations, not everything a reaction touches".
class _Reactions {
  _Reactions(this._owner);

  final GroupService _owner;

  Future<bool> react(
    NodeId groupId,
    String target,
    String emoji, {
    required ReactionTargetKind targetKind,
    bool publiclyVisible = false,
    bool broadcast = true,
  }) async {
    final b = await _owner.load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _owner._validControlFor(b.manifest, e),
    ).state;
    if (b.manifest.isSpace && state.isDeleted) return false;
    if (utf8.encode(emoji).length > 64) return false;
    GroupMessage? targetMessage;
    if (targetKind == ReactionTargetKind.message) {
      for (final message in await _owner.messagesOf(groupId)) {
        if (message.ref == target) {
          targetMessage = message;
          break;
        }
      }
      if (targetMessage == null) return false;
    }
    SpacePostView? targetPost;
    if (targetKind == ReactionTargetKind.spacePost) {
      if (!b.manifest.isSpace) return false;
      targetPost = (await _owner.postsOf(
        groupId,
      )).where((post) => post.postId == target).firstOrNull;
      if (targetPost == null) return false;
      if (publiclyVisible &&
          (b.manifest.visibility != SpaceVisibility.public ||
              targetPost.visibility != SpacePostVisibility.public)) {
        return false;
      }
    }
    if (!SpaceAcl(state).allows(
      _owner._signer.selfId,
      SpacePermission.publishMessages,
      channelId: targetMessage?.channelId,
    )) {
      return false;
    }
    // My current reaction on this message (if any) → tapping it again clears it.
    final visibleReactions = <GroupReaction>[];
    for (final reaction in _owner._acceptedReactionsWithinLifecycle(b, state)) {
      if (!SpaceAcl(state).allows(
        reaction.author,
        SpacePermission.publishMessages,
        atMs: reaction.createdAtMs,
      )) {
        continue;
      }
      final materialized = await _owner._materializeEncryptedReaction(
        b,
        reaction,
      );
      if (materialized != null) visibleReactions.add(materialized);
    }
    final onTarget =
        foldReactionsByKind(
          visibleReactions,
          _owner._signer.verifyReaction,
          targetKind,
        )[target] ??
        const <String, List<NodeId>>{};
    String? mine;
    for (final e in onTarget.entries) {
      if (e.value.any((n) => n == _owner._signer.selfId)) {
        mine = e.key;
        break;
      }
    }
    final next = (mine == emoji) ? '' : emoji;
    final mySeq = _owner._nextSeq(
      b.reactions
          .where(
            (r) =>
                r.author == _owner._signer.selfId &&
                _owner._validReactionFor(b.manifest.groupId, r),
          )
          .map((r) => r.seq),
    );
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _owner._encryptionEstablished(
      b.manifest,
      b.control,
    );
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    if (encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_owner._validLocalEpochKey(
              b.manifest,
              b.control,
              state.epoch,
              key,
            ))) {
      return false;
    }
    final createdAt = _owner._now();
    final lifecycleGeneration = b.manifest.isSpace
        ? state.lifecycleTransitionHash
        : null;
    late final GroupReaction unsigned;
    if (targetMessage?.isChannelEncrypted == true) {
      final channelId = targetMessage!.channelId!;
      final protected = state.protectedChannels[channelId.hex];
      if (!b.manifest.isSpace || protected == null) {
        return false;
      }
      final channel = await _owner._materializeProtectedChannel(
        b,
        state,
        protected,
      );
      if (channel == null ||
          !channel.recipients.contains(_owner._signer.selfId)) {
        return false;
      }
      final channelEpoch = protected.channelEpoch;
      final channelKey =
          b.localChannelEpochKeys[_channelKeyId(channelId, channelEpoch)];
      if (channelKey == null ||
          !_owner._validLocalChannelEpochKey(
            b.manifest,
            b.control,
            channelId,
            channelEpoch,
            channelKey,
          )) {
        return false;
      }
      final clear = GroupReactionCleartext(
        target: target,
        emoji: next,
        targetKind: ReactionTargetKind.message,
        schemaVersion: 2,
      ).encode();
      try {
        final encrypted = await encryptSpaceChannelReactionPayload(
          spaceId: groupId,
          channelId: channelId,
          channelEpoch: channelEpoch,
          author: _owner._signer.selfId,
          seq: mySeq,
          reactionVersion: lifecycleGeneration == null ? 7 : 8,
          lifecycleGeneration: lifecycleGeneration ?? '',
          createdAtMs: createdAt,
          clearText: clear,
          channelKey: channelKey,
        );
        unsigned = GroupReaction(
          groupId: groupId,
          author: _owner._signer.selfId,
          seq: mySeq,
          target: '',
          emoji: '',
          version: lifecycleGeneration == null ? 7 : 8,
          channelId: channelId,
          channelEpoch: channelEpoch,
          encryptedPayload: encrypted,
          lifecycleGeneration: lifecycleGeneration,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else if (descriptor != null && key != null) {
      final clear = GroupReactionCleartext(
        target: target,
        emoji: next,
        targetKind: targetKind,
        schemaVersion: 2,
      ).encode();
      try {
        final encrypted = await encryptGroupReactionPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _owner._signer.selfId,
          seq: mySeq,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
          reactionVersion: lifecycleGeneration == null ? 4 : 6,
          lifecycleGeneration: lifecycleGeneration ?? '',
        );
        unsigned = GroupReaction(
          groupId: groupId,
          author: _owner._signer.selfId,
          seq: mySeq,
          target: '',
          emoji: '',
          version: lifecycleGeneration == null ? 4 : 6,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          lifecycleGeneration: lifecycleGeneration,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupReaction(
        groupId: groupId,
        author: _owner._signer.selfId,
        seq: mySeq,
        target: target,
        emoji: next,
        version: lifecycleGeneration == null ? 3 : 5,
        targetKind: targetKind,
        lifecycleGeneration: lifecycleGeneration,
        createdAtMs: createdAt,
        signature: Uint8List(0),
      );
    }
    final signed = _owner._signer.signReaction(unsigned);
    SpacePublicReaction? publicReaction;
    if (publiclyVisible) {
      final lifecycle =
          lifecycleGeneration ?? _owner._legacyPostGeneration(groupId);
      if (targetKind != ReactionTargetKind.spacePost || targetPost == null) {
        return false;
      }
      final chain = _owner._publicReactionChain(
        b,
        target,
        _owner._signer.selfId,
      );
      if (chain == null) return false;
      final unsignedPublic = SpacePublicReaction(
        spaceId: groupId,
        postId: target,
        author: _owner._signer.selfId,
        seq: signed.seq,
        prevHash: chain.isEmpty ? '' : chain.last.recordHash,
        emoji: next,
        lifecycleGeneration: lifecycle,
        createdAtMs: createdAt,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      final detached = _owner._signer.signDetached(
        unsignedPublic.canonicalBytes(),
      );
      publicReaction = unsignedPublic.withSignature(
        detached.signature,
        detached.publicKey,
      );
      if (!publicReaction.verify(_owner._signer.verifyDetached)) return false;
    }
    await _owner._save(
      b.copyWith(
        reactions: [...b.reactions, signed],
        publicReactions: [...b.publicReactions, ?publicReaction],
      ),
    );
    if (broadcast) {
      unawaited(
        _owner.broadcastDelta(
          groupId,
          reactions: [signed],
          publicReactions: [?publicReaction],
        ),
      );
    }
    return true;
  }

  /// The folded reactions of [groupId]: `messageRef -> emoji -> reactors`.
  Future<Map<String, MessageReactions>> reactionsOf(NodeId groupId) async {
    final b = await _owner.load(groupId);
    if (b == null) return const {};
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _owner._validControlFor(b.manifest, e),
    ).state;
    if (b.manifest.isSpace && state.isDeleted) return const {};
    final protectedChannels = b.manifest.isSpace
        ? await _owner._protectedChannelsOf(b, state)
        : const <String, SpaceChannelControlCleartext>{};
    final visibleMessages = {
      for (final message in await _owner.messagesOf(groupId))
        message.ref: message,
    };
    final materialized = <GroupReaction>[];
    for (final reaction in b.reactions) {
      if (!_owner._validReactionFor(groupId, reaction) ||
          (reaction.isChannelEncrypted &&
              !(protectedChannels[reaction.channelId!.hex]?.recipients.contains(
                    reaction.author,
                  ) ??
                  false)) ||
          !SpaceAcl(state).allows(
            reaction.author,
            SpacePermission.publishMessages,
            atMs: reaction.createdAtMs,
          )) {
        continue;
      }
      final visible = await _owner._materializeEncryptedReaction(b, reaction);
      if (visible == null) continue;
      final target = visibleMessages[visible.target];
      if (target == null ||
          (reaction.isChannelEncrypted
              ? !target.isChannelEncrypted ||
                    target.channelId != reaction.channelId
              : target.isChannelEncrypted)) {
        continue;
      }
      materialized.add(visible);
    }
    return foldGroupReactions(materialized, _owner._signer.verifyReaction);
  }

  /// The folded reactions of visible, non-deleted Space publication roots.
  Future<Map<String, MessageReactions>> spacePostReactionsOf(
    NodeId spaceId,
  ) async {
    final bundle = await _owner.load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const {};
    return spacePostReactionsOfBundle(bundle);
  }

  Future<Map<String, MessageReactions>> spacePostReactionsOfBundle(
    GroupBundle bundle, {
    Set<String>? visiblePostIds,
  }) async {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _owner._validControlFor(bundle.manifest, entry),
    ).state;
    if (!SpaceAcl(state).allows(_owner._signer.selfId, SpacePermission.view)) {
      return const {};
    }
    final allowedPostIds =
        visiblePostIds ??
        {for (final post in await _owner._postsOfBundle(bundle)) post.postId};
    final materialized = <GroupReaction>[];
    for (final reaction in _owner._acceptedReactionsWithinLifecycle(
      bundle,
      state,
    )) {
      if (!SpaceAcl(state).allows(
        reaction.author,
        SpacePermission.publishMessages,
        atMs: reaction.createdAtMs,
      )) {
        continue;
      }
      final visible = await _owner._materializeEncryptedReaction(
        bundle,
        reaction,
      );
      if (visible != null &&
          visible.targetKind == ReactionTargetKind.spacePost &&
          allowedPostIds.contains(visible.target)) {
        materialized.add(visible);
      }
    }
    return foldReactionsByKind(
      materialized,
      _owner._signer.verifyReaction,
      ReactionTargetKind.spacePost,
    );
  }
}
