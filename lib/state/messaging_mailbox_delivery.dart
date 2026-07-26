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

  bool _paused = false;

  static const _maxBackgroundStashes = 1;
  static const _retryBackoff = Duration(seconds: 30);
  static const _peerUnresolvedCap = Duration(minutes: 30);

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

  void clearPeerBackoff(String peerHex) =>
      _peerUnresolvedBackoff.remove(peerHex);

  bool peerBackedOff(String peerHex, DateTime now) {
    final backoff = _peerUnresolvedBackoff[peerHex];
    return backoff != null && now.isBefore(backoff.nextAt);
  }

  /// Admit at most one background seal/fanout. Skipped ids stay durable and
  /// are reconsidered on the next flush, avoiding CPU bursts during calls.
  void stashInBackground(NodeId peer, String id, Uint8List wire) {
    if (_paused || _inFlight.length >= _maxBackgroundStashes) return;
    unawaited(maybeStash(peer, id, wire));
  }

  Future<void> maybeStash(NodeId peer, String id, Uint8List wire) async {
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
        if (error.toString().contains('PeerUnresolved')) {
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
