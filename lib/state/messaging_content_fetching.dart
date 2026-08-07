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

  /// Durable frame id for "please send me the missing chunks of this content".
  ///
  /// Stable per content, so however often the re-request timer fires the outbox
  /// holds ONE row for it — the same shape the endpoint shares use. The bitmap
  /// persisted is therefore the first one, which asks for a superset of what is
  /// still missing later: asking for a chunk we already have costs one chunk,
  /// asking for none costs the whole transfer.
  static String reRequestFrameId(String contentId) => 'creq:$contentId';

  _ActiveContentFetch? take(String contentId) {
    _activity.remove(contentId);
    final fetch = _entries.remove(contentId);
    if (fetch != null) {
      // Done, discarded or stale — either way stop asking. This is the single
      // removal point for a fetch, which is why the retire belongs here rather
      // than at each of its callers.
      _owner._retireOutboxFrame(fetch.peer.hex, reRequestFrameId(contentId));
    }
    return fetch;
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
      // DURABLE, not a bare live send.
      //
      // This was `_send` — live only, no offline path at all — while every
      // other control frame toward the same peer was being deposited at their
      // mailbox. So a transfer whose holder was not directly reachable stalled
      // forever: the receiver asked every 20 s, the request never left the
      // machine in any form that could arrive, and the sender sat waiting to be
      // asked. Reproduced on the stand: a 120 KB file, 8 re-requests over 140 s,
      // not one of them seen by the holder, while `p2p:ep:` and `ack:` frames to
      // that same peer deposited fine.
      unawaited(
        _owner.sendDurable(
          fetch.peer,
          reRequestFrameId(fetch.manifest.contentId),
          pieceRequestEnvelope(
            contentId: fetch.manifest.contentId,
            bitmaps: bitmaps,
          ),
          awaitLive: false,
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
