part of 'messaging_core.dart';

// Stable diagnostic codes, independent of peer/call/frame identifiers. Append
// stages instead of reordering them; dispatched means handed to the callback,
// not accepted by the FSM or received by a remote endpoint.
enum _CallSignalDecision {
  sendRequested,
  decoded,
  malformed,
  rejectedProvenance,
  rejectedContact,
  rejectedEnding,
  duplicate,
  handlerMissing,
  dispatched,
}

/// Outbox key prefix for a direct-endpoint share. One place, because the code
/// that mints these ids and the code that retires the superseded ones must
/// agree — a silent disagreement leaves the old frames re-driving.
const _kP2PEndpointFramePrefix = 'p2p:ep:';

/// Observation labels belong to the protocol, never a debug scope or payload.
enum _RealtimeControlKind {
  call(
    DiagnosticEvent.callSignalSent,
    DiagnosticEvent.callSignalFailed,
    DiagnosticEvent.callSignalReceived,
    'call-signal-send',
  ),
  p2p(
    DiagnosticEvent.p2pBootstrapSent,
    DiagnosticEvent.p2pBootstrapFailed,
    DiagnosticEvent.p2pBootstrapReceived,
    'p2p-bootstrap-send',
  ),
  modelInventory(
    DiagnosticEvent.modelInventorySent,
    DiagnosticEvent.modelInventoryFailed,
    DiagnosticEvent.modelInventoryReceived,
    'model-inventory-send',
  );

