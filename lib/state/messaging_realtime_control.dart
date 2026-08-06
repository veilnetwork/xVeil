part of 'messaging_core.dart';

/// Outbox key prefix for a direct-endpoint share. One place, because the code
/// that mints these ids and the code that retires the superseded ones must
/// agree — a silent disagreement leaves the old frames re-driving.
const _kP2PEndpointFramePrefix = 'p2p:ep:';

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

  /// This lane's own bound (audit XV-05). Smaller than the durable lane's:
  /// call control and endpoint sets are small frames, so a big one here is
  /// already the wrong shape, and the whole point of the lane is latency —
  /// a deep queue on it is worse than a dropped frame either way.
  final InboundAdmission admission = InboundAdmission(
    label: 'call-sig',
    maxBytes: 1 << 20,
    maxFrames: 512,
    maxKnownPeerBytes: 256 << 10,
    maxStrangerPeerBytes: 32 << 10,
    maxStrangerBytes: 128 << 10,
  );

  /// The tail of the serialized chain, for [MessagingService.dispose] to wait
  /// on before the shared container closes underneath it.
  Future<void> get inboundChain => _inboundChain;

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
    // Same rule as the durable lane: a frame chained before dispose() must not
    // run against a store that is being closed (audit XV-05).
    if (_owner._disposed) return;
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
      // BEFORE the contact check, not after: the cache below is primed by any
      // frame that ever looked like it came from this contact, so asking it
      // first would let the very claim under suspicion answer for itself.
      if (!_speaksForContact(message, 'endpoints')) return;
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
    if (signal.type == CallSignalType.offer) {
      if (!_speaksForContact(message, 'offer')) return;
      if (!isAccepted(message.src)) {
        final contact = await _owner._storage.getContact(message.src);
        if (contact?.status != ContactStatus.accepted) return;
        markAccepted(message.src);
      }
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

  /// Whether this delivery may be granted an accepted contact's privileges.
  ///
  /// The gates on this lane used to consult exactly one thing — "is `src` an
  /// accepted contact" — and `src` is the field the sender fills in. veil will
  /// hand the app whatever name a frame carried; what it now also hands over is
  /// how much it KNOWS about that name (audit X/V-01). An unauthenticated frame
  /// naming a contact gets a stranger's treatment, which on this lane is none.
  ///
  /// Not a ban on unauthenticated delivery, and deliberately not one. Anonymous
  /// meta-E2E arrives as [SenderProvenance.claimed] BY DESIGN and stays exactly
  /// as welcome as it was; call follow-ups (answer / end / health) are not
  /// routed through here either, because `CallService` matches them against the
  /// exact live `(peer, callId)` it is already in. What stops is a stranger
  /// wearing a contact's name to ring the phone, or to hand us bootstrap URIs
  /// we would then dial.
  ///
  /// Refusing costs the fast lane and never the delivery: both kinds this lane
  /// carries are sent on the durable contact lane at the same instant (see
  /// [_sendCallLive] and [_sendP2PBootstrap]), so the honest copy still lands.
  bool _speaksForContact(InboundMessage message, String what) {
    if (message.provenance.isAuthenticated) return true;
    devLog(
      () =>
          'xVeil[call-sig]: realtime $what from ${message.src.short} DROPPED — '
          'the delivery is unauthenticated (${message.provenance.name}), so the '
          'name is a claim, not a contact',
    );
    return false;
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
    // Retire every EARLIER endpoint frame for this peer first.
    //
    // Each share is keyed by its timestamp, so a refreshed set is a new frame
    // and the old one stays in the outbox, re-driven every few seconds until
    // acked. That was tolerable while only a call ever shared endpoints. Now a
    // conversation does, and on the stand two such frames were still being
    // re-driven minutes later — a superseded address list, retried forever.
    //
    // Superseding is what makes them moot: the receiver rejects an older set by
    // timestamp anyway ("drop endpoints … stale ts"), so re-driving one can
    // only ever produce a drop. Endpoints are, in this file's own words,
    // ephemeral runtime facts — the newest set is the only one worth sending.
    await _retireEarlierEndpointFrames(peer);
    final envelope = WireEnvelope.p2pEndpoints(bodyJson);
    await _owner.sendDurable(
      peer,
      '$_kP2PEndpointFramePrefix$sentAtMs',
      envelope,
      liveSender: (wire) => _sendP2PBootstrap(peer, wire),
      awaitLive: false,
      startLiveBeforeEnqueue: true,
    );
  }

  /// Drop this peer's pending endpoint frames from the outbox. Best-effort:
  /// failing to read the outbox must not stop us sending fresh endpoints, which
  /// is the useful half.
  Future<void> _retireEarlierEndpointFrames(NodeId peer) async {
    try {
      final pending = await _owner._storage.pendingOutboxFrames();
      for (final frame in pending) {
        if (frame.peerHex == peer.hex &&
            frame.frameId.startsWith(_kP2PEndpointFramePrefix)) {
          _owner._retireOutboxFrame(peer.hex, frame.frameId);
        }
      }
    } catch (e) {
      devLog(() => 'xVeil[p2p]: could not retire earlier endpoint frames for '
          '${peer.short} (non-fatal): $e');
    }
  }
}
