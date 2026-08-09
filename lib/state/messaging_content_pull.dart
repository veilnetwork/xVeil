part of 'messaging_core.dart';

/// Receive-side reliable content transfer.
///
/// Source selection, manifest probing, resumable range/swarm reads, verified
/// fallback and completion live together here. Persistent registries and
/// configuration remain owned by [MessagingService]; this extension only
/// isolates the pull state machine without changing its wire or storage API.
extension _MessagingContentPull on MessagingService {
  List<NodeId> _uniquePeers(Iterable<NodeId> peers) {
    final out = <String, NodeId>{};
    for (final peer in peers) {
      out[peer.hex] = peer;
    }
    return out.values.toList(growable: false);
  }

  List<NodeId> _orderedPullPeers(NodeId first, Iterable<NodeId> peers) {
    return _uniquePeers([first, ...peers]);
  }

  Future<(NodeId, ContentManifest)?> _raceManifestHeaders(
    Iterable<NodeId> peers,
    String cid,
  ) {
    final candidates = _uniquePeers(peers);
    if (candidates.isEmpty) {
      return Future.value(null);
    }
    final result = Completer<(NodeId, ContentManifest)?>();
    var pending = candidates.length;
    void finish(NodeId peer, ContentManifest? manifest) {
      pending--;
      if (manifest != null && !result.isCompleted) {
        result.complete((peer, manifest));
      } else if (pending == 0 && !result.isCompleted) {
        result.complete(null);
      }
    }

    for (final peer in candidates) {
      unawaited(
        _readManifestHeader(peer, cid).then(
          (manifest) => finish(peer, manifest),
          onError: (Object _, StackTrace _) => finish(peer, null),
        ),
      );
    }
    return result.future;
  }

  Future<bool> _eligiblePullSource(NodeId peer, String contentId) async {
    // Never ourselves. A node has no stream to itself worth opening: if we
    // held the bytes we would not be fetching them, so the probe can only
    // fail. It used to, once per retry, forever — a native stream opened and
    // aborted every ~18s against our own id, with the failure buried among
    // real ones in the log.
    if (peer.hex == await _selfHex()) return false;
    final contact = await _storage.getContact(peer);
    return (contact != null && contact.status == ContactStatus.accepted) ||
        _groupPullSourceAllowed(peer, contentId);
  }

  /// The subset of [peers] worth asking for [contentId].
  ///
  /// The manifest race is an optimisation over the serial loop that follows
  /// it, so it must not consider a source that loop would reject — otherwise
  /// the "cheap" parallel probe is the only place an ineligible peer, us
  /// included, still gets contacted.
  Future<List<NodeId>> _eligiblePullSources(
    Iterable<NodeId> peers,
    String contentId,
  ) async {
    final out = <NodeId>[];
    for (final peer in _uniquePeers(peers)) {
      if (await _eligiblePullSource(peer, contentId)) out.add(peer);
    }
    return out;
  }

  NodeId _offerPeer(
    ({ContentManifest manifest, Map<String, NodeId> peers}) offered, {
    required NodeId preferred,
  }) =>
      offered.peers[preferred.hex] ??
      (offered.peers.isNotEmpty ? offered.peers.values.first : preferred);

  List<NodeId> _offerPeers({
    required NodeId preferred,
    required String contentId,
  }) {
    final out = <String, NodeId>{preferred.hex: preferred};
    final offered = _offered[contentId];
    if (offered != null) {
      for (final peer in offered.peers.values) {
        out[peer.hex] = peer;
      }
    }
    final offeredRef = _offeredRefs[contentId];
    if (offeredRef != null) {
      for (final peer in offeredRef.peers.values) {
        out[peer.hex] = peer;
      }
    }
    return out.values.toList(growable: false);
  }

  Future<List<NodeId>> _contentSourcePeers({
    required NodeId preferred,
    required String contentId,
  }) async {
    final out = <String, NodeId>{
      for (final peer in _offerPeers(
        preferred: preferred,
        contentId: contentId,
      ))
        peer.hex: peer,
    };
    for (final peer in await _storedContentSourcePeers(contentId)) {
      out[peer.hex] = peer;
    }
    return _filterGoneSources(contentId, out.values);
  }

