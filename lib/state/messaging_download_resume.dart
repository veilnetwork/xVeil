part of 'messaging_core.dart';

/// Durable auto-resume state machine for interrupted content downloads.
///
/// The byte-transfer engine owns manifests, ranges and sinks. This collaborator
/// owns durable intent, retry/parking timers, liveness wake-ups and active-pull
/// admission so only one component can schedule a background retry.
class _MessagingDownloadResume {
  _MessagingDownloadResume(this._owner);

  final MessagingService _owner;

  static const String _pendingDownloadsKey = 'pending_downloads';
  static const int _resumeParkAfterAttempts = 8;

  Map<String, _PendingDownload>? _pendingCache;
  Future<void> _writeChain = Future.value();
  final Map<String, Timer> _timers = {};
  final Map<String, int> _attempts = {};
  final Map<String, DateTime> _progressAt = {};
  final Set<String> _inFlight = {};
  final Set<String> _parked = {};
  final Set<String> _persistedManifests = {};
  final Map<String, int> _activePullCount = {};

  StreamSubscription<String>? _failedSub;
  StreamSubscription<({String contentId, int done, int total})>? _progressSub;
  StreamSubscription<({String contentId, String name, String? savedToPath})>?
  _receivedSub;

  final _resuming = StreamController<Set<String>>.broadcast();
  Set<String> _lastResuming = const {};

  Duration startDelay = const Duration(seconds: 8);
  Duration backoffBase = const Duration(seconds: 10);
  Duration backoffCap = const Duration(minutes: 10);
  Duration liveGrace = const Duration(seconds: 10);

  Future<VeilPlainFileSink?> Function(String path, {bool resume})
  plainFileSinkOpener = veilPlainFileSinkOpener;

  Stream<Set<String>> get resuming => _resuming.stream;