  const _RealtimeControlKind(
    this.sent,
    this.failed,
    this.received,
    this.errorKind,
  );
  final DiagnosticEvent sent, failed, received;
  final String errorKind;
}

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
  static final _initialConsentEpoch = Object();
  final Map<String, Object> _consentEpochs = {};
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

  Object _consentEpoch(NodeId peer) =>
      _consentEpochs[peer.hex] ?? _initialConsentEpoch;

  bool _consentCurrent(NodeId peer, Object? epoch) =>
      !_owner._disposed &&
      epoch != null &&
      identical(_consentEpoch(peer), epoch);

  bool _cacheAccepted(NodeId peer, Object? epoch) {
    if (!_consentCurrent(peer, epoch)) return false;
    _acceptedPeers.add(peer.hex);
    return true;
  }

  void revoke(NodeId peer) {
    _acceptedPeers.remove(peer.hex);
    _consentEpochs[peer.hex] = Object();
  }

  // A read-only stranger does not allocate a map entry. Mutations invalidate
  // both pending reads and positive cache entries, independently per contact.
  Future<({Contact? contact, Object epoch})?> _readContactConsent(
    NodeId peer,
  ) async {
    for (var attempt = 0; attempt < 2 && !_owner._disposed; attempt++) {
      final epoch = _consentEpoch(peer);
      final contact = await _owner._storage.getContact(peer);
      if (_consentCurrent(peer, epoch)) return (contact: contact, epoch: epoch);
    }
    return null;
  }

  Future<Object?> _acceptedContactEpoch(NodeId peer) async {
    final read = await _readContactConsent(peer);
    return read?.contact?.status == ContactStatus.accepted ? read?.epoch : null;
  }

  final Map<String, ({NodeId identity, NodeId device, int pinnedAtMs})>
  _callReplyDevices = {};
  static const _callReplyRouteLifetime = Duration(hours: 6);
  static const _maxCallReplyRoutes = 32;
  static final _callSignalPrefix = utf8.encode(
    '{"t":${WireKind.callSignal.index},',
  );

  void pinCallReplyDevice(String callId, NodeId identity, NodeId device) {
    _callReplyDevices.remove(callId);
    while (_callReplyDevices.length >= _maxCallReplyRoutes) {
      _callReplyDevices.remove(_callReplyDevices.keys.first);
    }
    _callReplyDevices[callId] = (
      identity: identity,
      device: device,
      pinnedAtMs: _owner._now().millisecondsSinceEpoch,
    );
  }

  NodeId? routeCallPayload(NodeId peer, Uint8List payload) {
    if (_callReplyDevices.isEmpty) return null;
    if (payload.length < _callSignalPrefix.length) return null;
    for (var i = 0; i < _callSignalPrefix.length; i++) {
      if (payload[i] != _callSignalPrefix[i]) return null;
    }
    try {
      final envelope = WireEnvelope.decode(payload);
      if (envelope.kind != WireKind.callSignal) return null;
      final signal = CallSignal.tryDecode(envelope.body);
      if (signal == null) return null;
      final route = _callReplyDevices[signal.callId];
      if (route == null || route.identity != peer) return null;
      if (_owner._now().millisecondsSinceEpoch - route.pinnedAtMs >
          _callReplyRouteLifetime.inMilliseconds) {
        _callReplyDevices.remove(signal.callId);
        return null;
      }
      return route.device;
    } catch (_) {
      return null;
    }
  }

  /// Serialize APP_RT frames independently from the durable inbox. A transient
  /// failure drops only one datagram and cannot poison later answer/end frames.
  Future<void> deliverInbound(InboundMessage message) {
    // Start at Dart admission, before the serialized consent/dispatch lane.
    // This distinguishes local queue/handler waits from the age of a remote
    // signal. It cannot measure daemon/FFI waits or correct remote clock skew.
    final receivedAtMs = _owner._now().millisecondsSinceEpoch;
    final elapsed = Stopwatch()..start();
    final next = _inboundChain.then((_) async {
      final queueMs = elapsed.elapsedMilliseconds;
      try {
        await _handleInbound(
          message,
          receivedAtMs: receivedAtMs,
          elapsed: elapsed,
          queueMs: queueMs,
        );
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

  Future<void> _handleInbound(
    InboundMessage message, {
    required int receivedAtMs,
    required Stopwatch elapsed,
    required int queueMs,
  }) async {
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
    recordInbound(envelope.kind);

    if (envelope.kind == WireKind.p2pEndpoints) {
      // BEFORE the contact check, not after: the cache below is primed by any
      // frame that ever looked like it came from this contact, so asking it
      // first would let the very claim under suspicion answer for itself.
      if (!_speaksForContact(message, 'endpoints')) return;
      if (!isAccepted(message.src)) {
        final epoch = await _acceptedContactEpoch(message.src);
        if (!_cacheAccepted(message.src, epoch)) {
          // MY OWN DEVICE: a sibling's share is welcome without a contact
          // row (it has none), but it does not prime the accepted-cache —
          // that cache answers contact questions, and a sibling is not one.
          // The provenance gate above still applies in full: a CLAIMED
          // sibling handing us dial URIs is exactly the attack shape.
          if (!(await _owner.isOwnDevice?.call(message.src) ?? false)) {
            return;
          }
        }
      }
      if (_owner._disposed) return;
      _owner._noteAuthenticatedDevice(message);
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
            '(${envelope.body.length} B) queue=${queueMs}ms '
            'handler=${elapsed.elapsedMilliseconds - queueMs}ms',
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
    recordCallDecision(
      signal,
      signal == null
          ? _CallSignalDecision.malformed
          : _CallSignalDecision.decoded,
      realtime: true,
    );
    if (signal == null) return;
    if (!admitCallEnding(message, signal)) {
      recordCallDecision(
        signal,
        _CallSignalDecision.rejectedEnding,
        realtime: true,
      );
      return;
    }
    // Only an offer can create a call. Follow-ups avoid a storage read because
    // CallService independently checks the exact active `(peer, callId)`.
    if (signal.type == CallSignalType.offer) {
      if (!_speaksForContact(message, 'offer')) {
        recordCallDecision(
          signal,
          _CallSignalDecision.rejectedProvenance,
          realtime: true,
        );
        return;
      }
      if (!isAccepted(message.src)) {
        final epoch = await _acceptedContactEpoch(message.src);
        if (!_cacheAccepted(message.src, epoch)) {
          // MY OWN DEVICE: the sibling relay of a call offer (device
          // fan-out) — no contact row, welcome anyway, no cache priming.
          // CallService re-verifies the sender before honoring onBehalfOf.
          if (!(await _owner.isOwnDevice?.call(message.src) ?? false)) {
            recordCallDecision(
              signal,
              _CallSignalDecision.rejectedContact,
              realtime: true,
            );
            return;
          }
        }
      }
    }
    if (_owner._disposed) return;
    _owner._noteAuthenticatedDevice(message);
    final frameId = envelope.frameId;
    if (frameId != null) {
      final fresh = _owner._outbox.remember(message.src.hex, frameId);
      // Delivery into the call FSM is latency-critical; ACK storage/mailbox
      // work runs independently after dedup state is recorded.
      unawaited(_owner._ackFrame(message, frameId));
      if (!fresh) {
        recordCallDecision(
          signal,
          _CallSignalDecision.duplicate,
          realtime: true,
        );
        return;
      }
    }
    _noteInbound(message.src);
    devLog(() {
      final sentAt = signal.sentAtMs;
      final age = sentAt == null
          ? 'n/a'
          : '${_owner._now().millisecondsSinceEpoch - sentAt}ms';
      final receiptAge = sentAt == null ? 'n/a' : '${receivedAtMs - sentAt}ms';
      return 'xVeil[call-sig]: realtime in type=${signal.type.name} '
          'call=${signal.callId} from=${message.src.short} age=$age '
          'receipt_age=$receiptAge queue=${queueMs}ms '
          'handler=${elapsed.elapsedMilliseconds - queueMs}ms';
    });
    dispatchCallSignal(message.src, signal, realtime: true);
  }

  void recordCallDecision(
    CallSignal? signal,
    _CallSignalDecision decision, {
    bool realtime = false,
    bool outgoing = false,
  }) {
    // Heartbeat frequency must not evict the evidence needed to diagnose
    // ringing. Existing call/media counters retain liveness observations.
    if (signal?.type == CallSignalType.health) return;
    diagnosticJournal.record(
      DiagnosticEvent.callSignalDecision,
      values: {
        DiagnosticMetric.code: signal?.type.index ?? -1,
        DiagnosticMetric.state: decision.index,
        DiagnosticMetric.transport: outgoing ? -1 : (realtime ? 1 : 0),
        DiagnosticMetric.direction: outgoing ? 0 : 1,
      },
    );
  }

  void dispatchCallSignal(
    NodeId peer,
    CallSignal signal, {
    bool realtime = false,
  }) {
    final handler = onCallSignal;
    recordCallDecision(
      signal,
      handler == null
          ? _CallSignalDecision.handlerMissing
          : _CallSignalDecision.dispatched,
      realtime: realtime,
    );
    handler?.call(peer, signal);
  }

  /// Count decoded protocol arrivals, before consent/dedup, on either inbox.
  /// Copies on different live paths are arrivals, not distinct logical calls.
  void recordInbound(WireKind wireKind) {
    final kind = switch (wireKind) {
      WireKind.callSignal ||
      WireKind.groupCallSignal => _RealtimeControlKind.call,
      WireKind.p2pEndpoints => _RealtimeControlKind.p2p,
      WireKind.modelInventoryRequest ||
      WireKind.modelInventoryOffer => _RealtimeControlKind.modelInventory,
      _ => null,
    };
    if (kind == null) return;
    diagnosticJournal.record(
      kind.received,
      minInterval: const Duration(seconds: 1),
    );
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

  /// An ending may now suppress a later offer, even with no active call.
  /// Before recording it (or deduplicating its authenticated copy), require
  /// sender proof. Existing active calls still accept their unguessable call
  /// id as the bearer secret, including a verified sibling's relayed ending.
  bool admitCallEnding(InboundMessage message, CallSignal signal) {
    if (signal.type != CallSignalType.cancel &&
        signal.type != CallSignalType.end &&
        signal.type != CallSignalType.answerSelected) {
      return true;
    }
    if (message.provenance.isAuthenticated) return true;
    var caller = message.src;
    var directSignal = signal;
    final onBehalfOf = signal.onBehalfOf;
    if (onBehalfOf != null) {
      try {
        caller = NodeId.fromHex(onBehalfOf);
      } catch (_) {
        return false;
      }
      // Only the bearer capability is queried; the original signal is still
      // forwarded to CallService, which verifies sibling membership itself.
      directSignal = CallSignal(callId: signal.callId, type: signal.type);
    }
    if (_owner.acceptsCallDeviceSignal?.call(caller, directSignal) ?? false) {
      return true;
    }
    devLog(
      () =>
          'xVeil[call-sig]: early ${signal.type.name} from '
          '${message.src.short} dropped: unproven sender and no active call',
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
      if (!_owner._anonymous && transport is DeviceRealtimeTransport) {
        final device = _owner.routeFor?.call(peer);
        final replyDevice = routeCallPayload(peer, wire);
        // A different online sibling cannot receive the active dialog's
        // control. The call's pin alone does not establish an admitted route.
        if (device != null && device != peer && replyDevice == device) {
          return (transport as DeviceRealtimeTransport).sendRealtimeToDevice(
            peer,
            device,
            wire,
          );
        }
      }
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
    _RealtimeControlKind kind,
    String scope,
    NodeId peer,
    Uint8List wire,
  ) async {
    if (_owner._anonymous) {
      await _observeSend(kind, () => sendRealtime(peer, wire));
      return;
    }
    if (_owner._transport is! RealtimeTransport) {
      await _attempt(
        kind,
        scope,
        'contact',
        peer,
        () => sendRealtime(peer, wire),
      );
      return;
    }
    await Future.wait<void>([
      _attempt(
        kind,
        scope,
        'realtime direct',
        peer,
        () => sendRealtime(peer, wire),
      ),
      if (_owner._transport is RelayRealtimeTransport)
        _attempt(
          kind,
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
    // Like direct calls, race the dedicated realtime connection with the
    // contact identity lane. Transport acceptance on an admitted realtime
    // session does not prove the other endpoint can decrypt its ratchet frame.
    // The signed group event and durable id still deduplicate accepted copies.
    if (signal.type == GroupCallSignalType.heartbeat) {
      await _sendCallLive(peer, envelope.encode(), contactIdentity: true);
      return;
    }
    // The DESTINATION is part of the id, and it was not.
    //
    // The durable outbox keys a row by frame id alone —
    // `enqueueOutboxFrame` returns early on `_outboxById.containsKey(frameId)`
    // — so one signal fanned out to N members enqueued for the FIRST peer and
    // silently did nothing for the rest. They were left with the live leg,
    // which is sent `awaitLive: false` and is nothing at all for a member who
    // is offline: exactly the member a durable control frame exists for.
    await _owner.sendDurable(
      peer,
      'gcall:${signal.groupId.hex}:${signal.callId}:'
      '${signal.type.name}:${signal.nonce}:${peer.hex}',
      envelope,
      liveSender: (wire) => _sendCallLive(peer, wire, contactIdentity: true),
      awaitLive: false,
    );
  }

  /// Race admitted realtime and ordinary contact lanes for call control. Both
  /// copies share one durable frame id, so receiver dedup makes this safe.
  Future<void> _sendCallLive(
    NodeId peer,
    Uint8List wire, {
    required bool contactIdentity,
  }) async {
    if (_owner._anonymous) {
      await _observeSend(
        _RealtimeControlKind.call,
        () => sendRealtime(peer, wire),
      );
      return;
    }
    if (_owner._transport is! RealtimeTransport) {
      await _observeSend(
        _RealtimeControlKind.call,
        () => _owner._send(peer, wire, requireIdentityAddress: contactIdentity),
      );
      return;
    }
    await Future.wait<void>([
      _attempt(
        _RealtimeControlKind.call,
        'call-sig',
        'contact',
        peer,
        () => _owner._send(peer, wire, requireIdentityAddress: contactIdentity),
      ),
      // The realtime endpoint is bound under the identity. A physical device
      // id cannot receive this frame without a device-scoped binding there.
      _sendRealtimePaths(_RealtimeControlKind.call, 'call-sig', peer, wire),
    ]);
  }

  /// Endpoint exchange creates the direct session, so race the pre-admission
  /// contact lane with realtime instead of waiting for a mailbox re-drive.
  Future<void> _sendP2PBootstrap(NodeId peer, Uint8List wire) async {
    if (_owner._transport is! RealtimeTransport) {
      await _observeSend(
        _RealtimeControlKind.p2p,
        () => _owner._send(peer, wire),
      );
      return;
    }
    await Future.wait<void>([
      _attempt(
        _RealtimeControlKind.p2p,
        'p2p',
        'bootstrap contact',
        peer,
        () => _owner._send(peer, wire),
      ),
      _sendRealtimePaths(_RealtimeControlKind.p2p, 'p2p bootstrap', peer, wire),
    ]);
  }

  Future<void> _observeSend(
    _RealtimeControlKind kind,
    Future<void> Function() send,
  ) async {
    try {
      await send();
      diagnosticJournal.record(
        kind.sent,
        minInterval: const Duration(seconds: 1),
      );
    } catch (error, stack) {
      if (kDiagnosticReportEnabled) {
        errorJournal.record(
          kind: kind.errorKind,
          error: error,
          stack: stack,
          atMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      diagnosticJournal.record(
        kind.failed,
        minInterval: const Duration(seconds: 1),
      );
      rethrow;
    }
  }

  Future<void> _attempt(
    _RealtimeControlKind kind,
    String scope,
    String lane,
    NodeId peer,
    Future<void> Function() send,
  ) async {
    try {
      await _observeSend(kind, send);
    } catch (error) {
      devLog(
        () =>
            'xVeil[$scope]: $lane live leg failed '
            'peer=${peer.short}: $error',
      );
    }
  }

  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {
    if (_owner._disposed) return;
    // MY OWN DEVICE, same shape as [sendP2PEndpoints]: the call fan-out's
    // relayed offers and answered-elsewhere signals address a sibling, which
    // is never a contact — this gate silently ate the whole relay while the
    // service above it logged "fanning offer … out to 1 sibling device(s)".
    recordCallDecision(
      signal,
      _CallSignalDecision.sendRequested,
      outgoing: true,
    );
    final ownDevice = await _owner.isOwnDevice?.call(peer) ?? false;
    var contactIdentity = false;
    if (!ownDevice) {
      final epoch = await _acceptedContactEpoch(peer);
      if (_cacheAccepted(peer, epoch)) {
        contactIdentity = true;
      } else if (!(_owner.acceptsCallDeviceSignal?.call(peer, signal) ??
          false)) {
        recordCallDecision(
          signal,
          _CallSignalDecision.rejectedContact,
          outgoing: true,
        );
        return;
      }
    }
    if (_owner._disposed) return;
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
      await _sendRealtimePaths(
        _RealtimeControlKind.call,
        'call-sig',
        peer,
        envelope.encode(),
      );
      return;
    }
    // Destination-bound for the same reason as the group signal above: this
    // fan-out addresses sibling devices too — the comment at the top of this
    // method says so — and a shared id meant the first sibling took the only
    // durable row while the others got a live leg that is not awaited.
    final frameId = stamped.type == CallSignalType.transportInfo
        ? 'call:${signal.callId}:${signal.type.name}:${stamped.sentAtMs}'
              ':${stamped.transport?.kind.index}:${peer.hex}'
        : stamped.type == CallSignalType.renegotiate
        ? 'call:${signal.callId}:${signal.type.name}:${stamped.sentAtMs}'
              ':${peer.hex}'
        : 'call:${signal.callId}:${signal.type.name}:${peer.hex}';
    await _owner.sendDurable(
      peer,
      frameId,
      envelope,
      liveSender: (wire) =>
          _sendCallLive(peer, wire, contactIdentity: contactIdentity),
      awaitLive: false,
      startLiveBeforeEnqueue: true,
    );
  }

  /// One live model-inventory frame to an accepted contact.
  ///
  /// The accepted check is repeated here rather than trusted from the caller:
  /// this is the last place before the frame leaves, and the thing being sent
  /// is a description of what languages this device holds.
  Future<void> sendModelInventory(NodeId peer, WireEnvelope envelope) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    // APP_RT accepts only call control and endpoint exchange. Model inventory
    // belongs to the ordinary live inbox; no outbox or mailbox is created.
    await _attempt(
      _RealtimeControlKind.modelInventory,
      'model-inventory',
      'contact',
      peer,
      () => _owner._send(peer, envelope.encode(), requireIdentityAddress: true),
    );
  }

  Future<void> sendP2PEndpoints(
    NodeId peer,
    String bodyJson, {
    required int sentAtMs,
  }) async {
    if (_owner._disposed) return;
    // MY OWN DEVICE bypasses the contact gate but not the accepted-cache:
    // a sibling is never a contact, and this silent return was the reason a
    // sibling's ladder ran to the punch with nothing exchanged — the frame
    // the ladder thought it sent died right here.
    final ownDevice = await _owner.isOwnDevice?.call(peer) ?? false;
    Object? consentEpoch;
    if (!ownDevice) {
      consentEpoch = await _acceptedContactEpoch(peer);
      if (!_cacheAccepted(peer, consentEpoch)) return;
    }
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
    if (_owner._disposed) return;
    if (!ownDevice && !_consentCurrent(peer, consentEpoch)) {
      consentEpoch = await _acceptedContactEpoch(peer);
      if (!_cacheAccepted(peer, consentEpoch)) return;
    }
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
      devLog(
        () =>
            'xVeil[p2p]: could not retire earlier endpoint frames for '
            '${peer.short} (non-fatal): $e',
      );
    }
  }
}