  Future<List<NodeId>> _storedContentSourcePeers(String contentId) async {
    final out = <String, NodeId>{};
    try {
      for (final conv in await _storage.loadConversations()) {
        if (!conv.peer.canMessage) continue;
        final hasOffer = (await _storage.loadMessages(conv.id)).any(
          (m) =>
              m.direction == MessageDirection.incoming &&
              (m.fileContentId == contentId || m.fileId == contentId),
        );
        if (hasOffer) out[conv.peer.nodeId.hex] = conv.peer.nodeId;
      }
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: stored source scan failed '
            '${contentId.substring(0, 12)}: $e',
      );
    }
    return out.values.toList(growable: false);
  }

  Future<bool> _pullStream(
    NodeId peer,
    String cid,
    _FetchSink? sink, {
    String? savedPath,
    Iterable<NodeId> retryPeers = const [],
  }) async {
    final peers = _orderedPullPeers(peer, retryPeers);
    for (final candidate in peers) {
      final stream = await _openInitialPullStream(candidate, cid);
      if (stream == null) continue;
      final runPeers = _orderedPullPeers(candidate, peers);
      _contentStreams.runPull(() async {
        await _runPull(
          candidate,
          cid,
          sink,
          stream,
          savedPath,
          retryPeers: runPeers,
        );
      });
      return true;
    }
    return false; // no circuit → caller falls back
  }

  Future<bool?> _pullStreamToCompletion(
    NodeId peer,
    String cid, {
    _FetchSink? sink,
    String? savedPath,
    bool closeSinkOnFailure = true,
  }) async {
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    return _runPull(
      peer,
      cid,
      sink,
      stream,
      savedPath,
      emitFailure: false,
      closeSinkOnFailure: closeSinkOnFailure,
    );
  }

  Future<bool> _pullSwarmStream(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    Iterable<NodeId> peers,
  ) async {
    if (_transport is! StreamTransport) {
      return false;
    }
    if (!_streamRangeEnabled || manifest.pieceCount < 2) {
      devLog(
        () =>
            'xVeil[content]: swarm-range disabled '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      return _pullStream(preferred, cid, null, retryPeers: peers);
    }
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    if (sources.isEmpty) return false;
    if (sources.length < 2 &&
        !_explicitRangeFanout &&
        !await _hasStoredPiece(manifest)) {
      // ONE source and a FRESH download: a single whole-file stream beats the
      // range swarm — ranges pay per-stream opens + manifest rounds + a fresh
      // congestion ramp each (measured 64 MiB device A/B: sequential
      // 11.2-13.7s vs ranged p4 14-21s / p1 23-100s), and the sequential pull
      // already resumes at piece granularity on retry. The range swarm still
      // wins when it can fan out over DIFFERENT holders, and still handles a
      // PARTIALLY stored blob (it skips locally verified pieces; the
      // sequential stream would re-fetch them). An explicit
      // XVEIL_STREAM_RANGE_PARALLELISM keeps forcing the swarm path.
      devLog(
        () =>
            'xVeil[content]: swarm-range single-source '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      if (await _pullStream(preferred, cid, null, retryPeers: peers)) {
        return true;
      }
      // No stream could be opened RIGHT NOW (route flap at tap time). The
      // range swarm keeps retrying opens with backoff, so fall through to it
      // instead of degrading to the datagram path.
    }
    _contentStreams.runPull(
      () => _runSwarmPullThenFallback(preferred, cid, manifest, sources),
    );
    return true;
  }

  /// True if ANY piece of [manifest] is already in the blob store (a partial
  /// earlier download). Cheap for a fresh download: every lookup misses and
  /// the first stored piece short-circuits.
  Future<bool> _hasStoredPiece(ContentManifest manifest) async {
    final cid = manifest.contentId;
    for (var i = 0; i < manifest.pieceCount; i++) {
      final len = manifest.pieceLength(i);
      final existing = await _storage.readFileRange(
        cid,
        i * manifest.pieceSize,
        len,
      );
      if (existing != null && existing.length == len) return true;
    }
    return false;
  }

  Future<bool> _pullSwarmStreamToFile(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    Iterable<NodeId> peers,
    _FetchSink sink,
    String savedPath,
  ) async {
    if (_transport is! StreamTransport) {
      return false;
    }
    if (!_streamRangeEnabled || manifest.pieceCount < 2) {
      devLog(
        () =>
            'xVeil[content]: swarm-range-to-file disabled '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      return _pullStream(
        preferred,
        cid,
        sink,
        savedPath: savedPath,
        retryPeers: peers,
      );
    }
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    if (sources.isEmpty) return false;
    // A RESUME (sink.read != null) MUST take the range path even for one
    // source: only the range swarm hash-verifies pieces off disk and skips the
    // ones already written. The sequential stream would re-fetch from byte 0,
    // defeating the resume.
    final isResume = sink.read != null;
    if (sources.length < 2 && !_explicitRangeFanout && !isResume) {
      // See _pullSwarmStream: one source → sequential whole-file stream (a FRESH
      // sink download has no partially stored pieces to skip). Falls through to
      // the range swarm when no stream opens right now.
      devLog(
        () =>
            'xVeil[content]: swarm-range-to-file single-source '
            '${cid.substring(0, 12)}, using sequential stream',
      );
      if (await _pullStream(
        preferred,
        cid,
        sink,
        savedPath: savedPath,
        retryPeers: peers,
      )) {
        return true;
      }
    }
    _contentStreams.runPull(
      () => _runSwarmFileThenFallback(
        preferred,
        cid,
        manifest,
        sources,
        sink,
        savedPath,
      ),
    );
    return true;
  }

  Future<List<NodeId>> _eligibleStreamSources(
    Iterable<NodeId> peers, {
    required String contentId,
  }) async {
    final accepted = <String, NodeId>{};
    for (final peer in peers) {
      if (!await _eligiblePullSource(peer, contentId)) continue;
      accepted[peer.hex] = peer;
    }
    return accepted.values.toList(growable: false);
  }

  NodeId _offerRefPeer(
    ({_ContentManifestRef ref, Map<String, NodeId> peers}) offered, {
    required NodeId preferred,
  }) =>
      offered.peers[preferred.hex] ??
      (offered.peers.isNotEmpty ? offered.peers.values.first : preferred);

  Future<ContentManifest?> _fetchManifestFromRef(
    NodeId preferred,
    String cid,
    _ContentManifestRef ref,
    Iterable<NodeId> peers,
  ) async {
    final sources = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    for (final peer in sources) {
      final m = await _readManifestOnly(peer, cid, ref);
      if (m == null) continue;
      _rememberOfferedManifest(peer, m);
      return m;
    }
    return null;
  }

  Future<ContentManifest?> _readManifestOnly(
    NodeId peer,
    String cid,
    _ContentManifestRef ref,
  ) async {
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    var gracefulClose = false;
    try {
      final req = _streamRequest(cid, offset: ref.size);
      await Future<void>.delayed(_streamOpenWriteGrace);
      await stream.write(req).timeout(_streamRequestTimeout);
      final lenB = await MessagingService._readExactly(
        stream,
        4,
      ).timeout(MessagingService._streamManifestTimeout, onTimeout: () => null);
      if (lenB == null) throw StateError('no stream manifest');
      final mfLen = MessagingService._readU32be(lenB);
      if (mfLen <= 0 || mfLen > (1 << 20)) {
        throw StateError('bad stream manifest len');
      }
      final mfBytes = await MessagingService._readExactly(
        stream,
        mfLen,
      ).timeout(MessagingService._streamManifestTimeout, onTimeout: () => null);
      if (mfBytes == null) throw StateError('stream manifest truncated');
      final m = ContentManifest.fromJson(
        jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
      );
      if (m == null ||
          m.contentId != cid ||
          m.size != ref.size ||
          m.name != ref.name) {
        throw StateError('stream manifest does not bind advertised ref');
      }
      devLog(
        () =>
            'xVeil[content]: manifest stream-resolved '
            '${cid.substring(0, 12)} pieces=${m.pieceCount} '
            'piece_size=${m.pieceSize} <- ${peer.short}',
      );
      gracefulClose = true;
      return m;
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: manifest stream-resolve failed '
            '${cid.substring(0, 12)} <- ${peer.short}: $e',
      );
      return null;
    } finally {
      try {
        if (gracefulClose) {
          await stream.close();
        } else {
          await stream.abort();
        }
      } catch (_) {}
    }
  }

  Future<ContentManifest?> _fetchManifestFromStream(
    NodeId preferred,
    String cid,
    Iterable<NodeId> peers,
  ) async {
    final sourceList = await _eligibleStreamSources(
      _orderedPullPeers(preferred, peers),
      contentId: cid,
    );
    // Race the first few, then fall back to one at a time.
    //
    // Asking each holder in turn and waiting it out costs the full first-byte
    // bound per dead one — up to 8 s, measured at 2.6 s on a live transfer
    // where the announcing device could not serve and the next one could. That
    // wait is pure latency: the answer was one hop away the whole time.
    //
    // Bounded on purpose. Racing EVERY candidate is what the sibling path does,
    // but a probe opens a stream, and the comment on `_readManifestHeader` is
    // explicit that one can perturb the shared onion driver — so the fan-out
    // stays small and the long tail stays sequential.
    final sources = sourceList.toList(growable: false);
    final fanned = sources.take(_manifestProbeFanout);
    final raced = await _raceManifestHeaders(fanned, cid);
    if (raced != null) {
      _rememberOfferedManifest(raced.$1, raced.$2);
      return raced.$2;
    }
    for (final peer in sources.skip(_manifestProbeFanout)) {
      final m = await _readManifestHeader(peer, cid);
      if (m == null) continue;
      _rememberOfferedManifest(peer, m);
      return m;
    }
    return null;
  }

  /// How many holders a manifest probe asks at once before going one by one.
  ///
  /// Small: each one opens a stream, and the win is already taken by the second
  /// candidate — a dead first holder is the case this exists for, not a swarm.
  static const _manifestProbeFanout = 3;

  Future<ContentManifest?> _readManifestHeader(NodeId peer, String cid) async {
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    var gracefulClose = false;
    try {
      // Ask for the smallest possible payload after the manifest so the sender
      // can finish this probe cleanly. A length of 0 means "stream the whole
      // content" in the serve path; closing immediately after the manifest then
      // trips a noisy write-failure and can perturb the shared onion driver.
      final req = _streamRequest(cid, length: 1);
      await Future<void>.delayed(_streamOpenWriteGrace);
      await stream.write(req).timeout(_streamRequestTimeout);
      // First-byte stall: a source that never sends the length prefix is dead —
      // abandon it fast (the shorter of the two bounds) so the caller tries the
      // next holder rather than eating the full 25s cap on one silent peer.
      final firstByteTimeout =
          streamManifestFirstByteTimeout <
              MessagingService._streamManifestTimeout
          ? streamManifestFirstByteTimeout
          : MessagingService._streamManifestTimeout;
      final lenB = await MessagingService._readExactly(
        stream,
        4,
      ).timeout(firstByteTimeout, onTimeout: () => null);
      if (lenB == null) throw StateError('no stream manifest');
      final mfLen = MessagingService._readU32be(lenB);
      if (mfLen <= 0 || mfLen > (1 << 20)) {
        throw StateError('bad stream manifest len');
      }
      final mfBytes = await MessagingService._readExactly(
        stream,
        mfLen,
      ).timeout(MessagingService._streamManifestTimeout, onTimeout: () => null);
      if (mfBytes == null) throw StateError('stream manifest truncated');
      final m = ContentManifest.fromJson(
        jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
      );
      if (m == null || m.contentId != cid) {
        throw StateError('stream manifest does not bind requested content');
      }
      if (m.size > 0) {
        await MessagingService._readExactly(stream, 1).timeout(
          MessagingService._streamManifestTimeout,
          onTimeout: () => null,
        );
      }
      devLog(
        () =>
            'xVeil[content]: manifest stream-probed '
            '${cid.substring(0, 12)} pieces=${m.pieceCount} '
            'piece_size=${m.pieceSize} <- ${peer.short}',
      );
      gracefulClose = true;
      return m;
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: manifest stream-probe failed '
            '${cid.substring(0, 12)} <- ${peer.short}: $e',
      );
      return null;
    } finally {
      try {
        if (gracefulClose) {
          await stream.close();
        } else {
          await stream.abort();
        }
      } catch (_) {}
    }
  }

  void _rememberOfferedManifest(NodeId peer, ContentManifest manifest) {
    _contentAvailability.rememberManifest(peer, manifest);
  }

  Future<bool> _beginDownloadWithManifest(
    NodeId peer,
    String cid,
    ContentManifest manifest,
    _FetchSink? sink,
    String? savedPath,
  ) async {
    final retryPeers = await _contentSourcePeers(
      preferred: peer,
      contentId: cid,
    );
    if (sink != null) {
      if (_plainFileStream &&
          await _pullSwarmStreamToFile(
            peer,
            cid,
            manifest,
            retryPeers,
            sink,
            savedPath ?? cid,
          )) {
        return true;
      }
      await _beginFetch(peer, manifest, sink: sink);
      return true;
    }
    if (await _pullSwarmStream(peer, cid, manifest, retryPeers)) return true;
    if (await _pullStream(peer, cid, null, retryPeers: retryPeers)) return true;
    await _beginFetch(peer, manifest);
    return true;
  }

  Future<bool> _beginFetchFromManifestRef(
    NodeId peer,
    String cid,
    _ContentManifestRef ref,
    _FetchSink? sink,
    String? savedPath,
  ) async {
    final offeredRef = _offeredRefs[cid];
    final sources = _uniquePeers([
      peer,
      if (offeredRef != null) ...offeredRef.peers.values,
      ...await _storedContentSourcePeers(cid),
    ]);
    if (await _pipelinedPullToFile(peer, cid, sink, savedPath, sources)) {
      return true;
    }
    final m = await _fetchManifestFromRef(peer, cid, ref, sources);
    if (m == null) return false;
    return _beginDownloadWithManifest(peer, cid, m, sink, savedPath);
  }

  Future<bool> _beginFetchFromStreamManifest(
    NodeId peer,
    String cid,
    _FetchSink? sink, {
    String? savedPath,
    Iterable<NodeId> peers = const [],
  }) async {
    if (await _pipelinedPullToFile(peer, cid, sink, savedPath, peers)) {
      return true;
    }
    final m = await _fetchManifestFromStream(peer, cid, peers);
    if (m == null) return false;
    return _beginDownloadWithManifest(peer, cid, m, sink, savedPath);
  }

  /// PIPELINE: a plain-file download that would use ONE sequential stream
  /// anyway skips the standalone manifest probe (open + request + manifest +
  /// close ≈ two serialized onion RTTs before any payload) and goes straight
  /// to the pull stream — the serve path sends the manifest as the stream
  /// header, and that manifest self-authenticates against the requested
  /// contentId ([ContentManifest.isSelfConsistent] re-derives the id), so the
  /// probe adds no verification the pull itself lacks. Applies only when the
  /// swarm cannot be used anyway (range disabled) or would not be chosen
  /// (single accepted holder, no explicit fanout); sink downloads have no
  /// locally stored pieces the swarm could skip. Returns false → caller runs
  /// the classic probe-then-swarm path (which also retries opens).
  Future<bool> _pipelinedPullToFile(
    NodeId peer,
    String cid,
    _FetchSink? sink,
    String? savedPath,
    Iterable<NodeId> peers,
  ) async {
    if (sink == null ||
        !_plainFileStream ||
        _explicitRangeFanout ||
        _transport is! StreamTransport) {
      return false;
    }
    final streamSources = await _eligibleStreamSources(
      _orderedPullPeers(peer, peers),
      contentId: cid,
    );
    if (streamSources.isEmpty) return false;
    if (_streamRangeEnabled && streamSources.length > 1) return false;
    if (!await _pullStream(
      streamSources.first,
      cid,
      sink,
      savedPath: savedPath,
      retryPeers: streamSources,
    )) {
      return false; // no stream right now → probing path retries with backoff
    }
    devLog(
      () =>
          'xVeil[content]: manifest+data pipelined '
          '${cid.substring(0, 12)} -> ${streamSources.first.short} '
          '(sequential pull, probe round skipped)',
    );
    return true;
  }

  Future<void> _resumePendingFromManifestRef(
    NodeId peer,
    String cid,
    _ContentManifestRef ref,
  ) async {
    if (!_contentAvailability.hasPending(cid)) return;
    final m = await _fetchManifestFromRef(peer, cid, ref, [peer]);
    if (m == null || !_contentAvailability.hasPending(cid)) return;
    final sink = _contentAvailability.takePending(cid);
    devLog(
      () =>
          'xVeil[content]: manifest ref resolved for '
          '${cid.substring(0, 12)} — resuming the parked download',
    );
    await _beginDownloadWithManifest(peer, cid, m, sink, _fetchSavePath[cid]);
  }

  Future<void> _runSwarmPullThenFallback(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    List<NodeId> peers,
  ) async {
    if (await _pullSwarmPiecesToCompletion(peers, manifest) ||
        await _storage.hasFile(cid)) {
      return;
    }
    if (_cancelledDownloads.contains(cid)) return;
    devLog(
      () =>
          'xVeil[content]: swarm-range failed ${cid.substring(0, 12)}, '
          'falling back to sequential stream',
    );
    final fallbackPeers = _orderedPullPeers(preferred, [
      ...peers,
      ...await _contentSourcePeers(preferred: preferred, contentId: cid),
    ]);
    for (final peer in fallbackPeers) {
      final contact = await _storage.getContact(peer);
      if (contact == null || contact.status != ContactStatus.accepted) continue;
      final ok = await _pullStreamToCompletion(peer, cid);
      if (ok == true || await _storage.hasFile(cid)) return;
      if (_cancelledDownloads.contains(cid)) return;
    }
    final ok = await _pullStreamToCompletion(preferred, cid);
    if (ok == true || await _storage.hasFile(cid)) return;
    if (!_cancelledDownloads.contains(cid) && !_contentFailed.isClosed) {
      _contentFailed.add(cid);
    }
  }

  Future<void> _runSwarmFileThenFallback(
    NodeId preferred,
    String cid,
    ContentManifest manifest,
    List<NodeId> peers,
    _FetchSink sink,
    String savedPath,
  ) async {
    var ok = false;
    try {
      ok = await _pullSwarmPiecesToCompletion(
        peers,
        manifest,
        sink: sink,
        savedPath: savedPath,
      );
      if (ok) return;
      if (_cancelledDownloads.contains(cid)) return;
      devLog(
        () =>
            'xVeil[content]: swarm-range-to-file failed '
            '${cid.substring(0, 12)}, falling back to sequential stream',
      );
      final fallbackPeers = _orderedPullPeers(preferred, [
        ...peers,
        ...await _contentSourcePeers(preferred: preferred, contentId: cid),
      ]);
      for (final peer in fallbackPeers) {
        final contact = await _storage.getContact(peer);
        if (contact == null || contact.status != ContactStatus.accepted) {
          continue;
        }
        ok =
            await _pullStreamToCompletion(
              peer,
              cid,
              sink: sink,
              savedPath: savedPath,
              closeSinkOnFailure: false,
            ) ==
            true;
        if (ok) return;
        if (_cancelledDownloads.contains(cid)) return;
      }
    } finally {
      if (!ok) {
        try {
          await sink.close();
        } catch (_) {}
        if (!_cancelledDownloads.contains(cid) && !_contentFailed.isClosed) {
          _contentFailed.add(cid);
        }
      }
    }
  }

  Future<bool> _pullSwarmPiecesToCompletion(
    Iterable<NodeId> peers,
    ContentManifest manifest, {
    _FetchSink? sink,
    String? savedPath,
  }) async {
    _pullStarted(manifest.contentId);
    try {
      return await _pullSwarmPiecesToCompletionInner(
        peers,
        manifest,
        sink: sink,
        savedPath: savedPath,
      );
    } finally {
      _pullEnded(manifest.contentId);
    }
  }

  Future<bool> _pullSwarmPiecesToCompletionInner(
    Iterable<NodeId> peers,
    ContentManifest manifest, {
    _FetchSink? sink,
    String? savedPath,
  }) async {
    final cid = manifest.contentId;
    if (_cancelledDownloads.contains(cid)) return false;
    unawaited(_persistManifestIfPending(manifest));
    if (_transport is! StreamTransport ||
        !_streamRangeEnabled ||
        manifest.pieceCount < 2) {
      return false;
    }
    final initialPeers = peers.toList(growable: false);
    final sourceMap = <String, NodeId>{};

    Future<int> refreshSources() async {
      final before = sourceMap.length;
      final offered = _offered[cid];
      final accepted = await _eligibleStreamSources([
        ...initialPeers,
        if (offered != null) ...offered.peers.values,
        ...await _storedContentSourcePeers(cid),
      ], contentId: cid);
      for (final peer in accepted) {
        sourceMap[peer.hex] = peer;
      }
      final added = sourceMap.length - before;
      if (added > 0 && before > 0) {
        devLog(
          () =>
              'xVeil[content]: swarm-range sources refreshed '
              '${cid.substring(0, 12)} +$added -> ${sourceMap.length}',
        );
      }
      return added;
    }

    await refreshSources();
    if (sourceMap.isEmpty) return false;
    List<NodeId> sourceList() => sourceMap.values.toList(growable: false);

    final pending = <int>[];
    final completed = <int>{};
    var completedBytes = 0;
    // A RESUME reopen of a plain file provides a reader; read each piece back
    // off disk and hash-verify it (mirror of the encrypted-tier skip below), so
    // a restart re-pulls only the MISSING pieces instead of the whole file. A
    // fresh download / encrypted tier: sink.read is null → nothing to skip.
    final sinkRead = sink?.read;
    for (var i = 0; i < manifest.pieceCount; i++) {
      final len = manifest.pieceLength(i);
      final Uint8List? existing;
      if (sink == null) {
        existing = await _storage.readFileRange(
          cid,
          i * manifest.pieceSize,
          len,
        );
      } else if (sinkRead != null) {
        existing = await sinkRead(i * manifest.pieceSize, len);
      } else {
        existing = null;
      }
      if (existing != null &&
          existing.length == len &&
          manifest.verifyPiece(i, existing)) {
        completed.add(i);
        completedBytes += len;
      } else {
        pending.add(i);
      }
    }

    if (!_contentProgress.isClosed && completedBytes > 0) {
      _contentProgress.add((
        contentId: cid,
        done: completedBytes.clamp(0, manifest.size).toInt(),
        total: manifest.size,
      ));
    }
    if (pending.isEmpty) {
      if (!await _storage.hasFile(cid)) return false;
      if (!await _finishReceived(
        sourceList().first,
        manifest,
        null,
        null,
        verifiedSources: const <NodeId>[],
      )) {
        return false;
      }
      if (!_contentProgress.isClosed) {
        _contentProgress.add((
          contentId: cid,
          done: manifest.size,
          total: manifest.size,
        ));
      }
      return true;
    }

    final workerCount = pending.length < _streamRangeParallelism
        ? pending.length
        : _streamRangeParallelism;
    final attempts = List<int>.filled(manifest.pieceCount, 0);
    int maxAttemptsPerPiece() {
      final sourceCount = sourceMap.length;
      final minAttemptsPerPiece = sourceCount < 3 ? 3 : sourceCount;
      return _streamPullMaxAttempts < minAttemptsPerPiece
          ? minAttemptsPerPiece
          : _streamPullMaxAttempts;
    }

    var failed = false;
    NodeId? completionPeer;
    ContentManifest? completionManifest;
    final verifiedSources = <String, NodeId>{};
    Future<void> sinkWriteTail = Future<void>.value();

    Future<void> writePiece(int pieceIndex, Uint8List piece) {
      if (sink == null) {
        return _storage.storeFilePiece(
          cid,
          pieceIndex,
          manifest.pieceCount,
          manifest.pieceSize,
          manifest.size,
          piece,
          name: manifest.name,
        );
      }
      final offset = pieceIndex * manifest.pieceSize;
      final next = sinkWriteTail.then((_) => sink.write(offset, piece));
      // The UI/soak callers use one RandomAccessFile with setPosition+write.
      // Serialize those writes here so parallel network pulls do not race the
      // file cursor.
      sinkWriteTail = next.catchError((_) {});
      return next;
    }

    var adaptiveRangeTargetBytes = _streamRangeTargetBytes;
    var successfulBytesSinceRangeGrow = 0;
    const rangeGrowAfterBytes = 8 * 1024 * 1024;
    // Keep the production default conservative (p8), but make explicit
    // speed-test overrides literal. Otherwise a requested
    // `XVEIL_STREAM_RANGE_PARALLELISM=12` silently starts at p8 and never
    // exceeds p10, which hides whether the native route/circuit fixes can
    // actually sustain higher fanout.
    final explicitRangeFanout = _streamRangeParallelismDartDefine > 0;
    final maxAdaptiveWorkerLimit = explicitRangeFanout
        ? workerCount
        : (workerCount < MessagingService._defaultStreamRangeParallelism + 2
              ? workerCount
              : MessagingService._defaultStreamRangeParallelism + 2);
    var adaptiveWorkerLimit = explicitRangeFanout
        ? workerCount
        : (workerCount < MessagingService._defaultStreamRangeParallelism
              ? workerCount
              : MessagingService._defaultStreamRangeParallelism);
    var activeRangeWorkers = 0;
    var successfulBytesSinceFanoutGrow = 0;
    var consecutiveRangeFailures = 0;
    const fanoutGrowAfterBytes = 16 * 1024 * 1024;
    Future<void> rangeOpenTail = Future<void>.value();

    Future<void> paceRangeStreamOpen() {
      final previous = rangeOpenTail;
      final gate = Completer<void>();
      rangeOpenTail = gate.future;
      return previous.catchError((_) {}).then((_) async {
        if (MessagingService._streamRangeOpenPace > Duration.zero) {
          await Future<void>.delayed(MessagingService._streamRangeOpenPace);
        }
        gate.complete();
      });
    }

    final beforeStreamOpen =
        MessagingService._streamRangeOpenPace > Duration.zero
        ? paceRangeStreamOpen
        : null;

    void noteRangeFailure(List<int> pieces) {
      successfulBytesSinceRangeGrow = 0;
      successfulBytesSinceFanoutGrow = 0;
      consecutiveRangeFailures++;
      if (adaptiveWorkerLimit > 1 &&
          (adaptiveWorkerLimit >
                  MessagingService._defaultStreamRangeParallelism ||
              consecutiveRangeFailures >= 3)) {
        final previousLimit = adaptiveWorkerLimit;
        adaptiveWorkerLimit--;
        consecutiveRangeFailures = 0;
        devLog(
          () =>
              'xVeil[content]: swarm-range adapt fanout '
              '${cid.substring(0, 12)} workers=$previousLimit'
              '->$adaptiveWorkerLimit after failure '
              'failed_pieces=${pieces.length}',
        );
      }
      final minTarget = manifest.pieceSize < _streamRangeTargetBytes
          ? manifest.pieceSize
          : _streamRangeTargetBytes;
      if (adaptiveRangeTargetBytes <= minTarget) return;
      final previous = adaptiveRangeTargetBytes;
      var next = adaptiveRangeTargetBytes ~/ 2;
      if (next < minTarget) next = minTarget;
      adaptiveRangeTargetBytes = next;
      devLog(
        () =>
            'xVeil[content]: swarm-range adapt shrink '
            '${cid.substring(0, 12)} target_bytes=$previous'
            '->$adaptiveRangeTargetBytes failed_pieces=${pieces.length}',
      );
    }

    void noteRangeSuccess(int bytes) {
      consecutiveRangeFailures = 0;
      if (adaptiveWorkerLimit < maxAdaptiveWorkerLimit) {
        successfulBytesSinceFanoutGrow += bytes;
        if (successfulBytesSinceFanoutGrow >= fanoutGrowAfterBytes) {
          final previousLimit = adaptiveWorkerLimit;
          adaptiveWorkerLimit++;
          successfulBytesSinceFanoutGrow = 0;
          devLog(
            () =>
                'xVeil[content]: swarm-range adapt fanout '
                '${cid.substring(0, 12)} workers=$previousLimit'
                '->$adaptiveWorkerLimit after ${fanoutGrowAfterBytes}B ok',
          );
        }
      }
      if (adaptiveRangeTargetBytes >= _streamRangeTargetBytes) return;
      successfulBytesSinceRangeGrow += bytes;
      if (successfulBytesSinceRangeGrow < rangeGrowAfterBytes) return;
      final previous = adaptiveRangeTargetBytes;
      var next = adaptiveRangeTargetBytes * 2;
      if (next > _streamRangeTargetBytes) next = _streamRangeTargetBytes;
      adaptiveRangeTargetBytes = next;
      successfulBytesSinceRangeGrow = 0;
      devLog(
        () =>
            'xVeil[content]: swarm-range adapt grow '
            '${cid.substring(0, 12)} target_bytes=$previous'
            '->$adaptiveRangeTargetBytes',
      );
    }

    ({List<int> pieces, NodeId peer, int bytes})? takeRange() {
      if (_cancelledDownloads.contains(cid) || failed || pending.isEmpty) {
        return null;
      }
      final sources = sourceList();
      if (sources.isEmpty) {
        failed = true;
        return null;
      }
      final first = pending.removeAt(0);
      final firstAttempt = attempts[first];
      if (firstAttempt >= maxAttemptsPerPiece()) {
        failed = true;
        return null;
      }
      final pieces = <int>[first];
      var rangeBytes = manifest.pieceLength(first);
      var nextPiece = first + 1;
      while (nextPiece < manifest.pieceCount) {
        final pendingIndex = pending.indexOf(nextPiece);
        if (pendingIndex < 0) break;
        final nextLen = manifest.pieceLength(nextPiece);
        if (pieces.isNotEmpty &&
            rangeBytes + nextLen > adaptiveRangeTargetBytes) {
          break;
        }
        if (attempts[nextPiece] >= maxAttemptsPerPiece()) {
          failed = true;
          return null;
        }
        pending.removeAt(pendingIndex);
        pieces.add(nextPiece);
        rangeBytes += nextLen;
        nextPiece++;
      }
      for (final piece in pieces) {
        attempts[piece]++;
      }
      return (
        pieces: List<int>.unmodifiable(pieces),
        peer: sources[(first + firstAttempt) % sources.length],
        bytes: rangeBytes,
      );
    }

    Future<void> requeueAll(List<int> pieces) async {
      await refreshSources();
      for (final piece in pieces) {
        if (attempts[piece] >= maxAttemptsPerPiece()) {
          failed = true;
          return;
        }
      }
      for (final piece in pieces) {
        if (!completed.contains(piece)) {
          pending.add(piece);
        }
      }
    }

    // Swarm-wide payload progress tick plus per-task last-chunk tracking. The
    // tick lets an individual range reader distinguish "everything is quiet"
    // (global route churn — keep the long idle timeout) from "only MY stream is
    // quiet" (stalled route — abandon early and resume on a fresh stream). The
    // per-task stopwatches let tail hedging pick the quietest in-flight range.
    var swarmPayloadTick = 0;
    int swarmTick() => swarmPayloadTick;
    final activeTasks = <_ActiveRangeTask>{};
    var activeHedges = 0;

    void emitProgress() {
      if (_contentProgress.isClosed) return;
      _contentProgress.add((
        contentId: cid,
        done: completedBytes.clamp(0, manifest.size).toInt(),
        total: manifest.size,
      ));
    }

    void recordPulled(
      ({NodeId peer, ContentManifest manifest, List<int> pieces}) pulled,
    ) {
      completionPeer = pulled.peer;
      completionManifest = pulled.manifest;
      verifiedSources[pulled.peer.hex] = pulled.peer;
      for (final piece in pulled.pieces) {
        if (!completed.add(piece)) continue;
        completedBytes += manifest.pieceLength(piece);
      }
      emitProgress();
    }

    _ActiveRangeTask? takeHedge() {
      if (activeHedges >= MessagingService._maxStreamRangeHedges) return null;
      _ActiveRangeTask? best;
      for (final task in activeTasks) {
        if (task.hedges > 0) continue;
        if (task.lastChunk.elapsed < _streamRangeHedgeAfter) continue;
        if (best == null || task.lastChunk.elapsed > best.lastChunk.elapsed) {
          best = task;
        }
      }
      if (best == null) return null;
      best.hedges++;
      return best;
    }

    Future<void> runHedge(_ActiveRangeTask hedge) async {
      final pieces = hedge.pieces
          .where((piece) => !completed.contains(piece))
          .toList(growable: false);
      if (pieces.isEmpty) return;
      activeHedges++;
      activeRangeWorkers++;
      var hedgeBytes = 0;
      for (final piece in pieces) {
        hedgeBytes += manifest.pieceLength(piece);
      }
      devLog(
        () =>
            'xVeil[content]: swarm-range hedge ${cid.substring(0, 12)} '
            'p${pieces.first}..${pieces.last} '
            'silent=${hedge.lastChunk.elapsed.inMilliseconds}ms',
      );
      try {
        final pulled = await _pullPieceRangeToStorage(
          hedge.peer,
          manifest,
          pieces,
          writePiece: writePiece,
          beforeStreamOpen: beforeStreamOpen,
          swarmTick: swarmTick,
          onPayloadChunk: () => swarmPayloadTick++,
        );
        // A failed hedge is not a transfer failure: the original worker still
        // owns the range's retry/requeue budget, so do not shrink the adaptive
        // fanout for it either.
        if (pulled == null) return;
        noteRangeSuccess(hedgeBytes);
        recordPulled(pulled);
      } finally {
        activeRangeWorkers--;
        activeHedges--;
      }
    }

    Future<void> worker(int index) async {
      while (!_disposed && !_cancelledDownloads.contains(cid) && !failed) {
        while (!_disposed &&
            !_cancelledDownloads.contains(cid) &&
            !failed &&
            activeRangeWorkers >= adaptiveWorkerLimit) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final task = takeRange();
        if (task == null) {
          if (_disposed || _cancelledDownloads.contains(cid) || failed) return;
          if (completed.length >= manifest.pieceCount) return;
          if (pending.isNotEmpty) continue; // requeue raced takeRange
          // Tail: every remaining piece is in flight on another worker. Hedge
          // the quietest range on a fresh stream instead of exiting, so one
          // stalled route cannot pin the transfer until its idle timeout.
          final hedge = takeHedge();
          if (hedge != null) {
            await runHedge(hedge);
            continue;
          }
          if (activeTasks.isEmpty) return;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        final tracked = _ActiveRangeTask(task.pieces, task.peer);
        activeTasks.add(tracked);
        activeRangeWorkers++;
        ({NodeId peer, ContentManifest manifest, List<int> pieces})? pulled;
        try {
          pulled = await _pullPieceRangeToStorage(
            task.peer,
            manifest,
            task.pieces,
            writePiece: writePiece,
            beforeStreamOpen: beforeStreamOpen,
            swarmTick: swarmTick,
            onPayloadChunk: () {
              swarmPayloadTick++;
              tracked.lastChunk
                ..reset()
                ..start();
            },
          );
        } finally {
          activeRangeWorkers--;
          activeTasks.remove(tracked);
        }
        if (pulled == null) {
          if (task.pieces.every(completed.contains)) {
            // A hedge finished this range while the original attempt was
            // failing — nothing to requeue and no failure to adapt on.
            continue;
          }
          noteRangeFailure(task.pieces);
          await requeueAll(task.pieces);
          final nextDelayAttempt = task.pieces.fold<int>(
            0,
            (maxAttempt, piece) =>
                attempts[piece] > maxAttempt ? attempts[piece] : maxAttempt,
          );
          await Future<void>.delayed(
            MessagingService._streamPullRetryDelay(nextDelayAttempt),
          );
          continue;
        }
        noteRangeSuccess(task.bytes);
        recordPulled(pulled);
      }
    }

    devLog(
      () =>
          'xVeil[content]: swarm-range start ${cid.substring(0, 12)} '
          'pieces=${manifest.pieceCount} workers=$workerCount '
          'active_limit=$adaptiveWorkerLimit '
          'target_bytes=$_streamRangeTargetBytes '
          'open_pace_ms=${MessagingService._streamRangeOpenPace.inMilliseconds} '
          'sources=${sourceMap.length} resume=${completed.length} '
          'attempts_per_piece=${maxAttemptsPerPiece()}',
    );
    await Future.wait<void>([for (var i = 0; i < workerCount; i++) worker(i)]);
    if (_cancelledDownloads.contains(cid) ||
        failed ||
        completed.length < manifest.pieceCount ||
        (sink == null && !await _storage.hasFile(cid))) {
      devLog(
        () =>
            'xVeil[content]: swarm-range incomplete '
            '${cid.substring(0, 12)} completed=${completed.length}/'
            '${manifest.pieceCount} failed=$failed',
      );
      return false;
    }
    if (!await _finishReceived(
      completionPeer ?? sourceList().first,
      completionManifest ?? manifest,
      sink,
      savedPath,
      verifiedSources: verifiedSources.values,
    )) {
      return false;
    }
    if (!_contentProgress.isClosed) {
      _contentProgress.add((
        contentId: cid,
        done: manifest.size,
        total: manifest.size,
      ));
    }
    return true;
  }

  Future<({NodeId peer, ContentManifest manifest, List<int> pieces})?>
  _pullPieceRangeToStorage(
    NodeId peer,
    ContentManifest expected,
    List<int> pieceIndices, {
    required Future<void> Function(int pieceIndex, Uint8List piece) writePiece,
    Future<void> Function()? beforeStreamOpen,
    int Function()? swarmTick,
    void Function()? onPayloadChunk,
  }) async {
    final cid = expected.contentId;
    if (pieceIndices.isEmpty) return null;
    final pieces = pieceIndices.toList(growable: false);
    final firstPiece = pieces.first;
    final lastPiece = pieces.last;
    final offset = firstPiece * expected.pieceSize;
    var rangeLen = 0;
    for (final piece in pieces) {
      rangeLen += expected.pieceLength(piece);
    }
    if (beforeStreamOpen != null) await beforeStreamOpen();
    final stream = await _openInitialPullStream(peer, cid);
    if (stream == null) return null;
    ReliableStream? current = stream;
    var failed = false;
    try {
      final pulled = await _readRangePayloadResumable(
        peer,
        expected,
        current,
        offset: offset,
        rangeLen: rangeLen,
        firstPiece: firstPiece,
        lastPiece: lastPiece,
        beforeStreamOpen: beforeStreamOpen,
        swarmTick: swarmTick,
        onPayloadChunk: onPayloadChunk,
      );
      current = null; // consumed/closed by _readRangePayloadResumable
      final m = pulled.manifest;
      final range = pulled.bytes;
      var cursor = 0;
      final verifiedPieces = <({int index, Uint8List bytes})>[];
      for (final pieceIndex in pieces) {
        final pieceLen = expected.pieceLength(pieceIndex);
        final piece = Uint8List.sublistView(range, cursor, cursor + pieceLen);
        if (!expected.verifyPiece(pieceIndex, piece)) {
          throw StateError('piece $pieceIndex failed verify');
        }
        verifiedPieces.add((index: pieceIndex, bytes: piece));
        cursor += pieceLen;
      }
      for (final piece in verifiedPieces) {
        await writePiece(piece.index, piece.bytes);
      }
      return (peer: peer, manifest: m, pieces: pieces);
    } catch (e) {
      failed = true;
      devLog(
        () =>
            'xVeil[content]: swarm-range piece failed '
            '${cid.substring(0, 12)} p$firstPiece..$lastPiece '
            '<- ${peer.short}: $e',
      );
      return null;
    } finally {
      try {
        if (failed) {
          await current?.abort();
        } else {
          await current?.close();
        }
      } catch (_) {}
    }
  }

  /// Await one payload chunk while watching for a per-stream stall.
  ///
  /// The underlying FFI read blocks a worker isolate until data arrives or the
  /// stream is aborted, so the read future cannot be cancelled directly. This
  /// polls the same future in short slices and throws when either the full
  /// [idle] window elapses ([TimeoutException], same semantics as before) or
  /// the swarm made progress elsewhere while this stream stayed silent for at
  /// least [stallAfter] ([_RangeStallTimeout]); the caller then aborts the
  /// stream, which releases the blocked read.

  Future<({ContentManifest manifest, Uint8List bytes})>
  _readRangePayloadResumable(
    NodeId peer,
    ContentManifest expected,
    ReliableStream initialStream, {
    required int offset,
    required int rangeLen,
    required int firstPiece,
    required int lastPiece,
    Future<void> Function()? beforeStreamOpen,
    int Function()? swarmTick,
    void Function()? onPayloadChunk,
  }) async {
    final cid = expected.contentId;
    final idle =
        _streamPayloadIdleTimeout <
            MessagingService._streamRangePayloadIdleTimeout
        ? _streamPayloadIdleTimeout
        : MessagingService._streamRangePayloadIdleTimeout;
    final out = BytesBuilder(copy: false);
    ContentManifest? manifest;
    ReliableStream? current = initialStream;
    var got = 0;
    Object? lastError;
    for (
      var attempt = 1;
      got < rangeLen &&
          attempt <= _streamPullMaxAttempts &&
          !_disposed &&
          !_cancelledDownloads.contains(cid);
      attempt++
    ) {
      final startGot = got;
      try {
        if (current == null && beforeStreamOpen != null) {
          await beforeStreamOpen();
        }
        current ??= await _openRetryStream(
          peer,
          cid,
          attempt,
          timeout: MessagingService._streamRangeRetryOpenTimeout,
        );
        if (current == null) throw StateError('range retry-open unavailable');
        final remaining = rangeLen - got;
        final resumeOffset = offset + got;
        final req = _streamRequest(
          cid,
          offset: resumeOffset,
          length: remaining,
        );
        // veil_anon_stream_open returns once the local stream FSM exists; on the
        // datagram-backed anonymous stream the peer accept can trail by a few
        // milliseconds. A tiny grace before the first DATA frame avoids the
        // observed open/accept/no-request race without affecting bulk throughput.
        await Future<void>.delayed(_streamOpenWriteGrace);
        await current.write(req).timeout(_streamRequestTimeout);
        final lenB = await MessagingService._readExactly(current, 4).timeout(
          MessagingService._streamManifestTimeout,
          onTimeout: () => null,
        );
        if (lenB == null) throw StateError('no manifest (sender not serving)');
        final mfLen = MessagingService._readU32be(lenB);
        if (mfLen <= 0 || mfLen > (1 << 20)) {
          throw StateError('bad manifest len');
        }
        final mfBytes = await MessagingService._readExactly(current, mfLen)
            .timeout(
              MessagingService._streamManifestTimeout,
              onTimeout: () => null,
            );
        if (mfBytes == null) throw StateError('manifest truncated');
        final m = ContentManifest.fromJson(
          jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
        );
        if (m == null ||
            m.contentId != cid ||
            m.size != expected.size ||
            m.pieceSize != expected.pieceSize ||
            m.pieceCount != expected.pieceCount) {
          throw StateError('manifest does not bind requested piece range');
        }
        final previous = manifest;
        if (previous != null &&
            (previous.size != m.size ||
                previous.pieceSize != m.pieceSize ||
                previous.pieceCount != m.pieceCount ||
                previous.contentId != m.contentId)) {
          throw StateError('manifest changed across range resume');
        }
        manifest ??= m;
        _bulkStreamLog(
          () =>
              'xVeil[content]: swarm-range payload '
              '${cid.substring(0, 12)} p$firstPiece..$lastPiece '
              '<- ${peer.short} (${got > 0 ? 'resume=$got/' : ''}$rangeLen)',
        );
        final silence = Stopwatch()..start();
        var tickAtLastChunk = swarmTick?.call() ?? 0;
        while (got < rangeLen) {
          final nextRemaining = rangeLen - got;
          final maxBytes = nextRemaining < MessagingService._streamReadChunk
              ? nextRemaining
              : MessagingService._streamReadChunk;
          final chunk = await MessagingService._awaitPayloadChunk(
            current.read(maxBytes: maxBytes),
            idle: idle,
            stallAfter: _streamRangeStallAbandon,
            silence: silence,
            tickAtLastChunk: tickAtLastChunk,
            swarmTick: swarmTick,
            timeoutLabel: (reason) =>
                'pieces $firstPiece..$lastPiece $reason after $got/$rangeLen',
          );
          if (chunk.isEmpty) {
            throw StateError(
              'pieces $firstPiece..$lastPiece EOF after $got/$rangeLen',
            );
          }
          out.add(chunk);
          got += chunk.length;
          onPayloadChunk?.call();
          silence
            ..reset()
            ..start();
          tickAtLastChunk = swarmTick?.call() ?? 0;
        }
      } catch (e) {
        lastError = e;
        if (got > startGot || got > 0) {
          devLog(
            () =>
                'xVeil[content]: swarm-range resume '
                '${cid.substring(0, 12)} p$firstPiece..$lastPiece '
                '<- ${peer.short} got=$got/$rangeLen after: $e',
          );
        }
        try {
          await current?.abort();
        } catch (_) {}
        current = null;
        // A zero-byte attempt normally means "sender not serving this range" —
        // fail the range so the swarm can requeue it elsewhere. A stall
        // abandon is different: the swarm was demonstrably progressing while
        // this stream sat on a bad route, so retry in place on a fresh stream
        // even before the first payload byte.
        if ((got <= 0 && e is! _RangeStallTimeout) ||
            attempt >= _streamPullMaxAttempts ||
            _disposed ||
            _cancelledDownloads.contains(cid)) {
          break;
        }
        if (_disposed || _cancelledDownloads.contains(cid)) break;
        await Future<void>.delayed(
          MessagingService._streamPullRetryDelay(attempt),
        );
      }
    }
    try {
      await current?.close();
    } catch (_) {}
    if (got < rangeLen) {
      throw lastError ??
          StateError(
            'pieces $firstPiece..$lastPiece incomplete $got/$rangeLen',
          );
    }
    final m = manifest;
    if (m == null) throw StateError('range completed without manifest');
    return (manifest: m, bytes: out.takeBytes());
  }

  Future<ReliableStream?> _openInitialPullStream(
    NodeId peer,
    String cid,
  ) async {
    if (_disposed || _cancelledDownloads.contains(cid)) return null;
    final t = _transport;
    if (t is! StreamTransport) return null;
    final sw = Stopwatch()..start();
    final useP2P =
        _p2pStreamsEnabled &&
        !_anonymous &&
        t is P2PStreamTransport &&
        await _p2pStreamAllowed(peer);
    _bulkStreamLog(
      () =>
          'xVeil[content]: stream-open ${cid.substring(0, 12)} '
          '-> ${peer.short} (${useP2P ? 'p2p' : 'anon'})',
    );
    final slowLog = Timer(const Duration(seconds: 5), () {
      devLog(
        () =>
            'xVeil[content]: stream-open still pending '
            '${cid.substring(0, 12)} -> ${peer.short} '
            '(${sw.elapsedMilliseconds}ms)',
      );
    });
    ReliableStream? stream;
    try {
      if (useP2P) {
        stream = await _contentStreams.awaitOpen(
          (t as P2PStreamTransport).openP2PStream(peer),
        );
      }
      if (_disposed || _contentStreams.closing) return null;
      stream ??= await _contentStreams.awaitOpen(
        (t as StreamTransport).openStream(peer),
      );
    } finally {
      slowLog.cancel();
    }
    if (stream == null) {
      devLog(
        () =>
            'xVeil[content]: stream-open unavailable '
            '${cid.substring(0, 12)} -> ${peer.short} '
            '(${sw.elapsedMilliseconds}ms), using datagram fallback',
      );
      return null;
    }
    if (_cancelledDownloads.contains(cid)) {
      await stream.abort();
      return null;
    }
    _bulkStreamLog(
      () =>
          'xVeil[content]: stream-open ok ${cid.substring(0, 12)} '
          '-> ${peer.short} (${sw.elapsedMilliseconds}ms, '
          '${useP2P && stream != null ? 'p2p-or-fallback' : 'anon'})',
    );
    return _trackPullStream(cid, stream);
  }

  Future<bool> _runPull(
    NodeId peer,
    String cid,
    _FetchSink? sink,
    ReliableStream initialStream,
    String? savedPath, {
    bool emitFailure = true,
    Iterable<NodeId> retryPeers = const [],
    bool closeSinkOnFailure = true,
  }) async {
    if (_cancelledDownloads.contains(cid)) {
      await initialStream.abort();
      return false;
    }
    var ok = false;
    Object? lastError;
    ReliableStream? stream = initialStream;
    final peers = _orderedPullPeers(peer, retryPeers);
    // `_streamPullMaxAttempts` protects a single-source transfer from retrying
    // forever, but a group/swarm transfer may know more holders than that cap.
    // Give every known holder at least one stream attempt; after that, cycle up
    // to the configured retry budget.
    final maxAttempts = _streamPullMaxAttempts < peers.length
        ? peers.length
        : _streamPullMaxAttempts;
    ContentManifest? resumeManifest;
    var resumePiece = 0;
    _pullStarted(cid);
    try {
      for (
        var attempt = 1;
        attempt <= maxAttempts &&
            !_disposed &&
            !_cancelledDownloads.contains(cid);
        attempt++
      ) {
        var payloadStarted = false;
        var readBytes = 0;
        var committedPieces = 0;
        Timer? manifestWait;
        final attemptStream = stream;
        stream = null;
        ReliableStream? current;
        final attemptPeer = attemptStream != null
            ? peer
            : peers[(attempt - 1) % peers.length];
        var attemptFailed = false;
        try {
          current =
              attemptStream ??
              await _openRetryStream(attemptPeer, cid, attempt);
          if (current == null) {
            throw StateError('stream retry-open unavailable');
          }
          devLog(
            () =>
                'xVeil[content]: stream-pull request '
                '${cid.substring(0, 12)} -> ${attemptPeer.short} '
                '(attempt $attempt)',
          );
          final resumeFrom = resumeManifest;
          final resumeOffset = resumeFrom == null
              ? 0
              : (resumePiece * resumeFrom.pieceSize)
                    .clamp(0, resumeFrom.size)
                    .toInt();
          // The sender consumes the whole fixed-size request frame. The first
          // 32 bytes are contentId; bytes 32..40 carry an optional big-endian
          // resume offset; bytes 40..48 carry an optional requested length.
          // Keep this first write to a single onion-stream cell: padding this
          // to several cells created a request burst before payload pacing had
          // a chance to smooth the transfer.
          final req = _streamRequest(cid, offset: resumeOffset);
          await Future<void>.delayed(_streamOpenWriteGrace);
          await current.write(req).timeout(_streamRequestTimeout);
          devLog(
            () =>
                'xVeil[content]: stream-pull request sent '
                '${cid.substring(0, 12)} -> ${attemptPeer.short} '
                '(${req.length}B'
                '${resumeOffset > 0 ? ', resume=$resumeOffset' : ''}, '
                'attempt $attempt)',
          );
          manifestWait = Timer(const Duration(seconds: 5), () {
            devLog(
              () =>
                  'xVeil[content]: stream-pull waiting manifest '
                  '${cid.substring(0, 12)} <- ${attemptPeer.short} '
                  '(attempt $attempt)',
            );
          });
          // First-byte stall (length prefix): a sender that never emits the
          // 4-byte manifest length is not serving on this stream — the request
          // never landed (flaky/stale first circuit) or the serve source is
          // absent. Abandon it on the SHORTER bound so we retry-open (a fresh
          // circuit, often a different route) fast instead of eating the full
          // 25s cap on a silent first attempt — device-observed as ~25s "долго
          // перед скачиванием" before attempt 2 succeeds. Once the length
          // prefix arrives the manifest BODY keeps the full timeout (patient
          // once bytes actually flow). Mirrors the probe path (_readManifestHeader).
          final firstByteTimeout =
              streamManifestFirstByteTimeout <
                  MessagingService._streamManifestTimeout
              ? streamManifestFirstByteTimeout
              : MessagingService._streamManifestTimeout;
          final lenB = await MessagingService._readExactly(
            current,
            4,
          ).timeout(firstByteTimeout, onTimeout: () => null);
          manifestWait.cancel();
          manifestWait = null;
          if (lenB == null) {
            throw StateError('no manifest (sender not serving)');
          }
          final mfLen = MessagingService._readU32be(lenB);
          if (mfLen <= 0 || mfLen > (1 << 20)) {
            throw StateError('bad manifest len');
          }
          final mfBytes = await MessagingService._readExactly(current, mfLen)
              .timeout(
                MessagingService._streamManifestTimeout,
                onTimeout: () => null,
              );
          if (mfBytes == null) throw StateError('manifest truncated');
          final m = ContentManifest.fromJson(
            jsonDecode(utf8.decode(mfBytes)) as Map<String, dynamic>,
          );
          if (m == null || m.contentId != cid) {
            throw StateError('manifest does not bind the requested cid');
          }
          final previous = resumeManifest;
          if (previous != null &&
              (previous.size != m.size ||
                  previous.pieceSize != m.pieceSize ||
                  previous.pieceCount != m.pieceCount ||
                  previous.contentId != m.contentId)) {
            throw StateError('manifest changed across resume');
          }
          resumeManifest ??= m;
          unawaited(_persistManifestIfPending(m));
          final startPiece = resumeOffset > 0
              ? (resumeOffset ~/ m.pieceSize).clamp(0, m.pieceCount)
              : 0;
          readBytes = (startPiece * m.pieceSize).clamp(0, m.size).toInt();
          payloadStarted = true;
          devLog(
            () =>
                'xVeil[content]: stream-pull ${cid.substring(0, 12)} '
                '(${m.size}B, ${m.pieceCount} pieces) <- ${attemptPeer.short} '
                '(attempt $attempt'
                '${readBytes > 0 ? ', resume=$readBytes' : ''})',
          );
          if (!_contentProgress.isClosed) {
            _contentProgress.add((
              contentId: cid,
              done: readBytes,
              total: m.size,
            ));
          }
          var lastProgressBytes = readBytes;
          var lastProgressMs = 0;
          final progressSw = Stopwatch()..start();
          const minProgressBytes = 1024 * 1024; // avoid UI backpressure
          const minProgressMs = 1000;
          void emitReadProgress() {
            if (_contentProgress.isClosed || m.size <= 0) return;
            final elapsedMs = progressSw.elapsedMilliseconds;
            if (readBytes < m.size &&
                readBytes - lastProgressBytes < minProgressBytes &&
                elapsedMs - lastProgressMs < minProgressMs) {
              return;
            }
            final visibleDone = readBytes < m.size ? readBytes : m.size - 1;
            _contentProgress.add((
              contentId: cid,
              done: visibleDone,
              total: m.size,
            ));
            lastProgressBytes = readBytes;
            lastProgressMs = elapsedMs;
          }

          final buf = BytesBuilder(copy: false);
          var bufLen = 0;
          for (var pi = startPiece; pi < m.pieceCount; pi++) {
            final pieceLen = m.pieceLength(pi);
            while (bufLen < pieceLen) {
              final chunk = await current
                  .read(maxBytes: MessagingService._streamReadChunk)
                  .timeout(
                    _streamPayloadIdleTimeout,
                    onTimeout: () => throw TimeoutException(
                      'payload idle after $readBytes/${m.size}B',
                      _streamPayloadIdleTimeout,
                    ),
                  );
              if (chunk.isEmpty) throw StateError('stream EOF mid-piece $pi');
              buf.add(chunk);
              bufLen += chunk.length;
              readBytes = (readBytes + chunk.length).clamp(0, m.size).toInt();
              emitReadProgress();
            }
            final acc = buf.takeBytes(); // clears buf
            final piece = acc.length == pieceLen
                ? acc
                : Uint8List.sublistView(acc, 0, pieceLen);
            if (!m.verifyPiece(pi, piece)) {
              throw StateError('piece $pi failed verify');
            }
            if (sink != null) {
              await sink.write(pi * m.pieceSize, piece);
            } else {
              await _storage.storeFilePiece(
                cid,
                pi,
                m.pieceCount,
                m.pieceSize,
                m.size,
                piece,
                name: m.name,
              );
            }
            committedPieces++;
            if (acc.length > pieceLen) {
              buf.add(Uint8List.sublistView(acc, pieceLen));
              bufLen = acc.length - pieceLen;
            } else {
              bufLen = 0;
            }
          }
          if (_cancelledDownloads.contains(cid) ||
              !await _finishReceived(attemptPeer, m, sink, savedPath)) {
            lastError = StateError('download finalization failed');
            break;
          }
          ok = true;
          if (!_contentProgress.isClosed) {
            _contentProgress.add((contentId: cid, done: m.size, total: m.size));
          }
          break;
        } catch (e) {
          attemptFailed = true;
          lastError = e;
          if (payloadStarted && committedPieces > 0) {
            final completed = (resumePiece + committedPieces)
                .clamp(
                  0,
                  resumeManifest?.pieceCount ?? resumePiece + committedPieces,
                )
                .toInt();
            if (completed > resumePiece) {
              resumePiece = completed;
              final m = resumeManifest;
              final resumeBytes = m == null
                  ? 0
                  : (resumePiece * m.pieceSize).clamp(0, m.size).toInt();
              devLog(
                () =>
                    'xVeil[content]: stream-pull resume point '
                    '${cid.substring(0, 12)} piece=$resumePiece '
                    'offset=$resumeBytes after attempt $attempt',
              );
            }
          }
          devLog(
            () =>
                'xVeil[content]: stream-pull attempt $attempt failed '
                '${cid.substring(0, 12)}: $e',
          );
          if (attempt == maxAttempts ||
              _disposed ||
              _cancelledDownloads.contains(cid)) {
            break;
          }
        } finally {
          manifestWait?.cancel();
          try {
            if (attemptFailed) {
              await current?.abort();
            } else {
              await current?.close();
            }
          } catch (_) {}
        }

        await Future<void>.delayed(
          MessagingService._streamPullRetryDelay(attempt),
        );
      }
    } finally {
      _pullEnded(cid);
      if (!ok && lastError != null) {
        devLog(
          () =>
              'xVeil[content]: stream-pull failed '
              '${cid.substring(0, 12)}: $lastError',
        );
      }
      if (!ok &&
          !_cancelledDownloads.contains(cid) &&
          sink != null &&
          closeSinkOnFailure) {
        try {
          await sink.close();
        } catch (_) {}
        _fetchSavePath.remove(cid);
      }
      if (!ok &&
          !_cancelledDownloads.contains(cid) &&
          emitFailure &&
          !_contentFailed.isClosed) {
        _contentFailed.add(cid);
      }
    }
    return ok;
  }

  Future<ReliableStream?> _openRetryStream(
    NodeId peer,
    String cid,
    int attempt, {
    Duration? timeout,
  }) async {
    if (_disposed || _cancelledDownloads.contains(cid)) return null;
    final t = _transport;
    if (t is! StreamTransport) return null;
    final streamTransport = t as StreamTransport;
    final useP2P =
        _p2pStreamsEnabled &&
        !_anonymous &&
        t is P2PStreamTransport &&
        await _p2pStreamAllowed(peer);
    devLog(
      () =>
          'xVeil[content]: stream-pull retry-open '
          '${cid.substring(0, 12)} -> ${peer.short} '
          '(attempt $attempt, ${useP2P ? 'p2p' : 'anon'})',
    );
    try {
      ReliableStream? stream;
      if (useP2P) {
        stream = await _contentStreams.awaitOpen(
          (t as P2PStreamTransport).openP2PStream(peer),
          timeout: timeout ?? _streamRequestTimeout,
        );
      }
      if (_disposed || _contentStreams.closing) return null;
      stream ??= await _contentStreams.awaitOpen(
        streamTransport.openStream(peer),
        timeout: timeout ?? _streamRequestTimeout,
      );
      if (stream == null) return null;
      if (_cancelledDownloads.contains(cid)) {
        await stream.abort();
        return null;
      }
      return _trackPullStream(cid, stream);
    } catch (e) {
      devLog(
        () =>
            'xVeil[content]: stream-pull retry-open failed '
            '${cid.substring(0, 12)} -> ${peer.short}: $e',
      );
      return null;
    }
  }

  ReliableStream _trackPullStream(String contentId, ReliableStream stream) {
    return _contentStreams.trackPull(contentId, stream);
  }

  Future<bool> _finishReceived(
    NodeId peer,
    ContentManifest m,
    _FetchSink? sink,
    String? savedPath, {
    Iterable<NodeId>? verifiedSources,
  }) async {
    final ackId = m.msgId ?? m.contentId;
    final actualSources = verifiedSources ?? <NodeId>[peer];
    final groupScoped = actualSources.any(
      (source) => _groupPullSourceAllowed(source, m.contentId),
    );
    if (sink != null) {
      try {
        await sink.close();
      } catch (e) {
        devLog(
          () =>
              'xVeil[content]: plaintext close failed '
              '${m.contentId.substring(0, 12)} -> $savedPath: $e',
        );
        if (!_contentFailed.isClosed) _contentFailed.add(m.contentId);
        return false;
      }
      if (savedPath != null) {
        try {
          await _storage.putSetting('saved:${m.contentId}', savedPath);
          // Serve the saved plaintext back on demand (content-addressed): the
          // ORIGINAL SENDER can recover a file they deleted, and any accepted
          // holder can re-seed. Mirrors the sender's serve-from-source model —
          // persist the manifest + the serve path so a stream request / reoffer
          // reopens the file. If the user later moves or deletes this plain
          // file, the reopen fails and the peer gets an honest content-GONE.
          await _persistServeManifest(m);
          // JSON record with the hashing params, so a missing mf: blob
          // (IndexFull) can be rebuilt from the saved file — same contract as
          // the sender-side durable offer.
          await _storage.putSetting(
            'served:${m.contentId}',
            jsonEncode({
              'path': savedPath,
              'size': m.size,
              'pieceSize': m.pieceSize,
              'name': m.name,
            }),
          );
          // Durable-only (no RAM _serving entry): every serve/reoffer reopens
          // the file from served:<cid>, so a since-moved/deleted plain file is
          // detected and answered with content-GONE instead of a false offer.
        } catch (_) {}
      }
      _fetchSavePath.remove(m.contentId);
      devLog(
        () =>
            'xVeil[content]: COMPLETE ${m.contentId.substring(0, 12)} '
            '(${m.size}B) saved to $savedPath (serveable)',
      );
      if (!groupScoped) {
        await _send(peer, WireEnvelope.ack(ackId).encode());
      }
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: m.contentId,
          name: m.name,
          savedToPath: savedPath,
        ));
      }
      _clearGroupPullSources(m.contentId);
      return true;
    }
    devLog(
      () =>
          'xVeil[content]: COMPLETE ${m.contentId.substring(0, 12)} '
          '(${m.size}B) stored',
    );
    final persisted = await _persistReceivedContent(
      peer,
      m,
      surfaceOffer: !groupScoped,
    );
    if (persisted && !groupScoped) {
      await _send(peer, WireEnvelope.ack(ackId).encode());
    }
    if (persisted) {
      // The holder receipt is live-only observability. The verified blob is
      // already durable, so group folding/storage latency must not postpone
      // the user's completion event (or turn a successful download into a
      // failed one).
      unawaited(
        _groupContent.reportVerifiedSources(m.contentId, actualSources),
      );
    }
    if (persisted) _clearGroupPullSources(m.contentId);
    if (persisted && await _consumeParkedPlainFileSave(m.contentId)) {
      return true;
    }
    if (!_contentReceived.isClosed) {
      _contentReceived.add((
        contentId: m.contentId,
        name: m.name,
        savedToPath: null,
      ));
    }
    return persisted;
  }

  /// Read EXACTLY [n] bytes (looping); null on EOF before [n] arrives.

  Future<void> _onPieceChunk(PieceChunkFrame f) async {
    final fetch = _contentFetching.active(f.contentId);
    if (fetch == null) {
      // The manifest never arrived (or this content was already completed/
      // deleted): we hold no reassembler, so the chunk is dropped. A burst of
      // these means a LOST MANIFEST — the receiver can't reassemble or
      // re-request without it.
      devLog(
        () =>
            'xVeil[content]: pieceChunk DROPPED — no manifest/fetch for '
            '${f.contentId.substring(0, 12)} (p${f.pieceIndex} c${f.chunkIndex})',
      );
      return; // not fetching this content
    }
    _contentFetching.touch(f.contentId); // progress — keep this fetch non-stale
    final piece = fetch.xfer.addChunk(
      f.pieceIndex,
      f.chunkIndex,
      f.chunkCount,
      f.data,
    );
    if (piece != null) {
      // Stream the verified piece STRAIGHT to its destination; the reassembler
      // keeps no piece bytes, so the whole file never sits in RAM (any size).
      final m = fetch.manifest;
      try {
        if (fetch.sink != null) {
          // UNENCRYPTED download → write the piece to the user's plaintext file
          // at its byte offset; nothing is kept in the app.
          await fetch.sink!.write(f.pieceIndex * m.pieceSize, piece);
        } else {
          // Store via the Storage port (encrypted on-disk tier / in-volume).
          await _storage.storeFilePiece(
            m.contentId,
            f.pieceIndex,
            m.pieceCount,
            m.pieceSize,
            m.size,
            piece,
            name: m.name,
          );
        }
      } catch (e) {
        fetch.xfer.unverify(f.pieceIndex); // write failed → re-request it
        devLog(
          () =>
              'xVeil[content]: piece ${f.pieceIndex} store/write failed '
              'for ${m.contentId.substring(0, 12)}: $e',
        );
        return;
      }
      devLog(
        () =>
            'xVeil[content]: piece ${f.pieceIndex} VERIFIED+'
            '${fetch.sink != null ? 'WRITTEN' : 'STORED'} for '
            '${m.contentId.substring(0, 12)} '
            '(${fetch.xfer.verifiedCount}/${fetch.xfer.pieceCount})',
      );
      if (!_contentProgress.isClosed) {
        _contentProgress.add((
          contentId: f.contentId,
          done: fetch.xfer.verifiedCount,
          total: fetch.xfer.pieceCount,
        ));
      }
    }
    if (!fetch.xfer.isComplete) return;
    // Every piece verified AND written → done.
    _contentFetching.take(f.contentId);
    final ackId = fetch.manifest.msgId ?? f.contentId;
    final sink = fetch.sink;
    if (sink != null) {
      // UNENCRYPTED-to-file: the bytes are on the user's disk, NOT in the app —
      // so no offer→downloaded flip; just finalise the file, ack (we received
      // it), and tell the UI where it landed.
      final savedPath = _fetchSavePath.remove(f.contentId);
      try {
        await sink.close();
      } catch (e) {
        devLog(
          () =>
              'xVeil[content]: plaintext close failed '
              '${f.contentId.substring(0, 12)} -> $savedPath: $e',
        );
        if (!_contentFailed.isClosed) _contentFailed.add(f.contentId);
        return;
      }
      // Remember where it landed so a later tap OPENS the file instead of
      // re-offering it (it isn't in the app store → hasFile is false).
      if (savedPath != null) {
        try {
          await _storage.putSetting('saved:${f.contentId}', savedPath);
        } catch (_) {
          /* non-fatal */
        }
      }
      devLog(
        () =>
            'xVeil[content]: COMPLETE ${f.contentId.substring(0, 12)} '
            '(${fetch.manifest.size}B) saved UNENCRYPTED to $savedPath',
      );
      await _send(fetch.peer, WireEnvelope.ack(ackId).encode());
      if (!_contentReceived.isClosed) {
        _contentReceived.add((
          contentId: f.contentId,
          name: fetch.name,
          savedToPath: savedPath,
        ));
      }
      return;
    }
    // Stored in the app (encrypted tier / in-volume) → surface offer→downloaded.
    devLog(
      () =>
          'xVeil[content]: COMPLETE ${f.contentId.substring(0, 12)} '
          '(${fetch.manifest.size}B) streamed to disk',
    );
    final groupScoped = _groupPullSourceAllowed(fetch.peer, f.contentId);
    final persisted = await _persistReceivedContent(
      fetch.peer,
      fetch.manifest,
      surfaceOffer: !groupScoped,
    );
    // Ack by the per-send msgId (the EVENT identity) so the SENDER's specific
    // file message flips sent->delivered = actually received (a legacy sender
    // without msgId falls back to the contentId — old behaviour).
    if (persisted && !groupScoped) {
      devLog(
        () =>
            'xVeil[timeline]: content-ack id=$ackId '
            'via=direct t=${DateTime.now().millisecondsSinceEpoch}',
      );
      await _send(fetch.peer, WireEnvelope.ack(ackId).encode());
    }
    if (persisted && groupScoped) {
      unawaited(_groupContent.reportVerifiedSources(f.contentId, [fetch.peer]));
      _clearGroupPullSources(f.contentId);
    }
    if (persisted && await _consumeParkedPlainFileSave(f.contentId)) {
      return;
    }
    if (!_contentReceived.isClosed) {
      _contentReceived.add((
        contentId: f.contentId,
        name: fetch.name,
        savedToPath: null,
      ));
    }
  }

  /// A content transfer completed: its pieces were already streamed to disk
  /// (storeFilePiece in [_onPieceChunk]), so the blob is hasFile-complete.
  /// Ordinary 1:1 transfers ensure the OFFER exists; group-scoped pulls retain
  /// the same manifest/serving state without creating a direct-chat row.
  Future<bool> _persistReceivedContent(
    NodeId peer,
    ContentManifest m, {
    bool surfaceOffer = true,
  }) async {
    _contentAvailability.forgetOffer(m.contentId);
    if (surfaceOffer) {
      await _surfaceFileOffer(peer, m, route: 'persisted');
    } else {
      devLog(
        () =>
            'xVeil[content]: group download kept out of 1:1 chat '
            '${m.contentId.substring(0, 12)} <- ${peer.short}',
      );
    }
    await _persistServeManifest(m);
    _serving[m.contentId] = (manifest: m, source: null, servedAt: _now());
    _evictServing();
    _ensureContentTimer();
    _signal();
    return true;
  }

  /// Surface a received file as an incoming filePost — an OFFER carrying the
  /// descriptor (name/size + the contentId to download on demand), NOT the blob.
  /// Idempotent on the sender's per-send msgId. A re-send of previously-DELETED
  /// content surfaces as a NEW message (A); a re-delivery of the SAME (deleted)
  /// event stays gone. The "downloaded" state is derived from hasFile(contentId),
  /// so no message rewrite is needed when the blob later lands.
  Future<void> _surfaceFileOffer(
    NodeId peer,
    ContentManifest m, {
    required String route,
  }) async {
    await _surfaceFileOfferFields(
      peer,
      route: route,
      contentId: m.contentId,
      name: m.name,
      size: m.size,
      msgId: m.msgId,
      seq: m.seq,
      ts: m.ts,
      thumb: m.thumbB64,
    );
  }

  /// Does this conversation already show [contentId], under any id?
  ///
  /// Asked only when an arrival brought no per-send id of its own, so the row
  /// it would create is keyed by the content hash and would sit beside the one
  /// the sender's id already made.
  Future<bool> _hasFileRowFor(NodeId peer, String contentId) async {
    try {
      final rows = await _storage.loadMessages(peer.hex);
      return rows.any(
        (m) => m.fileContentId == contentId || m.fileId == contentId,
      );
    } catch (_) {
      // Storage locked or unavailable: say no and let the ordinary id-based
      // checks below decide, exactly as before this guard existed.
      return false;
    }
  }

  Future<void> _surfaceFileOfferFields(
    NodeId peer, {

    /// Which arrival produced this row. Four different ones can, and the id a
    /// row gets is `msgId ?? contentId` — so two arrivals that disagree about
    /// carrying a msgId make TWO rows for one file, which is what a user saw
    /// as a video note "sent twice", with the list reshuffling around them.
    required String route,
    required String contentId,
    required String name,
    required int size,
    String? msgId,
    int? seq,
    int? ts,
    String? thumb,
  }) async {
    // The manifest's seq is a peer's number like any other — the single funnel
    // for both the full manifest and the compact ref, so neither route can
    // land an out-of-range slot.
    if (!isAcceptableWireSeq(seq)) return;
    final msgIdOrContent = msgId ?? contentId; // legacy sender → hash id
    // No msgId means this row would be keyed by the CONTENT HASH, and four
    // different arrivals can surface a file. When one of them carries the
    // sender's per-send id and another does not, the two keys disagree and the
    // same file becomes TWO rows — measured on the stand:
    //
    //   offered 2d01fce1523e as msg 238610a8 seq=126  via=manifest
    //   offered 2d01fce1523e as msg 2d01fce1 seq=null via=persisted
    //
    // A user saw that as one video note arriving twice, and the list
    // reshuffling around it: the second row carries no seq, so storage
    // allocates a local one and the two land in different (author, seq)
    // streams, which is the display order's key.
    //
    // Only the ANONYMOUS arrival defers. A genuine re-send of the same bytes
    // carries a fresh per-send id and still surfaces as a new message — that
    // is deliberate (a cleared file re-sent must reappear) and has its own
    // test; this branch cannot reach it.
    if (msgId == null && await _hasFileRowFor(peer, contentId)) {
      devLog(
        () =>
            'xVeil[content]: offer skip ${contentId.substring(0, 12)} '
            'via=$route — already surfaced under the sender\'s own id, and '
            'this arrival carries none <- ${peer.short}',
      );
      return;
    }
    if (await _hasMessage(peer, msgIdOrContent)) {
      devLog(
        () =>
            'xVeil[content]: offer skip ${contentId.substring(0, 12)} '
            'msg ${msgIdOrContent.substring(0, 8)} already stored <- ${peer.short}',
      );
      return; // already surfaced
    }
    if (await _storage.isMessageDeleted(peer.hex, msgIdOrContent)) {
      devLog(
        () =>
            'xVeil[content]: offer skip ${contentId.substring(0, 12)} '
            'msg ${msgIdOrContent.substring(0, 8)} deleted <- ${peer.short}',
      );
      return; // already surfaced / deliberately deleted
    }
    await _store(
      peer,
      MessageDirection.incoming,
      '📎 $name',
      MessageStatus.delivered,
      fileContentId: contentId,
      fileSize: size,
      fileName: name,
      thumb: thumb,
      id: msgIdOrContent,
      seq: seq,
      // The manifest's `mts` is UNBOUND — deliberately absent from the contentId
      // (see ContentManifest), so a manifest that hashes correctly still carries
      // a completely unauthenticated send-time. Through the same receive-time
      // bound as every other wire stamp, not a bare fromMillisecondsSinceEpoch.
      timestamp: _wireSentAtMs(ts) ?? _now(),
    );
    _emitIncoming(
      peer,
      '📎 $name',
      isFile: true,
      fileName: name,
      sidecar: thumb,
    );
    _signal();
    devLog(
      () =>
          'xVeil[content]: offered ${contentId.substring(0, 12)} as msg '
          '${msgIdOrContent.substring(0, 8)} seq=$seq via=$route '
          '${msgId == null ? "(msgId ABSENT — the row is keyed by the content "
                    "hash, so an arrival that HAS one becomes a SECOND row)" : ""}'
          '(${size}B) <- ${peer.short}',
    );
  }
}
