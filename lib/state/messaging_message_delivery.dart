part of 'messaging_core.dart';

/// Retry, acknowledgement and bounded reconnect lifecycle for ordinary chat
/// messages.
///
/// Durable control frames and mailbox sealing have their own collaborators.
/// This subsystem coordinates those paths with the event-log message outbox,
/// keeping all session-only delivery state together and off the service core.
class _MessagingMessageDelivery {
  _MessagingMessageDelivery(this._owner);

  final MessagingService _owner;

  /// Per-message live-resend backoff. The outbox flush fires every 3s, but
  /// re-sending every un-acked message on every tick becomes an onion/FFI storm
  /// under persistent loss. The first retry remains immediate; later retries
  /// back off 3s, 6s, 12s, 24s and stay capped there.
  final Map<String, ({int count, DateTime nextAt, String peer})> _retryBackoff =
      {};

  /// Bounds inbound-triggered retry rewinds to one per peer per retry interval.
  final Map<String, DateTime> _lastNudgeAt = {};

  /// Session early-cancel and ACK dedup. Durable delivered status remains the
  /// source of truth across restart.
  final Set<String> _delivered = {};

  /// Per-peer reconnect probe throttle. Give-up itself is per message below.
  final Map<String, DateTime> _lastReconnectAt = {};

  static const _retryInterval = Duration(seconds: 3);
  static const _maxRetryBackoff = Duration(seconds: 24);
  static const _reconnectThreshold = Duration(minutes: 2);
  static const _reconnectInterval = Duration(minutes: 15);
  static const _reconnectGiveUpAge = Duration(minutes: 90);

  Duration get retryInterval => _retryInterval;

  /// Stop retrying immediately, reset the peer's recovery throttle and return
  /// whether this is the first ACK for the message in this process.
  bool noteAck(String peerHex, String messageId) {
    _retryBackoff.remove(messageId);
    _lastReconnectAt.remove(peerHex);
    return _delivered.add(messageId);
  }

  /// Any authenticated inbound proves the peer's path is healthy now. Rewind
  /// pending retry windows without resetting their exponential-backoff counts.
  void nudge(String peerHex) {
    final now = DateTime.now();
    final last = _lastNudgeAt[peerHex];
    if (last != null && now.difference(last) < _retryInterval) return;
    _lastNudgeAt[peerHex] = now;
    var nudged = false;
    for (final id in _retryBackoff.keys.toList()) {
      final backoff = _retryBackoff[id]!;
      if (backoff.peer == peerHex && backoff.nextAt.isAfter(now)) {
        _retryBackoff[id] = (
          count: backoff.count,
          nextAt: now,
          peer: backoff.peer,
        );
        nudged = true;
      }
    }
    // Durable control frames use the same alive-now rewind as messages.
    if (_owner._outbox.nudge(peerHex)) nudged = true;
    if (nudged) unawaited(_owner._retryFlush());
  }

  /// Re-drive durable control frames, reconciliation beacons and ordinary
  /// messages. Public callers continue to use [MessagingService.flushOutbox].
  Future<void> flush() async {
    // Control frames are independent of conversation message state.
    await _owner._flushOutboxFrames();
    // Background chat work waits while a call owns the latency budget.
    if (_owner.backgroundStashPaused) return;
    final conversations = await _owner._storage.loadConversations();
    for (final conversation in conversations) {
      if (conversation.peer.status != ContactStatus.accepted) continue;
      final peer = conversation.peer.nodeId;
      _owner._sendSyncBestEffort(peer);
      final messages = await _owner._storage.loadMessages(conversation.id);
      // Runs before unresolved-peer backoff so dead identities still terminate.
      await _maybeReconnect(peer, messages);
      if (_owner._mailboxDelivery.peerBackedOff(peer.hex, DateTime.now())) {
        continue;
      }
      for (final message in messages) {
        if (message.direction != MessageDirection.outgoing ||
            message.status != MessageStatus.sent ||
            _delivered.contains(message.id) ||
            message.isFile) {
          continue;
        }

        final now = DateTime.now();
        final backoff = _retryBackoff[message.id];
        if (backoff != null && now.isBefore(backoff.nextAt)) continue;
        final count = (backoff?.count ?? 0) + 1;
        // Clamp the shift: an unbounded count eventually wraps the delay to 0.
        final delayMs =
            (_retryInterval.inMilliseconds * (1 << (count - 1).clamp(0, 10)))
                .clamp(0, _maxRetryBackoff.inMilliseconds);
        _retryBackoff[message.id] = (
          count: count,
          nextAt: now.add(Duration(milliseconds: delayMs)),
          peer: peer.hex,
        );

        // Preserve the original timestamp and author sequence so retry and
        // gap-fill fold into the same convergent event on the recipient.
        final recommendation = parseSpaceRecommendationMessage(message.body);
        final wire =
            (recommendation == null
                    ? WireEnvelope.message(
                        message.body,
                        id: message.id,
                        sentAtMs: message.timestamp.millisecondsSinceEpoch,
                        seq: message.seq,
                        replyTo: message.replyToId,
                        forwardedFrom: message.forwardedFrom,
                        customEmoji: message.customEmoji,
                      )
                    : WireEnvelope.spaceRecommendation(
                        recommendation,
                        id: message.id,
                        sentAtMs: message.timestamp.millisecondsSinceEpoch,
                        seq: message.seq,
                      ))
                .encode();
        devLog(
          () =>
              'xVeil[timeline]: retry id=${message.id} '
              't=${DateTime.now().millisecondsSinceEpoch}',
        );
        // Only the initial send creates a one-shot reply circuit. Retrying that
        // setup every three seconds was the dominant circuit-build load.
        await _owner._send(peer, wire);
        _owner._stashInBackground(peer, message.id, wire);
      }
    }
  }

  /// Re-introduce a peer that may have forgotten us, and give each old message
  /// its own terminal deadline so new traffic cannot keep stale work alive.
  Future<void> _maybeReconnect(NodeId peer, List<Message> messages) async {
    final now = _owner._now();
    var failedAny = false;
    var anyTrying = false;
    for (final message in messages) {
      if (message.direction != MessageDirection.outgoing ||
          message.status != MessageStatus.sent ||
          _delivered.contains(message.id) ||
          now.difference(message.timestamp) <= _reconnectThreshold) {
        continue;
      }
      if (now.difference(message.timestamp) > _reconnectGiveUpAge) {
        await _owner._storage.markMessageStatus(
          peer.hex,
          message.id,
          MessageStatus.failed,
        );
        failedAny = true;
      } else {
        anyTrying = true;
      }
    }
    if (failedAny) _owner._signal();

    final reconnectFrameId = 'reconnect:${peer.hex}';
    if (!anyTrying) {
      if (_lastReconnectAt.remove(peer.hex) != null ||
          _owner._outbox.hasLiveEntry(peer.hex, reconnectFrameId)) {
        _owner._retireOutboxFrame(peer.hex, reconnectFrameId);
      }
      return;
    }
    final last = _lastReconnectAt[peer.hex];
    if (last != null && now.difference(last) < _reconnectInterval) return;
    _lastReconnectAt[peer.hex] = now;
    _owner._mailboxDelivery.removeStashed(reconnectFrameId);
    await _owner.sendDurable(
      peer,
      reconnectFrameId,
      const WireEnvelope.reconnect(''),
    );
    devLog(() => 'xVeil[reconnect]: -> ${peer.short}');
  }
}
