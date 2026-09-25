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

  /// Pending durable frames per peer, so a caller can ask how backed up a
  /// destination is without reading the whole outbox.
  ///
  /// Rebuilt from the authoritative list on every [flush] and adjusted in
  /// between, so it can lag by at most one flush interval — which is nothing
  /// next to the hundreds of frames the cap it feeds is measured in.
  final Map<String, int> _pendingByPeer = {};

  /// Whether [_pendingByPeer] has ever been filled from the store.
  ///
  /// It matters at start-up and nowhere else. The counter is refreshed by
  /// [flush], which first runs up to one interval after the service starts —
  /// and the replication burst that this counter exists to bound
  /// (`nudgeGroupSyncAll`) happens AT start-up, inside that window. Left
  /// unseeded the cap would read zero and wave through exactly the batch it is
  /// there to stop.
  bool _pendingSeeded = false;

  /// Fill the per-peer counts from the store if [flush] has not yet done it.
  Future<void> ensurePendingCounted() async {
    if (_pendingSeeded) return;
    try {
      final pending = await _owner._storage.pendingOutboxFrames();
      _pendingByPeer.clear();
      for (final frame in pending) {
        _pendingByPeer[frame.peerHex] =
            (_pendingByPeer[frame.peerHex] ?? 0) + 1;
      }
      _pendingSeeded = true;
    } catch (_) {
      // Unreadable store: leave it unseeded and try again next time rather
      // than pretending every queue is empty for the rest of the session.
    }
  }

  /// Pending durable frames held for [peerHex] as of the last [flush].
  int pendingFor(String peerHex) => _pendingByPeer[peerHex] ?? 0;

  /// How many undelivered replication frames one peer may hold before we stop
  /// queueing more for it.
  ///
  /// Replication fans a snapshot out to every member, so a member that never
  /// acks accumulates one batch per change, forever. Measured on the stand:
  /// 3473 frames and 9.56 MB queued to a device that had been wiped four days
  /// earlier, growing with every app start.
  ///
  /// NOTHING IS DROPPED and convergence is not weakened. A device that returns
  /// asks what it is missing — `nudgeGroupSyncAll` runs for every group at
  /// every app start — and the sender recomputes the answer against that
  /// device's own frontier. The queue was never the mechanism that brings two
  /// devices to the same state; it is only an optimisation for a peer that is
  /// briefly away, and this bounds it. Below the cap the behaviour is
  /// unchanged, so a device away for a day still finds everything waiting.
  static const _replicationBacklogCap = 256;

  // A "give up after N failed passes" rule lived here and was removed: it
  // counted a pass as failed only when the send THREW, and this send never
  // does — it returns as soon as the local node takes the frame, so an
  // unreachable peer is indistinguishable from a reachable one at that point.
  // The rule was inert against the very case it was written for (measured: 177
  // frames for a gone device, zero give-ups in nine minutes). Age is the only
  // honest signal, and it lives in `_retireStaleReplication`.

  /// Whether replication to [peerHex] should pause because its queue is not
  /// draining. See [_replicationBacklogCap].
  bool replicationBackedUpFor(String peerHex) =>
      pendingFor(peerHex) >= _replicationBacklogCap;

  /// Frames whose live leg has gone out but whose durable row is not written
  /// yet, and the subset of those the peer already acknowledged.
  ///
  /// `startLiveBeforeEnqueue` sends before persisting on purpose — call control
  /// must not queue behind a slow encrypted store. That opens a window: an ACK
  /// arriving inside it retires a frame whose row does not exist, the retire
  /// finds nothing to delete, and the enqueue right after creates a row for a
  /// frame that was already confirmed. Nothing ever retires it again, so it
  /// re-drives on every outbox cycle for the life of the session (audit
  /// XV-19).
  final Set<String> _sendingUnpersisted = {};
  final Set<String> _ackedWhileUnpersisted = {};
  final Map<String, Timer> _fastCallRetryTimers = {};

  static const _seenFramesCap = 4096;

  /// Frame state is per (peer, frameId) — never per frameId alone.
  ///
  /// A frameId is not unique by itself. A `gcr:` content request reuses one id
  /// across every holder it asks, and `reconnect:`/`accept:` ids are derived
  /// from the peer in a way any contact can predict. Keyed by frameId alone,
  /// one peer's entry overwrote another's live backoff, and a contact who knew
  /// the id could ACK it first and retire somebody else's pending frame
  /// (audit XV-02).
  static String _key(String peerHex, String frameId) => '$peerHex|$frameId';
  static const _nudgeGrace = Duration(seconds: 10);

  /// How long after its last send a frame must wait before inbound from its
  /// peer may rewind it — growing with the attempts, as the ladder itself does.
  ///
  /// A flat grace let any peer that talks steadily turn the ladder off: every
  /// frame came due again ten seconds after each send, however many times it
  /// had already gone unanswered. Measured on the stand as 12 frames re-driven
  /// 76 times in one minute to a peer that was plainly reachable — it was the
  /// ACKS that were going astray (to a sibling device of the sender), and no
  /// amount of re-sending could fix that. The first rewinds stay quick, which
  /// is what the rewind is for: a peer just back gets what it missed at once.
  /// A frame that reachability has already failed to deliver several times
  /// stops being pulled forward faster than its own ladder.
  static Duration _nudgeGraceFor(int count) => Duration(
    milliseconds: (_nudgeGrace.inMilliseconds * (1 << (count - 1).clamp(0, 10)))
        .clamp(0, _liveResendCap.inMilliseconds),
  );
  static const _liveResend = Duration(seconds: 20);
  static const _callSignalLiveResend = Duration(milliseconds: 250);
  static const _fastCallRetryAttempts = 4;
  static const _liveResendCap = Duration(minutes: 10);

  /// Spread of the deterministic jitter subtracted from every live-resend
  /// delay, as a fraction of the delay itself.
  ///
  /// The backoff is per FRAME, and it saturates: after about six attempts every
  /// pending frame is waiting the same ten minutes. Frames queued together then
  /// come due together, and one flush pass emits the whole set back-to-back —
  /// exponential backoff bounds how OFTEN a frame retries and says nothing
  /// about how many retry at the same instant.
  ///
  /// Measured on the phone against three offline contacts: 55 bursts in 38
  /// minutes, of which the four large ones carried ~1100-1600 sends each in
  /// 6-7 s — about **175 sends per second** — while the quiet ticks in between
  /// were three sends per minute. The bursts were ~95% of all attempts, and
  /// each one is a DHT lookup for a peer that is not there.
  ///
  /// `veil_dht`'s `RepublishScheduler` already solves this shape for DHT keys:
  /// a hash of the key picks an offset inside the interval so the herd never
  /// forms. Same trick here, keyed on the frame id so a frame keeps its own
  /// offset across recomputes rather than walking around under a fresh random
  /// draw each pass.
  static const _liveResendJitter = 0.25;

  /// `delayMs` pulled EARLIER by a deterministic offset in
  /// `[0, delayMs * _liveResendJitter]`, derived from `frameId`.
  ///
  /// Two properties, both load-bearing.
  ///
  /// **Earlier, never later.** The ladder is a promise the rest of the system
  /// reads: a caller that waits `base * 2^n` expects the frame to have gone by
  /// then, and `durable_redrive_test` pins exactly that by advancing a fake
  /// clock 21 s and then 41 s. Jittering upward broke both of those, which is
  /// the test doing its job — a frame would have retried LATER than the ladder
  /// says, so delivery could only get slower. Subtracting cannot regress
  /// latency; the cost is that the mean delay drops by half the spread.
  ///
  /// **Deterministic, not random.** A fresh draw each pass would let a frame
  /// wander back into the herd it was just moved out of, and would make the
  /// ladder untestable. FNV-1a because `String.hashCode` is not stable across
  /// runs, and because it is the hash `veil_dht`'s `RepublishScheduler` uses to
  /// solve this same shape for DHT keys.
  static int _jittered(int delayMs, String frameId) {
    if (delayMs <= 0) return delayMs;
    final spread = (delayMs * _liveResendJitter).round();
    if (spread <= 0) return delayMs;
    var hash = 0xcbf29ce484222325;
    for (final unit in frameId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return delayMs - (hash % spread);
  }
  static const _callSignalTtl = Duration(minutes: 2);

  void recordQueued(String frameId, String peerHex, {bool callSignal = false}) {
    final now = _owner._now();
    _liveBackoff[_key(peerHex, frameId)] = (
      count: 1,
      nextAt: now.add(callSignal ? _callSignalLiveResend : _liveResend),
      peer: peerHex,
      lastSentAt: now,
    );
  }

  bool hasLiveEntry(String peerHex, String frameId) =>
      _liveBackoff.containsKey(_key(peerHex, frameId));

  bool hasSeen(String peerHex, String frameId) =>
      _seenFrames.contains(_key(peerHex, frameId));

  bool remember(String peerHex, String frameId) =>
      _seenFrames.add(_key(peerHex, frameId));

  /// Rewind pending control frames when authenticated inbound proves the peer
  /// is reachable, while leaving just-sent frames alone so their ACK can land.
  bool nudge(String peerHex) {
    final now = _owner._now();
    var nudged = false;
    for (final id in _liveBackoff.keys.toList()) {
      final backoff = _liveBackoff[id]!;
      if (now.difference(backoff.lastSentAt) < _nudgeGraceFor(backoff.count)) {
        continue;
      }
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
        repeat: _seenFrames.contains(_key(message.src.hex, frameId)),
      );
    } catch (error) {
      // Best-effort — a re-drive will prompt another ACK. But say so: a
      // failing ack is indistinguishable from one that was never owed, and
      // the sender answers by re-driving the same frame forever. Silence here
      // is what a stuck outbox looks like from the other side.
      devLog(
        () =>
            'xVeil[timeline]: ack FAILED id=$frameId '
            'to=${message.src.short}: $error',
      );
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
    final unpersistedKey = _key(peer.hex, frameId);
    final earlyLive = startLiveBeforeEnqueue ? tryLive() : null;
    if (earlyLive != null) {
      // From here until the row exists, an ACK has nothing to delete. Mark the
      // window so `retire` can tell us, rather than losing the fact.
      _sendingUnpersisted.add(unpersistedKey);
      await Future.any<void>([
        earlyLive,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
    }
    await _owner._storage.enqueueOutboxFrame(frameId, peer.hex, wire);
    _pendingByPeer[peer.hex] = (_pendingByPeer[peer.hex] ?? 0) + 1;
    recordQueued(
      frameId,
      peer.hex,
      callSignal: _MessagingMailboxDelivery.isCallSignalId(frameId),
    );
    if (earlyLive != null) {
      _sendingUnpersisted.remove(unpersistedKey);
      if (_ackedWhileUnpersisted.remove(unpersistedKey)) {
        // Confirmed while we were still writing it. Retire the row we have
        // just created — persisting first instead would put the encrypted
        // store back in front of call setup, which is the latency this flag
        // exists to avoid.
        retire(peer.hex, frameId);
        return;
      }
    }
    // THE DEPOSIT IS THE COPY THAT SURVIVES THE PEER BEING GONE, so it cannot
    // be sequenced behind an attempt to reach a peer that is gone. It used to
    // sit below the live wait, and the wait buys it nothing: [tryLive] swallows
    // every error, so the deposit that follows happens on success and failure
    // alike. All the ordering ever added was the live leg's latency — and a
    // live leg has no deadline of its own, so "latency" includes "never".
    //
    // What that cost in the field: this method is awaited in serial fan-outs
    // (`group_service.broadcast`, one recipient at a time; the chunk loop in
    // `messaging_replication`), so ONE device on a stale direct address made
    // every later recipient's deposit wait out its dial too.
    _owner._stashInBackground(peer, frameId, wire);
    if (earlyLive != null) {
      if (awaitLive) await boundedLiveLeg(earlyLive);
    } else if (awaitLive) {
      await boundedLiveLeg(tryLive());
    } else {
      unawaited(tryLive());
    }
    if (_MessagingMailboxDelivery.isCallSignalId(frameId) &&
        liveSender != null) {
      _scheduleFastCallRedrive(peer, frameId, wire, liveSender);
    }
  }

  /// Wait for a live leg for at most [MessagingService.liveLegDeadline], and
  /// never let it throw.
  ///
  /// The deadline is the point; the swallow is what makes it usable at the
  /// call sites. `_owner._send` throws for a peer the transport rejects
  /// outright, and every caller below is a best-effort re-drive standing in
  /// front of other peers' work — one throw used to abandon the rest of the
  /// pass, which is the same pile-up the deadline exists to stop.
  ///
  /// It returns a future that is DONE at the deadline, not one that cancels
  /// the send: Dart cannot retract a `Future`, and the send must not be
  /// retracted anyway — see [MessagingService.liveLegDeadline].
  Future<void> boundedLiveLeg(Future<void> live) async {
    try {
      await live.timeout(_owner.liveLegDeadline);
    } on TimeoutException {
      devLog(
        () =>
            'xVeil[durable]: live leg ABANDONED after '
            '${_owner.liveLegDeadline.inSeconds}s — the durable copy is '
            'already deposited, so the pass moves on',
      );
    } catch (_) {
      // Best-effort by contract; the durable copy and the deposit both stand.
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
        final previous = _liveBackoff[_key(peer.hex, frameId)];
        if (_owner._disposed || previous == null) return;

        final now = _owner._now();
        final count = previous.count + 1;
        final nextDelay = Duration(
          milliseconds: _jittered(
            (_callSignalLiveResend.inMilliseconds *
                    (1 << (count - 1).clamp(0, 10)))
                .clamp(0, _liveResendCap.inMilliseconds),
            frameId,
          ),
        );
        _liveBackoff[_key(peer.hex, frameId)] = (
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
        if (attemptsLeft > 1 &&
            _liveBackoff.containsKey(_key(peer.hex, frameId))) {
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
    // The authoritative count, once per cycle. Everything between cycles only
    // adjusts it.
    _pendingByPeer.clear();
    for (final frame in pending) {
      _pendingByPeer[frame.peerHex] = (_pendingByPeer[frame.peerHex] ?? 0) + 1;
    }
    _pendingSeeded = true;
    final oldest = <String, int>{};
    for (final frame in pending) {
      final at = frame.enqueuedAtMs;
      if (at == null) continue;
      final seen = oldest[frame.peerHex];
      if (seen == null || at < seen) oldest[frame.peerHex] = at;
    }
    await _loadSilences(_pendingByPeer.keys, oldestQueued: oldest);
    // THE DEPOSITS ARE A PASS OF THEIR OWN, ahead of every dial.
    //
    // The queue is one flat list, so walking it as "admit, deposit, dial" put
    // frame i's dial in front of frame i+1's DEPOSIT — and the dial is the
    // slow half by orders of magnitude. Measured: 117 frames pending, 109 of
    // them group-sync to a device that no longer exists, while content
    // re-requests to a HEALTHY peer sat behind them and the transfer they
    // belonged to never moved. Whatever one dial to a gone peer costs, that
    // list multiplied it by 109 and charged it to everything behind it.
    //
    // Splitting the walk decouples the two: every frame in this pass is
    // offered to the deposit gate before any of them is dialled, so a
    // destination that cannot be reached costs the LIVE half of the pass and
    // nothing else. The dials keep their serial order and their ladder —
    // firing them all at once would trade a pile-up for a storm.
    final redrive = <({NodeId peer, OutboxFrame frame, int attempt})>[];
    NodeId? selfNode;
    try {
      selfNode = await _owner._transport.nodeId();
    } catch (_) {
      // No self id (transport still booting) — skip the self check this pass.
    }
    for (final frame in pending) {
      if (_retireExpiredTransient(frame)) continue;
      if (_retireStaleReplication(frame)) continue;
      if (selfNode != null && frame.peerHex == selfNode.hex) {
        // Addressed to THIS NODE: snapshotRecipients' device-group fallback
        // guesses the identity when the local device id is unresolved, and on
        // a restored sibling that guess keeps this device and drops the
        // master. The live path already refuses self-sends; the durable half
        // used to keep the frame forever (measured: 61 frames to self,
        // re-depositing into unresolved-peer backoff for hours). "A guess
        // that misroutes is recoverable" is a promise this retire keeps.
        devLog(
          () =>
              'xVeil[durable]: frame ${frame.frameId} is addressed to THIS '
              'node — moot, retiring',
        );
        retire(frame.peerHex, frame.frameId);
        continue;
      }
      // Media pauses unrelated maintenance, but never call lifecycle recovery.
      // The same predicate the deposit gate uses, so the two cannot disagree —
      // this loop used to carve call signals out of the pause and then hand
      // them to a deposit that re-checked the pause and dropped them.
      final isCallSignal = _MessagingMailboxDelivery.isCallSignalId(
        frame.frameId,
      );
      if (_owner.backgroundStashPaused && !isCallSignal) continue;
      final peer = NodeId.fromHex(frame.peerHex);
      final Contact? contact;
      try {
        contact = await _owner._storage.getContact(peer);
      } catch (_) {
        continue;
      }
      var groupMemberCarrier = false;
      final externalSpaceProposalCarrier =
          frame.frameId.startsWith('space-join-request:') ||
          frame.frameId.startsWith('space-join-decision:') ||
          frame.frameId.startsWith('space-moderation-appeal:') ||
          frame.frameId.startsWith('space-moderation-appeal-decision:') ||
          frame.frameId.startsWith('space-abuse-report:') ||
          frame.frameId.startsWith('space-abuse-report-decision:');
      if (contact == null || contact.status != ContactStatus.accepted) {
        final parts = frame.frameId.split(':');
        if (parts.length >= 3 &&
            (parts.first == 'gcall' || parts.first == 'gcr')) {
          groupMemberCarrier =
              await _owner.allowStrangerGroupSync?.call(peer, parts[1]) ??
              false;
        }
      }
      // A CONTENT REQUEST ADDRESSED TO A SIGNING KEY can never complete: the
      // sovereign owner of a device group is an authority, not a node, and a
      // gcr aimed at it re-drives forever — measured as a sibling's outbox
      // retrying attempt 15 against an address nobody has ever listened on.
      // The frames predate the fix that stopped creating them; retire the
      // survivors instead of carrying them to every flush until the till TTL.
      if (frame.frameId.startsWith('gcr:') &&
          (await _owner.isSovereignAuthority?.call(peer) ?? false)) {
        devLog(
          () =>
              'xVeil[durable]: retire gcr fid=${frame.frameId} — addressed to '
              'the sovereign authority, which is a key, not a node',
        );
        retire(frame.peerHex, frame.frameId);
        continue;
      }
      // MY OWN DEVICE IS NOT A STRANGER, asked HERE because this is the line
      // that deletes. A sibling is never a contact — the identity does not
      // befriend itself — so the retire below threw away every device-sync
      // frame on the first flush. Measured on the stand: a chunked snapshot's
      // first chunk deposited, the rest DEFERRED "for the outbox flush to
      // reconsider", and the flush had already deleted the frames it would
      // have reconsidered — outbox 0, sibling waiting forever, sender
      // convinced it had delivered.
      final ownDevice =
          contact == null &&
          (await _owner.isOwnDevice?.call(peer) ?? false);
      if (contact == null &&
          !ownDevice &&
          !groupMemberCarrier &&
          !externalSpaceProposalCarrier) {
        retire(frame.peerHex, frame.frameId);
        continue;
      }
      if (contact?.status == ContactStatus.blocked && !groupMemberCarrier) {
        continue;
      }
      if (_owner._mailboxDelivery.suppressedByBackoff(
        frame.peerHex,
        _owner._now(),
        'outbox flush',
      )) {
        continue;
      }
      // Already in the recipient's mailbox: nothing to re-offer. Asked here
      // rather than inside the deposit path so the pass does not spawn a task
      // and write a log line per pending frame per pass to learn it. The
      // deposit still comes BEFORE the live leg for everything that genuinely
      // needs depositing — that ordering is what stops an unreachable peer
      // from holding up the durable copy.
      if (!_owner._mailboxDelivery.alreadyDeposited(frame.frameId)) {
        _owner._stashInBackground(peer, frame.frameId, frame.wire);
      }
      final now = _owner._now();
      final backoff = _liveBackoff[_key(frame.peerHex, frame.frameId)];
      if (backoff != null && now.isBefore(backoff.nextAt)) continue;
      // A CEILING ON THE LIVE HALF OF ONE PASS.
      //
      // The ladder that spaces re-drives lives in `_liveBackoff`, which is RAM
      // only. After a restart it is empty, so every frame in the queue is due
      // at the same instant and the pass below sends all of them back to back —
      // serial, but serial is not bounded. A backlog of a few hundred is an
      // ordinary state for a device that was away, and this is the shape the
      // outbox was already measured producing: bursts of about 175 sends a
      // second, each one a radio wake and a DHT lookup.
      //
      // Frames past the ceiling are simply not dialled THIS pass. They keep
      // their place, their deposit was already offered above — that half is
      // what carries an offline peer — and the flush comes round again in
      // seconds. Nothing is dropped and no attempt is counted against them,
      // which is why the check sits before the ladder bookkeeping rather than
      // after it: a frame that was never sent must not be told to wait longer
      // for the next try.
      if (redrive.length >= _maxLiveRedrivesPerPass) continue;
      // Past the ceiling check, so a probe is spent only on a frame that goes.
      if (!isCallSignal && !_takeSilentProbe(frame.peerHex, now)) continue;
      final count = (backoff?.count ?? 0) + 1;
      // Call control is useful only inside the ring window and therefore uses
      // a sub-second initial ladder; ordinary durable control starts at 20s. Both grow
      // exponentially and cap at ten minutes to avoid permanent ghost load.
      final baseMs = isCallSignal
          ? _callSignalLiveResend.inMilliseconds
          : _liveResend.inMilliseconds;
      final delayMs = _jittered(
        (baseMs * (1 << (count - 1).clamp(0, 10))).clamp(
          0,
          _liveResendCap.inMilliseconds,
        ),
        frame.frameId,
      );
      _liveBackoff[_key(frame.peerHex, frame.frameId)] = (
        count: count,
        nextAt: now.add(Duration(milliseconds: delayMs)),
        peer: frame.peerHex,
        lastSentAt: now,
      );
      redrive.add((peer: peer, frame: frame, attempt: count));
    }
    // The live half, after every deposit this pass had to offer. Bounded per
    // send: this is NOT a delivery signal — a send returns when the local node
    // takes the frame, so an unreachable peer looks exactly like a reachable
    // one from here, and retention reasons about AGE rather than about what
    // this did. What it must never do is fail to return, because the pass is
    // single-flighted behind `_flushing` and one that never ends is the last
    // one this process runs.
    for (final entry in redrive) {
      devLog(
        () =>
            'xVeil[durable]: re-drive fid=${entry.frame.frameId} '
            'dst=${entry.peer.short} attempt=${entry.attempt} '
            't=${DateTime.now().millisecondsSinceEpoch}',
      );
      await boundedLiveLeg(_owner._send(entry.peer, entry.frame.wire));
    }
  }

  /// When traffic last came from each peer, by the name it came under — the
  /// identity and, for a direct session, the device. Seeded from the stored
  /// "last seen" the first time a pass has something for the peer, so a
  /// restart does not make a month of silence look like none.
  final Map<String, DateTime> _lastHeard = {};

  /// When this process last probed each silent peer. Stored with
  /// [_quietSince], so the probe cadence survives a restart too.
  final Map<String, DateTime> _lastContact = {};

  /// For a peer with no stored "last seen" at all: when a pass first had
  /// something for it. Timing a silence from there, and remembering it, is
  /// what keeps a device never heard since it was linked from being treated
  /// as freshly quiet after every restart.
  final Map<String, DateTime> _quietSince = {};

  /// Peers whose stored silence has been read this process.
  final Set<String> _silenceLoaded = {};

  /// The probe interval each silent peer was last logged at.
  final Map<String, Duration> _silenceNoted = {};

  /// How long a peer may say nothing before its frames stop being re-driven
  /// one by one. The re-drive ladder's own ceiling: by then every frame for
  /// it is being tried at the slowest step anyway.
  static const _silentAfter = Duration(minutes: 10);

  static String _probeKey(String peerHex) => 'peer_probe:$peerHex';

  /// How often ONE frame is re-driven to a peer that has been silent for
  /// [silence] — the time from when it was last heard to when it was last
  /// probed.
  ///
  /// The ladder spaces each FRAME, and a peer that has gone away collects
  /// frames: measured on a stand, an absent linked device of one node had 143
  /// queued and drew 81% of that node's live sends — about thirty a minute,
  /// each a route lookup for a device that was not there, for as long as the
  /// node ran. One frame answers the only question a re-drive can: is it back?
  /// And the longer it has been away, the less often that is worth asking: a
  /// device gone for a month is probed weekly, not every two minutes forever.
  /// Nothing is dropped and no attempt is counted against the frames that
  /// wait; the first thing heard from the peer rewinds all of them. The
  /// mailbox copy is offered on every pass regardless, so a slow probe delays
  /// only the live half.
  @visibleForTesting
  static Duration silentProbeInterval(Duration silence) {
    if (silence >= const Duration(days: 30)) return const Duration(days: 7);
    if (silence >= const Duration(days: 7)) return const Duration(days: 1);
    if (silence >= const Duration(days: 1)) return const Duration(hours: 2);
    if (silence >= const Duration(hours: 3)) return const Duration(minutes: 30);
    if (silence >= const Duration(hours: 1)) return const Duration(minutes: 15);
    return const Duration(minutes: 2);
  }

  /// Read, once per process, what is stored about each peer's silence.
  ///
  /// A peer with nothing stored at all is timed from its OLDEST frame still
  /// waiting, when the queue knows it ([oldestQueued], ms). A peer heard since
  /// then would have acknowledged that frame and it would be gone, so its age
  /// is a floor under the silence — and without it a device that has been
  /// away since before this record existed would start its silence over, and
  /// take a month to reach the cadence a month of silence has earned.
  Future<void> _loadSilences(
    Iterable<String> peers, {
    Map<String, int> oldestQueued = const {},
  }) async {
    for (final peerHex in peers.toList()) {
      if (!_silenceLoaded.add(peerHex)) continue;
      DateTime? seen;
      try {
        seen = await _owner.lastSeen(NodeId.fromHex(peerHex));
      } catch (_) {}
      String? raw;
      try {
        raw = await _owner._storage.getSetting(_probeKey(peerHex));
      } catch (_) {}
      final parts = (raw ?? '').split(',');
      DateTime? at(int i) {
        final ms = parts.length > i ? int.tryParse(parts[i]) : null;
        return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      }

      var quiet = at(0);
      final contact = at(1);
      final queuedMs = oldestQueued[peerHex];
      // Stamped by the wall clock when queued; one from the future (a clock
      // that moved back) says nothing about how long the peer has been away.
      if (seen == null &&
          quiet == null &&
          queuedMs != null &&
          queuedMs <= _owner._now().millisecondsSinceEpoch) {
        quiet = DateTime.fromMillisecondsSinceEpoch(queuedMs);
        _quietSince[peerHex] = quiet;
        _storeSilence(peerHex);
      }
      final stored = quiet;
      if (stored != null) _quietSince.putIfAbsent(peerHex, () => stored);
      if (contact != null) _lastContact.putIfAbsent(peerHex, () => contact);
      final heard = seen ?? quiet;
      final current = _lastHeard[peerHex];
      if (heard != null && (current == null || heard.isAfter(current))) {
        _lastHeard[peerHex] = heard;
      }
    }
  }

  void _storeSilence(String peerHex) {
    final quiet = _quietSince[peerHex]?.millisecondsSinceEpoch;
    final contact = _lastContact[peerHex]?.millisecondsSinceEpoch;
    final value = quiet == null && contact == null
        ? ''
        : '${quiet ?? ''},${contact ?? ''}';
    unawaited(() async {
      try {
        await _owner._storage.putSetting(_probeKey(peerHex), value);
      } catch (_) {
        // Best-effort: a lost record costs one early probe after a restart.
      }
    }());
  }

  /// When [peer] was last heard from, or — never heard — since when a pass
  /// has had something for it. Null when neither is known.
  Future<DateTime?> silentSince(NodeId peer) async {
    await _loadSilences([peer.hex]);
    return _lastHeard[peer.hex];
  }

  /// Traffic from [peerHex] arrived: it is not silent, and its queue goes
  /// back to the ordinary ladder at once.
  ///
  /// Returns whether this ENDED a silence, in which case every frame for the
  /// peer is due now — the recently probed ones too. [nudge] spares a frame
  /// sent moments ago so its ack can land, but a probe sent into a silence was
  /// lost: had it arrived, the answer would have ended the silence sooner.
  bool noteHeard(String peerHex) {
    final now = _owner._now();
    final heard = _lastHeard[peerHex];
    final wasSilent = heard != null && now.difference(heard) >= _silentAfter;
    _lastHeard[peerHex] = now;
    _silenceNoted.remove(peerHex);
    // The silence is over, so what was stored about it is too. Written only
    // when there was something, so an ordinary inbound frame costs no write.
    final hadContact = _lastContact.remove(peerHex) != null;
    final hadQuiet = _quietSince.remove(peerHex) != null;
    if (hadContact || hadQuiet) _storeSilence(peerHex);
    if (!wasSilent) return false;
    for (final id in _liveBackoff.keys.toList()) {
      final backoff = _liveBackoff[id]!;
      if (backoff.peer != peerHex || !backoff.nextAt.isAfter(now)) continue;
      _liveBackoff[id] = (
        count: backoff.count,
        nextAt: now,
        peer: backoff.peer,
        lastSentAt: backoff.lastSentAt,
      );
    }
    devLog(
      () =>
          'xVeil[durable]: ${peerHex.substring(0, 8)} answered after '
          '${now.difference(heard).inMinutes}m of silence — its queue is due now',
    );
    return true;
  }

  /// Whether a frame for [peerHex] may be re-driven this pass, and if the peer
  /// is silent, spend its probe.
  ///
  /// A peer never heard from at all is timed from the first pass that had
  /// something for it, and that moment is stored, so neither a restart nor a
  /// fresh process makes a long-gone peer look freshly quiet.
  bool _takeSilentProbe(String peerHex, DateTime now) {
    var heard = _lastHeard[peerHex];
    if (heard == null) {
      heard = _quietSince.putIfAbsent(peerHex, () => now);
      _lastHeard[peerHex] = heard;
      _storeSilence(peerHex);
    }
    if (now.difference(heard) < _silentAfter) return true;
    // THE INTERVAL IS CHOSEN BY THE SILENCE AT THE LAST PROBE — how long the
    // peer had said nothing when it was last asked. A probe from before the
    // peer was last heard belongs to an earlier silence and does not count.
    final last = _lastContact[peerHex];
    if (last != null && last.isAfter(heard)) {
      final every = silentProbeInterval(last.difference(heard));
      if (now.isBefore(last.add(every))) return false;
    }
    _lastContact[peerHex] = now;
    _storeSilence(peerHex);
    final every = silentProbeInterval(now.difference(heard));
    if (_silenceNoted[peerHex] != every) {
      _silenceNoted[peerHex] = every;
      devLog(
        () =>
            'xVeil[durable]: ${peerHex.substring(0, 8)} silent for '
            '${now.difference(heard!).inMinutes}m — one frame re-driven per '
            '${every.inMinutes}m until it answers',
      );
    }
    return true;
  }

  /// Frames dialled in one flush pass.
  ///
  /// The pass repeats on the flush cadence, so this is a rate rather than a
  /// limit on the queue: a backlog drains over several passes instead of in
  /// one burst. See the ceiling's use for why a restart is when it matters.
  static const _maxLiveRedrivesPerPass = 16;

  /// How long a queued REPLICATION frame is worth keeping.
  ///
  /// State only, and only state: a group snapshot this old has been overtaken
  /// by the sender's own newer state anyway, and a device that comes back is
  /// re-synced from its own frontier by `nudgeGroupSyncAll` at every app
  /// start. Event frames are user data and are never dropped by age — a peer
  /// away for a day must still find them waiting, which is the entire contract
  /// of a durable queue.
  static const _replicationMaxAge = Duration(hours: 6);

  /// How long a queued DIRECT-ENDPOINT share is worth keeping.
  ///
  /// The frame says "these are my dial addresses right now". Delivered an hour
  /// later it does not merely fail to help — it tells the peer to dial an
  /// address that has probably moved. `_retireEarlierEndpointFrames` clears the
  /// superseded ones whenever a NEW set is sent, which covers every peer we
  /// still talk to; this covers the one we do not. A phone was measured
  /// re-driving a single endpoint frame to a peer its own P2P policy refused,
  /// with nothing in the design that would ever have stopped.
  static const _endpointMaxAge = Duration(minutes: 30);

  /// Drop a replication frame that has been queued past [_replicationMaxAge].
  ///
  /// This is what stops the pile-up at the source rather than reacting to it:
  /// a peer that stops accepting no longer leaves an unbounded, permanent
  /// backlog behind it. Frames written before stamping carry no time at all,
  /// and an unknown age is treated as "keep" — a migration is no reason to
  /// throw anything away.
  bool _retireStaleReplication(OutboxFrame frame) {
    final isReplication = MessagingService._isReplicationFrame(frame.frameId);
    final isEndpoints = frame.frameId.startsWith(_kP2PEndpointFramePrefix);
    if (!isReplication && !isEndpoints) return false;
    final at = frame.enqueuedAtMs;
    if (at == null) return false;
    final age = _owner._now().difference(
      DateTime.fromMillisecondsSinceEpoch(at),
    );
    final maxAge = isEndpoints ? _endpointMaxAge : _replicationMaxAge;
    if (age <= maxAge) return false;
    devLog(
      () =>
          'xVeil[durable]: dropping stale '
          '${isEndpoints ? 'endpoints' : 'replication'} fid=${frame.frameId} '
          'dst=${frame.peerHex.substring(0, 8)} age=${age.inMinutes}m',
    );
    _owner._retireOutboxFrame(frame.peerHex, frame.frameId);
    return true;
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
        retire(frame.peerHex, frame.frameId);
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
      retire(frame.peerHex, frame.frameId);
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

  /// A narrowly scoped external Space proposal can address a non-contact. An
  /// ACK may retire it only when the exact id is still queued for that
  /// authenticated peer; guessed ids and cross-peer acknowledgements remain
  /// inert.
  Future<bool> authorizedExternalSpaceProposalAck(
    NodeId peer,
    String frameId,
  ) async {
    if (!frameId.startsWith('space-join-request:') &&
        !frameId.startsWith('space-join-decision:') &&
        !frameId.startsWith('space-moderation-appeal:') &&
        !frameId.startsWith('space-moderation-appeal-decision:') &&
        !frameId.startsWith('space-abuse-report:') &&
        !frameId.startsWith('space-abuse-report-decision:')) {
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

  /// Retire a frame the given peer confirmed.
  ///
  /// [peerHex] is not decoration: without it, an accepted contact who knew or
  /// guessed the frameId could ACK it and retire a frame addressed to someone
  /// else, suppressing that delivery entirely (audit XV-02).
  void retire(String peerHex, String frameId) {
    final key = _key(peerHex, frameId);
    if (_sendingUnpersisted.contains(key)) {
      // The row is still being written. Remember the ACK so the sender retires
      // it the moment it exists — otherwise this call deletes nothing and the
      // frame is left pending forever.
      _ackedWhileUnpersisted.add(key);
    }
    _fastCallRetryTimers.remove(frameId)?.cancel();
    _owner._mailboxDelivery.removeStashed(frameId);
    _liveBackoff.remove(_key(peerHex, frameId));
    final left = (_pendingByPeer[peerHex] ?? 0) - 1;
    if (left > 0) {
      _pendingByPeer[peerHex] = left;
    } else {
      _pendingByPeer.remove(peerHex);
    }
    unawaited(_owner._storage.ackOutboxFrame(frameId, fromPeerHex: peerHex));
  }

  void dispose() {
    for (final timer in _fastCallRetryTimers.values) {
      timer.cancel();
    }
    _fastCallRetryTimers.clear();
  }
}
