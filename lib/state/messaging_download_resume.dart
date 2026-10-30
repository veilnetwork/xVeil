part of 'messaging_core.dart';

/// Ownership of one asynchronous download preparation, before its setup call
/// returns. This is independent of a CID's cancel latch, which a retry clears.
class _DownloadPreparationRetired implements Exception {
  const _DownloadPreparationRetired();
}

/// The layout claims a durable registry, but a complete copy is unavailable.
/// Source-owned type/message only: no CID, destination, bytes or exception text.
class _IncompleteDownloadResumeRegistry extends StateError {
  _IncompleteDownloadResumeRegistry()
    : super('Download resume registry is incomplete');
}

class _DownloadPreparation {
  _DownloadPreparation(this.token, this.isCurrent, this.finish);
  final Object token;
  final bool Function() isCurrent;
  final void Function() finish;

  Future<T> wait<T>(Future<T> Function() operation) async {
    if (!isCurrent()) throw const _DownloadPreparationRetired();
    try {
      final value = await operation();
      if (!isCurrent()) throw const _DownloadPreparationRetired();
      return value;
    } catch (_) {
      if (!isCurrent()) throw const _DownloadPreparationRetired();
      rethrow;
    }
  }
}

/// Durable auto-resume state machine for interrupted content downloads.
///
/// The byte-transfer engine owns manifests, ranges and sinks. This collaborator
/// owns durable intent, retry/parking timers, liveness wake-ups and active-pull
/// admission so only one component can schedule a background retry.
class _MessagingDownloadResume {
  _MessagingDownloadResume(this._owner);

  final MessagingService _owner;

  static const String _pendingDownloadsKey = 'pending_downloads';
  static const String _pendingDownloadsFile = 'download-resume.registry.v1';
  static const String _fileLayout = 'file:v1';
  static const int _resumeParkAfterAttempts = 8;

  Map<String, _PendingDownload>? _pendingCache;
  Future<Map<String, _PendingDownload>>? _pendingLoad;
  bool _pendingReadFailed = false, _layoutMarked = false;
  Future<void> _writeChain = Future.value();
  final Map<String, Timer> _timers = {};
  final Map<String, int> _attempts = {};
  final Map<String, DateTime> _progressAt = {};
  // Identity tokens fence resumptions still awaiting an external opener/read.
  // A stale continuation may close its own sink, never retire a newer slot.
  final Map<String, Object> _inFlight = {};
  final Map<String, Object> _preparations = {};
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

  /// A new explicit request supersedes any suspended auto-resume preparation.
  void beginUserRequest(String contentId) {
    _inFlight.remove(contentId);
    _preparations.remove(contentId);
    _owner._cancelledDownloads.remove(contentId);
  }

  _DownloadPreparation? prepare(
    String contentId, {
    required bool userInitiated,
  }) {
    if (_owner._disposed) return null;
    if (userInitiated) {
      beginUserRequest(contentId);
    } else if (_owner._cancelledDownloads.contains(contentId) ||
        _preparations.containsKey(contentId)) {
      return null; // an explicit preparation already owns this content
    }
    final token = Object();
    _preparations[contentId] = token;
    return _DownloadPreparation(
      token,
      () =>
          !_owner._disposed &&
          !_owner._cancelledDownloads.contains(contentId) &&
          identical(_preparations[contentId], token),
      () {
        if (identical(_preparations[contentId], token)) {
          _preparations.remove(contentId);
        }
      },
    );
  }

