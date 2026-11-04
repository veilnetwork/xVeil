part of 'messaging_core.dart';

/// The first network attempt for a durably queued group frame. Sync responses
/// can be created inside serialized inbound handling: waiting for their live
/// legs there blocks unrelated incoming chat for every response fragment.
extension _GroupSourceSending on _MessagingReplication {
  String _groupSourceKey(int epoch, String peerHex, String frameId) =>
      crypto.sha256.convert(utf8.encode('$epoch|$peerHex|$frameId')).toString();

  void _cancelQueuedGroupFrame(String peerHex, String frameId) {
    // ACK ids are untrusted. Only bounded source IDs can own queue work.
    if (frameId.length > 340 ||
        (!frameId.startsWith('grp:') && !frameId.startsWith('grpc:'))) {
      return;
    }
    _owner._groupSourceQueue.cancelPending(
      _groupSourceKey(_groupEpoch, peerHex, frameId),
    );
  }

  Future<void> _sendStoredGroupFrame(
    NodeId destination,
    String frameId,
    WireEnvelope envelope, {
    required bool awaitInitialSend,
  }) async {
    if (awaitInitialSend) {
      await _owner.sendDurable(destination, frameId, envelope);
      return;
    }
    await _sendStoredGroupFrames(destination, [
      (frameId: frameId, envelope: envelope),
    ]);
  }

  Future<void> _sendStoredGroupFrames(
    NodeId destination,
    List<({String frameId, WireEnvelope envelope})> frames, {
    bool awaitInitialSend = false,
  }) async {
    if (frames.isEmpty || frames.length > _kMaxGroupReasmChunks) {
      throw ArgumentError('group persistence transfer exceeds its bound');
    }
    if (_owner._disposed) throw StateError('messaging is disposing');
    _refreshGroupHandlers();
    final epoch = _groupEpoch;
    final peer = NodeId(Uint8List.fromList(destination.bytes));
    final skipLive = await _owner._outbox._longSilent(peer.hex);
    final prepared = [
      for (final frame in frames)
        (
          frameId: frame.frameId,
          background: _MessagingOutbox._usesBackgroundLane(frame.envelope.kind),
          wire: frame.envelope.withFrameId(frame.frameId).encode(),
        ),
    ];
    // Publication/ACK of the request may proceed only after its reply frames
    // exist durably. A refused first-attempt job leaves the ordinary outbox
    // row intact for retry, including across shutdown and restart.
    // One complete image, not independently committed cohorts: a crash or lost
    // reply must not strand an unfilterable prefix of a mixed snapshot.
    if (prepared.length == 1) {
      final frame = prepared.single;
      await _owner._outbox.enqueue(peer, frame.frameId, frame.wire);
    } else {
      await _owner._outbox.enqueueTransfer(peer, [
        for (final frame in prepared)
          OutboxFrame(
            frameId: frame.frameId,
            peerHex: peer.hex,
            wire: frame.wire,
          ),
      ]);
    }
    // The awaited initial leg must retain its attempt across startup cleanup;
    // queue-only responses never await that barrier inside ingress.
    if (awaitInitialSend) await _owner._expiryLifecycle.settle();
    if (skipLive || !_currentGroupEpoch(epoch)) return;
    if (awaitInitialSend) {
      for (final frame in prepared) {
        if (!_currentGroupEpoch(epoch)) return;
        await _owner._outbox.boundedLiveLeg(
          _sendCurrentStoredGroupWire(
            peer,
            frame.frameId,
            frame.wire,
            epoch: epoch,
            background: frame.background,
          ),
        );
      }
      return;
    }
    for (final frame in prepared) {
      _queueStoredGroupWire(
        peer,
        frame.frameId,
        frame.wire,
        epoch: epoch,
        background: frame.background,
      );
    }
  }

  Future<void> _sendCurrentStoredGroupWire(
    NodeId peer,
    String frameId,
    Uint8List wire, {
    required int epoch,
    required bool background,
  }) async {
    if (_owner._expiryLifecycle.deferSource(peer.hex, frameId) ||
        !_currentGroupEpoch(epoch) ||
        _expiry.blocks(peer.hex, frameId)) {
      return;
    }
    if (!await _owner._storage.containsOutboxFrame(
      OutboxFrame(frameId: frameId, peerHex: peer.hex, wire: wire),
    )) {
      return;
    }
    if (!_currentGroupEpoch(epoch) ||
        _expiry.blocks(peer.hex, frameId) ||
        _owner._expiryLifecycle.deferSource(peer.hex, frameId)) {
      return;
    }
    // Admission already owns the complete durable image. Never enqueue here:
    // TTL/ACK may have retired it while a preceding live attempt was pending.
    _owner._outbox.recordQueued(frameId, peer.hex);
    await _owner._send(peer, wire, background: background);
  }

  void _queueStoredGroupWire(
    NodeId peer,
    String frameId,
    Uint8List wire, {
    required int epoch,
    required bool background,
  }) {
    final queue = _owner._groupSourceQueue;
    // Charge the encoded payload, bounded IDs and routing/closure overhead.
    // The worker keeps no original inbound message, bundle or admission lease.
    final bytes = 512 + 6 * frameId.length + 2 * wire.length;
    final key = bytes > queue.maxBytes
        ? 'oversized'
        : _groupSourceKey(epoch, peer.hex, frameId);
    final dropped = queue.dropped;
    final done = queue.submit(
      key: key,
      lane: peer.hex,
      bytes: bytes,
      send: () async {
        // Await the actual attempt, rather than detaching a timed-out send
        // per fragment. Only one initial send is active per recipient, with
        // four recipient lanes sharing the worker's global count/byte budget.
        await _sendCurrentStoredGroupWire(
          peer,
          frameId,
          wire,
          epoch: epoch,
          background: background,
        );
      },
    );
    if (queue.dropped != dropped && queue.dropped & (queue.dropped - 1) == 0) {
      devLog(
        () =>
            'xVeil[group]: initial-send queue refused ${queue.dropped} jobs; durable retries retained',
      );
    }
    unawaited(done);
  }
}
