part of 'messaging_core.dart';

/// Bounded 1:1 event-log reconciliation over authenticated peer sessions.
///
/// Sync beacons advertise per-author high-water marks and holes. The peer then
/// re-ships missing events, while throttles and bounded batches prevent an
/// absent or hostile peer from creating background traffic or amplification.
class _MessagingPeerSync {
  _MessagingPeerSync(this._owner);

  final MessagingService _owner;

  final Map<String, DateTime> _lastSentAt = {};
  final Map<String, DateTime> _lastActedAt = {};
  final Map<String, int> _unanswered = {};

  static const _sendInterval = Duration(seconds: 20);
  static const _backoffCap = Duration(minutes: 10);
  static const _actInterval = Duration(seconds: 5);
  static const _reshipCap = 100;

  /// Let a reconnect beacon immediately and bound session-scoped throttle maps.
  void resetSession() {
    _lastSentAt.clear();
    _lastActedAt.clear();
  }

  /// Any authenticated inbound proves that the peer is answering again.
  void noteInbound(NodeId peer) => _unanswered.remove(peer.hex);

  /// Send a gap-fill beacon over the live path. Offline peers beacon when they
  /// return, so this intentionally does not create a mailbox deposit.
  Future<void> _send(NodeId peer, {bool force = false}) async {
    final now = DateTime.now();
    final last = _lastSentAt[peer.hex];
    // Escalate for peers that never answer: 20s → … → 10m.
    final streak = _unanswered[peer.hex] ?? 0;
    var interval = _sendInterval * (1 << (streak > 5 ? 5 : streak));
    if (interval > _backoffCap) interval = _backoffCap;
    if (!force && last != null && now.difference(last) < interval) return;
    _lastSentAt[peer.hex] = now;
    _unanswered[peer.hex] = streak + 1;

    // Declare the prefix of our stream that no longer exists at the source.
    // Persisting it locally first keeps our own high-water and holes honest.
    final selfHex = await _owner._selfHex();
    final ownFloor = await _owner._storage.ownSyncFloor(peer.hex, selfHex);
    if (ownFloor > 0) {
      await _owner._storage.applyAuthorSyncFloor(peer.hex, selfHex, ownFloor);
    }
    final sync = await _owner._storage.conversationSync(peer.hex);
    final holes = <String, List<List<int>>>{
      for (final e in sync.holes.entries)
        e.key: [
          for (final h in e.value) [h.$1, h.$2],
        ],
    };
    final body = jsonEncode({
      'hw': sync.highWater,
      if (holes.isNotEmpty) 'holes': holes,
      if (ownFloor > 0) 'fl': {selfHex: ownFloor},
      'ep': now.millisecondsSinceEpoch,
    });
    devLog(
      () =>
          'xVeil[sync]: -> ${peer.short} hw=${sync.highWater} '
          'holes=${holes.length}',
    );
    await _owner._send(peer, WireEnvelope.sync(body).encode());
  }

  void sendBestEffort(NodeId peer, {bool force = false}) {
    unawaited(
      _send(peer, force: force).catchError((_) {
        // Advisory reconciliation must not abort another in-flight operation.
      }),
    );
  }

  /// Re-ship events authored by us above the peer's bounded, clamped high-water.
  Future<void> handle(NodeId peer, String body) async {
    final now = DateTime.now();
    final lastActed = _lastActedAt[peer.hex];
    if (lastActed != null && now.difference(lastActed) < _actInterval) {
      sendBestEffort(peer);
      return;
    }
    _lastActedAt[peer.hex] = now;

    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final highWater = json['hw'];
    if (highWater is! Map) return;
    final selfHex = await _owner._selfHex();

    // A peer may void only a prefix of its own authenticated author stream.
    final floors = json['fl'];
    if (floors is Map) {
      final declared = floors[peer.hex];
      if (declared is int && declared > 0) {
        await _owner._storage.applyAuthorSyncFloor(
          peer.hex,
          peer.hex,
          declared,
        );
      }
    }

    final claimed = highWater[selfHex];
    var peerHighWater = claimed is int && claimed >= 0 ? claimed : 0;
    // Anti-forgery: a peer cannot acknowledge a sequence we never emitted.
    final ours = await _owner._storage.conversationSync(peer.hex);
    final ourMax = ours.highWater[selfHex] ?? 0;
    if (peerHighWater > ourMax) peerHighWater = ourMax;

    final events = await _owner._storage.loadEventsSince(
      peer.hex,
      selfHex,
      peerHighWater,
      limit: _reshipCap,
    );
    if (events.isNotEmpty) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} peerHw(me)=$peerHighWater '
            'reship=${events.length}',
      );
      final byId = {
        for (final message in await _owner._storage.loadMessages(peer.hex))
          message.id: message,
      };
      for (final event in events) {
        switch (event.kind) {
          case EventKind.post:
          case EventKind.filePost:
            final stored = byId[event.id];
            final isFile =
                event.kind == EventKind.filePost || (stored?.isFile ?? false);
            if (isFile) {
              if (stored == null) continue;
              final contentId = stored.fileContentId ?? stored.fileId;
              final served = contentId == null
                  ? null
                  : _owner._serving[contentId];
              if (served != null) {
                final manifest = served.manifest.withEvent(
                  msgId: event.id,
                  author: selfHex,
                  seq: event.seq,
                  ts: event.ts,
                );
                await _owner._sendContentManifest(peer, manifest);
                continue;
              }
              // Legacy transfers heal by querying only the missing chunks.
              if (stored.fileId == null) continue;
              await _owner._send(
                peer,
                fileQueryEnvelope(
                  transferId: event.id,
                  name: stored.fileName,
                  seq: event.seq,
                  sentAtMs: event.ts,
                ).encode(),
              );
              continue;
            }
            final recommendation = parseSpaceRecommendationMessage(
              event.body ?? '',
            );
            await _owner._send(
              peer,
              (recommendation == null
                      ? WireEnvelope.message(
                          event.body ?? '',
                          id: event.id,
                          sentAtMs: event.ts,
                          seq: event.seq,
                          replyTo: event.replyTo,
                          forwardedFrom: event.forwardedFrom,
                          customEmoji: stored?.customEmoji ?? const [],
                        )
                      : WireEnvelope.spaceRecommendation(
                          recommendation,
                          id: event.id,
                          sentAtMs: event.ts,
                          seq: event.seq,
                        ))
                  .encode(),
            );
          case EventKind.edit:
            if (event.target == null) continue;
            await _owner._send(
              peer,
              WireEnvelope.edit(
                event.target!,
                event.body ?? '',
                seq: event.seq,
                customEmoji: event.customEmoji,
              ).encode(),
            );
          case EventKind.void_:
            await _owner._send(peer, WireEnvelope.voidSeq(event.seq).encode());
          case EventKind.delete:
          case EventKind.clear:
            continue;
        }
      }
    }
    sendBestEffort(peer);
  }
}
