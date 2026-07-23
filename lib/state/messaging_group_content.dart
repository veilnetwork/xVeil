part of 'messaging_core.dart';

/// Membership-authorized registration and serving scope for group content.
/// The main service retains transport and storage primitives while this object
/// owns the short-lived grant maps and their public registration workflow.
class _MessagingGroupContent {
  _MessagingGroupContent(this._owner);

  final MessagingService _owner;

  /// Membership-authorized serve grants: `<peerHex>|<cid>` → expiry (ms).
  /// Granted by the group layer after [onGroupContentRequest] authorizes; lets
  /// [_serveStream] serve a NON-contact group member. RAM-only — after a
  /// restart the member's retry re-authorizes.
  final Map<String, int> _groupServeGrants = {};

  /// Receiver-side mirror of the group content authorization: these peers are
  /// current group members that the group layer has just sent a signed fetch
  /// request for THIS cid. It only permits us to attempt a stream; the holder
  /// still independently verifies membership+reference and silently denies the
  /// stream unless [_groupServeGrants] contains the matching requester/cid.
  final Map<String, int> _groupPullSources = {};

  /// Public-feed capability pulls share the content-addressed transport but
  /// never mint membership receipts. Keep their admission scope separate so a
  /// verified public download cannot be misreported as group distribution.
  final Map<String, int> _publicPullSources = {};

  void clear() {
    _groupServeGrants.clear();
    _groupPullSources.clear();
    _publicPullSources.clear();
  }

  /// Persist and send a signed group content-fetch request without opening a
  /// general stranger-send capability. The group binding in [frameId] lets the
  /// durable outbox re-drive this exact request to a co-member.
  Future<void> sendGroupContentRequest(NodeId dst, String requestJson) async {
    GroupContentRequest? request;
    try {
      request = GroupContentRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      // Malformed local request: do not enqueue it.
    }
    if (request == null) return;

    // Authorize the reply path before the request leaves this process. A
    // verified holder answers with a live manifest/ref advertisement; without
    // this receiver-side scope the normal contact gate would drop it before
    // the delayed group pull starts. The holder still verifies membership,
    // the group reference and freshness independently.
    allowGroupPullSources(request.contentId, [dst]);
    final frameId =
        'gcr:${request.groupId.hex}:${request.contentId}:${request.nonce}';
    final wire = WireEnvelope.groupContentRequest(
      requestJson,
    ).withFrameId(frameId).encode();
    await _owner._storage.enqueueOutboxFrame(frameId, dst.hex, wire);
    _owner._outbox.recordQueued(frameId, dst.hex);
    unawaited(() async {
      try {
        await _owner._send(dst, wire);
      } catch (_) {
        // Mailbox copy + outbox re-drive remain authoritative.
      }
    }());
    _owner._stashInBackground(dst, frameId, wire);
  }

  /// Send a completion receipt over the live authenticated transport only.
  ///
  /// Unlike the request this is intentionally never put in the outbox or
  /// mailbox: it is bounded by the holder's in-RAM request challenge and is
  /// diagnostics/proof material, not a user-visible or durable read event.
  Future<void> sendGroupContentReceipt(NodeId dst, String receiptJson) =>
      _owner._send(dst, WireEnvelope.groupContentReceipt(receiptJson).encode());

