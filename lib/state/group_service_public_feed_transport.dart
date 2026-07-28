part of 'group_service.dart';

/// The live-only transport under a public space feed: asking a holder for one
/// object, serving one to a stranger, reassembling the chunks that come back,
/// and the public-media grant that lets the ordinary stream server hand over
/// bytes without anyone becoming a member.
///
/// A collaborator rather than an extension, for the same reason as
/// [_Reactions] and [_LogCompaction]: extension members cannot be overridden
/// and dispatch statically, which breaks both a test subclass and any dynamic
/// call. The four public entry points stay on the owner because they are bound
/// as tear-offs by the providers and the headless runtime — moving them would
/// change the API, which this decomposition does not do.
///
/// The bounded state they share (pending requests, the two serve quotas, the
/// replay set) stays with the owner as well: [GroupService.dispose] clears it,
/// and splitting "who owns the map" from "who clears it" is how a leak on
/// shutdown gets written.
class _PublicFeedTransport {
  _PublicFeedTransport(this._owner);

  final GroupService _owner;

  void _purgePublicFeedTransportState() {
    final cutoff = _owner._now() - kSpacePublicFeedRequestWindow.inMilliseconds;
    final expired = [
      for (final entry in _owner._pendingPublicFeedObjects.entries)
        if (entry.value.createdAtMs < cutoff) entry.key,
    ];
    for (final nonce in expired) {
      final pending = _owner._pendingPublicFeedObjects.remove(nonce);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.complete(null);
      }
    }
    _owner._publicFeedServeQuotas.removeWhere(
      (_, quota) => quota.windowStartedAtMs < cutoff,
    );
    _owner._publicMediaServeQuotas.removeWhere(
      (_, quota) => quota.windowStartedAtMs < cutoff,
    );
    // The replay set has to outlive the ACCEPTANCE window, not the request
    // window. A requester signs its own `createdAtMs`, so it may future-date a
    // request by up to the tolerated clock skew and the same bytes stay
    // structurally valid for `window + skew`. Pruning after `window` alone let
    // the identical signed request find an empty replay set and fire `grant()`
    // again — each hit renewing the serve TTL, so one signed request stretched
    // into several windows of serve authority. This handler promises that
    // "invalid, replayed, unreferenced and unavailable requests are all
    // silent"; remembering a request for exactly as long as it can be accepted
    // is what makes that true.
    final replayCutoff =
        _owner._now() -
        (kSpacePublicMediaGrantRequestWindow + kSpacePublicClockSkew)
            .inMilliseconds;
    _owner._seenPublicMediaRequests.removeWhere(
      (_, seenAtMs) => seenAtMs < replayCutoff,
    );
  }

  String _freshPublicFeedNonce() {
    final random = Random.secure();
    String nonce;
    do {
      nonce = List<int>.generate(
        32,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    } while (_owner._pendingPublicFeedObjects.containsKey(nonce));
    return nonce;
  }

  Future<Uint8List?> _requestPublicFeedObject({
    required NodeId holder,
    required SpacePublicDescriptor descriptor,
    required String objectHash,
    required Duration timeout,
  }) async {
    final send = _owner.sendPublicFeedRequest;
    if (send == null || holder == _owner.selfId) return null;
    _purgePublicFeedTransportState();
    if (_owner._pendingPublicFeedObjects.length >=
        GroupService._kMaxPendingPublicFeedObjects) {
      return null;
    }
    final nonce = _freshPublicFeedNonce();
    final createdAtMs = _owner._now();
    final unsigned = SpacePublicFeedObjectRequest(
      spaceId: descriptor.spaceId,
      descriptorHash: descriptor.descriptorHash,
      manifestHash: descriptor.publicFeedManifestHash,
      objectHash: objectHash,
      requester: _owner.selfId,
      requesterPublicKey: _owner._signer.selfPubKey,
      nonce: nonce,
      createdAtMs: createdAtMs,
    );
    final signed = _owner._signer.signDetached(unsigned.canonicalBytes());
    if (!_listEquals(signed.publicKey, _owner._signer.selfPubKey)) return null;
    final request = unsigned.withSignature(signed.signature);
    if (!request.verifyAt(
      createdAtMs,
      _owner.selfId,
      _owner._signer.verifyDetached,
    )) {
      return null;
    }
    final pending = _PendingPublicFeedObject(
      spaceId: descriptor.spaceId,
      holder: holder,
      manifestHash: descriptor.publicFeedManifestHash,
      objectHash: objectHash,
      createdAtMs: createdAtMs,
    );
    _owner._pendingPublicFeedObjects[nonce] = pending;
    try {
      await send(holder, jsonEncode(request.toJson()));
    } catch (_) {
      _owner._pendingPublicFeedObjects.remove(nonce);
      return null;
    }
    final timedOut = Completer<Uint8List?>();
    final timeoutTimer = Timer(timeout, () => timedOut.complete(null));
    final result = await Future.any<Uint8List?>([
      pending.completer.future,
      timedOut.future,
    ]);
    timeoutTimer.cancel();
    _owner._pendingPublicFeedObjects.remove(nonce);
    if (!pending.completer.isCompleted) pending.completer.complete(null);
    return result;
  }

  /// Holder-side live-only object service. Invalid, uncommitted or over-quota
  /// requests are silent so the path exposes neither membership nor cache
  /// state beyond the descriptor the requester already resolved from DHT.
  Future<void> handlePublicFeedObjectRequest(
    NodeId peer,
    String requestJson,
  ) async {
    final send = _owner.sendPublicFeedChunk;
    if (send == null) return;
    final SpacePublicFeedObjectRequest? request;
    try {
      request = SpacePublicFeedObjectRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return;
    }
    final nowMs = _owner._now();
    if (request == null ||
        request.requester != peer ||
        !request.isStructurallyValidAt(nowMs)) {
      return;
    }
    _purgePublicFeedTransportState();
    final quota = _owner._publicFeedServeQuotas[peer.hex];
    final currentQuota =
        quota == null ||
            nowMs - quota.windowStartedAtMs >
                kSpacePublicFeedRequestWindow.inMilliseconds
        ? (windowStartedAtMs: nowMs, requests: 0)
        : quota;
    if (currentQuota.requests >=
        GroupService._kPublicFeedServeRequestsPerWindow) {
      return;
    }
    if (_owner._publicFeedServeQuotas.length >=
            GroupService._kMaxPublicFeedServeQuotaIdentities &&
        !_owner._publicFeedServeQuotas.containsKey(peer.hex)) {
      _owner._publicFeedServeQuotas.remove(
        _owner._publicFeedServeQuotas.keys.first,
      );
    }
    _owner._publicFeedServeQuotas[peer.hex] = (
      windowStartedAtMs: currentQuota.windowStartedAtMs,
      requests: currentQuota.requests + 1,
    );
    if (!request.verifyAt(nowMs, peer, _owner._signer.verifyDetached)) return;

    final cached = await _owner._loadOrRebuildVerifiedPublicFeed(
      spaceId: request.spaceId,
      descriptorHash: request.descriptorHash,
      manifestHash: request.manifestHash,
    );
    if (cached == null) return;
    final Uint8List? bytes;
    if (request.objectHash == request.manifestHash) {
      bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(cached.feed.manifest.toJson())),
      );
    } else {
      SpacePublicFeedPage? page;
      for (final candidate in cached.feed.pages) {
        if (candidate.contentHash == request.objectHash) {
          page = candidate;
          break;
        }
      }
      SpacePublicDiscussionPage? discussionPage;
      if (page == null) {
        for (final candidate in cached.feed.discussionPages) {
          if (candidate.contentHash == request.objectHash) {
            discussionPage = candidate;
            break;
          }
        }
      }
      bytes = page?.canonicalBytes() ?? discussionPage?.canonicalBytes();
    }
    if (bytes == null ||
        bytes.isEmpty ||
        bytes.length > kSpacePublicFeedObjectMaxBytes) {
      return;
    }
    for (final chunk in chunkSpacePublicFeedObject(
      spaceId: request.spaceId,
      manifestHash: request.manifestHash,
      objectHash: request.objectHash,
      nonce: request.nonce,
      bytes: bytes,
    )) {
      try {
        await send(peer, jsonEncode(chunk.toJson()));
      } catch (_) {
        return;
      }
    }
  }

  /// Holder-side public media gate. This never treats the requester as a
  /// member: the only authority is an exact, still-live verified public
  /// descriptor/feed package that names [SpacePublicMediaGrantRequest.contentId].
  /// Invalid, replayed, unreferenced and unavailable requests are all silent.
  Future<void> handlePublicMediaGrantRequest(
    NodeId peer,
    String requestJson,
  ) async {
    final grant = _owner.grantPublicContentServe;
    if (grant == null) return;
    final SpacePublicMediaGrantRequest? request;
    try {
      request = SpacePublicMediaGrantRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return;
    }
    final nowMs = _owner._now();
    if (request == null ||
        request.requester != peer ||
        !request.isStructurallyValidAt(nowMs)) {
      return;
    }

    _purgePublicFeedTransportState();
    final quota = _owner._publicMediaServeQuotas[peer.hex];
    final currentQuota =
        quota == null ||
            nowMs - quota.windowStartedAtMs >
                kSpacePublicMediaGrantRequestWindow.inMilliseconds
        ? (windowStartedAtMs: nowMs, requests: 0)
        : quota;
    if (currentQuota.requests >=
        GroupService._kPublicMediaServeRequestsPerWindow) {
      return;
    }
    if (_owner._publicMediaServeQuotas.length >=
            GroupService._kMaxPublicMediaServeQuotaIdentities &&
        !_owner._publicMediaServeQuotas.containsKey(peer.hex)) {
      _owner._publicMediaServeQuotas.remove(
        _owner._publicMediaServeQuotas.keys.first,
      );
    }
    _owner._publicMediaServeQuotas[peer.hex] = (
      windowStartedAtMs: currentQuota.windowStartedAtMs,
      requests: currentQuota.requests + 1,
    );
    if (!request.verifyAt(nowMs, peer, _owner._signer.verifyDetached)) return;

    final replayKey = '${peer.hex}:${request.nonce}';
    if (_owner._seenPublicMediaRequests.containsKey(replayKey)) return;
    while (_owner._seenPublicMediaRequests.length >=
        GroupService._kMaxSeenPublicMediaRequests) {
      _owner._seenPublicMediaRequests.remove(
        _owner._seenPublicMediaRequests.keys.first,
      );
    }
    _owner._seenPublicMediaRequests[replayKey] = nowMs;

    final cached = await _owner._loadOrRebuildVerifiedPublicFeed(
      spaceId: request.spaceId,
      descriptorHash: request.descriptorHash,
      manifestHash: request.manifestHash,
    );
    if (cached == null) return;
    final descriptor = cached.descriptor;
    final referenced =
        cached.feed
            .verifiedReferencedContentIds(_owner._signer.verifyDetached)
            .contains(request.contentId) ||
        descriptor.avatarContentId == request.contentId ||
        descriptor.coverContentId == request.contentId;
    if (!referenced) return;

    // The ordinary stream server remains the single byte-serving
    // implementation. Its exact `(peer, CID, TTL)` gate keeps this public
    // capability from becoming a generic stranger or membership permission.
    grant(peer, request.contentId);
  }

  /// Requester-side bounded reassembly. Unsolicited chunks and chunks from a
  /// different authenticated holder never allocate a slot.
  void handlePublicFeedObjectChunk(NodeId peer, String chunkJson) {
    final SpacePublicFeedObjectChunk? chunk;
    try {
      chunk = SpacePublicFeedObjectChunk.fromJson(jsonDecode(chunkJson));
    } catch (_) {
      return;
    }
    if (chunk == null) return;
    _purgePublicFeedTransportState();
    final pending = _owner._pendingPublicFeedObjects[chunk.nonce];
    if (pending == null ||
        pending.holder != peer ||
        pending.spaceId != chunk.spaceId ||
        pending.manifestHash != chunk.manifestHash ||
        pending.objectHash != chunk.objectHash ||
        (pending.count != null && pending.count != chunk.count) ||
        (pending.totalBytes != null &&
            pending.totalBytes != chunk.totalBytes)) {
      return;
    }
    pending.count ??= chunk.count;
    pending.totalBytes ??= chunk.totalBytes;
    if (pending.parts.containsKey(chunk.index)) return;
    pending.parts[chunk.index] = Uint8List.fromList(chunk.data);
    if (pending.parts.length != chunk.count) return;
    final joined = BytesBuilder(copy: false);
    for (var index = 0; index < chunk.count; index++) {
      final part = pending.parts[index];
      if (part == null) return;
      joined.add(part);
    }
    final bytes = joined.toBytes();
    if (bytes.length != chunk.totalBytes) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
      return;
    }
    final hashMatches = chunk.objectHash == chunk.manifestHash
        ? SpacePublicFeedManifest.fromJson(
                _decodePublicFeedObjectJson(bytes),
              )?.manifestHash ==
              chunk.objectHash
        : crypto.sha256.convert(bytes).toString() == chunk.objectHash;
    if (!hashMatches) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
      return;
    }
    if (!pending.completer.isCompleted) pending.completer.complete(bytes);
  }

  /// Request one verified public media object without materializing a fake
  /// membership. The caller must already have fetched and verified this exact
  /// descriptor/feed pair. Every selected holder independently repeats that
  /// reference check before opening its stream gate.
  Future<bool> requestPublicSpaceMedia(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders,
    String contentId,
  ) async {
    final send = _owner.sendPublicMediaGrantRequest;
    if (send == null ||
        (_owner.startPublicContentPullFromAny == null &&
            _owner.startContentPull == null) ||
        !_sharedContentIdPattern.hasMatch(contentId)) {
      return false;
    }
    final nowMs = _owner._now();
    if (!descriptor.verifyAt(nowMs, _owner._signer.verifyDetached)) {
      return false;
    }
    final cached = await _owner._loadOrRebuildVerifiedPublicFeed(
      spaceId: descriptor.spaceId,
      descriptorHash: descriptor.descriptorHash,
      manifestHash: descriptor.publicFeedManifestHash,
    );
    if (cached == null ||
        cached.descriptor.descriptorHash != descriptor.descriptorHash ||
        !(cached.feed
                .verifiedReferencedContentIds(_owner._signer.verifyDetached)
                .contains(contentId) ||
            descriptor.avatarContentId == contentId ||
            descriptor.coverContentId == contentId)) {
      return false;
    }

    final candidates = <String, NodeId>{};
    for (final holder in holders) {
      if (holder.holder == _owner.selfId ||
          holder.spaceId != descriptor.spaceId ||
          holder.descriptorHash != descriptor.descriptorHash ||
          holder.publicFeedManifestHash != descriptor.publicFeedManifestHash ||
          !holder.verifyAt(nowMs, _owner._signer.verifyDetached)) {
        continue;
      }
      candidates[holder.holder.hex] = holder.holder;
      if (candidates.length >= GroupService._kPublicMediaHolderFanout) break;
    }
    if (candidates.isEmpty) return false;

    final requested = <NodeId>[];
    for (final holder in candidates.values) {
      final createdAtMs = _owner._now();
      final unsigned = SpacePublicMediaGrantRequest(
        spaceId: descriptor.spaceId,
        descriptorHash: descriptor.descriptorHash,
        manifestHash: descriptor.publicFeedManifestHash,
        contentId: contentId,
        requester: _owner.selfId,
        requesterPublicKey: _owner._signer.selfPubKey,
        nonce: _freshPublicFeedNonce(),
        createdAtMs: createdAtMs,
      );
      final signed = _owner._signer.signDetached(unsigned.canonicalBytes());
      if (!_listEquals(signed.publicKey, _owner._signer.selfPubKey)) continue;
      final request = unsigned.withSignature(signed.signature);
      if (!request.verifyAt(
        createdAtMs,
        _owner.selfId,
        _owner._signer.verifyDetached,
      )) {
        continue;
      }
      try {
        await send(holder, jsonEncode(request.toJson()));
        requested.add(holder);
      } catch (_) {
        // Try the remaining independently verified holders.
      }
    }
    if (requested.isEmpty) return false;
    if (_owner.contentGrantDelay > Duration.zero) {
      await Future<void>.delayed(_owner.contentGrantDelay);
    }
    final pullAny = _owner.startPublicContentPullFromAny;
    if (pullAny != null) {
      await pullAny(List<NodeId>.unmodifiable(requested), contentId);
    } else {
      await _owner.startContentPull!(requested.first, contentId);
    }
    return true;
  }

  Object? _decodePublicFeedObjectJson(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } catch (_) {
      return null;
    }
  }
}
