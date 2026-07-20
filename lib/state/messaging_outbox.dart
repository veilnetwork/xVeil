part of 'messaging_core.dart';

/// Durable control-frame persistence, deduplication, acknowledgement and
/// bounded live re-drive.
///
/// Chat messages retain their event-log outbox. This subsystem owns the
/// parallel durable path used by control frames such as accepts, edits, call
/// transitions, group requests and replication records.
class _MessagingOutbox {
  _MessagingOutbox(this._owner);

  final MessagingService _owner;

  final Map<
    String,
    ({int count, DateTime nextAt, String peer, DateTime lastSentAt})
  >
  _liveBackoff = {};

  final Set<String> _seenFrames = {};

  static const _seenFramesCap = 4096;
  static const _nudgeGrace = Duration(seconds: 10);
  static const _liveResend = Duration(seconds: 20);
  static const _callSignalLiveResend = Duration(seconds: 4);
  static const _liveResendCap = Duration(minutes: 10);
  static const _callSignalTtl = Duration(minutes: 2);

  void recordQueued(String frameId, String peerHex, {bool callSignal = false}) {
    final now = _owner._now();
    _liveBackoff[frameId] = (
      count: 1,
      nextAt: now.add(callSignal ? _callSignalLiveResend : _liveResend),
      peer: peerHex,
      lastSentAt: now,
    );
  }

  bool hasLiveEntry(String frameId) => _liveBackoff.containsKey(frameId);

  bool hasSeen(String frameId) => _seenFrames.contains(frameId);

  bool remember(String frameId) => _seenFrames.add(frameId);

  /// Rewind pending control frames when authenticated inbound proves the peer
  /// is reachable, while leaving just-sent frames alone so their ACK can land.
  bool nudge(String peerHex) {
    final now = _owner._now();
    var nudged = false;
    for (final id in _liveBackoff.keys.toList()) {
      final backoff = _liveBackoff[id]!;
      if (now.difference(backoff.lastSentAt) < _nudgeGrace) continue;
      if (backoff.peer == peerHex && backoff.nextAt.isAfter(now)) {
        _liveBackoff[id] = (
          count: backoff.count,
          nextAt: now,
          peer: backoff.peer,
          lastSentAt: backoff.lastSentAt,
        );
        nudged = true;
      }
    }
    return nudged;
  }

  Future<void> ackFrame(InboundMessage message, String frameId) async {
    if (_seenFrames.length > _seenFramesCap) {
      _seenFrames.remove(_seenFrames.first);
    }
    try {
      await _owner._ackTo(
        message,
        frameId,
        repeat: _seenFrames.contains(frameId),
      );
    } catch (_) {
      // Best-effort — a re-drive will prompt another ACK.
    }
  }

