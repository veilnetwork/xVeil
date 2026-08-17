part of 'messaging_core.dart';

/// Offline mailbox fallback and its CPU/network admission controls.
///
/// A live send remains the latency path. This subsystem owns recipient lookup,
/// ML-KEM sealing and relay fanout for the durable fallback, including all
/// session deduplication and backoff needed to keep unreachable peers from
/// waking worker isolates every retry tick.
class _MessagingMailboxDelivery {
  _MessagingMailboxDelivery();

  MailboxSink? _mailbox;
  final Set<String> _stashed = {};
  final Set<String> _inFlight = {};
  final Map<String, DateTime> _failedAt = {};
  final Map<String, ({int count, DateTime nextAt})> _peerUnresolvedBackoff = {};
  final Map<String, DateTime> _lastSuppressionLog = {};

  bool _paused = false;

  static const _maxBackgroundStashes = 1;
  static const _retryBackoff = Duration(seconds: 30);

  /// Hard deadline on one deposit attempt. The background slot is GLOBAL and
  /// there is exactly one, so a stash that never completes does not lose one
  /// message — it freezes every mailbox deposit to every peer until the app
  /// restarts, and the log shows only an endless "another deposit is in
  /// flight". Measured live 2026-08-16: a large deposit the relay silently
  /// dropped held the slot for 10+ minutes while 70+ frames per sibling sat
  /// durable and unmoving. Generous because a seal alone can take ~12s and a
  /// cold KEM resolve ~8s; the relay dedups by contentId, so a deposit that
  /// completes after we stopped waiting is harmless.
  /// An instance field, not a const, for the same reason as [ackGrace]: the
  /// test that proves the slot cannot wedge must not sit out 45 real seconds.
  Duration stashDeadline = const Duration(seconds: 45);
  static const _peerUnresolvedCap = Duration(minutes: 30);
  static const _suppressionLogEvery = Duration(minutes: 1);

  /// What the recipient has confirmed storing — see [MailboxDepositGate].
  final _gate = MailboxDepositGate();

  /// How long a user send waits for that confirmation before paying for a
  /// relay copy. Zero deposits at once.
  ///
  /// Off by default and switched on where the app wires the service up. The
  /// wait changes the TIMING of the main send path, and a suite that asserts
  /// deposits would otherwise be asserting this timer instead — every such test
  /// sitting out a window for a confirmation no fake peer was ever going to
  /// send. The decision it guards is tested on its own; see
  /// `mailbox_deposit_gate.dart`.
  Duration ackGrace = Duration.zero;

  void noteAcknowledged(String id) => _gate.noteAcknowledged(id);

  bool acknowledged(String id) => _gate.acknowledged(id);

