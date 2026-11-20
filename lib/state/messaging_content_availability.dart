part of 'messaging_core.dart';

typedef _ContentManifestOffer = ({
  ContentManifest manifest,
  Map<String, NodeId> peers,
});

typedef _ContentManifestRefOffer = ({
  _ContentManifestRef ref,
  Map<String, NodeId> peers,
});

typedef _ReofferRequest = ({
  NodeId peer,
  NodeId device,
  String contentId,
  Completer<bool>? receipt,
  bool Function() acceptsReceipt,
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

  /// The DEVICE each holder offered a content id from, when the node named
  /// one: `contentId -> holder identity hex -> device`.
  ///
  /// The bytes live on the device that offered them, and an identity with
  /// several devices publishes its stream address under ONE of them — so a
  /// pull addressed to the identity lands on whichever sibling holds that
  /// slot. Measured on the stand: every pull of a file a second device sent
  /// was answered UNSERVED by the first, 480 times in three attempts.
  final Map<String, Map<String, NodeId>> _holderDevices = {};

  /// Downloads parked until a manifest/ref reappears, or until an already
  /// active encrypted fetch completes and can be exported to this sink.
  final Map<String, _FetchSink?> _pending = {};
  final Map<String, ({Timer timer, Object? saveOwner})> _reofferWaits = {};
  final Set<Future<void>> _pendingCloses = {};

  /// A local send completion only means the reoffer was enqueued. A retry
  /// must give the source time to relearn the requester's authenticated device
  /// before opening a stream which cannot prove that ownership itself.
  final _reofferRequests = <String, _ReofferRequest>{};
  static const _retryReofferInterval = Duration(seconds: 2);
  static const _maxRetryReofferSends = 8;

  void cancelReoffers([String? contentId]) {
    for (final entry in _reofferRequests.entries.toList()) {
      if (contentId != null && entry.value.contentId != contentId) continue;
      _reofferRequests.remove(entry.key);
      final receipt = entry.value.receipt;
      if (receipt != null && !receipt.isCompleted) receipt.complete(false);
    }
  }

  bool confirmRetryReoffer(InboundMessage message, String? frameId) {
    final pending = _reofferRequests[frameId];
    final receipt = pending?.receipt;
    if (pending == null ||
        receipt == null ||
        !pending.acceptsReceipt() ||
        !message.provenance.isAuthenticated ||
        message.src != pending.peer) {
      return false;
    }
    final device = message.srcDevice ?? message.src;
    // Another sibling receiving the family fanout has not restored the proof
    // on the device which actually holds this file. A stale receipt is also
    // insufficient: every request uses a fresh, unpredictable frame id.
    if (pending.device != pending.peer && device != pending.device) {
      return false;
    }
    if (device != pending.peer &&
        !_owner.deviceProofAllowed(pending.peer, device)) {
      return false;
    }
    if (!receipt.isCompleted) receipt.complete(true);
    return true;
  }

  static final Duration _reofferTimeout = Duration(
    milliseconds: const int.fromEnvironment(
      'XVEIL_CONTENT_REOFFER_TIMEOUT_MS',
      defaultValue: 20000,
    ),
  );

  int get offerCount => _offerOrder.length;

  bool hasPending(String contentId) => _pending.containsKey(contentId);

  _FetchSink? takePending(String contentId) {
    _reofferWaits.remove(contentId)?.timer.cancel();
    return _pending.remove(contentId);
  }

  void holdPending(String contentId, _FetchSink? sink) {
    _reofferWaits.remove(contentId)?.timer.cancel();
    final previous = _pending[contentId];
    if (previous != null && previous != sink) _closeLater(previous);
    _pending[contentId] = sink;
  }

  Future<void> discardPending(String contentId) async {
    if (!hasPending(contentId)) return;
    final sink = takePending(contentId);
    if (sink != null) await _close(sink);
  }

  void retireReofferWait(String contentId) {
    final wait = _reofferWaits[contentId];
    if (wait == null) return;
    final sink = takePending(contentId);
    final saveOwner = wait.saveOwner;
    if (saveOwner != null) {
      _owner._forgetFetchSavePath(contentId, owner: saveOwner);
    }
    if (sink != null) _closeLater(sink);
  }

  ContentDownloadResult requestReofferFromAny(
    Iterable<NodeId> peers,
    String contentId,
    _FetchSink? sink,
  ) {
    if (_owner._cancelledDownloads.contains(contentId)) {
      if (sink != null) _closeLater(sink);
      _owner._forgetFetchSavePath(contentId);
      return ContentDownloadResult.noOffer;
    }
    final sources = _owner._uniquePeers(peers);
    if (sources.isEmpty) {
      if (sink != null) _closeLater(sink);
      _owner._forgetFetchSavePath(contentId);
      return ContentDownloadResult.noOffer;
    }
    devLog(
      () =>
          'xVeil[content]: no live manifest for '
          '${contentId.substring(0, 12)} — requesting re-advertise from '
          '${sources.length} source(s)',
    );
    holdPending(contentId, sink);
    final saveOwner = sink == null
        ? null
        : _owner._fetchSavePath[contentId]?.owner;
    var expired = false;
    final timer = Timer(_reofferTimeout, () {
      expired = true;
      if (_owner._cancelledDownloads.contains(contentId)) return;
      retireReofferWait(contentId);
      devLog(
        () =>
            'xVeil[content]: re-advertise TIMED OUT for '
            '${contentId.substring(0, 12)} — sender not serving; re-send needed',
      );
      if (!_owner._contentFailed.isClosed) {
        _owner._contentFailed.add(contentId);
      }
    });
    _reofferWaits[contentId] = (timer: timer, saveOwner: saveOwner);
    for (final peer in sources) {
      unawaited(
        requestContentReoffer(
          peer,
          contentId,
          // One answer can start the pull while the other sources are still
          // preparing. Those offers can still join the download.
          isWanted: () => !expired,
        ).then<void>((_) {}, onError: _reportReofferFailure),
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

  /// Remember that [holder] offered [contentId] from [device].
  void noteHolderDevice(String contentId, NodeId holder, NodeId? device) {
    if (device == null || device == holder) return;
    // Re-inserted, so the newest content id is the last to be evicted.
    final byHolder = _holderDevices.remove(contentId) ?? <String, NodeId>{};
    byHolder[holder.hex] = device;
    _holderDevices[contentId] = byHolder;
    // Bounded like the offers: the oldest mapping goes first.
    while (_holderDevices.length > _maxOffers) {
      _holderDevices.remove(_holderDevices.keys.first);
    }
  }

  /// Where a stream pulling [contentId] from [holder] has to go: the device
  /// that offered it, or the holder itself when no device was named.
  NodeId streamTargetFor(NodeId holder, String contentId) =>
      _holderDevices[contentId]?[holder.hex] ?? holder;

  Future<void> clearSession() async {
    cancelReoffers();
    for (final wait in _reofferWaits.values) {
      wait.timer.cancel();
    }
    _reofferWaits.clear();
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

  Future<bool> requestContentReoffer(
    NodeId peer,
    String contentId, {
    Duration? confirmationTimeout,
    bool Function()? isWanted,
  }) async {
    if (_owner._disposed ||
        _owner._cancelledDownloads.contains(contentId) ||
        _reofferRequests.length >= _maxOffers ||
        isWanted?.call() == false) {
      return false;
    }

    // Register before reading consent so cancel/restart also retires requests
    // suspended in storage. An unconfirmed request keeps its id local.
    final frameId = 'reoffer:${_uuid.v4()}';
    final receipt = confirmationTimeout == null ? null : Completer<bool>();
    final consent = _owner._realtimeControl;
    final epoch = consent._consentEpoch(peer);
    var wasAdmitted = false;
    bool isCurrent() =>
        _reofferRequests.containsKey(frameId) &&
        !_owner._cancelledDownloads.contains(contentId) &&
        consent._consentCurrent(peer, epoch) &&
        isWanted?.call() != false;
    _reofferRequests[frameId] = (
      peer: peer,
      device: streamTargetFor(peer, contentId),
      contentId: contentId,
      receipt: receipt,
      acceptsReceipt: () => wasAdmitted && isCurrent(),
    );
    Timer? retryTimer;
    try {
      if (!identical(await consent._acceptedContactEpoch(peer), epoch) ||
          !isCurrent()) {
        return false;
      }
      devLog(
        () =>
            'xVeil[content]: requesting manifest re-advertise '
            '${contentId.substring(0, 12)} from ${peer.short}',
      );
      final envelope = contentReofferEnvelope(contentId);
      final payload =
          (receipt == null ? envelope : envelope.withFrameId(frameId)).encode();

      Future<bool> send() async {
        if (!isCurrent() || receipt?.isCompleted == true) return false;
        var admitted = false;
        await _owner._send(
          peer,
          payload,
          admitTransport: () {
            admitted = isCurrent() && receipt?.isCompleted != true;
            wasAdmitted = wasAdmitted || admitted;
            return admitted;
          },
        );
        return admitted;
      }

      if (receipt == null) return await send();

      Future<void> sendUntilConfirmed() async {
        for (var attempt = 0; attempt < _maxRetryReofferSends; attempt++) {
          if (receipt.isCompleted) return;
          if ((attempt > 0 &&
                  !identical(
                    await consent._acceptedContactEpoch(peer),
                    epoch,
                  )) ||
              !await send()) {
            if (!receipt.isCompleted) receipt.complete(false);
            return;
          }
          if (receipt.isCompleted || attempt + 1 == _maxRetryReofferSends) {
            return;
          }
          // Reuse the id. A source that already processed it repeats its ACK
          // without rebuilding the manifest.
          final delay = Completer<void>();
          retryTimer = Timer(_retryReofferInterval, delay.complete);
          try {
            await Future.any<void>([
              delay.future,
              receipt.future.then<void>((_) {}),
            ]);
          } finally {
            retryTimer?.cancel();
            retryTimer = null;
          }
        }
      }

      // Timeout covers both local enqueue and the authenticated receipt.
      // Cancellation can leave an already admitted transport call running.
      return await (() async {
        final sent = sendUntilConfirmed();
        await Future.any<void>([
          sent,
          receipt.future.then<void>((confirmed) async {
            // Success still joins this send's ratchet persistence.
            if (confirmed) await sent;
          }),
        ]);
        return await receipt.future && isCurrent();
      })().timeout(confirmationTimeout!, onTimeout: () => false);
    } finally {
      retryTimer?.cancel();
      _reofferRequests.remove(frameId);
      if (receipt != null && !receipt.isCompleted) receipt.complete(false);
    }
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
    await _owner._surfaceFileOffer(peer, manifest, route: 'stream');
    devLog(
      () =>
          'xVeil[content]: offer stream-materialized '
          '${contentId.substring(0, 12)} <- ${peer.short}',
    );
    _owner._signal();
    return true;
  }

  Future<void> onContentReoffer(
    NodeId peer,
    String contentId,
    Object epoch,
  ) async {
    bool isCurrent() => _owner._realtimeControl._consentCurrent(peer, epoch);
    if (!isCurrent()) return;

    try {
      // Find this peer's message before waiting on a file reopen. A failed
      // history read cannot turn an event-backed offer into a bare one.
      final rows = await _owner._storage.loadMessages(peer.hex);
      Message? post;
      for (final row in rows.reversed) {
        if (row.direction == MessageDirection.outgoing &&
            (row.fileContentId ?? row.fileId) == contentId) {
          post = row;
          break;
        }
      }
      final eligibility = post == null
          ? null
          : _StoredPostEligibility(_owner, peer, post);
      final preparation = eligibility?.prepare();
      if (preparation != null) await preparation;
      if (!isCurrent() || eligibility?.canSend == false) return;

      var served = _owner._serving[contentId];
      if (served == null) {
        final restored = await _restoreReofferSource(contentId, isCurrent);
        // A different send can install this content while disk I/O is pending.
        served = _owner._serving[contentId];
        if (restored != null) {
          if (isCurrent() && served == null) {
            served = _owner._serving[contentId] = restored;
            _owner._evictServing();
            _owner._ensureContentTimer();
          } else {
            final opened = restored.source;
            final current = served?.source;
            if (opened != null &&
                (current == null ||
                    !_owner._sameServeSource(opened, current))) {
              await opened.close();
            }
          }
        }
      }
      if (!isCurrent()) return;
      if (served == null) {
        unawaited(replyContentGone(peer, contentId, isCurrent: isCurrent));
        return;
      }
      final record = served.sourceRecord;
      if (record != null &&
          !await _owner._servedSourceStillAuthorized(contentId, record) &&
          !await _owner._storage.hasFile(contentId)) {
        unawaited(replyContentGone(peer, contentId, isCurrent: isCurrent));
        return;
      }
      // A concurrent pull may have only refreshed servedAt. Keep its state,
      // but do not apply an authorization check to a replacement source.
      final current = _owner._serving[contentId];
      if (!isCurrent() || current == null || current.sourceRecord != record) {
        return;
      }
      _owner._serving[contentId] = (
        manifest: current.manifest,
        source: current.source,
        sourceRecord: record,
        servedAt: _owner._now(),
      );

      // The stored manifest can carry another chat's event fields. The
      // content description is shared, but the per-send fields are not.
      final base = _owner._baseContentManifest(current.manifest);
      final offer = post == null
          ? base
          : base.withEvent(
              msgId: post.id,
              author: post.author,
              seq: post.seq,
              ts: post.timestamp.millisecondsSinceEpoch,
              thumbB64: post.thumb,
            );
      final frame = _owner._encodeContentManifest(offer).frame;
      // Keep source readiness and the authenticated receipt independent of
      // the outbound offer's route preparation.
      if (eligibility == null) {
        unawaited(
          _owner
              ._send(peer, frame, admitTransport: isCurrent)
              .catchError(_reportReofferFailure),
        );
      } else {
        unawaited(
          eligibility
              .send(frame, epoch, stopOnReceipt: false)
              .then<void>((_) {}, onError: _reportReofferFailure),
        );
      }
    } catch (error) {
      _reportReofferFailure(error);
    }
  }

  void _reportReofferFailure(Object error) =>
      devLog(() => 'xVeil[content]: reoffer deferred (${error.runtimeType})');

  Future<_ServedContent?> _restoreReofferSource(
    String contentId,
    bool Function() isCurrent,
  ) async {
    var manifest = await _owner._loadPersistedManifest(contentId);
    if (!isCurrent()) return null;
    if (manifest != null && await _owner._storage.hasFile(contentId)) {
      return (
        manifest: manifest,
        source: null,
        sourceRecord: null,
        servedAt: _owner._now(),
      );
    }
    if (_owner.sourceOpener == null || !isCurrent()) return null;
    final record = _owner._parseServedRecord(
      await _owner._storage.getSetting('served:$contentId'),
    );
    if (record == null || !isCurrent()) return null;
    // A full container may have kept the source record but lost the manifest.
    manifest ??= await _owner._rebuildManifestFromServedRecord(
      contentId,
      record,
    );
    if (manifest == null || !isCurrent()) return null;
    final source = await _owner._openVerifiedServedSource(contentId, record);
    if (source == null) return null;
    return (
      manifest: manifest,
      source: source,
      sourceRecord: record,
      servedAt: _owner._now(),
    );
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
    _owner._forgetFetchSavePath(contentId);
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

  Future<void> replyContentGone(
    NodeId peer,
    String contentId, {
    bool Function()? isCurrent,
  }) async {
    if (_owner._disposed || isCurrent?.call() == false) return;
    try {
      if (await _owner._storage.hasFile(contentId)) return;
      devLog(
        () =>
            'xVeil[content]: reply content-GONE '
            '${contentId.substring(0, 12)} -> ${peer.short}',
      );
      await _owner._send(
        peer,
        contentGoneEnvelope(contentId).encode(),
        admitTransport: isCurrent,
      );
    } catch (_) {
      // Best-effort: silence leaves the requester on its timeout fallback.
    }
  }
}