  Future<void> send(
    NodeId peer,
    String frameId,
    WireEnvelope envelope, {
    Future<void> Function(Uint8List wire)? liveSender,
    bool awaitLive = true,
    bool startLiveBeforeEnqueue = false,
  }) async {
    final wire = envelope.withFrameId(frameId).encode();
    Future<void> tryLive() async {
      final stopwatch = Stopwatch()..start();
      try {
        await (liveSender?.call(wire) ?? _owner._send(peer, wire));
        devLog(
          () =>
              'xVeil[durable]: live leg ok fid=$frameId '
              'peer=${peer.short} in ${stopwatch.elapsedMilliseconds}ms',
        );
      } catch (error) {
        devLog(
          () =>
              'xVeil[durable]: live leg FAILED fid=$frameId '
              'peer=${peer.short} after ${stopwatch.elapsedMilliseconds}ms: '
              '$error',
        );
      }
    }

    // Call/P2P control must not wait behind a slow encrypted-store operation.
    // The live leg gets a bounded scheduling head start, while persistence is
    // still authoritative and always completes before this method returns.
    final earlyLive = startLiveBeforeEnqueue ? tryLive() : null;
    if (earlyLive != null) {
      await Future.any<void>([
        earlyLive,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
    }
    await _owner._storage.enqueueOutboxFrame(frameId, peer.hex, wire);
    recordQueued(
      frameId,
      peer.hex,
      callSignal: frameId.startsWith('call:') || frameId.startsWith('gcall:'),
    );
    if (earlyLive != null) {
      if (awaitLive) await earlyLive;
    } else if (awaitLive) {
      await tryLive();
    } else {
      unawaited(tryLive());
    }
    _owner._stashInBackground(peer, frameId, wire);
  }

  Future<void> flush() async {
    // The periodic timer outlives lock/unlock; a deliberately closed volume is
    // not an error and must not wake its worker every three seconds.
    if (!_owner._storage.isOpen) return;
    final List<OutboxFrame> pending;
    try {
      pending = await _owner._storage.pendingOutboxFrames();
    } catch (_) {
      return;
    }
    for (final frame in pending) {
      if (_retireExpiredTransient(frame)) continue;
      final isCallSignal =
          frame.frameId.startsWith('call:') ||
          frame.frameId.startsWith('gcall:');
      // Media pauses unrelated maintenance, but never call lifecycle recovery.
      if (_owner._backgroundDeliveryPaused && !isCallSignal) continue;
      final peer = NodeId.fromHex(frame.peerHex);
      final Contact? contact;
      try {
        contact = await _owner._storage.getContact(peer);
      } catch (_) {
        continue;
      }
      var groupMemberCarrier = false;
      if (contact == null || contact.status != ContactStatus.accepted) {
        final parts = frame.frameId.split(':');
        if (parts.length >= 3 &&
            (parts.first == 'gcall' || parts.first == 'gcr')) {
          groupMemberCarrier =
              await _owner.allowStrangerGroupSync?.call(peer, parts[1]) ??
              false;
        }
      }
      if (contact == null && !groupMemberCarrier) {
        retire(frame.frameId);
        continue;
      }
      if (contact?.status == ContactStatus.blocked && !groupMemberCarrier) {
        continue;
      }
      final peerBackoff = _owner._peerUnresolvedBackoff[frame.peerHex];
      if (peerBackoff != null && _owner._now().isBefore(peerBackoff.nextAt)) {
        continue;
      }
      _owner._stashInBackground(peer, frame.frameId, frame.wire);
      final now = _owner._now();
      final backoff = _liveBackoff[frame.frameId];
      if (backoff != null && now.isBefore(backoff.nextAt)) continue;
      final count = (backoff?.count ?? 0) + 1;
      // Call control is useful only inside the ring window and therefore uses
      // the fast 4s ladder; ordinary durable control starts at 20s. Both grow
      // exponentially and cap at ten minutes to avoid permanent ghost load.
      final baseMs = isCallSignal
          ? _callSignalLiveResend.inMilliseconds
          : _liveResend.inMilliseconds;
      final delayMs = (baseMs * (1 << (count - 1).clamp(0, 10))).clamp(
        0,
        _liveResendCap.inMilliseconds,
      );
      _liveBackoff[frame.frameId] = (
        count: count,
        nextAt: now.add(Duration(milliseconds: delayMs)),
        peer: frame.peerHex,
        lastSentAt: now,
      );
      devLog(
        () =>
            'xVeil[durable]: re-drive fid=${frame.frameId} '
            'dst=${peer.short} attempt=$count '
            't=${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        await _owner._send(peer, frame.wire);
      } catch (_) {
        // Best-effort.
      }
    }
  }

  bool _retireExpiredTransient(OutboxFrame frame) {
    final direct = frame.frameId.startsWith('call:');
    final group = frame.frameId.startsWith('gcall:');
    final groupContent = frame.frameId.startsWith('gcr:');
    if (!direct && !group && !groupContent) return false;
    try {
      final envelope = WireEnvelope.decode(frame.wire);
      if (groupContent) {
        if (envelope.kind != WireKind.groupContentRequest) return false;
        final request = GroupContentRequest.fromJson(jsonDecode(envelope.body));
        if (request == null) return false;
        final age = _owner._now().difference(
          DateTime.fromMillisecondsSinceEpoch(request.tsMs),
        );
        if (age <= kGroupContentRequestWindow) return false;
        devLog(
          () =>
              'xVeil[durable]: retire stale group content request '
              'fid=${frame.frameId} age=${age.inSeconds}s',
        );
        retire(frame.frameId);
        return true;
      }
      if (direct && envelope.kind != WireKind.callSignal) return false;
      if (group && envelope.kind != WireKind.groupCallSignal) return false;
      final sentAtMs = direct
          ? (CallSignal.tryDecode(envelope.body)?.sentAtMs ?? envelope.sentAtMs)
          : envelope.sentAtMs;
      if (sentAtMs == null) return false;
      final age = _owner._now().difference(
        DateTime.fromMillisecondsSinceEpoch(sentAtMs),
      );
      if (age <= _callSignalTtl) return false;
      devLog(
        () =>
            'xVeil[durable]: retire stale call frame '
            'fid=${frame.frameId} age=${age.inSeconds}s',
      );
      retire(frame.frameId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authorizedGroupCallAck(NodeId peer, String frameId) async {
    final parts = frameId.split(':');
    if (parts.length < 5 || parts.first != 'gcall') return false;
    if (!(await _owner.allowStrangerGroupSync?.call(peer, parts[1]) ?? false)) {
      return false;
    }
    try {
      return (await _owner._storage.pendingOutboxFrames()).any(
        (frame) => frame.frameId == frameId && frame.peerHex == peer.hex,
      );
    } catch (_) {
      return false;
    }
  }

  void retire(String frameId) {
    _owner._stashed.remove(frameId);
    _liveBackoff.remove(frameId);
    unawaited(_owner._storage.ackOutboxFrame(frameId));
  }
}