  /// Allow [peer] to pull [cid] for [ttl] (defaults to the request window).
  void grantGroupContentServe(
    NodeId peer,
    String cid, {
    Duration ttl = const Duration(minutes: 10),
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _groupServeGrants.removeWhere((_, exp) => exp <= now);
    _groupServeGrants['${peer.hex}|$cid'] = now + ttl.inMilliseconds;
    devLog(
      () =>
          'xVeil[content]: group serve GRANTED '
          '${cid.substring(0, cid.length < 12 ? cid.length : 12)} '
          '-> ${peer.short}',
    );
    // A successful signed membership check is also a safe, live holder
    // announcement. Send it only when we really have the verified blob; a
    // non-holder remains completely silent, preserving the no-read-oracle
    // contract. This avoids blind stream opens to every group member (and the
    // native timeout of each offline member) before the requester reaches the
    // one member that downloaded the content.
    unawaited(advertiseGrantedGroupContent(peer, cid));
  }

  Future<void> advertiseGrantedGroupContent(NodeId peer, String cid) async {
    if (!await _owner._storage.hasFile(cid)) return;
    final manifest =
        _owner._serving[cid]?.manifest ??
        await _owner._loadPersistedManifest(cid);
    if (manifest == null || manifest.contentId != cid) return;
    try {
      await _owner._sendGroupContentManifest(
        peer,
        _owner._baseContentManifest(manifest),
      );
      devLog(
        () =>
            'xVeil[content]: group holder announced '
            '${cid.substring(0, cid.length < 12 ? cid.length : 12)} '
            '-> ${peer.short}',
      );
    } catch (e) {
      // Best-effort live hint. The signed request remains durable and the
      // requester retains the blind, content-addressed stream fallback.
      devLog(
        () =>
            'xVeil[content]: group holder announcement failed '
            '${cid.substring(0, cid.length < 12 ? cid.length : 12)} '
            '-> ${peer.short}: $e',
      );
    }
  }

  bool groupServeGranted(NodeId peer, String cid) =>
      (_groupServeGrants['${peer.hex}|$cid'] ?? 0) >
      DateTime.now().millisecondsSinceEpoch;

  void allowGroupPullSources(
    String cid,
    Iterable<NodeId> peers, {
    Duration ttl = const Duration(minutes: 10),
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _groupPullSources.removeWhere((_, exp) => exp <= now);
    final expires = now + ttl.inMilliseconds;
    for (final peer in peers) {
      _groupPullSources['${peer.hex}|$cid'] = expires;
    }
  }

  bool groupPullSourceAllowed(NodeId peer, String cid) =>
      ((_groupPullSources['${peer.hex}|$cid'] ?? 0) >
          DateTime.now().millisecondsSinceEpoch) ||
      ((_publicPullSources['${peer.hex}|$cid'] ?? 0) >
          DateTime.now().millisecondsSinceEpoch);

  void allowPublicPullSources(
    String cid,
    Iterable<NodeId> peers, {
    required Duration ttl,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _publicPullSources.removeWhere((_, exp) => exp <= now);
    final expires = now + ttl.inMilliseconds;
    for (final peer in peers) {
      _publicPullSources['${peer.hex}|$cid'] = expires;
    }
  }

  void clearGroupPullSources(String cid) {
    _groupPullSources.removeWhere((key, _) => key.endsWith('|$cid'));
    _publicPullSources.removeWhere((key, _) => key.endsWith('|$cid'));
  }

  /// Report only sources that were explicitly authorized for this group pull.
  /// Callers invoke this after the complete blob is hash-verified and durable.
  Future<void> reportVerifiedSources(
    String cid,
    Iterable<NodeId> sources,
  ) async {
    final verified = <String, NodeId>{};
    for (final source in sources) {
      if ((_groupPullSources['${source.hex}|$cid'] ?? 0) >
          DateTime.now().millisecondsSinceEpoch) {
        verified[source.hex] = source;
      }
    }
    if (verified.isEmpty) return;
    final callback = _owner.onGroupContentVerifiedSources;
    if (callback == null) return;
    try {
      await callback(cid, Set<NodeId>.unmodifiable(verified.values));
    } catch (e) {
      // The bytes are already verified and persisted. A best-effort
      // observability receipt must never turn that success into a failed
      // download.
      devLog(
        () =>
            'xVeil[content]: verified-source receipt failed '
            '${cid.substring(0, cid.length < 12 ? cid.length : 12)}: $e',
      );
    }
  }

  Future<void> persistRequiredGroupManifest(ContentManifest manifest) async {
    final cid = manifest.contentId;
    // The manifest is what makes the blob/source SERVABLE — a swallowed failure
    // here mints a ref nobody can fetch. Retry the transient first-write failure
    // once, then make the caller refuse to post the group reference.
    final mfBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(manifest.toJson())),
    );
    try {
      await _owner._storage.storeFile('mf:$cid', mfBytes, name: 'manifest');
    } catch (e) {
      devLog(() => 'xVeil[content]: group manifest persist retry after: $e');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _owner._storage.storeFile('mf:$cid', mfBytes, name: 'manifest');
    }
  }

  /// Register in-RAM [bytes] as fetchable group content: the blob goes into
  /// the encrypted file store under its contentId and the manifest under
  /// `mf:<cid>`, so [_serveStream] can serve it to membership-granted members.
  /// Idempotent — the cid is content-derived. Returns the contentId the signed
  /// group message should carry.
  Future<String> registerGroupContent(
    Uint8List bytes, {
    required String name,
  }) async {
    final m = ContentManifest.fromBytes(name, bytes);
    final cid = m.contentId;
    if (!await _owner._storage.hasFile(cid)) {
      await _owner._storage.storeFile(cid, bytes, name: name);
    }
    await persistRequiredGroupManifest(m);
    final previous = _owner._serving[cid];
    if (previous?.source != null) {
      _owner._retireServeSourceForContent(cid, previous!.source!);
    }
    _owner._serving[cid] = (manifest: m, source: null, servedAt: _owner._now());
    _owner._evictServing();
    _owner._ensureContentTimer();
    devLog(
      () =>
          'xVeil[content]: group content registered '
          '${cid.substring(0, 12)} (${bytes.length}B)',
    );
    return cid;
  }

  /// Register arbitrarily large group content directly from the user's source
  /// file. Hashing and later serving are range-based, so RAM is bounded by one
  /// adaptive piece and the cleartext is never copied to a staging file or the
  /// hidden volume. [close] ownership transfers to this service on entry.
  ///
  /// When [sourcePath] is present, the source and hashing parameters are also
  /// recorded so a restart can reopen/revalidate it for a later group pull.
  Future<String> registerGroupContentStreaming(
    String name,
    int size,
    Future<Uint8List> Function(int offset, int length) read, {
    required Future<void> Function() close,
    String? sourcePath,
  }) async {
    if (size <= 0) {
      await close();
      throw ArgumentError.value(size, 'size', 'must be positive');
    }
    final source = (read: read, close: close);
    final ContentManifest manifest;
    try {
      manifest = await ContentManifest.fromReader(
        name: name,
        size: size,
        pieceSize: MessagingService.adaptivePieceSize(size),
        chunkBytes: MessagingService._contentChunkBytes,
        readRange: read,
      );
      await persistRequiredGroupManifest(manifest);
    } catch (_) {
      await close();
      rethrow;
    }
    final cid = manifest.contentId;
    if (sourcePath != null) {
      try {
        await _owner._storage.putSetting(
          'served:$cid',
          jsonEncode({
            'path': sourcePath,
            'size': size,
            'pieceSize': manifest.pieceSize,
            'name': name,
          }),
        );
      } catch (e) {
        // The live source remains valid. This only loses restart durability.
        devLog(
          () =>
              'xVeil[content]: group durable source persist failed for '
              '${cid.substring(0, 12)}: $e',
        );
      }
    }

    final previous = _owner._serving[cid];
    final activePrevious = (_owner._activeStreamServes[cid] ?? 0) > 0
        ? previous?.source
        : null;
    if (activePrevious != null) {
      // Same bytes are already flowing from another handle. Keep that source
      // stable and release the newly-hashed duplicate.
      await close();
      _owner._serving[cid] = (
        manifest: manifest,
        source: activePrevious,
        servedAt: _owner._now(),
      );
    } else {
      if (previous?.source != null &&
          !_owner._sameServeSource(previous!.source!, source)) {
        _owner._retireServeSourceForContent(cid, previous.source!);
      }
      _owner._serving[cid] = (
        manifest: manifest,
        source: source,
        servedAt: _owner._now(),
      );
    }
    _owner._evictServing();
    _owner._ensureContentTimer();
    devLog(
      () =>
          'xVeil[content]: group source registered '
          '${cid.substring(0, 12)} (${manifest.pieceCount} pieces, ${size}B)',
    );
    return cid;
  }

  /// Returns the original user-selected source path only after re-hashing it
  /// against [cid]. A moved or modified plaintext source is never opened under
  /// an old signed media reference.
  Future<String?> verifiedSourcePath(String cid) async {
    final record = _owner._parseServedRecord(
      await _owner._storage.getSetting('served:$cid'),
    );
    if (record == null) return null;
    final manifest = await _owner._rebuildManifestFromServedRecord(cid, record);
    return manifest?.contentId == cid ? record.path : null;
  }

  /// The active (unexpired) grants, for the debug hook / tests.
  List<Map<String, Object>> debugGroupServeGrants() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final e in _groupServeGrants.entries)
        if (e.value > now)
          {
            'peer': e.key.split('|').first,
            'cid': e.key.split('|').last,
            'expiresInMs': e.value - now,
          },
    ];
  }
}