  Future<String?> cancel(String contentId) async {
    _inFlight.remove(contentId);
    _preparations.remove(contentId);
    _owner._cancelledDownloads.add(contentId);
    _owner._contentAvailability.cancelRetryReoffers(contentId);
    _owner._clearGroupPullSources(contentId);
    final savedPath = _owner._forgetFetchSavePath(contentId);
    final parkedSink = _owner._contentAvailability.takePending(contentId);
    final fetch = _owner._contentFetching.take(contentId);

    final sinks = <_FetchSink>{?parkedSink, ?fetch?.sink};
    await _owner._contentStreams.abortPulls(contentId);

    // Wait briefly for native reads to observe the cancellation latch before
    // an immediate re-tap is allowed to start a new transfer.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (((_activePullCount[contentId] ?? 0) > 0 ||
            _inFlight.containsKey(contentId)) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (final sink in sinks) {
      try {
        await sink.close();
      } catch (_) {}
    }
    await _removePending(contentId);
    if (!_owner._contentCancelled.isClosed) {
      _owner._contentCancelled.add(contentId);
    }
    _owner._signal();
    return savedPath;
  }

  Future<int> clearPending() async {
    _inFlight.clear();
    _preparations.clear();
    final pending = await _pendingDownloads();
    if (_pendingReadFailed) {
      throw StateError('Download resume state unavailable');
    }
    final count = pending.length;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _attempts.clear();
    _progressAt.clear();
    _parked.clear();
    _persistedManifests.clear();
    await _mutatePending((map) => map.clear());
    return count;
  }

  Future<List<String>> pendingContentIds() async =>
      (await _pendingDownloads()).keys.toList(growable: false);

  Future<Map<String, _PendingDownload>> _pendingDownloads() {
    final cached = _pendingCache;
    if (cached != null) return Future.value(cached);
    return _pendingLoad ??= _loadPending().whenComplete(
      () => _pendingLoad = null,
    );
  }

  void _report(String kind, {Object? cause, StackTrace? stack}) {
    const message = 'Download resume state could not be saved or read';
    // Keep useful failure categories/errno without retaining the original
    // FormatException.source or filesystem message/path, even in the RAM UI.
    final Object safeError = switch (cause) {
      _IncompleteDownloadResumeRegistry() =>
        _IncompleteDownloadResumeRegistry(),
      FormatException() => const FormatException(message),
      FileSystemException(:final osError) => FileSystemException(
        message,
        null,
        osError == null
            ? null
            : OSError('operation refused', osError.errorCode),
      ),
      _ => StateError(message),
    };
    errorJournal.record(
      kind: kind,
      error: safeError,
      stack: stack,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<Map<String, _PendingDownload>> _loadPending() async {
    final map = <String, _PendingDownload>{};
    try {
      final stored = await _owner._storage.loadFile(_pendingDownloadsFile);
      final legacy = await _owner._storage.getSetting(_pendingDownloadsKey);
      _layoutMarked = legacy == _fileLayout;
      if (stored == null &&
          (_layoutMarked ||
              await _owner._storage.hasFile(_pendingDownloadsFile))) {
        throw _IncompleteDownloadResumeRegistry();
      }
      final raw = stored == null ? legacy : utf8.decode(stored);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! List) {
          throw const FormatException('Invalid pending download registry');
        }
        for (final entry in decoded) {
          final pending = entry is Map<String, dynamic>
              ? _PendingDownload.fromJson(entry)
              : null;
          if (pending == null) {
            throw const FormatException('Invalid pending download');
          }
          if (DateTime.now().difference(pending.requestedAt) >
              const Duration(days: 14)) {
            continue;
          }
          map[pending.contentId] = pending;
        }
      }
      _pendingReadFailed = false;
      return _pendingCache = map;
    } catch (error, stack) {
      // Leave the durable bytes intact. Background readers can stay idle, but
      // a new request must not overwrite an unreadable registry with an empty
      // one. Do not cache this failure: the next request may recover the read.
      _pendingReadFailed = true;
      _report('download-resume-read', cause: error, stack: stack);
      return {};
    }
  }

  Future<void> _mutatePending(
    void Function(Map<String, _PendingDownload> map) mutate, {
    bool Function()? isCurrent,
  }) {
    final write = _writeChain.then((_) async {
      if (isCurrent != null && !isCurrent()) return;
      final current = await _pendingDownloads();
      if (isCurrent != null && !isCurrent()) return;
      if (_pendingReadFailed) {
        throw StateError('Download resume state unavailable');
      }
      final map = Map<String, _PendingDownload>.of(current);
      mutate(map);
      final encoded = jsonEncode([
        for (final pending in map.values) pending.toJson(),
      ]);
      // One KV value stopped fitting at about ten requests on the real store.
      // FileStore publishes its replacement metadata only after every chunk
      // is durable, preserving the old registry if an intermediate write fails.
      await _owner._storage.storeFile(
        _pendingDownloadsFile,
        Uint8List.fromList(utf8.encode(encoded)),
      );
      _pendingCache = map;
      if (!_layoutMarked) {
        try {
          // Publish the layout only AFTER the file. This also retires the old
          // JSON value; cancellation must not resurrect it as a fallback.
          await _owner._storage.putSetting(_pendingDownloadsKey, _fileLayout);
          _layoutMarked = true;
        } catch (error, stack) {
          // The authoritative file is already committed. Retry marker cleanup
          // on the next mutation without misreporting that commit as lost.
          _report('download-resume-layout', cause: error, stack: stack);
        }
      }
      _emitResuming(map.keys.toSet());
    });
    _writeChain = write.then<void>((_) {}, onError: (_) {});
    return write;
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

  Future<void> record(
    String contentId, {
    required String mode,
    String? savedPath,
    required Iterable<NodeId> peers,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent() ||
        _owner._disposed ||
        _owner._cancelledDownloads.contains(contentId)) {
      return;
    }
    final peerHexes = [for (final peer in peers) peer.hex];
    await _mutatePending((map) {
      // Preparation can yield on storage/source discovery before recording.
      // Cancellation must win over that suspended attempt, including a write
      // already queued on the persistence chain. A fresh user tap clears the
      // cancellation latch before recording its new intent.
      if (_owner._cancelledDownloads.contains(contentId)) return;
      final prior = map[contentId];
      map[contentId] = _PendingDownload(
        contentId: contentId,
        mode: mode,
        savedPath: savedPath ?? prior?.savedPath,
        peers: {...?prior?.peers, ...peerHexes}.toList(growable: false),
        requestedAt: prior?.requestedAt ?? DateTime.now(),
      );
    }, isCurrent: isCurrent);
    if (!isCurrent()) return;
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
      _owner._contentFetching.contains(contentId) ||
      _owner._contentAvailability.hasPending(contentId);

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
    unawaited(
      _removePending(contentId).catchError((Object error, StackTrace stack) {
        _report('download-resume-write', cause: error, stack: stack);
      }),
    );
  }

  Future<void> _removePending(String contentId) async {
    _timers.remove(contentId)?.cancel();
    _attempts.remove(contentId);
    _progressAt.remove(contentId);
    _parked.remove(contentId);
    _persistedManifests.remove(contentId);
    // Decide after older queued writes, not from a cache sampled while an
    // insertion is still committing. A cancelled insertion must not resurrect.
    await _mutatePending((map) => map.remove(contentId));
  }

  Future<void> start() async {
    _failedSub ??= _owner.contentDownloadFailed.listen((contentId) async {
      diagnosticJournal.record(DiagnosticEvent.downloadFailed);
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
    _receivedSub ??= _owner.contentReceived.listen((event) {
      diagnosticJournal.record(DiagnosticEvent.downloadReceived);
      complete(event.contentId);
    });
    await resumeAll(initial: startDelay, stagger: const Duration(seconds: 2));
  }

  Future<void> resumeAll({
    Duration initial = const Duration(seconds: 2),
    Duration stagger = Duration.zero,
  }) async {
    final pending = await _pendingDownloads();
    final warmed = <String>{};
    for (final entry in pending.entries) {
      for (final hex in entry.value.peers) {
        final target = _owner._contentAvailability.streamTargetFor(
          NodeId.fromHex(hex),
          entry.key,
        );
        // One identity may have offered different files from different devices.
        if (warmed.add(target.hex)) warmPeer(target);
      }
    }
    var index = 0;
    for (final contentId in pending.keys.toList(growable: false)) {
      // A parked download is waiting for evidence that a holder came back —
      // an offer, or an inbound frame from one. Reconnecting is not that
      // evidence: a holder we may no longer pull from is no more reachable
      // for being online. Re-arming them here is what kept an impossible
      // download cycling forever, since every reconnect also cleared the
      // backoff that was supposed to end it.
      if (_parked.contains(contentId)) continue;
      _schedule(contentId, after: initial + stagger * index++);
    }
  }

  void reconcileOnConnect() {
    _attempts.clear();
    unawaited(resumeAll(stagger: const Duration(seconds: 2)));
  }

  void warmPeer(NodeId peer, {String? contentId}) {
    final transport = _owner._transport;
    if (transport is! StreamTransport) return;
    final target = contentId == null
        ? peer
        : _owner._contentAvailability.streamTargetFor(peer, contentId);
    unawaited(
      (transport as StreamTransport).warmStreamPeer(target).catchError((
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

  /// Whether any recorded holder is still a source we may pull from.
  Future<bool> _anyEligibleSource(
    List<NodeId> peers,
    String contentId,
    bool Function() isCurrent,
  ) async {
    for (final peer in peers) {
      if (!isCurrent()) return false;
      if (await _owner._eligiblePullSource(peer, contentId)) return true;
    }
    return false;
  }

  void noteInbound(NodeId peer) {
    if (_owner._disposed || _parked.isEmpty) return;
    final peerHex = peer.hex;
    // Not ourselves. A node hears its own traffic — a self-addressed frame, a
    // loopback of its own send — and that is no evidence a holder came back.
    // Where our own id sits in a download's recorded holders, this un-parked
    // it every twenty seconds: the resume then found no eligible source
    // (ourselves being the one thing we never pull from) and parked again,
    // round and round, for as long as the app ran.
    unawaited(() async {
      if (peerHex == await _owner._selfHex()) return;
      _noteInboundFrom(peerHex, peer);
    }());
  }

  void _noteInboundFrom(String peerHex, NodeId peer) {
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
        diagnosticJournal.record(
          DiagnosticEvent.downloadParked,
          values: {DiagnosticMetric.attempt: attempt},
        );
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
      if (_inFlight.containsKey(contentId)) {
        _schedule(contentId, after: const Duration(seconds: 30));
      } else {
        unawaited(_resume(contentId));
      }
    });
  }

  /// How many resume ticks have actually run. Test seam: the difference
  /// between a download that parks once and one that is re-armed on every
  /// reconnect is invisible from the outside — a re-armed tick that parks
  /// again sends nothing and opens nothing. It is only visible here.
  int resumeTicks = 0;

  Future<void> _resume(String contentId) async {
    resumeTicks++;
    if (_owner._disposed || _inFlight.containsKey(contentId)) return;
    final attempt = Object();
    _inFlight[contentId] = attempt;
    bool isCurrent() =>
        !_owner._disposed &&
        !_owner._cancelledDownloads.contains(contentId) &&
        identical(_inFlight[contentId], attempt);
    final short = contentId.length >= 12
        ? contentId.substring(0, 12)
        : contentId;
    try {
      final intent = (await _pendingDownloads())[contentId];
      if (intent == null || !isCurrent()) return;
      var completed = await _owner._storage.hasFile(contentId);
      if (!isCurrent()) return;
      if (!completed) {
        completed = await _owner.isContentUnavailable(contentId);
        if (!isCurrent()) return;
      }
      if (!completed && intent.mode == _PendingDownload.modeFile) {
        completed = await _owner.contentSavedPath(contentId) != null;
        if (!isCurrent()) return;
      }
      if (completed) {
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
      // Nobody left we are allowed to ask. This is not a slow download, it is
      // an impossible one: every recorded holder has since stopped being a
      // source we may pull from (contact removed, membership gone). Retrying
      // on a timer would never end — and did not: each attempt asked the same
      // ineligible peer to re-offer, the offer that came back cleared the
      // attempt counter, and the backoff sat at one forever, every ten
      // seconds, for as long as the app ran.
      //
      // Park instead. The un-parking path already exists and is the right one:
      // it waits for something to actually happen — an offer, or an inbound
      // frame from a recorded holder — rather than for a clock.
      final eligible =
          peers.isEmpty ||
          await _anyEligibleSource(peers, contentId, isCurrent);
      if (!isCurrent()) return;
      if (!eligible) {
        _parked.add(contentId);
        diagnosticJournal.record(
          DiagnosticEvent.downloadParked,
          values: {DiagnosticMetric.sources: peers.length},
        );
        _timers.remove(contentId)?.cancel();
        devLog(
          () =>
              'xVeil[content]: auto-resume PARKED $short — no eligible source '
              'among ${peers.length} recorded holder(s); waiting for one to '
              'return rather than retrying on a timer',
        );
        return;
      }
      if (_owner._offered[contentId] == null && peers.isNotEmpty) {
        final manifest = await loadPersistedManifest(contentId);
        if (!isCurrent()) return;
        if (manifest != null) {
          for (final peer in peers) {
            _owner._contentAvailability.rememberManifest(peer, manifest);
          }
        }
      }
      devLog(
        () =>
            'xVeil[content]: auto-resume $short '
            '(mode=${intent.mode}, attempt=${_attempts[contentId] ?? 0},'
            ' peers=${peers.length}, manifest=${_owner._offered[contentId] != null})',
      );
      diagnosticJournal.record(
        DiagnosticEvent.downloadRetry,
        values: {
          DiagnosticMetric.attempt: _attempts[contentId] ?? 0,
          DiagnosticMetric.sources: peers.length,
        },
      );
      if ((_attempts[contentId] ?? 0) >= 1) {
        for (final peer in peers) {
          unawaited(_owner.requestContentReoffer(peer, contentId));
        }
      }
      if (intent.mode == _PendingDownload.modeFile &&
          intent.savedPath != null) {
        await _resumePlainFile(intent, peers, isCurrent);
      } else {
        await _owner.downloadContentFromAny(
          peers,
          contentId,
          userInitiated: false,
        );
      }
    } catch (error, stack) {
      // A late failure belongs to the retired attempt, not the replacement.
      if (!isCurrent()) return;
      if (kDiagnosticReportEnabled) {
        errorJournal.record(
          kind: 'download-resume',
          error: error,
          stack: stack,
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      devLog(() => 'xVeil[content]: auto-resume $short failed: $error');
      _schedule(contentId, backoff: true);
    } finally {
      if (identical(_inFlight[contentId], attempt)) _inFlight.remove(contentId);
    }
  }

  Future<void> _resumePlainFile(
    _PendingDownload intent,
    List<NodeId> peers,
    bool Function() isCurrent,
  ) async {
    final contentId = intent.contentId;
    final path = intent.savedPath!;
    final sink = await plainFileSinkOpener(path, resume: true);
    if (!isCurrent()) {
      // Openers cannot be cancelled. Retain ownership of their late handle,
      // but never give an obsolete destination back to the download engine.
      await sink?.close();
      return;
    }
    if (sink == null) {
      // A vanished mount or temporarily unavailable save-panel grant is not
      // completion or cancellation. Keep the durable destination and verified
      // bytes; the caller applies the same bounded retry/parking policy as for
      // an opener that throws. A new user-selected path can replace this intent.
      throw StateError('Download destination unavailable');
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
    _inFlight.clear();
    _preparations.clear();
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
