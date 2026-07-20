part of 'messaging_core.dart';

typedef _ActiveContentFetch = ({
  ContentManifest manifest,
  ContentTransfer xfer,
  NodeId peer,
  String name,
  _FetchSink? sink,
});

/// Owns receive-side datagram reassembly and plaintext sink handles.
///
/// Stream/range pulls remain in [MessagingService]. This registry centralizes
/// stale eviction, chunk re-request cadence and teardown for the conservative
/// piece fallback so a sink never disappears through a bare map removal.
class _MessagingContentFetching {
  _MessagingContentFetching(this._owner);

  final MessagingService _owner;

  static const _staleTimeout = Duration(minutes: 5);

  final Map<String, _ActiveContentFetch> _entries = {};
  final Map<String, DateTime> _activity = {};
  final Set<Future<void>> _pendingCloses = {};
  Timer? _timer;

  int get count => _entries.length;

  bool contains(String contentId) => _entries.containsKey(contentId);

  _ActiveContentFetch? active(String contentId) => _entries[contentId];

  bool refreshManifest(NodeId peer, ContentManifest manifest) {
    final current = _entries[manifest.contentId];
    if (current == null) return false;
    _entries[manifest.contentId] = (
      manifest: manifest,
      xfer: current.xfer,
      peer: peer,
      name: manifest.name,
      sink: current.sink,
    );
    return true;
  }

  void add(
    String contentId, {
    required ContentManifest manifest,
    required ContentTransfer xfer,
    required NodeId peer,
    required String name,
    required _FetchSink? sink,
  }) {
    _entries[contentId] = (
      manifest: manifest,
      xfer: xfer,
      peer: peer,
      name: name,
      sink: sink,
    );
    _activity[contentId] = _owner._now();
  }

  void touch(String contentId) => _activity[contentId] = _owner._now();

  _ActiveContentFetch? take(String contentId) {
    _activity.remove(contentId);
    return _entries.remove(contentId);
  }

  Future<_ActiveContentFetch?> discard(String contentId) async {
    final fetch = take(contentId);
    if (fetch?.sink != null) await _close(fetch!.sink!);
    return fetch;
  }

  Future<void> evictStale() async {
    final cutoff = _owner._now();
    final stale = <_ActiveContentFetch>[];
    for (final contentId in _entries.keys.toList(growable: false)) {
      final last = _activity[contentId];
      if (last == null || cutoff.difference(last) <= _staleTimeout) continue;
      final fetch = take(contentId);
      if (fetch != null) stale.add(fetch);
    }
    await Future.wait([
      for (final fetch in stale)
        if (fetch.sink != null) _close(fetch.sink!),
    ]);
  }

  void ensureTimer() {
    _timer ??= Timer.periodic(
      _owner._contentReRequestInterval,
      (_) => unawaited(_reRequest()),
    );
  }

  Future<void> _reRequest() async {
    await evictStale();
    if (_entries.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    for (final fetch in _entries.values) {
      // Window the re-request to a few unverified pieces and ask for only their
      // missing chunks. This keeps both the request and sender burst bounded.
      final pieces = fetch.xfer.nextUnverifiedPieces(
        MessagingService._reRequestPieceWindow,
      );
      if (pieces.isEmpty) continue;
      final bitmaps = {
        for (final piece in pieces) piece: fetch.xfer.missingChunkBitmap(piece),
      };
      final remaining = fetch.xfer.missingPieces().length;
      devLog(
        () =>
            'xVeil[content]: re-request '
            '${fetch.manifest.contentId.substring(0, 12)} — chunk-granular over '
            'pieces $pieces ($remaining/${fetch.manifest.pieceCount} unverified) '
            '-> ${fetch.peer.short}',
      );
      unawaited(
        _owner._send(
          fetch.peer,
          pieceRequestEnvelope(
            contentId: fetch.manifest.contentId,
            bitmaps: bitmaps,
          ).encode(),
        ),
      );
    }
  }

  Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    final sinks = Set<_FetchSink>.identity();
    for (final fetch in _entries.values) {
      if (fetch.sink != null) sinks.add(fetch.sink!);
    }
    _entries.clear();
    _activity.clear();
    await Future.wait([
      ..._pendingCloses,
      for (final sink in sinks) _close(sink),
    ]);
  }

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
}
