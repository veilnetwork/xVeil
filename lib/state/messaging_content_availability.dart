part of 'messaging_core.dart';

typedef _ContentManifestOffer = ({
  ContentManifest manifest,
  Map<String, NodeId> peers,
});

typedef _ContentManifestRefOffer = ({
  _ContentManifestRef ref,
  Map<String, NodeId> peers,
});

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

  /// Live manifest handles are deliberately RAM-only; the durable chat event
  /// remains the source of truth across restart. Full manifests and compact
  /// refs share ONE cap so alternating frame kinds cannot double the budget.
  static const _maxOffers = 256;
  final Map<String, _ContentManifestOffer> offered = {};
  final Map<String, _ContentManifestRefOffer> offeredRefs = {};
  final Set<String> _offerOrder = {};

  /// Downloads parked until a manifest/ref reappears, or until an already
  /// active encrypted fetch completes and can be exported to this sink.
  final Map<String, _FetchSink?> _pending = {};
  final Map<String, Timer> _pendingTimers = {};
  final Set<Future<void>> _pendingCloses = {};

  static final Duration _reofferTimeout = Duration(
    milliseconds: const int.fromEnvironment(
      'XVEIL_CONTENT_REOFFER_TIMEOUT_MS',
      defaultValue: 20000,
    ),
  );

  int get offerCount => _offerOrder.length;

  bool hasPending(String contentId) => _pending.containsKey(contentId);

  _FetchSink? takePending(String contentId) {
    _pendingTimers.remove(contentId)?.cancel();
    return _pending.remove(contentId);
  }

  void holdPending(String contentId, _FetchSink? sink) {
    _pendingTimers.remove(contentId)?.cancel();
    final previous = _pending[contentId];
    if (previous != null && previous != sink) _closeLater(previous);
    _pending[contentId] = sink;
  }

  Future<void> discardPending(String contentId) async {
    if (!hasPending(contentId)) return;
    final sink = takePending(contentId);
    if (sink != null) await _close(sink);
  }

  ContentDownloadResult requestReofferFromAny(
    Iterable<NodeId> peers,
    String contentId,
    _FetchSink? sink,
  ) {
    if (_owner._cancelledDownloads.contains(contentId)) {
      if (sink != null) _closeLater(sink);
      _owner._fetchSavePath.remove(contentId);
      return ContentDownloadResult.noOffer;
    }
    final sources = _owner._uniquePeers(peers);
    if (sources.isEmpty) {
      if (sink != null) _closeLater(sink);
      _owner._fetchSavePath.remove(contentId);
      return ContentDownloadResult.noOffer;
    }
    devLog(
      () =>
          'xVeil[content]: no live manifest for '
          '${contentId.substring(0, 12)} — requesting re-advertise from '
          '${sources.length} source(s)',
    );
    holdPending(contentId, sink);
    _pendingTimers[contentId] = Timer(_reofferTimeout, () {
      if (_owner._cancelledDownloads.contains(contentId)) return;
      _pendingTimers.remove(contentId);
      final parked = _pending.remove(contentId);
      if (parked != null) _closeLater(parked);
      _owner._fetchSavePath.remove(contentId);
      devLog(
        () =>
            'xVeil[content]: re-advertise TIMED OUT for '
            '${contentId.substring(0, 12)} — sender not serving; re-send needed',
      );
      if (!_owner._contentFailed.isClosed) {
        _owner._contentFailed.add(contentId);
      }
    });
    for (final peer in sources) {
      unawaited(
        _owner._send(peer, contentReofferEnvelope(contentId).encode()),
      );
    }
    return ContentDownloadResult.requestedReoffer;
  }

  void rememberManifest(NodeId peer, ContentManifest manifest) {
    final contentId = manifest.contentId;
    final existing = offered[contentId];
    offered[contentId] = (
      manifest: manifest,
      peers: {if (existing != null) ...existing.peers, peer.hex: peer},
    );
    // A full verified manifest dominates a compact ref for the same bytes.
    final replacedRef = offeredRefs.remove(contentId) != null;
    if (existing == null || replacedRef) {
      _offerOrder
        ..remove(contentId)
        ..add(contentId);
    }
    _evictOffers();
  }

  void rememberRef(NodeId peer, _ContentManifestRef ref) {
    final contentId = ref.contentId;
    final existing = offeredRefs[contentId];
    offeredRefs[contentId] = (
      ref: ref,
      peers: {if (existing != null) ...existing.peers, peer.hex: peer},
    );
    _offerOrder.add(contentId);
    _evictOffers();
  }

  void removeOfferPeer(String contentId, NodeId peer) {
    offered[contentId]?.peers.remove(peer.hex);
    offeredRefs[contentId]?.peers.remove(peer.hex);
  }

  void forgetOffer(String contentId) {
    offered.remove(contentId);
    offeredRefs.remove(contentId);
    _offerOrder.remove(contentId);
  }

  Future<void> clearSession() async {
    for (final timer in _pendingTimers.values) {
      timer.cancel();
    }
    _pendingTimers.clear();
    final sinks = Set<_FetchSink>.identity();
    for (final sink in _pending.values) {
      if (sink != null) sinks.add(sink);
    }
    _pending.clear();
    _goneSources.clear();
    offered.clear();
    offeredRefs.clear();
    _offerOrder.clear();
    await Future.wait([
      ..._pendingCloses,
      for (final sink in sinks) _close(sink),
    ]);
  }

  void _closeLater(_FetchSink sink) => unawaited(_close(sink));

  Future<void> _close(_FetchSink sink) {
    final pending = _closeQuietly(sink);
    _pendingCloses.add(pending);
    unawaited(pending.whenComplete(() => _pendingCloses.remove(pending)));
    return pending;
  }

  Future<void> _closeQuietly(_FetchSink sink) async {
    try {
      await sink.close();
    } catch (_) {}
  }

  void _evictOffers() {
    while (_offerOrder.length > _maxOffers) {
      final oldest = _offerOrder.first;
      forgetOffer(oldest);
    }
  }

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
    if (offered.containsKey(contentId) ||
        offeredRefs.containsKey(contentId) ||
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
      final source = await _owner._openVerifiedServedSource(contentId, record);
      if (source == null) {
        devLog(
          () =>
              'xVeil[content]: reoffer ${contentId.substring(0, 12)} — '
              'source GONE or CHANGED (${record.path}) <- ${peer.short} '
              '(re-send)',
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
    removeOfferPeer(contentId, peer);
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
    forgetOffer(contentId);
    await _owner._storage.putSetting(
      'gone:$contentId',
      _owner._now().toIso8601String(),
    );
    _owner._completePendingDownload(contentId);
    await discardPending(contentId);
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
