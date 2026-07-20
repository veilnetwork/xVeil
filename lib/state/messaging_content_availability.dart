part of 'messaging_core.dart';

/// Reoffer and terminal-availability lifecycle for large content.
///
/// The content transfer engine remains responsible for moving and persisting
/// bytes. This collaborator owns the control-plane state which answers stale
/// offers, remembers holders that explicitly said GONE, and turns a fresh
/// manifest back into an obtainable offer.
class _MessagingContentAvailability {
  _MessagingContentAvailability(this._owner);

  final MessagingService _owner;

  /// Per-content peers that explicitly answered GONE in this process session.
  final Map<String, Set<String>> _goneSources = {};

  Future<bool> requestContentReoffer(NodeId peer, String contentId) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    devLog(
      () =>
          'xVeil[content]: requesting manifest re-advertise '
          '${contentId.substring(0, 12)} from ${peer.short}',
    );
    await _owner._send(peer, contentReofferEnvelope(contentId).encode());
    return true;
  }

  Future<bool> resolveContentOfferViaStream(
    NodeId peer,
    String contentId,
  ) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    if (_owner._offered.containsKey(contentId) ||
        _owner._offeredRefs.containsKey(contentId) ||
        await _owner._storage.hasFile(contentId)) {
      return true;
    }
    final manifest = await _owner._fetchManifestFromStream(peer, contentId, [
      peer,
    ]);
    if (manifest == null) return false;
    await _owner._surfaceFileOffer(peer, manifest);
    devLog(
      () =>
          'xVeil[content]: offer stream-materialized '
          '${contentId.substring(0, 12)} <- ${peer.short}',
    );
    _owner._signal();
    return true;
  }

  Future<void> onContentReoffer(NodeId peer, String contentId) async {
    final served = _owner._serving[contentId];
    if (served != null) {
      _owner._serving[contentId] = (
        manifest: served.manifest,
        source: served.source,
        servedAt: _owner._now(),
      );
      devLog(
        () =>
            'xVeil[content]: re-advertising ${contentId.substring(0, 12)} '
            '-> ${peer.short} (live serving)',
      );
      final offer = await _owner._manifestForPeerOffer(peer, served.manifest);
      unawaited(_owner._sendContentManifest(peer, offer));
      return;
    }
    if (_owner.sourceOpener == null) {
      devLog(
        () =>
            'xVeil[content]: reoffer for UNSERVED '
            '${contentId.substring(0, 12)} <- ${peer.short} (no opener — re-send)',
      );
      unawaited(replyContentGone(peer, contentId));
      return;
    }
    try {
      final record = _owner._parseServedRecord(
        await _owner._storage.getSetting('served:$contentId'),
      );
      final manifestBytes = await _owner._storage.loadFile('mf:$contentId');
      if (record == null) {
        devLog(
          () =>
              'xVeil[content]: reoffer ${contentId.substring(0, 12)} — no '
              'durable record <- ${peer.short} (re-send)',
        );
        unawaited(replyContentGone(peer, contentId));
        return;
      }
      ContentManifest? manifest;
      if (manifestBytes != null) {
        manifest = ContentManifest.fromJson(
          jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>,
        );
      }
      // The manifest blob can be the first casualty of an IndexFull store.
      // Rebuild it from the durable source instead of answering false GONE.
      manifest ??= await _owner._rebuildManifestFromServedRecord(
        contentId,
        record,
      );
      if (manifest == null) {
        unawaited(replyContentGone(peer, contentId));
        return;
      }
      final source = await _owner.sourceOpener!(record.path);
      if (source == null) {
        devLog(
          () =>
              'xVeil[content]: reoffer ${contentId.substring(0, 12)} — '
              'source GONE (${record.path}) <- ${peer.short} (re-send)',
        );
        unawaited(replyContentGone(peer, contentId));
        return;
      }
      _owner._serving[contentId] = (
        manifest: manifest,
        source: source,
        servedAt: _owner._now(),
      );
      _owner._evictServing();
      _owner._ensureContentTimer();
      devLog(
        () =>
            'xVeil[content]: re-advertising ${contentId.substring(0, 12)} '
            '-> ${peer.short} (DURABLE — re-opened ${record.path})',
      );
      final offer = await _owner._manifestForPeerOffer(peer, manifest);
      unawaited(_owner._sendContentManifest(peer, offer));
    } catch (error) {
      devLog(
        () =>
            'xVeil[content]: durable reoffer failed for '
            '${contentId.substring(0, 12)}: $error',
      );
    }
  }

  Future<bool> isContentUnavailable(String contentId) async =>
      ((await _owner._storage.getSetting('gone:$contentId')) ?? '').isNotEmpty;

  List<NodeId> filterGoneSources(String contentId, Iterable<NodeId> peers) {
    final gone = _goneSources[contentId];
    if (gone == null || gone.isEmpty) return peers.toList(growable: false);
    return [
      for (final peer in peers)
        if (!gone.contains(peer.hex)) peer,
    ];
  }

  Future<void> onContentGone(NodeId peer, String contentId) async {
    if (contentId.isEmpty) return;
    if (await _owner._storage.hasFile(contentId)) return;
    devLog(
      () =>
          'xVeil[content]: content-GONE '
          '${contentId.substring(0, 12)} <- ${peer.short}',
    );
    (_goneSources[contentId] ??= {}).add(peer.hex);
    _owner._offered[contentId]?.peers.remove(peer.hex);
    _owner._offeredRefs[contentId]?.peers.remove(peer.hex);
    final remaining = filterGoneSources(
      contentId,
      await _owner._contentSourcePeers(preferred: peer, contentId: contentId),
    );
    if (remaining.isNotEmpty) {
      devLog(
        () =>
            'xVeil[content]: ${contentId.substring(0, 12)} still has '
            '${remaining.length} candidate holder(s) — keep trying',
      );
      return;
    }
    await _owner._storage.putSetting(
      'gone:$contentId',
      _owner._now().toIso8601String(),
    );
    _owner._completePendingDownload(contentId);
    final parked = _owner._pendingDownload.remove(contentId);
    _owner._pendingTimers.remove(contentId)?.cancel();
    if (parked != null) unawaited(parked.close());
    await _owner._contentFetching.discard(contentId);
    _owner._fetchSavePath.remove(contentId);
    if (!_owner._contentFailed.isClosed) {
      _owner._contentFailed.add(contentId);
    }
    _owner._signal();
  }

  Future<void> clearContentGone(String contentId) async {
    _goneSources.remove(contentId);
    if (((await _owner._storage.getSetting('gone:$contentId')) ?? '')
        .isNotEmpty) {
      await _owner._storage.putSetting('gone:$contentId', '');
      _owner._signal();
    }
  }

  Future<void> replyContentGone(NodeId peer, String contentId) async {
    try {
      if (await _owner._storage.hasFile(contentId)) return;
      devLog(
        () =>
            'xVeil[content]: reply content-GONE '
            '${contentId.substring(0, 12)} -> ${peer.short}',
      );
      await _owner._send(peer, contentGoneEnvelope(contentId).encode());
    } catch (_) {
      // Best-effort: silence leaves the requester on its timeout fallback.
    }
  }
}
