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
    if (_owner._disposed) throw StateError('messaging is disposing');
    _refreshGroupHandlers();
    final epoch = _groupEpoch;
    final peer = NodeId(Uint8List.fromList(destination.bytes));
    final skipLive = await _owner._outbox._longSilent(peer.hex);
    final background = _MessagingOutbox._usesBackgroundLane(envelope.kind);
    final wire = envelope.withFrameId(frameId).encode();
    // Publication/ACK of the request may proceed only after its reply frames
    // exist durably. A refused first-attempt job leaves the ordinary outbox
    // row intact for retry, including across shutdown and restart.
    await _owner._outbox.enqueue(peer, frameId, wire);
    if (skipLive || !_currentGroupEpoch(epoch)) return;
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
        if (!_currentGroupEpoch(epoch)) return;
        // Await the actual attempt, rather than detaching a timed-out send
        // per fragment. Only one initial send is active per recipient, with
        // four recipient lanes sharing the worker's global count/byte budget.
        await _owner._send(peer, wire, background: background);
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