  bool get paused => _paused;

  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    _mailbox?.backgroundDrainPaused = value;
  }

  void attach(MailboxSink mailbox) {
    _mailbox = mailbox;
    mailbox.backgroundDrainPaused = _paused;
  }

  void nudgeDrain() => _mailbox?.nudgeDrain();

  void noteActivity() => _mailbox?.noteActivity();

  void removeStashed(String id) => _stashed.remove(id);

  void clearPeerBackoff(String peerHex) {
    _peerUnresolvedBackoff.remove(peerHex);
    _lastSuppressionLog.remove(peerHex);
  }

  /// Live proof the peer is online: an AUTHENTICATED delivery from it.
  ///
  /// The backoff below had exactly two ways out — a deposit that SUCCEEDS, and
  /// the chat being deleted — and the first cannot happen while the backoff is
  /// running. So the ladder only ever climbed, and a peer that went away for a
  /// moment and came straight back stayed penalised for up to
  /// [_peerUnresolvedCap]. A phone that dozes for a minute is the ordinary case,
  /// not an edge one, and on the stand it turned a one-minute nap into half an
  /// hour of silence in the direction of a peer that was demonstrably back
  /// (2026-08-06).
  ///
  /// Hearing FROM the peer is the recovery signal the loop never had. It must be
  /// AUTHENTICATED: `src` on an unauthenticated delivery is a name the sender
  /// wrote (see `_speaksForContact`), so accepting it here would let anyone
  /// clear anyone's backoff on demand and aim the retry loop at an unresolvable
  /// peer — the exact hammering the backoff exists to stop.
  void notePeerReachable(String peerHex) {
    if (_peerUnresolvedBackoff.remove(peerHex) == null) return;
    _lastSuppressionLog.remove(peerHex);
    devLog(
      () =>
          'xVeil[send]: backoff CLEARED dst=${_short(peerHex)} — an '
          'authenticated delivery arrived, so the peer is reachable now',
    );
  }

  /// Whether a deposit for [peerHex] is suppressed by the unresolved-peer
  /// backoff — and the one place that says so out loud.
  ///
  /// The predicate and the log line are deliberately the SAME call. They used to
  /// be separate: three call sites took this decision and not one of them
  /// reported it, so a node sitting on a running backoff looked from the outside
  /// exactly like a node doing nothing — no deposit, no error, no line, for up
  /// to [_peerUnresolvedCap]. That silence, not the backoff itself, was the
  /// expensive half of diagnosing the 2026-08-06 outage. Keeping the two joined
  /// means a future call site cannot acquire the behaviour without the evidence.
  bool suppressedByBackoff(String peerHex, DateTime now, String where) {
    final backoff = _peerUnresolvedBackoff[peerHex];
    if (backoff == null || !now.isBefore(backoff.nextAt)) return false;
    // One line per peer per window rather than one per pass: the flush loop asks
    // about every conversation every few seconds, and a line each would bury the
    // log this exists to make readable.
    final last = _lastSuppressionLog[peerHex];
    if (last == null || now.difference(last) >= _suppressionLogEvery) {
      _lastSuppressionLog[peerHex] = now;
      devLog(
        () =>
            'xVeil[send]: deposit SUPPRESSED dst=${_short(peerHex)} at $where — '
            'unresolved-peer backoff, ${backoff.nextAt.difference(now).inSeconds}s '
            'left (attempt ${backoff.count}). Clears on a deposit that succeeds '
            'or on an authenticated delivery from the peer',
      );
    }
    return true;
  }

  static String _short(String peerHex) =>
      peerHex.length >= 8 ? peerHex.substring(0, 8) : peerHex;

  /// Whether [id] is call lifecycle control — an offer, answer or cancel whose
  /// only value is inside the ring window.
  ///
  /// This lives here, next to the admission gate that has to know it, rather
  /// than only at the flush loop that used to ask. See [stashInBackground].
  static bool isCallSignalId(String id) =>
      id.startsWith('call:') || id.startsWith('gcall:');

  /// Admit at most one background seal/fanout. Skipped ids stay durable and
  /// are reconsidered on the next flush, avoiding CPU bursts during calls.
  ///
  /// CALL CONTROL IS EXEMPT, and that is the whole point of this method rather
  /// than an inline check. A call sets [paused] for its entire life
  /// (`CallService`: paused = status != ended), so while a call is dialing every
  /// deposit is suppressed — including the deposit of that call's own offer.
  /// The flush loop already carved call signals out of the pause and then
  /// handed them straight to this method, which re-checked `_paused` and
  /// dropped them anyway: the exemption was two lines away from the decision.
  ///
  /// Measured on the stand, 2026-08-07, with the live path broken by a node
  /// reboot: nine live re-drives over 75s, not one deposit, `ring timeout`, and
  /// the offer finally deposited 170ms AFTER the call had given up — so the
  /// callee rang for a call that no longer existed. A plain text message on the
  /// same broken path arrived in 15s, because nothing had paused its deposit.
  ///
  /// The capacity gate is waived too: call control is a handful of small frames
  /// bounded by the number of live calls, and being dropped is worse for it
  /// than being queued behind a bulk seal.
  void stashInBackground(
    NodeId peer,
    String id,
    Uint8List wire, {
    // True only where a live leg has just gone out and an ack may still be
    // coming. The outbox flush passes false: it deposits BECAUSE the live leg
    // failed, so there is nothing to wait for and waiting would only delay the
    // one copy the recipient is going to get.
    bool awaitAck = false,
  }) {
    if (isCallSignalId(id)) {
      unawaited(maybeStash(peer, id, wire));
      return;
    }
    if (_paused || _inFlight.length >= _maxBackgroundStashes) {
      devLog(
        () =>
            'xVeil[send]: stash DEFERRED dst=${peer.short} id=$id — '
            '${_paused ? "a call has paused background deposits" : "another "
                      "deposit is in flight"}; the outbox flush reconsiders it',
      );
      return;
    }
    unawaited(maybeStash(peer, id, wire, awaitAck: awaitAck));
  }

  Future<void> maybeStash(
    NodeId peer,
    String id,
    Uint8List wire, {
    bool awaitAck = false,
  }) async {
    // The backoff belongs HERE, at the one place a deposit is attempted, not
    // at each call site. It was checked in the outbox flush loop only, so
    // every other route — a user send finishes with its own background stash,
    // and so do contact and content frames — walked straight past it and kept
    // hammering the mailbox of a peer we had just failed to resolve. The frame
    // stays durable regardless: the flush loop deposits it once the backoff
    // expires.
    if (suppressedByBackoff(peer.hex, DateTime.now(), 'maybeStash')) return;
    // Deposit only what nobody has confirmed. A live send that reached ANY
    // device of the recipient ends with that device acking after it stored the
    // message, and the recipient's devices mirror it among themselves — so a
    // relay copy would be a second delivery of something already safe.
    //
    // Call control is exempt: its whole value is inside the ring window, and
    // waiting out the grace period is the one thing it cannot afford.
    if (awaitAck && !isCallSignalId(id)) {
      if (!shouldDeposit(
        id: id,
        acknowledged: acknowledged(id),
        isCallSignal: false,
      )) {
        devLog(
          () =>
              'xVeil[send]: stash SKIP dst=${peer.short} id=$id — already '
              'acknowledged (stored by the recipient)',
        );
        return;
      }
      if (ackGrace > Duration.zero) {
        await Future<void>.delayed(ackGrace);
        if (!shouldDeposit(
          id: id,
          acknowledged: acknowledged(id),
          isCallSignal: false,
        )) {
          devLog(
            () =>
                'xVeil[send]: stash SKIP dst=${peer.short} id=$id — '
                'acknowledged within ${ackGrace.inSeconds}s',
          );
          return;
        }
      }
    }
    final mailbox = _mailbox;
    if (mailbox == null) {
      devLog(
        () =>
            'xVeil[send]: stash SKIP dst=${peer.short} id=$id '
            '— NO mailbox (transport not VeilFlutter or no relays)',
      );
      return;
    }
    if (_stashed.contains(id)) {
      devLog(
        () =>
            'xVeil[send]: stash SKIP dst=${peer.short} id=$id — already stashed',
      );
      return;
    }
    // A failed seal can block a worker for ~12s. Never respawn it on every 3s
    // flush; the durable entry remains pending and retries after this window.
    final failedAt = _failedAt[id];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _retryBackoff) {
      return;
    }
    // Initial send and periodic flush can race for the same stable id.
    if (!_inFlight.add(id)) return;
    try {
      try {
        await mailbox
            .stash(
              recipient: peer,
              payload: wire,
              contentId: _contentIdFor(id),
            )
            .timeout(stashDeadline);
        _stashed.add(id);
        _failedAt.remove(id);
        clearPeerBackoff(peer.hex);
        devLog(
          () =>
              'xVeil[send]: stash OK dst=${peer.short} id=$id '
              '(deposited at recipient relay)',
        );
      } catch (error, stackTrace) {
        _failedAt[id] = DateTime.now();
        // Both spellings of the same dead end: the native path says
        // `PeerUnresolved`, the Dart path throws [MailboxPeerUnresolved]. Only
        // the first was recognised, so a peer that had simply not advertised a
        // mailbox — an asleep phone, most often — never earned a backoff and
        // was retried at the caller's cadence indefinitely.
        if (error is MailboxPeerUnresolved ||
            error.toString().contains('PeerUnresolved')) {
          final previous = _peerUnresolvedBackoff[peer.hex];
          final count = (previous?.count ?? 0) + 1;
          final seconds = (30 * (1 << (count - 1))).clamp(
            30,
            _peerUnresolvedCap.inSeconds,
          );
          _peerUnresolvedBackoff[peer.hex] = (
            count: count,
            nextAt: DateTime.now().add(Duration(seconds: seconds)),
          );
        }
        devLog(
          () =>
              'xVeil[send]: stash FAILED dst=${peer.short} id=$id '
              '(backoff ${_peerUnresolvedBackoff[peer.hex]?.nextAt.difference(DateTime.now()).inSeconds ?? _retryBackoff.inSeconds}s, '
              'attempt ${_peerUnresolvedBackoff[peer.hex]?.count ?? 0}): '
              '$error\n$stackTrace',
        );
      }
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Stable relay-side dedup/eviction key, distinct from the wire message id.
  static Uint8List _contentIdFor(String id) =>
      blake3DeriveKey('veil.mailbox.content_id.v1', utf8.encode(id));
}
