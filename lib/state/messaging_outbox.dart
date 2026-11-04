part of 'messaging_core.dart';

typedef _OutboxRedrive = ({
  NodeId peer,
  OutboxFrame frame,
  bool callSignal,
  bool contactIdentity,
});

class _GroupSliceAcks {
  _GroupSliceAcks(this.count)
    : _known = Uint8List((count + 7) >> 3),
      _acknowledged = Uint8List((count + 7) >> 3);
  final int count;
  final Uint8List _known;
  final Uint8List _acknowledged;
  int ackCount = 0;

  bool knows(int index) =>
      index >= 0 &&
      index < count &&
      (_known[index >> 3] & (1 << (index & 7))) != 0;
  void noteKnown(int index) => _known[index >> 3] |= 1 << (index & 7);
  void noteAck(int index) {
    final mask = 1 << (index & 7);
    if ((_acknowledged[index >> 3] & mask) == 0) {
      _acknowledged[index >> 3] |= mask;
      ackCount++;
    }
  }
}

/// A flush owns a snapshot, not a lease to send rows after their ACK. Track
/// changes even while that snapshot is being read. Nothing survives the pass.
class _OutboxFlushSnapshot {
  final _candidates = <String>{};
  Set<String>? _changedWhileReading = {};
  var _changedBytes = 0;
  var _cancelled = false;

  void invalidate(String key) {
    _candidates.remove(key);
    final changed = _changedWhileReading;
    if (_cancelled || changed == null || changed.contains(key)) return;
    // A slow read must not retain an unbounded stream of unrelated ACK IDs.
    // Overflow postpones this pass; the next pass reads authoritative rows.
    final bytes = 64 + 2 * key.length;
    if (changed.length >= 256 || _changedBytes + bytes > 64 * 1024) {
      cancel();
      return;
    }
    changed.add(key);
    _changedBytes += bytes;
  }

  bool capture(List<OutboxFrame> rows) {
    if (_cancelled) return false;
    final changed = _changedWhileReading!;
    _changedWhileReading = null;
    for (final row in rows) {
      final key = _MessagingOutbox._key(row.peerHex, row.frameId);
      if (!changed.contains(key)) _candidates.add(key);
    }
    return true;
  }

  bool contains(String peer, String id) =>
      !_cancelled && _candidates.contains(_MessagingOutbox._key(peer, id));

  void cancel() {
    _cancelled = true;
    _candidates.clear();
    _changedWhileReading = null;
  }
}

/// Durable control-frame persistence, deduplication, acknowledgement and
/// bounded live re-drive.
///
/// Chat messages retain their event-log outbox. This subsystem owns the
/// parallel durable path used by control frames such as accepts, edits, call
/// transitions, group requests and replication records.
class _MessagingOutbox {
  _MessagingOutbox(this._owner);

  final MessagingService _owner;
  late final _editExpiry = _MessageEditExpiry(this);

  _OutboxFlushSnapshot? _flushSnapshot;

  // A wait deadline does not cancel the underlying transport future. Keep
  // the recipient occupied until that future actually settles, across flush
  // passes, so late operations cannot pile up behind repeated deadlines.
  final Map<String, Object> _activeLivePeers = {};

  // Large replication slices share the endpoint's background source lane
  // with file bodies. Small group/control updates keep their normal path.
  // Derive this from durable wire kind so restart/re-drive keeps the lane;
  // it adds no persistent flag or relay-visible scheduling metadata.
  static bool _usesBackgroundLane(WireKind kind) =>
      kind == WireKind.groupEntryChunk || kind == WireKind.cloudDocumentChunk;

  static bool _backgroundWire(Uint8List wire) {
    try {
      return _usesBackgroundLane(WireEnvelope.decode(wire).kind);
    } catch (_) {
      return false;
    }
  }

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
  final Set<String> _pendingKeys = {};

