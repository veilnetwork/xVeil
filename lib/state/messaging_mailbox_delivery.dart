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
  static const _peerUnresolvedCap = Duration(minutes: 30);
  static const _suppressionLogEvery = Duration(minutes: 1);

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

  /// Admit at most one background seal/fanout. Skipped ids stay durable and
  /// are reconsidered on the next flush, avoiding CPU bursts during calls.
  void stashInBackground(NodeId peer, String id, Uint8List wire) {
    if (_paused || _inFlight.length >= _maxBackgroundStashes) return;
    unawaited(maybeStash(peer, id, wire));
  }

  Future<void> maybeStash(NodeId peer, String id, Uint8List wire) async {
    // The backoff belongs HERE, at the one place a deposit is attempted, not
    // at each call site. It was checked in the outbox flush loop only, so
    // every other route — a user send finishes with its own background stash,
    // and so do contact and content frames — walked straight past it and kept
    // hammering the mailbox of a peer we had just failed to resolve. The frame
    // stays durable regardless: the flush loop deposits it once the backoff
    // expires.
    if (suppressedByBackoff(peer.hex, DateTime.now(), 'maybeStash')) return;
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
        await mailbox.stash(
          recipient: peer,
          payload: wire,
          contentId: _contentIdFor(id),
        );
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
