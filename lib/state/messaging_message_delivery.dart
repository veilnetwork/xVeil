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

  // Coalesce timer/reconnect/manual passes. A later caller starts no duplicate
  // jobs and need not wait behind another caller's unfinished journal write.
  Future<void>? _conversationPass;
  final Map<String, Object> _activeMessageSends = {};
  static const _retryPeerLanes = 4;

  /// Per-message live-resend backoff. The outbox flush fires every 3s, but
  /// re-sending every un-acked message on every tick becomes an onion/FFI storm
  /// under persistent loss. The first retry remains immediate; later retries
  /// back off 3s, 6s, 12s, 24s and stay capped there.
  final Map<String, ({int count, DateTime nextAt, String peer})> _retryBackoff =
      {};

  /// Bounds inbound-triggered retry rewinds to one per peer per retry interval.
  final Map<String, DateTime> _lastNudgeAt = {};

  /// Steady inbound can nudge durable controls without rewinding messages.
  /// It must not consume the retry opportunity of a restored direct route.
  /// Silence-ending inbound and direct-route events share this throttle so
  /// those two recovery signals cannot immediately duplicate each other.
  final Map<String, DateTime> _lastRecoveryNudgeAt = {};

  /// When each peer was last heard from, on the service clock — whether that
  /// inbound rewound anything or not (see [nudge]).
  final Map<String, DateTime> _lastHeardAt = {};

  /// Session early-cancel and ACK dedup. Durable delivered status remains the
  /// source of truth across restart.
  final _delivered = DeliveryAckCache();

  // A trusted sibling can report delivery before this device receives the
  // mirror. Keep that bounded evidence separate: an ordinary peer's ACK for
  // an absent row must not authorize a future append's initial status.
  final _mirroredDelivery = DeliveryAckCache();

  bool hasMirroredDelivery(String peerHex, String messageId) =>
      _mirroredDelivery.contains(peerHex, messageId);

  void noteMirroredDelivery(String peerHex, String messageId) {
    _mirroredDelivery.remember(peerHex, messageId);
    if (_retryBackoff[messageId]?.peer == peerHex) {
      _retryBackoff.remove(messageId);
    }
    _lastReconnectAt.remove(peerHex);
  }

  bool _hasDeliveryReceipt(String peerHex, String messageId) =>
      _delivered.contains(peerHex, messageId) ||
      hasMirroredDelivery(peerHex, messageId);

  /// Per-peer reconnect probe throttle. Give-up itself is per message below.
  final Map<String, DateTime> _lastReconnectAt = {};

  static const _retryInterval = Duration(seconds: 3);
  static const _maxRetryBackoff = Duration(seconds: 24);
  static const _reconnectThreshold = Duration(minutes: 2);
  static const _reconnectInterval = Duration(minutes: 15);
  static const _reconnectGiveUpAge = Duration(minutes: 90);

  Duration get retryInterval => _retryInterval;

  /// Stop retrying immediately, reset the peer's recovery throttle and return
  /// whether this ACK is absent from the bounded session receipt window.
  bool noteAck(String peerHex, String messageId) {
    if (_retryBackoff[messageId]?.peer == peerHex) {
      _retryBackoff.remove(messageId);
    }
    _lastReconnectAt.remove(peerHex);
    final first = _delivered.remember(peerHex, messageId);
    if (first) diagnosticJournal.record(DiagnosticEvent.messageAcknowledged);
    return first;
  }

  /// Keep early retry cancellation while the status write is pending, but do
  /// not let a failed write become permanent ACK deduplication. A normal retry
  /// can obtain another receipt once storage recovers.
  Future<bool> persistAckStatus(String peerHex, String messageId) async {
    try {
      final moved = await _owner._storage.markMessageStatus(
        peerHex,
        messageId,
        MessageStatus.delivered,
      );
      if (!moved) {
        // false also covers a failed target read. Cache only a settled row or
        // an absent control-frame id, never a readable row still awaiting ACK.
        final target = await _owner._storage.loadMessageById(
          peerHex,
          messageId,
        );
        if (target != null && target.status != MessageStatus.delivered) {
          throw StateError('Delivery status was not saved');
        }
      }
      return moved;
    } catch (_) {
      _delivered.forget(peerHex, messageId);
      rethrow;
    }
  }

  /// Any authenticated inbound proves the peer's path is healthy now. Rewind
  /// pending retry windows without resetting their exponential-backoff counts.
  ///
  /// Messages are rewound only when a SILENCE ends ([force] for a direct
  /// session coming up). A peer that keeps talking is not coming back, and
  /// rewinding on its every frame re-sent every un-acked message each retry
  /// interval: measured on the stand after a restart, the counterpart was
  /// processing ~10 frames a second, nearly all of them re-sends, and a new
  /// message waited ~100 s behind them — its ack later still, so the re-sends
  /// fed the queue that delayed the acks that would have stopped them.
  void nudge(String peerHex, {bool force = false}) {
    // The throttle runs on the service's clock, like the outbox ladder it
    // gates; it is only ever compared with itself. On the wall clock it let
    // one nudge through per three REAL seconds, so a test stepping the
    // service clock saw the rewinds it was asserting about only once, and
    // stayed green whatever the ladder did.
    final at = _owner._now();
    final heard = _lastHeardAt[peerHex];
    _lastHeardAt[peerHex] = at;
    final silenceEnded =
        force || heard == null || at.difference(heard) >= _maxRetryBackoff;
    final last = (force ? _lastRecoveryNudgeAt : _lastNudgeAt)[peerHex];
    if (last != null && at.difference(last) < _retryInterval) return;
    _lastNudgeAt[peerHex] = at;
    if (silenceEnded) _lastRecoveryNudgeAt[peerHex] = at;
    // The message ladder below keeps the wall clock it was stamped with.
    final now = DateTime.now();
    var nudged = false;
    for (final id in silenceEnded ? _retryBackoff.keys.toList() : <String>[]) {
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
    // Both jobs have their own durable state and admission rules. A control
    // read or live-leg deadline must not defer unrelated conversation retries.
    // Join both even on failure, so a finished pass owns no detached work.
    await Future.wait<void>([
      _owner._flushOutboxFrames(),
      _flushConversations(),
    ]);
  }

  Future<void> _flushConversations() {
    final pending = _conversationPass;
    if (pending != null) return Future<void>.value();
    late final Future<void> work;
    work = _runConversationPass().whenComplete(() {
      if (identical(_conversationPass, work)) _conversationPass = null;
    });
    _conversationPass = work;
    return work;
  }

  Future<void> _runConversationPass() async {
    if (_owner._disposed || _owner.backgroundStashPaused ||
        _owner._expiryLifecycle.pending) {
      return;
    }
    final conversations = await _owner._storage.loadConversations();
    final accepted = {
      for (final conversation in conversations)
        if (conversation.peer.status == ContactStatus.accepted)
          conversation.peer.nodeId.hex,
    };
    _retryBackoff.removeWhere((_, value) => !accepted.contains(value.peer));
    _lastNudgeAt.removeWhere((peer, _) => !accepted.contains(peer));
    _lastRecoveryNudgeAt.removeWhere((peer, _) => !accepted.contains(peer));
    _lastHeardAt.removeWhere((peer, _) => !accepted.contains(peer));
    _lastReconnectAt.removeWhere((peer, _) => !accepted.contains(peer));
    var next = 0;
    Object? firstError;
    StackTrace? firstStack;
    Future<void> worker() async {
      while (!_owner._disposed &&
          !_owner.backgroundStashPaused &&
          next < conversations.length) {
        final conversation = conversations[next++];
        if (conversation.peer.status != ContactStatus.accepted) continue;
        try {
          await _retryConversation(conversation);
        } catch (error, stack) {
          // A damaged history for one contact must not skip every later one.
          // Keep the failure observable after all other admitted jobs finish.
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    await Future.wait<void>([
      for (var i = 0; i < conversations.length && i < _retryPeerLanes; i++)
        worker(),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }

  Future<void> _retryConversation(Conversation conversation) async {
    final peer = conversation.peer.nodeId;
    _owner._sendSyncBestEffort(peer);
    final cutoff = await _owner.disappearingCutoffOf(peer);
    final messages = [
      for (final message in await _owner._storage.loadMessages(conversation.id))
        if (cutoff == null || message.timestamp.isAfter(cutoff)) message,
    ];
    if (_owner._disposed || _owner.backgroundStashPaused) return;
    // Runs before unresolved-peer backoff so dead identities still terminate.
    final failed = await _maybeReconnect(peer, messages);
    final retryable = {
      for (final message in messages)
        if (message.direction == MessageDirection.outgoing &&
            !message.reflectedEdit &&
            message.status == MessageStatus.sent &&
            !failed.contains(message.id) &&
            !_hasDeliveryReceipt(peer.hex, message.id))
          message.id,
    };
    // A deleted or terminal message no longer owns retry state. Keep the
    // cleanup scoped to this conversation: other peer lanes run concurrently.
    _retryBackoff.removeWhere(
      (id, value) => value.peer == peer.hex && !retryable.contains(id),
    );
    if (_owner._disposed ||
        _owner.backgroundStashPaused ||
        _activeMessageSends.containsKey(peer.hex)) {
      return;
    }
    for (final message in messages) {
      if (_owner._disposed || _owner.backgroundStashPaused) return;
      if (message.direction != MessageDirection.outgoing ||
          message.reflectedEdit ||
          message.status != MessageStatus.sent ||
          failed.contains(message.id) ||
          _hasDeliveryReceipt(peer.hex, message.id)) {
        continue;
      }

      final now = DateTime.now();
      final backoff = _retryBackoff[message.id];
      if (backoff != null && now.isBefore(backoff.nextAt)) continue;

      // The conversation row becomes visible before its required device-log
      // commit. A timer/reconnect retry must respect the same durable boundary
      // as the initial send, including repair after an interrupted write.
      if (!await _owner._deviceMirror.prepareStoredRetry(peer, message)) {
        continue;
      }

      if (_owner._disposed || _owner.backgroundStashPaused) return;
      if (_hasDeliveryReceipt(peer.hex, message.id)) continue;
      if (!await _canRetry(peer, message)) continue;

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

      // A file message re-drives its OFFER — the manifest naming the content,
      // the same frame the original send built and deposited. The bytes are
      // never re-driven: the recipient pulls them on its own terms, and
      // re-pushing them on a 3s tick is the cost that used to justify
      // dropping file messages from this loop altogether. A message with no
      // manifest to offer (a small inline file, whose bytes ARE the send)
      // yields null and is skipped, so that cost cannot reappear here.
      //
      // Preserve the original timestamp and author sequence so retry and
      // gap-fill fold into the same convergent event on the recipient.
      diagnosticJournal.record(
        DiagnosticEvent.messageRetry,
        values: {DiagnosticMetric.attempt: count},
        minInterval: const Duration(seconds: 1),
      );
      final Uint8List wire;
      if (message.isFile) {
        final offer = await _owner._fileOfferRetryFrame(message);
        if (offer == null) continue;
        wire = offer;
        if (!await _canRetry(peer, message)) continue;
      } else {
        final recommendation = parseSpaceRecommendationMessage(message.body);
        wire =
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
      }
      devLog(
        () =>
            'xVeil[timeline]: retry id=${message.id} '
            't=${DateTime.now().millisecondsSinceEpoch}',
      );
      // Only the initial send creates a one-shot reply circuit. Retrying that
      // setup every three seconds was the dominant circuit-build load.
      // Bound this live retry so one unreachable peer does not hold every
      // later conversation's retry behind its dial.
      if (_owner._disposed || _owner.backgroundStashPaused) return;
      final lease = Object();
      _activeMessageSends[peer.hex] = lease;
      var settled = false;
      final live = _owner._send(peer, wire).whenComplete(() {
        settled = true;
        if (identical(_activeMessageSends[peer.hex], lease)) {
          _activeMessageSends.remove(peer.hex);
        }
      });
      await _owner._outbox.boundedLiveLeg(live);
      // A deadline stops waiting, not the transport. Do not stack the next
      // message or a later pass on this contact until the actual send settles.
      if (!settled) return;
    }
  }

  Future<bool> _canRetry(NodeId peer, Message message) async {
    if (await _owner._storage.isMessageDeleted(peer.hex, message.id)) return false;
    final setting = await _owner.disappearingOf(peer);
    return !_owner._disposed &&
        !_owner.backgroundStashPaused &&
        !setting.hasExpired(message.timestamp, _owner._now());
  }

  /// Re-introduce a peer that may have forgotten us, and give each old message
  /// its own terminal deadline so new traffic cannot keep stale work alive.
  Future<Set<String>> _maybeReconnect(
    NodeId peer,
    List<Message> messages,
  ) async {
    final now = _owner._now();
    var failedAny = false;
    final failed = <String>{};
    var anyTrying = false;
    for (final message in messages) {
      if (message.direction != MessageDirection.outgoing ||
          message.reflectedEdit ||
          message.status != MessageStatus.sent ||
          _hasDeliveryReceipt(peer.hex, message.id) ||
          now.difference(message.timestamp) <= _reconnectThreshold) {
        continue;
      }
      if (now.difference(message.timestamp) > _reconnectGiveUpAge) {
        await _owner._storage.markMessageStatus(
          peer.hex,
          message.id,
          MessageStatus.failed,
        );
        failed.add(message.id);
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
      return failed;
    }
    final last = _lastReconnectAt[peer.hex];
    if (last != null && now.difference(last) < _reconnectInterval) {
      return failed;
    }
    _lastReconnectAt[peer.hex] = now;
    _owner._mailboxDelivery.removeStashed(reconnectFrameId);
    await _owner.sendDurable(
      peer,
      reconnectFrameId,
      const WireEnvelope.reconnect(''),
    );
    devLog(() => 'xVeil[reconnect]: -> ${peer.short}');
    return failed;
  }
}