  // Older receivers reply to an opted-in transfer with individual ACKs.
  // Keep ALL durable payloads until every slice is acknowledged: removing one
  // made a receiver restart leave an unreconstructable, retrying tail. Only
  // volatile progress is needed; losing it resends the complete durable copy.
  final _groupSliceAcks = <String, _GroupSliceAcks>{};
  static const _maxGroupSliceAckTransfers = 128;

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
      _pendingKeys.clear();
      for (final frame in pending) {
        _pendingKeys.add(_key(frame.peerHex, frame.frameId));
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
  // A recovered route must not wait through the ordinary exponential tail
  // for an answer/end. These transitions expire after two minutes; keep their
  // retry spacing short beyond the initial fast burst as well. The existing
  // flush admission, peer lanes, ACK retirement and TTL still bound the work.
  static const _callSignalResendCap = Duration(seconds: 2);
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
    _flushSnapshot?.invalidate(_key(peerHex, frameId));
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

  /// Persist before a first contact attempt; no network work starts here.
  Future<void> enqueue(NodeId peer, String frameId, Uint8List wire) async {
    await _owner._storage.enqueueOutboxFrame(frameId, peer.hex, wire);
    final tid = _MessagingReplication._canonicalChunkTransfer(frameId);
    final progress = tid == null ? null : _groupSliceAcks[_key(peer.hex, tid)];
    if (progress != null) {
      final part = _optedGroupSlice(frameId, wire);
      if (part != null && part.count == progress.count) {
        progress.noteKnown(part.index);
      }
    }
    // Manual retries replace the same durable row, rather than adding one.
    if (_pendingKeys.add(_key(peer.hex, frameId))) {
      _pendingByPeer[peer.hex] = (_pendingByPeer[peer.hex] ?? 0) + 1;
    }
    recordQueued(
      frameId,
      peer.hex,
      callSignal: _MessagingMailboxDelivery.isCallSignalId(frameId),
    );
  }

  Future<void> retireRequests(NodeId peer) async {
    for (final frame in await _owner._storage.pendingOutboxFrames()) {
      if (frame.peerHex != peer.hex || !frame.frameId.startsWith('request:')) {
        continue;
      }
      // Prefix is an optimization, not authority over an unrelated frame.
      try {
        if (WireEnvelope.decode(frame.wire).kind != WireKind.request) continue;
      } catch (_) {
        continue;
      }
      await _retirePersisted(peer.hex, frame.frameId);
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
    if (envelope.kind == WireKind.edit &&
        !await _editExpiry.allow(peer.hex, frameId, wire, persisted: false)) {
      return;
    }
    final mailboxEligible =
        envelope.kind == WireKind.request || envelope.kind == WireKind.accept;
    final skipLive =
        !_MessagingMailboxDelivery.isCallSignalId(frameId) &&
        !startLiveBeforeEnqueue &&
        await _longSilent(peer.hex);
    Future<void> tryLive() async {
      final stopwatch = Stopwatch()..start();
      try {
        if (_owner._expiryLifecycle.defers(OutboxFrame(
          peerHex: peer.hex, frameId: frameId, wire: wire,
        ))) {
          return;
        }
        if (envelope.kind == WireKind.edit &&
            (!await _editExpiry.allow(peer.hex, frameId, wire, persisted: true) ||
                _owner._disposed)) {
          return;
        }
        await (liveSender?.call(wire) ??
            _owner._send(
              peer,
              wire,
              background: _usesBackgroundLane(envelope.kind),
            ));
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
    await enqueue(peer, frameId, wire);
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
    // Enqueue can wait behind encrypted-store I/O. Expiry cleanup is part of
    // this durable handoff, even when a silent peer gets no live leg (or its
    // live leg is detached). Do not rely on tryLive to retire the stored body.
    if (envelope.kind == WireKind.edit &&
        !await _editExpiry.allow(peer.hex, frameId, wire, persisted: true)) {
      return;
    }
    // Contact requests and acceptance use mailbox. Start
    // its deposit before waiting for a live send to an unavailable requester.
    if (mailboxEligible) _owner._stashInBackground(peer, frameId, wire);
    if (skipLive) {
      if (_liveSkipNoted.add(peer.hex)) {
        devLog(
          () =>
              'xVeil[durable]: ${peer.short} silent for over a day — new '
              'frames are queued without a live leg; the probe ladder and '
              'its first answer reach them',
        );
      }
    } else if (earlyLive != null) {
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
            '${_owner.liveLegDeadline.inSeconds}s — the durable copy remains '
            'queued, so the pass moves on',
      );
    } catch (_) {
      // Best-effort by contract; the durable copy remains queued until ACK.
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
                .clamp(0, _callSignalResendCap.inMilliseconds),
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
          // Every constituent path is best-effort; the next live retry remains.
        }
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
    if (!_owner._storage.isOpen || _owner._disposed || _flushSnapshot != null) {
      return;
    }
    final snapshot = _OutboxFlushSnapshot();
    _flushSnapshot = snapshot;
    try {
      await _flush(snapshot);
    } finally {
      _flushSnapshot = null;
    }
  }

  Future<void> _flush(_OutboxFlushSnapshot snapshot) async {
    final List<OutboxFrame> pending;
    try {
      pending = await _owner._storage.pendingOutboxFrames();
    } catch (_) {
      return;
    }
    if (_owner._disposed || !snapshot.capture(pending)) return;
    bool current(OutboxFrame frame) =>
        !_owner._disposed && snapshot.contains(frame.peerHex, frame.frameId) &&
        !_editExpiry.blocks(frame.peerHex, frame.frameId) &&
        !_owner._replication._expiry.blocks(frame.peerHex, frame.frameId);
    // The authoritative count, once per cycle. Everything between cycles only
    // adjusts it.
    _pendingByPeer.clear();
    _pendingKeys.clear();
    for (final frame in pending) {
      _pendingKeys.add(_key(frame.peerHex, frame.frameId));
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
    // nothing else. Attempts retain serial order within each recipient and their ladder.
    // A bounded number of recipient lanes prevents a single stalled dial
    // from holding every other peer behind it.
    final redrive = <String, List<_OutboxRedrive>>{};
    final plannedSilentPeers = <String>{};
    NodeId? selfNode;
    String? selfIdentityHex;
    bool? selfAliasIsAuthority;
    try {
      selfNode = await _owner._transport.nodeId();
    } catch (_) {
      // No self id (transport still booting) — skip the self check this pass.
    }
    try {
      selfIdentityHex = await _owner.selfIdentityHex?.call();
    } catch (_) {
      // An unavailable identity cannot justify retiring its queued state.
    }
    for (final frame in pending) {
      if (!current(frame)) continue;
      if (_owner._expiryLifecycle.defers(frame)) continue;
      try {
        if (!await _editExpiry.allow(
          frame.peerHex,
          frame.frameId,
          frame.wire,
          persisted: true,
          enqueuedAtMs: frame.enqueuedAtMs,
        )) {
          continue;
        }
      } catch (_) {
        // Retain an unreadable edit for retry, but never re-drive its body.
        continue;
      }
      if (!current(frame)) continue;
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
      if (frame.peerHex == selfIdentityHex &&
          (frame.frameId.startsWith('grp:') ||
              frame.frameId.startsWith('grpc:'))) {
        var groupReplication = false;
        try {
          final kind = WireEnvelope.decode(frame.wire).kind;
          groupReplication =
              kind == WireKind.groupEntry || kind == WireKind.groupEntryChunk;
        } catch (_) {}
        if (groupReplication) {
          try {
            selfAliasIsAuthority ??=
                await _owner.isSovereignAuthority?.call(peer) ?? false;
          } catch (_) {
            selfAliasIsAuthority = false;
          }
          if (selfAliasIsAuthority == true) {
            if (!current(frame)) continue;
            // An old sync answer addressed the shared authority rather than
            // the requesting device. Fragments can reach different endpoints
            // and never assemble. Current sync asks carry a physical reply
            // address and recover state from the source journal instead.
            devLog(
              () =>
                  'xVeil[durable]: retire group frame addressed to '
                  'the sovereign authority, not a device',
            );
            retire(frame.peerHex, frame.frameId);
            continue;
          }
        }
      }
      final Contact? contact;
      try {
        contact = await _owner._storage.getContact(peer);
      } catch (_) {
        continue;
      }
      if (!current(frame)) continue;
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
        if (!current(frame)) continue;
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
          contact == null && (await _owner.isOwnDevice?.call(peer) ?? false);
      if (!current(frame)) continue;
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
      // Contact handshake frames use these stable prefixes. Avoid parsing
      // each queued group snapshot on every three-second flush just to skip it.
      // The deposit gate still validates the actual wire kind.
      final mailboxEligible =
          frame.frameId.startsWith('accept:') ||
          frame.frameId.startsWith('request:');
      if (mailboxEligible &&
          _owner._mailboxDelivery.suppressedByBackoff(
            frame.peerHex,
            _owner._now(),
            'outbox flush',
          )) {
        continue;
      }
      // Re-offer a contact handshake only if it has not reached mailbox.
      if (mailboxEligible &&
          !_owner._mailboxDelivery.alreadyDeposited(frame.frameId)) {
        _owner._stashInBackground(peer, frame.frameId, frame.wire);
      }
      final now = _owner._now();
      if (!snapshot.contains(frame.peerHex, frame.frameId)) continue;
      if (_activeLivePeers.containsKey(frame.peerHex)) continue;
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
      // Frames past the ceiling remain queued for the next pass. Nothing is
      // dropped and no attempt is counted against an unsent frame.
      if ((redrive[frame.peerHex]?.length ?? 0) >= _maxLiveRedrivesPerPass) {
        continue;
      }
      // Reserve only this pass's slot here. The persisted probe cadence and
      // retry ladder advance when the actual attempt starts, not while it is
      // waiting behind another peer. A cancelled candidate spends neither.
      if (!isCallSignal) {
        if (!_canTakeSilentProbe(frame.peerHex, now)) continue;
        final heard =
            _lastHeard[frame.peerHex] ?? _quietSince[frame.peerHex] ?? now;
        if (now.difference(heard) >= _silentAfter &&
            !plannedSilentPeers.add(frame.peerHex)) {
          continue;
        }
      }
      (redrive[frame.peerHex] ??= []).add((
        peer: peer,
        frame: frame,
        callSignal: isCallSignal,
        contactIdentity: contact?.status == ContactStatus.accepted,
      ));
    }
    // Give each due recipient a slot before taking another from its backlog.
    // The global ceiling stays 16 attempts; a cold first peer must not consume
    // all of them while a healthy peer waits at the end of the stored list.
    final selected = <String, List<_OutboxRedrive>>{};
    var left = _maxLiveRedrivesPerPass;
    for (var index = 0; left > 0; index++) {
      var added = false;
      for (final lane in redrive.entries) {
        if (index >= lane.value.length) continue;
        (selected[lane.key] ??= []).add(lane.value[index]);
        added = true;
        if (--left == 0) break;
      }
      if (!added) break;
    }
    // Join at most four worker jobs, each waiting for one recipient's attempts
    // in order. Keep the existing live-leg deadline semantics: timing out stops
    // waiting, not an already-started transport operation. The pass still
    // admits at most 16 attempts; local/wire lanes and consent stay unchanged.
    final lanes = selected.values.toList();
    var next = 0;
    Future<void> worker() async {
      while (!_owner._disposed && next < lanes.length) {
        final lane = lanes[next++];
        for (final entry in lane) {
          if (!await _redriveCandidate(entry, snapshot)) break;
        }
      }
    }

    await Future.wait<void>([
      for (var i = 0; i < lanes.length && i < 4; i++) worker(),
    ]);
  }

  // False leaves this recipient's unsent tail for a later pass: its actual
  // operation is still running even though this worker stopped waiting.
  Future<bool> _redriveCandidate(
    _OutboxRedrive entry,
    _OutboxFlushSnapshot snapshot,
  ) async {
    if (_owner._disposed ||
        !snapshot.contains(entry.frame.peerHex, entry.frame.frameId)) {
      return true;
    }
    try {
      if (!await _editExpiry.allow(
        entry.peer.hex,
        entry.frame.frameId,
        entry.frame.wire,
        persisted: true,
        enqueuedAtMs: entry.frame.enqueuedAtMs,
      )) {
        return true;
      }
    } catch (_) {
      // Keep the durable row, but do not send an edit whose expiry could not
      // be checked. Other recipients retain their own attempts this pass.
      return true;
    }
    if (_owner._disposed ||
        !snapshot.contains(entry.frame.peerHex, entry.frame.frameId)) {
      return true;
    }
    final peerHex = entry.frame.peerHex;
    if (_activeLivePeers.containsKey(peerHex)) return false;
    final now = _owner._now();
    final key = _key(entry.frame.peerHex, entry.frame.frameId);
    final backoff = _liveBackoff[key];
    if (backoff != null && now.isBefore(backoff.nextAt)) return true;
    if (!entry.callSignal && !_takeSilentProbe(entry.frame.peerHex, now)) {
      return true;
    }
    final count = (backoff?.count ?? 0) + 1;
    final baseMs = entry.callSignal
        ? _callSignalLiveResend.inMilliseconds
        : _liveResend.inMilliseconds;
    final delayMs = _jittered(
      (baseMs * (1 << (count - 1).clamp(0, 10))).clamp(
        0,
        (entry.callSignal ? _callSignalResendCap : _liveResendCap)
            .inMilliseconds,
      ),
      entry.frame.frameId,
    );
    _liveBackoff[key] = (
      count: count,
      nextAt: now.add(Duration(milliseconds: delayMs)),
      peer: entry.frame.peerHex,
      lastSentAt: now,
    );
    devLog(
      () =>
          'xVeil[durable]: re-drive fid=${entry.frame.frameId} '
          'dst=${entry.peer.short} attempt=$count '
          't=${DateTime.now().millisecondsSinceEpoch}',
    );
    final token = Object();
    _activeLivePeers[peerHex] = token;
    var completed = false;
    Future<void> send() async {
      try {
        await _redriveLive(
          entry.peer,
          entry.frame.wire,
          contactIdentity: entry.contactIdentity,
        );
      } finally {
        completed = true;
        if (identical(_activeLivePeers[peerHex], token)) {
          _activeLivePeers.remove(peerHex);
        }
      }
    }

    await boundedLiveLeg(send());
    return completed;
  }

  /// Restore the original live lanes after restart and after the fast retry
  /// ladder ends. A queued answer must still race realtime when the ordinary
  /// stream is stalled. Classify the saved wire, never its frame-id prefix;
  /// the caller has already checked contact/device/group authorization.
  Future<void> _redriveLive(
    NodeId peer,
    Uint8List wire, {
    required bool contactIdentity,
  }) {
    WireKind? kind;
    try {
      kind = WireEnvelope.decode(wire).kind;
    } catch (_) {
      // Keep the existing ordinary path for an unreadable legacy frame.
    }
    switch (kind) {
      case WireKind.callSignal:
        return _owner._realtimeControl._sendCallLive(
          peer,
          wire,
          contactIdentity: contactIdentity,
        );
      case WireKind.groupCallSignal:
        return _owner._realtimeControl._sendCallLive(
          peer,
          wire,
          contactIdentity: true,
        );
      case WireKind.p2pEndpoints:
        return _owner._realtimeControl._sendP2PBootstrap(peer, wire);
      default:
        return _owner._send(peer, wire, background: _backgroundWire(wire));
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

  /// A peer silent this long gets no live leg for a NEW frame, only the queue.
  ///
  /// The ladder spaces re-drives, but every new frame still dialled at once:
  /// measured on the stand, a linked device dead for 29 hours drew 343 live
  /// sends and 850 KB in fifteen minutes from its sibling, every device-log
  /// delta dialled into nothing. The reason the first send was left alone —
  /// an idle but living sibling would wait out the probe interval — does not
  /// reach this far: a living device is heard from far more often than once
  /// a day, and the first thing heard from it rewinds its whole queue.
  static const _liveOnlyWhenHeardWithin = Duration(days: 1);

  /// Peers already told about in the log, once each.
  final Set<String> _liveSkipNoted = {};

  Future<bool> _longSilent(String peerHex) async {
    try {
      await _loadSilences([peerHex]);
    } catch (_) {
      return false;
    }
    final heard = _lastHeard[peerHex];
    if (heard == null) return false;
    final silent = _owner._now().difference(heard) >= _liveOnlyWhenHeardWithin;
    if (!silent) _liveSkipNoted.remove(peerHex);
    return silent;
  }

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
  bool _canTakeSilentProbe(String peerHex, DateTime now) {
    final heard = _lastHeard[peerHex] ?? _quietSince[peerHex] ?? now;
    if (now.difference(heard) < _silentAfter) return true;
    final last = _lastContact[peerHex];
    return last == null ||
        !last.isAfter(heard) ||
        !now.isBefore(last.add(silentProbeInterval(last.difference(heard))));
  }

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
    if (!_canTakeSilentProbe(peerHex, now)) return false;
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
    unawaited(_retirePersisted(peerHex, frameId));
  }

  Future<bool> retireGroupTransfer(
    NodeId source,
    String tid, {
    required bool ownDeviceAck,
    int? requireSliceCount,
  }) async {
    if (_owner._disposed) return false;
    final destination = NodeId.fromHex(tid.split(':').last);
    if (source != destination &&
        !(ownDeviceAck &&
            (await _owner.isOwnDevice?.call(destination) ?? false))) {
      return false;
    }
    final pending = await _owner._storage.pendingOutboxFrames();
    if (_owner._disposed) return false;
    final ids = <String>[];
    for (final frame in pending) {
      if (frame.peerHex != destination.hex ||
          !frame.frameId.startsWith('grpc:$tid:')) {
        continue;
      }
      try {
        final envelope = WireEnvelope.decode(frame.wire);
        if (envelope.kind != WireKind.groupEntryChunk) continue;
        final part = parseGroupEntryChunk(envelope.body);
        if (part.transferAck &&
            part.transferId == tid &&
            (requireSliceCount == null ||
                (part.count == requireSliceCount &&
                    part.index >= 0 &&
                    part.index < requireSliceCount)) &&
            frame.frameId == 'grpc:$tid:${part.index}') {
          ids.add(frame.frameId);
        }
      } catch (_) {
        /* malformed queued data cannot consume another namespace */
      }
    }
    if (ids.isEmpty ||
        (requireSliceCount != null && ids.length != requireSliceCount)) {
      return false;
    }
    void invalidate() {
      for (final id in ids) {
        _flushSnapshot?.invalidate(_key(destination.hex, id));
      }
    }

    invalidate();
    final List<String> retired;
    try {
      retired = await _owner._storage.ackOutboxFrames(
        ids,
        fromPeerHex: destination.hex,
      );
    } finally {
      // A flush can start while the atomic retirement is still waiting.
      invalidate();
    }
    // Change volatile accounting only after the all-or-none storage commit.
    for (final id in retired) {
      _owner._replication._cancelQueuedGroupFrame(destination.hex, id);
      _owner._mailboxDelivery.removeStashed(id);
      final key = _key(destination.hex, id);
      _liveBackoff.remove(key);
      if (_pendingKeys.remove(key)) {
        final left = (_pendingByPeer[destination.hex] ?? 0) - 1;
        if (left > 0) {
          _pendingByPeer[destination.hex] = left;
        } else {
          _pendingByPeer.remove(destination.hex);
        }
      }
    }
    if (retired.isNotEmpty) _groupSliceAcks.remove(_key(destination.hex, tid));
    return retired.isNotEmpty;
  }

  static ({String tid, int index, int count})? _optedGroupSlice(
    String frameId,
    Uint8List wire,
  ) {
    final tid = _MessagingReplication._canonicalChunkTransfer(frameId);
    if (tid == null) return null;
    try {
      final env = WireEnvelope.decode(wire);
      if (env.kind != WireKind.groupEntryChunk) return null;
      final part = parseGroupEntryChunk(env.body);
      if (!part.transferAck ||
          part.transferId != tid ||
          part.count <= 0 ||
          part.count > _kMaxGroupReasmChunks ||
          part.index < 0 ||
          part.index >= part.count ||
          frameId != 'grpc:$tid:${part.index}') {
        return null;
      }
      return (tid: tid, index: part.index, count: part.count);
    } catch (_) {
      return null;
    }
  }

  /// Returns true when an individual ACK belongs to an opted-in transfer and
  /// was handled as transfer progress instead of deleting its recovery bytes.
  Future<bool> _collectGroupSliceAck(String peerHex, String frameId) async {
    final tid = _MessagingReplication._canonicalChunkTransfer(frameId);
    if (tid == null || tid.split(':').last != peerHex) return false;
    final index = int.tryParse(frameId.substring(frameId.lastIndexOf(':') + 1));
    if (index == null || frameId != 'grpc:$tid:$index') return false;
    final key = _key(peerHex, tid);
    var progress = _groupSliceAcks[key];
    if (progress == null || !progress.knows(index)) {
      // Usually one scan, at the first legacy ACK. Later enqueues update the
      // known set too, so a receiver that ACKs during enqueue need not make
      // every ACK decode the whole transfer again.
      final pending = await _owner._storage.pendingOutboxFrames();
      if (_owner._disposed) return true;
      ({String tid, int index, int count})? target;
      for (final frame in pending) {
        if (frame.peerHex == peerHex && frame.frameId == frameId) {
          target = _optedGroupSlice(frame.frameId, frame.wire);
          break;
        }
      }
      if (target == null) return false;
      progress = _groupSliceAcks[key];
      if (progress == null) {
        if (_groupSliceAcks.length >= _maxGroupSliceAckTransfers) {
          _groupSliceAcks.remove(_groupSliceAcks.keys.first);
        }
        progress = _GroupSliceAcks(target.count);
        _groupSliceAcks[key] = progress;
      }
      if (progress.count != target.count) return true;
      for (final frame in pending) {
        if (frame.peerHex != peerHex ||
            !frame.frameId.startsWith('grpc:$tid:')) {
          continue;
        }
        final part = _optedGroupSlice(frame.frameId, frame.wire);
        if (part != null && part.count == progress.count) {
          progress.noteKnown(part.index);
        }
      }
    }
    if (!progress.knows(index)) return true;
    progress.noteAck(index);
    if (progress.ackCount == progress.count) {
      // A final authoritative scan also refuses pre-upgrade orphaned tails or
      // an ACK racing rows that have not all become durable yet.
      await retireGroupTransfer(
        NodeId.fromHex(peerHex),
        tid,
        ownDeviceAck: false,
        requireSliceCount: progress.count,
      );
    }
    return true;
  }

  Future<void> _retirePersisted(String peerHex, String frameId) async {
    final key = _key(peerHex, frameId);
    // Preserve synchronous flush invalidation even when chunk ACK handling
    // must await its first authoritative metadata read.
    _flushSnapshot?.invalidate(key);
    // Another live/retry copy may have earned this ACK while its first attempt
    // was still waiting behind a different frame. Do not send that stale copy.
    // Storage failure still leaves the durable row for the ordinary retry.
    _owner._replication._cancelQueuedGroupFrame(peerHex, frameId);
    if (_MessagingReplication._canonicalChunkTransfer(frameId) != null) {
      if (_sendingUnpersisted.contains(key)) {
        _ackedWhileUnpersisted.add(key);
        return;
      }
      if (await _collectGroupSliceAck(peerHex, frameId)) return;
    }
    if (_sendingUnpersisted.contains(key)) {
      // The row is still being written. Remember the ACK so the sender retires
      // it the moment it exists — otherwise this call deletes nothing and the
      // frame is left pending forever.
      _ackedWhileUnpersisted.add(key);
    }
    _fastCallRetryTimers.remove(frameId)?.cancel();
    _owner._mailboxDelivery.removeStashed(frameId);
    _liveBackoff.remove(_key(peerHex, frameId));
    if (_pendingKeys.remove(key)) {
      final left = (_pendingByPeer[peerHex] ?? 0) - 1;
      if (left > 0) {
        _pendingByPeer[peerHex] = left;
      } else {
        _pendingByPeer.remove(peerHex);
      }
    }
    try {
      await _owner._storage.ackOutboxFrame(frameId, fromPeerHex: peerHex);
    } finally {
      _flushSnapshot?.invalidate(key);
    }
  }

  void dispose() {
    _groupSliceAcks.clear();
    _flushSnapshot?.cancel();
    _activeLivePeers.clear();
    for (final timer in _fastCallRetryTimers.values) {
      timer.cancel();
    }
    _fastCallRetryTimers.clear();
  }
}
