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
  final Map<String, Timer> _fastCallRetryTimers = {};

  static const _seenFramesCap = 4096;
  static const _nudgeGrace = Duration(seconds: 10);
  static const _liveResend = Duration(seconds: 20);
  static const _callSignalLiveResend = Duration(milliseconds: 250);
  static const _fastCallRetryAttempts = 4;
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
    if ((frameId.startsWith('call:') || frameId.startsWith('gcall:')) &&
        liveSender != null) {
      _scheduleFastCallRedrive(peer, frameId, wire, liveSender);
    }
  }

  /// Call setup cannot inherit the ordinary three-second outbox cadence: a
  /// couple of silently dropped best-effort relay sends previously turned into
  /// the measured 13.5-second ring delay. Re-drive the same deduplicated frame
  /// at 250/500/1000/2000 ms, then hand it back to the normal bounded outbox
  /// ladder. ACK retirement cancels the next timer immediately.
  void _scheduleFastCallRedrive(
    NodeId peer,
    String frameId,
    Uint8List wire,
    Future<void> Function(Uint8List wire) liveSender,
  ) {
    _fastCallRetryTimers.remove(frameId)?.cancel();

    void schedule(Duration delay, int attemptsLeft) {
      _fastCallRetryTimers[frameId] = Timer(delay, () async {
        _fastCallRetryTimers.remove(frameId);
        final previous = _liveBackoff[frameId];
        if (_owner._disposed || previous == null) return;

        final now = _owner._now();
        final count = previous.count + 1;
        final nextDelay = Duration(
          milliseconds:
              (_callSignalLiveResend.inMilliseconds *
                      (1 << (count - 1).clamp(0, 10)))
                  .clamp(0, _liveResendCap.inMilliseconds),
        );
        _liveBackoff[frameId] = (
          count: count,
          nextAt: now.add(nextDelay),
          peer: previous.peer,
          lastSentAt: now,
        );
        devLog(
          () =>
              'xVeil[durable]: fast call re-drive fid=$frameId '
              'dst=${peer.short} attempt=$count',
        );
        try {
          await liveSender(wire);
        } catch (_) {
          // Every constituent path is best-effort; the next timer or durable
          // mailbox copy remains authoritative.
        }
        _owner._stashInBackground(peer, frameId, wire);
        if (attemptsLeft > 1 && _liveBackoff.containsKey(frameId)) {
          schedule(nextDelay, attemptsLeft - 1);
        }
      });
    }

    schedule(_callSignalLiveResend, _fastCallRetryAttempts);
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
      if (_owner.backgroundStashPaused && !isCallSignal) continue;
      final peer = NodeId.fromHex(frame.peerHex);
      final Contact? contact;
      try {
        contact = await _owner._storage.getContact(peer);
      } catch (_) {
        continue;
      }
      var groupMemberCarrier = false;
      final spaceJoinCarrier =
          frame.frameId.startsWith('space-join-request:') ||
          frame.frameId.startsWith('space-join-decision:');
      if (contact == null || contact.status != ContactStatus.accepted) {
        final parts = frame.frameId.split(':');
        if (parts.length >= 3 &&
            (parts.first == 'gcall' || parts.first == 'gcr')) {
          groupMemberCarrier =
              await _owner.allowStrangerGroupSync?.call(peer, parts[1]) ??
              false;
        }
      }
      if (contact == null && !groupMemberCarrier && !spaceJoinCarrier) {
        retire(frame.frameId);
        continue;
      }
      if (contact?.status == ContactStatus.blocked && !groupMemberCarrier) {
        continue;
      }
      if (_owner._mailboxDelivery.peerBackedOff(frame.peerHex, _owner._now())) {
        continue;
      }
      _owner._stashInBackground(peer, frame.frameId, frame.wire);
      final now = _owner._now();
      final backoff = _liveBackoff[frame.frameId];
      if (backoff != null && now.isBefore(backoff.nextAt)) continue;
      final count = (backoff?.count ?? 0) + 1;
      // Call control is useful only inside the ring window and therefore uses
      // a sub-second initial ladder; ordinary durable control starts at 20s. Both grow
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

  /// A public Space join frame can be addressed to a non-contact. An ACK may
  /// retire it only when the exact id is still queued for that authenticated
  /// peer; guessed ids and cross-peer acknowledgements remain inert.
  Future<bool> authorizedSpaceJoinAck(NodeId peer, String frameId) async {
    if (!frameId.startsWith('space-join-request:') &&
        !frameId.startsWith('space-join-decision:')) {
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
    _fastCallRetryTimers.remove(frameId)?.cancel();
    _owner._mailboxDelivery.removeStashed(frameId);
    _liveBackoff.remove(frameId);
    unawaited(_owner._storage.ackOutboxFrame(frameId));
  }

  void dispose() {
    for (final timer in _fastCallRetryTimers.values) {
      timer.cancel();
    }
    _fastCallRetryTimers.clear();
  }
}