  Future<String?> cancel(String contentId) async {
    _owner._cancelledDownloads.add(contentId);
    _owner._clearGroupPullSources(contentId);
    final savedPath = _owner._fetchSavePath.remove(contentId);
    complete(contentId);
    _owner._pendingTimers.remove(contentId)?.cancel();
    final parkedSink = _owner._pendingDownload.remove(contentId);
    final fetch = _owner._fetching.remove(contentId);
    _owner._fetchActivity.remove(contentId);

    final sinks = <_FetchSink>{?parkedSink, ?fetch?.sink};
    final streams =
        _owner._activePullStreams[contentId]?.toList(growable: false) ??
        const <_TrackedPullStream>[];
    await Future.wait([for (final stream in streams) stream.abort()]);
    if (!_owner._contentCancelled.isClosed) {
      _owner._contentCancelled.add(contentId);
    }

    // Wait briefly for native reads to observe the cancellation latch before
    // an immediate re-tap is allowed to start a new transfer.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (((_activePullCount[contentId] ?? 0) > 0 ||
            _inFlight.contains(contentId)) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (final sink in sinks) {
      try {
        await sink.close();
      } catch (_) {}
    }
    await _writeChain;
    _owner._signal();
    return savedPath;
  }

  Future<int> clearPending() async {
    final pending = await _pendingDownloads();
    final count = pending.length;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _attempts.clear();
    _progressAt.clear();
    _parked.clear();
    _persistedManifests.clear();
    _mutatePending((map) => map.clear());
    return count;
  }

  Future<List<String>> pendingContentIds() async =>
      (await _pendingDownloads()).keys.toList(growable: false);

  Future<Map<String, _PendingDownload>> _pendingDownloads() async {
    final cached = _pendingCache;
    if (cached != null) return cached;
    final map = <String, _PendingDownload>{};
    try {
      final raw = await _owner._storage.getSetting(_pendingDownloadsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            final pending = entry is Map<String, dynamic>
                ? _PendingDownload.fromJson(entry)
                : null;
            if (pending == null) continue;
            if (DateTime.now().difference(pending.requestedAt) >
                const Duration(days: 14)) {
              continue;
            }
            map[pending.contentId] = pending;
          }
        }
      }
    } catch (_) {
      // A corrupt registry starts empty; new explicit requests repopulate it.
    }
    return _pendingCache = map;
  }

  void _mutatePending(void Function(Map<String, _PendingDownload> map) mutate) {
    _writeChain = _writeChain.then((_) async {
      final map = await _pendingDownloads();
      mutate(map);
      try {
        await _owner._storage.putSetting(
          _pendingDownloadsKey,
          jsonEncode([for (final pending in map.values) pending.toJson()]),
        );
      } catch (_) {
        // The in-memory registry still drives this session. A later mutation
        // retries persistence with the merged state.
      }
      _emitResuming(map.keys.toSet());
    });
  }

  void _emitResuming(Set<String> pending) {
    if (_resuming.isClosed) return;
    if (pending.length == _lastResuming.length &&
        pending.containsAll(_lastResuming)) {
      return;
    }
    _lastResuming = pending;
    _resuming.add(pending);
  }

  void record(
    String contentId, {
    required String mode,
    String? savedPath,
    required Iterable<NodeId> peers,
  }) {
    if (_owner._disposed) return;
    final peerHexes = [for (final peer in peers) peer.hex];
    _mutatePending((map) {
      final prior = map[contentId];
      map[contentId] = _PendingDownload(
        contentId: contentId,
        mode: mode,
        savedPath: savedPath ?? prior?.savedPath,
        peers: {...?prior?.peers, ...peerHexes}.toList(growable: false),
        requestedAt: prior?.requestedAt ?? DateTime.now(),
      );
    });
    final offered = _owner._offered[contentId];
    if (offered != null) {
      unawaited(_owner._persistServeManifest(offered.manifest));
    }
  }

  void pullStarted(String contentId) =>
      _activePullCount[contentId] = (_activePullCount[contentId] ?? 0) + 1;

  void pullEnded(String contentId) {
    final count = (_activePullCount[contentId] ?? 1) - 1;
    if (count <= 0) {
      _activePullCount.remove(contentId);
    } else {
      _activePullCount[contentId] = count;
    }
  }

  bool pullActive(String contentId) =>
      (_activePullCount[contentId] ?? 0) > 0 ||
      _owner._fetching.containsKey(contentId) ||
      _owner._pendingDownload.containsKey(contentId);

  Future<void> persistManifestIfPending(ContentManifest manifest) async {
    if (!_persistedManifests.add(manifest.contentId)) return;
    if (!(await _pendingDownloads()).containsKey(manifest.contentId)) {
      _persistedManifests.remove(manifest.contentId);
      return;
    }
    await _owner._persistServeManifest(manifest);
  }

  Future<ContentManifest?> loadPersistedManifest(String contentId) async {
    try {
      final bytes = await _owner._storage.loadFile('mf:$contentId');
      if (bytes == null) return null;
      final manifest = ContentManifest.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
      if (manifest == null || manifest.contentId != contentId) return null;
      return manifest;
    } catch (_) {
      return null;
    }
  }

  void complete(String contentId) {
    _timers.remove(contentId)?.cancel();
    _attempts.remove(contentId);
    _progressAt.remove(contentId);
    _parked.remove(contentId);
    _persistedManifests.remove(contentId);
    if (_pendingCache?.containsKey(contentId) ?? true) {
      _mutatePending((map) => map.remove(contentId));
    }
  }

  Future<void> start() async {
    _failedSub ??= _owner.contentDownloadFailed.listen((contentId) async {
      if ((await _pendingDownloads()).containsKey(contentId)) {
        _schedule(contentId, backoff: true);
      }
    });
    _progressSub ??= _owner.contentProgress.listen((event) async {
      if ((await _pendingDownloads()).containsKey(event.contentId)) {
        _progressAt[event.contentId] = DateTime.now();
        _attempts.remove(event.contentId);
        _parked.remove(event.contentId);
      }
    });
    _receivedSub ??= _owner.contentReceived.listen(
      (event) => complete(event.contentId),
    );
    await resumeAll(initial: startDelay, stagger: const Duration(seconds: 2));
  }

  Future<void> resumeAll({
    Duration initial = const Duration(seconds: 2),
    Duration stagger = Duration.zero,
  }) async {
    final pending = await _pendingDownloads();
    final warmed = <String>{};
    for (final intent in pending.values) {
      for (final hex in intent.peers) {
        if (warmed.add(hex)) warmPeer(NodeId.fromHex(hex));
      }
    }
    var index = 0;
    for (final contentId in pending.keys.toList(growable: false)) {
      _schedule(contentId, after: initial + stagger * index++);
    }
  }

  void reconcileOnConnect() {
    _attempts.clear();
    unawaited(resumeAll(stagger: const Duration(seconds: 2)));
  }

  void warmPeer(NodeId peer) {
    final transport = _owner._transport;
    if (transport is! StreamTransport) return;
    unawaited(
      (transport as StreamTransport).warmStreamPeer(peer).catchError((
        Object e,
      ) {
        devLog(() => 'xVeil[stream]: warm ${peer.short} failed: $e');
      }),
    );
  }

  Future<void> onOffer(String contentId, {ContentManifest? manifest}) async {
    if (_owner._disposed) return;
    if (!(await _pendingDownloads()).containsKey(contentId)) return;
    if (manifest != null) {
      unawaited(_owner._persistServeManifest(manifest));
    }
    _parked.remove(contentId);
    _attempts.remove(contentId);
    if (_timers.containsKey(contentId)) return;
    _schedule(contentId, after: const Duration(seconds: 3));
  }

  void noteInbound(NodeId peer) {
    if (_owner._disposed || _parked.isEmpty) return;
    final peerHex = peer.hex;
    unawaited(() async {
      final pending = await _pendingDownloads();
      for (final contentId in _parked.toList(growable: false)) {
        final intent = pending[contentId];
        if (intent == null) {
          _parked.remove(contentId);
          continue;
        }
        if (!intent.peers.contains(peerHex)) continue;
        _parked.remove(contentId);
        _attempts.remove(contentId);
        devLog(
          () =>
              'xVeil[content]: holder ${peer.short} is alive — un-parking '
              '${contentId.substring(0, 12)}',
        );
        _schedule(contentId, after: const Duration(seconds: 2));
      }
    }());
  }

  void _schedule(String contentId, {Duration? after, bool backoff = false}) {
    if (_owner._disposed) return;
    Duration delay;
    if (after != null) {
      delay = after;
    } else if (backoff) {
      final attempt = (_attempts[contentId] ?? 0) + 1;
      _attempts[contentId] = attempt;
      if (attempt >= _resumeParkAfterAttempts) {
        _parked.add(contentId);
        _timers.remove(contentId)?.cancel();
        devLog(
          () =>
              'xVeil[content]: auto-resume PARKED '
              '${contentId.substring(0, 12)} after $attempt fruitless attempts — '
              'will retry on the next offer/inbound from a holder',
        );
        return;
      }
      final candidate = backoffBase * (1 << (attempt - 1).clamp(0, 6));
      delay = candidate > backoffCap ? backoffCap : candidate;
    } else {
      delay = Duration.zero;
    }
    _timers[contentId]?.cancel();
    _timers[contentId] = Timer(delay, () {
      _timers.remove(contentId);
      if (_inFlight.contains(contentId)) {
        _schedule(contentId, after: const Duration(seconds: 30));
      } else {
        unawaited(_resume(contentId));
      }
    });
  }

  Future<void> _resume(String contentId) async {
    if (_owner._disposed || !_inFlight.add(contentId)) return;
    final short = contentId.length >= 12
        ? contentId.substring(0, 12)
        : contentId;
    try {
      final intent = (await _pendingDownloads())[contentId];
      if (intent == null || _owner._cancelledDownloads.contains(contentId)) {
        return;
      }
      if (await _owner._storage.hasFile(contentId) ||
          await _owner.isContentUnavailable(contentId) ||
          (intent.mode == _PendingDownload.modeFile &&
              await _owner.contentSavedPath(contentId) != null)) {
        complete(contentId);
        return;
      }
      if (pullActive(contentId)) {
        _schedule(contentId, after: liveGrace * 2);
        return;
      }
      final lastProgress = _progressAt[contentId];
      if (lastProgress != null &&
          DateTime.now().difference(lastProgress) < liveGrace) {
        _schedule(contentId, after: liveGrace * 2);
        return;
      }
      final peers = <NodeId>[];
      for (final hex in intent.peers) {
        try {
          peers.add(NodeId.fromHex(hex));
        } catch (_) {}
      }
      if (_owner._offered[contentId] == null && peers.isNotEmpty) {
        final manifest = await loadPersistedManifest(contentId);
        if (manifest != null) {
          _owner._offered[contentId] = (
            manifest: manifest,
            peers: {for (final peer in peers) peer.hex: peer},
          );
        }
      }
      devLog(
        () =>
            'xVeil[content]: auto-resume $short '
            '(mode=${intent.mode}, attempt=${_attempts[contentId] ?? 0},'
            ' peers=${peers.length}, manifest=${_owner._offered[contentId] != null})',
      );
      if ((_attempts[contentId] ?? 0) >= 1) {
        for (final peer in peers) {
          unawaited(_owner.requestContentReoffer(peer, contentId));
        }
      }
      if (intent.mode == _PendingDownload.modeFile &&
          intent.savedPath != null) {
        await _resumePlainFile(intent, peers);
      } else {
        await _owner.downloadContentFromAny(
          peers,
          contentId,
          userInitiated: false,
        );
      }
    } catch (error) {
      devLog(() => 'xVeil[content]: auto-resume $short failed: $error');
      _schedule(contentId, backoff: true);
    } finally {
      _inFlight.remove(contentId);
    }
  }

  Future<void> _resumePlainFile(
    _PendingDownload intent,
    List<NodeId> peers,
  ) async {
    final contentId = intent.contentId;
    final path = intent.savedPath!;
    final sink = await plainFileSinkOpener(path, resume: true);
    if (sink == null) {
      devLog(
        () =>
            'xVeil[content]: auto-resume cannot reopen $path — '
            'dropping the pending plain-file download',
      );
      complete(contentId);
      return;
    }
    final result = await _owner.downloadContentToFileFromAny(
      peers,
      contentId,
      path,
      write: sink.write,
      close: sink.close,
      read: sink.read,
      userInitiated: false,
    );
    if (result == ContentDownloadResult.noOffer) {
      await sink.close();
    }
  }

  Future<void> dispose() async {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    await _failedSub?.cancel();
    _failedSub = null;
    await _progressSub?.cancel();
    _progressSub = null;
    await _receivedSub?.cancel();
    _receivedSub = null;
    await _writeChain;
    await _resuming.close();
  }
}
