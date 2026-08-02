part of 'messaging_core.dart';

/// Latency-critical 1:1 call and direct-endpoint control plane.
///
/// Owns the dedicated serialized inbound lane, its session-scoped consent
/// cache, and outbound live-lane selection. Durable persistence and re-drive
/// remain owned by [_MessagingOutbox].
class _MessagingRealtimeControl {
  _MessagingRealtimeControl(this._owner);

  final MessagingService _owner;

  /// Follow-up call control is accepted only by CallService's active
  /// `(peer, callId)` FSM. New offers are consent-checked here first.
  void Function(NodeId peer, CallSignal signal)? onCallSignal;

  /// Endpoint exchange can initiate a dial and is therefore always gated by an
  /// accepted relationship before this callback fires.
  void Function(NodeId peer, String bodyJson)? onP2PEndpoints;

  final Set<String> _acceptedPeers = {};
  Future<void> _inboundChain = Future<void>.value();

  bool isAccepted(NodeId peer) => _acceptedPeers.contains(peer.hex);

  void markAccepted(NodeId peer) => _acceptedPeers.add(peer.hex);

  void revoke(NodeId peer) => _acceptedPeers.remove(peer.hex);

  /// Serialize APP_RT frames independently from the durable inbox. A transient
  /// failure drops only one datagram and cannot poison later answer/end frames.
  Future<void> deliverInbound(InboundMessage message) {
    final next = _inboundChain.then((_) async {
      try {
        await _handleInbound(message);
      } catch (error, stackTrace) {
        devLog(
          () =>
              'xVeil[call-sig]: realtime dispatch FAILED '
              'from=${message.src.short}: $error\n$stackTrace',
        );
      }
    });
    _inboundChain = next;
    return next;
  }

  Future<void> _handleInbound(InboundMessage message) async {
    late final WireEnvelope envelope;
    try {
      envelope = WireEnvelope.decode(message.payload);
    } catch (error) {
      devLog(
        () =>
            'xVeil[call-sig]: realtime decode FAILED '
            'from=${message.src.short}: $error',
      );
      return;
    }
    if (envelope.kind != WireKind.callSignal &&
        envelope.kind != WireKind.p2pEndpoints) {
      // Fail closed: APP_RT must not become a route around message consent.
      return;
    }

    if (envelope.kind == WireKind.p2pEndpoints) {
      if (!isAccepted(message.src)) {
        final contact = await _owner._storage.getContact(message.src);
        if (contact?.status != ContactStatus.accepted) return;
        markAccepted(message.src);
      }
      final frameId = envelope.frameId;
      if (frameId != null) {
        final fresh = _owner._outbox.remember(message.src.hex, frameId);
        unawaited(_owner._ackFrame(message, frameId));
        if (!fresh) return;
      }
      _noteInbound(message.src);
      devLog(
        () =>
            'xVeil[p2p]: realtime in endpoints from=${message.src.short} '
            '(${envelope.body.length} B)',
      );
      final endpointsHandler = onP2PEndpoints;
      if (endpointsHandler == null) {
        // The endpoint service registers this callback in start(); losing a
        // frame here means the service was never instantiated (see the eager
        // watch in app.dart) — say so instead of vanishing the frame.
        devLog(
          () =>
              'xVeil[p2p]: endpoints frame from ${message.src.short} dropped '
              '(no endpoint service attached)',
        );
      } else {
        endpointsHandler(message.src, envelope.body);
      }
      return;
    }

    final signal = CallSignal.tryDecode(envelope.body);
    if (signal == null) return;
    // Only an offer can create a call. Follow-ups avoid a storage read because
    // CallService independently checks the exact active `(peer, callId)`.
    if (signal.type == CallSignalType.offer && !isAccepted(message.src)) {
      final contact = await _owner._storage.getContact(message.src);
      if (contact?.status != ContactStatus.accepted) return;
      markAccepted(message.src);
    }
    final frameId = envelope.frameId;
    if (frameId != null) {
      final fresh = _owner._outbox.remember(message.src.hex, frameId);
      // Delivery into the call FSM is latency-critical; ACK storage/mailbox
      // work runs independently after dedup state is recorded.
      unawaited(_owner._ackFrame(message, frameId));
      if (!fresh) return;
    }
    _noteInbound(message.src);
    devLog(() {
      final sentAt = signal.sentAtMs;
      final age = sentAt == null
          ? 'n/a'
          : '${_owner._now().millisecondsSinceEpoch - sentAt}ms';
      return 'xVeil[call-sig]: realtime in type=${signal.type.name} '
          'call=${signal.callId} from=${message.src.short} age=$age';
    });
    onCallSignal?.call(message.src, signal);
  }

  void _noteInbound(NodeId peer) {
    _owner._peerSync.noteInbound(peer);
    _owner._nudgeRetries(peer.hex);
    _owner.noteInboundFromPeer(peer);
  }

  Future<void> sendRealtime(NodeId peer, Uint8List wire) {
    final transport = _owner._transport;
    if (transport is RealtimeTransport) {
      return (transport as RealtimeTransport).sendRealtime(
        peer,
        wire,
        anonymous: _owner._anonymous,
      );
    }
    return _owner._send(peer, wire);
  }

  Future<void> _sendRelayRealtime(NodeId peer, Uint8List wire) {
    final transport = _owner._transport;
    if (transport is RelayRealtimeTransport) {
      return (transport as RelayRealtimeTransport).sendRelayRealtime(
        peer,
        wire,
      );
    }
    return Future<void>.error(
      UnsupportedError('relay realtime transport unavailable'),
    );
  }

  Future<void> _sendRealtimePaths(
    String scope,
    NodeId peer,
    Uint8List wire,
  ) async {
    if (_owner._anonymous) {
      await sendRealtime(peer, wire);
      return;
    }
    await Future.wait<void>([
      _attempt(scope, 'realtime direct', peer, () => sendRealtime(peer, wire)),
      _attempt(
        scope,
        'realtime relay',
        peer,
        () => _sendRelayRealtime(peer, wire),
      ),
    ]);
  }

  /// Send one already-signed and epoch-encrypted group-call signal. Lifecycle
  /// transitions are durable; heartbeats stay best-effort because the next one
  /// supersedes stale liveness work.
  Future<void> sendGroupCallSignal(
    NodeId peer,
    GroupCallSignal signal,
    String frameJson,
  ) async {
    final envelope = WireEnvelope.groupCallSignal(
      frameJson,
      sentAtMs: signal.sentAtMs,
    );
    // Keep group-call control on the dedicated realtime IPC connection. The
    // main client can be occupied by mailbox drains, anonymous sends or file
    // streams on the node's sequential per-connection loop.
    if (signal.type == GroupCallSignalType.heartbeat) {
      await _sendRealtimePaths('gcall-sig', peer, envelope.encode());
      return;
    }
    await _owner.sendDurable(
      peer,
      'gcall:${signal.groupId.hex}:${signal.callId}:'
      '${signal.type.name}:${signal.nonce}',
      envelope,
      liveSender: (wire) => _sendRealtimePaths('gcall-sig', peer, wire),
      awaitLive: false,
    );
  }

  /// Race admitted realtime and ordinary contact lanes for call control. Both
  /// copies share one durable frame id, so receiver dedup makes this safe.
  Future<void> _sendCallLive(NodeId peer, Uint8List wire) async {
    if (_owner._anonymous) {
      await sendRealtime(peer, wire);
      return;
    }
    if (_owner._transport is! RealtimeTransport) {
      await _owner._send(peer, wire);
      return;
    }
    await Future.wait<void>([
      _attempt('call-sig', 'contact', peer, () => _owner._send(peer, wire)),
      _sendRealtimePaths('call-sig', peer, wire),
    ]);
  }

  /// Endpoint exchange creates the direct session, so race the pre-admission
  /// contact lane with realtime instead of waiting for a mailbox re-drive.
  Future<void> _sendP2PBootstrap(NodeId peer, Uint8List wire) async {
    if (_owner._transport is! RealtimeTransport) {
      await _owner._send(peer, wire);
      return;
    }
    await Future.wait<void>([
      _attempt(
        'p2p',
        'bootstrap contact',
        peer,
        () => _owner._send(peer, wire),
      ),
      _sendRealtimePaths('p2p bootstrap', peer, wire),
    ]);
  }

  Future<void> _attempt(
    String scope,
    String lane,
    NodeId peer,
    Future<void> Function() send,
  ) async {
    try {
      await send();
    } catch (error) {
      devLog(
        () =>
            'xVeil[$scope]: $lane live leg failed '
            'peer=${peer.short}: $error',
      );
    }
  }

  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    markAccepted(peer);
    final stamped = signal.sentAtMs == null
        ? signal.copyWith(sentAtMs: _owner._now().millisecondsSinceEpoch)
        : signal;
    devLog(
      () =>
          'xVeil[call-sig]: out type=${stamped.type.name} '
          'call=${stamped.callId} to=${peer.short}',
    );
    final envelope = WireEnvelope.callSignal(stamped.encode());
    if (stamped.type == CallSignalType.health) {
      await _sendRealtimePaths('call-sig', peer, envelope.encode());
      return;
    }
    final frameId = stamped.type == CallSignalType.renegotiate
        ? 'call:${signal.callId}:${signal.type.name}:${stamped.sentAtMs}'
        : 'call:${signal.callId}:${signal.type.name}';
    await _owner.sendDurable(
      peer,
      frameId,
      envelope,
      liveSender: (wire) => _sendCallLive(peer, wire),
      awaitLive: false,
      startLiveBeforeEnqueue: true,
    );
  }

  Future<void> sendP2PEndpoints(
    NodeId peer,
    String bodyJson, {
    required int sentAtMs,
  }) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    markAccepted(peer);
    devLog(
      () =>
          'xVeil[p2p]: out endpoints to=${peer.short} '
          '(${bodyJson.length} B)',
    );
    final envelope = WireEnvelope.p2pEndpoints(bodyJson);
    await _owner.sendDurable(
      peer,
      'p2p:ep:$sentAtMs',
      envelope,
      liveSender: (wire) => _sendP2PBootstrap(peer, wire),
      awaitLive: false,
      startLiveBeforeEnqueue: true,
    );
  }
}
