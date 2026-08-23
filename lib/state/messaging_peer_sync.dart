part of 'messaging_core.dart';

/// Bounded 1:1 event-log reconciliation over authenticated peer sessions.
///
/// Sync beacons advertise per-author high-water marks and holes. The peer then
/// re-ships missing events, while throttles and bounded batches prevent an
/// absent or hostile peer from creating background traffic or amplification.
const _kSendInterval = Duration(seconds: 20);
const _kBackoffCap = Duration(minutes: 10);

/// The cadence a beacon to this peer gets.
///
/// Two independent reasons to ask less often, and the longer streak wins
/// because neither cancels the other:
///
/// * `unanswered` — nobody is there. Any inbound frame settles it.
/// * `quiet` — there is nothing to reconcile. Only a CHANGE settles it.
///
/// The second was missing, and its absence was the whole cost: a peer that
/// answers an empty beacon with an equally empty beacon resets `unanswered`,
/// so two idle conversations sat at one beacon every 20 s each way, for as
/// long as both stayed online. Measured from the constants: 0.1 frames/s per
/// idle contact, against a whole-node floor of ~2.4 frames/s — six such
/// contacts would have been a quarter of everything the node sends.
///
/// Pure so the schedule can be checked without a clock.
Duration beaconInterval({required int unanswered, required int quiet}) {
  final escalation = unanswered > quiet ? unanswered : quiet;
  final capped = escalation > 5 ? 5 : escalation;
  final interval = _kSendInterval * (1 << capped);
  return interval > _kBackoffCap ? _kBackoffCap : interval;
}

/// What a beacon SAYS, as a comparable string.
///
/// Deliberately excludes the `ep` timestamp the wire body carries: it moves
/// every tick and is not news, so comparing whole bodies would make every
/// beacon look new and the quiet streak could never start.
///
/// Pure so "did anything change" is testable without a conversation.
String beaconStatement({
  required Map<String, int> highWater,
  required Map<String, List<List<int>>> holes,
  required String selfHex,
  required int ownFloor,
}) => jsonEncode({
  'hw': highWater,
  if (holes.isNotEmpty) 'holes': holes,
  if (ownFloor > 0) 'fl': {selfHex: ownFloor},
});

class _MessagingPeerSync {
  _MessagingPeerSync(this._owner);

  final MessagingService _owner;

  final Map<String, DateTime> _lastSentAt = {};
  final Map<String, DateTime> _lastActedAt = {};
  final Map<String, int> _unanswered = {};

  /// What the last beacon to this peer actually SAID — high-water, holes and
  /// floor, with the timestamp left out because it moves every tick and is not
  /// news. Keyed by peer.
  final Map<String, String> _lastStated = {};

  /// Consecutive beacons that would have restated [_lastStated] verbatim.
  ///
  /// Separate from [_unanswered] because they answer different questions. That
  /// one asks "is anyone there", and any inbound frame settles it. This one
  /// asks "is there anything to reconcile", and only a CHANGE settles it — a
  /// peer answering an empty beacon with an equally empty beacon is not
  /// evidence that reconciliation is needed, and treating it as such is what
  /// pinned two idle conversations at one beacon every 20 s forever.
  final Map<String, int> _quiet = {};

  static const _actInterval = Duration(seconds: 5);
  static const _reshipCap = 100;

  /// How many beacons may name the SAME unmoved hole before we stop waiting
  /// for it.
  ///
  /// A high-water is a claim of CONTIGUITY, so one sequence nobody can supply
  /// pins it forever — and the peer, reading that pinned mark, re-ships the
  /// entire tail above it on every round. Measured on a live pair: 316 frames
  /// and 1.4 MB per round, between two idle devices, indefinitely.
  ///
  /// The give-up is taken HERE, by the side that is waiting, and never by the
  /// sender. The sender cannot tell "I lost it" from "I deleted it for myself
  /// only", and a sender-side rule would turn the second into a delete for
  /// everyone. Waiting is our own business; we are the only ones who can count
  /// how long we have waited.
  static const _holeGiveUpRounds = 6;

  /// …or this long, whichever comes first.
  ///
  /// Counting ROUNDS alone tied the give-up to how often we beacon, and that
  /// made the beacon cadence unchangeable: any throttle stretched the wait for
  /// a hole nobody can fill, so the re-shipping storm those rounds exist to
  /// stop came back. Waiting is measured in time, not in how often we happen to
  /// ask, and a wall-clock rule lets the cadence be chosen for what it costs.
  ///
  /// Two minutes is what six rounds at the base interval already meant, so a
  /// peer answering normally sees no change.
  static const _holeGiveUpAfter = Duration(minutes: 2);

  /// Per (peer, author): the hole's signature, how many beacons have named it
  /// unmoved, and when we first saw it.
  final Map<String, (String, int, DateTime)> _holeStreak = {};

  /// Let a reconnect beacon immediately and bound session-scoped throttle maps
  /// — except for peers that have stopped answering.
  ///
  /// Clearing their timestamp too made the escalation in [_send] unreachable:
  /// the interval is consulted only when a last-sent time EXISTS, so every
  /// reconnect beaconed the whole contact list at once no matter how long a
  /// peer had been silent. Reconnects land about once a minute on an idle node
  /// and each beacon is a sealed send that persists ~1 KB of ratchet state,
  /// permanently, because the container never reuses a slot.
  ///
  /// Measured on the stand: 46 beacons in five idle minutes to nine contacts,
  /// ten times what their own backoff had earned — about 1.4 MB per contact
  /// per day, LINEAR in the roster. At a thousand contacts that is 1.4 GB a
  /// day of garbage, and ten thousand sealed sends per reconnect is a CPU and
  /// network storm besides. The cost has to follow the peers being reconciled,
  /// not the size of the address book.
  ///
  /// A reconnect says WE came back. It says nothing about a peer that was
  /// already not answering, and beaconing it sooner does not make it likelier
  /// to reply — its own escalation (20 s → 10 min) is the right cadence and
  /// this is what lets it run.
  void resetSession() {
    _lastSentAt.removeWhere(
      (peerHex, _) => (_unanswered[peerHex] ?? 0) < _reconnectStreakLimit,
    );
    _lastActedAt.clear();
  }

  /// Unanswered beacons after which a reconnect alone stops being a reason to
  /// beacon immediately.
  ///
  /// Not zero: the streak counts SENDS and any authenticated inbound clears it,
  /// so a peer that is answering normally sits at one or two between rounds,
  /// and those are exactly the peers a reconnect should catch up with.
  static const _reconnectStreakLimit = 3;

  /// Any authenticated inbound proves that the peer is answering again.
  void noteInbound(NodeId peer) => _unanswered.remove(peer.hex);

  /// Are we still waiting on a hole from this peer?
  bool _awaitingHoleFrom(String peerHex) =>
      _holeStreak.keys.any((k) => k.startsWith('$peerHex|'));

  /// Send a gap-fill beacon over the live path. Offline peers beacon when they
  /// return, so this intentionally does not create a mailbox deposit.
  Future<void> _send(NodeId peer, {bool force = false}) async {
    final now = DateTime.now();
    final last = _lastSentAt[peer.hex];
    // Escalate for peers that never answer: 20s → … → 10m — and, separately,
    // for conversations where there is nothing to reconcile. Whichever streak
    // is longer sets the cadence, because either one alone is a reason to ask
    // less often and neither cancels the other.
    final streak = _unanswered[peer.hex] ?? 0;
    final quiet = _quiet[peer.hex] ?? 0;
    final interval = beaconInterval(unanswered: streak, quiet: quiet);
    final throttled = !force && last != null && now.difference(last) < interval;
    // A throttled peer we are WAITING ON still has its stuck hole judged: the
    // give-up used to be a side effect of sending, so any cadence change
    // stretched it and brought back the re-shipping storm it exists to stop.
    // Judging costs the reads below; sending costs a sealed frame and ~1 KB of
    // permanent ratchet state, and it is the second one that scales with the
    // roster. For a throttled peer with nothing outstanding, neither happens.
    if (throttled && !_awaitingHoleFrom(peer.hex)) return;
    if (!throttled) {
      _lastSentAt[peer.hex] = now;
      _unanswered[peer.hex] = streak + 1;
    }

    // Declare the prefix of our stream that no longer exists at the source.
    // Persisting it locally first keeps our own high-water and holes honest.
    final selfHex = await _owner._selfHex();
    final ownFloor = await _owner._storage.ownSyncFloor(peer.hex, selfHex);
    if (ownFloor > 0) {
      await _owner._storage.applyAuthorSyncFloor(peer.hex, selfHex, ownFloor);
    }
    var sync = await _owner._storage.conversationSync(peer.hex);
    if (await _giveUpOnStuckHoles(peer, selfHex, sync)) {
      // The floor changed our own high-water; re-read so the beacon states
      // what we now actually hold rather than what we held a moment ago.
      sync = await _owner._storage.conversationSync(peer.hex);
    }
    final holes = <String, List<List<int>>>{
      for (final e in sync.holes.entries)
        e.key: [
          for (final h in e.value) [h.$1, h.$2],
        ],
    };
    // What this beacon SAYS, without the timestamp. `ep` moves every tick and
    // is not news; comparing the whole body would make every beacon look new.
    final stated = beaconStatement(
      highWater: sync.highWater,
      holes: holes,
      selfHex: selfHex,
      ownFloor: ownFloor,
    );
    final body = jsonEncode({
      'hw': sync.highWater,
      if (holes.isNotEmpty) 'holes': holes,
      if (ownFloor > 0) 'fl': {selfHex: ownFloor},
      'ep': now.millisecondsSinceEpoch,
    });
    if (throttled) return; // judged above; the wire frame is what we skip
    // Count the quiet round only on a round that actually SENDS: a throttled
    // pass emits nothing, so letting it escalate would back the cadence off
    // for beacons that were never on the wire.
    if (_awaitingHoleFrom(peer.hex)) {
      // A hole IS something to reconcile. However unchanged the beacon looks,
      // this conversation is not quiet, and asking less often is the last
      // thing it needs.
      _quiet.remove(peer.hex);
      _lastStated[peer.hex] = stated;
    } else if (stated == _lastStated[peer.hex]) {
      _quiet[peer.hex] = quiet + 1;
    } else {
      _lastStated[peer.hex] = stated;
      _quiet.remove(peer.hex);
    }
    devLog(
      () =>
          'xVeil[sync]: -> ${peer.short} hw=${sync.highWater} '
          'holes=${holes.length}',
    );
    await _owner._send(peer, WireEnvelope.sync(body).encode());
  }

  /// Stop waiting for a hole that has not moved for [_holeGiveUpRounds]
  /// beacons, by flooring past it. Returns whether anything changed.
  ///
  /// One hole per pass, the LOWEST: a floor is a prefix, so flooring at the
  /// first hole's end covers exactly that gap and leaves every later one still
  /// requested.
  ///
  /// Never applied to our OWN stream. A gap there is not a delivery problem —
  /// we authored those sequences — so it means our own store lost something,
  /// and flooring would have us claim a contiguity we cannot back. That guard
  /// is NOT covered by a test: producing a hole in one's own stream needs a
  /// partial store loss, which no public API can bring about (verified by
  /// breaking it — removing the guard fails nothing).
  Future<bool> _giveUpOnStuckHoles(
    NodeId peer,
    String selfHex,
    ({Map<String, int> highWater, Map<String, List<(int, int)>> holes}) sync,
  ) async {
    var changed = false;
    for (final entry in sync.holes.entries) {
      final author = entry.key;
      if (author == selfHex || entry.value.isEmpty) continue;
      final first = entry.value.reduce((a, b) => a.$1 <= b.$1 ? a : b);
      final key = '${peer.hex}|$author';
      final signature = '${first.$1}-${first.$2}';
      final previous = _holeStreak[key];
      final unmoved = previous != null && previous.$1 == signature;
      final rounds = unmoved ? previous.$2 + 1 : 1;
      final firstSeenAt = unmoved ? previous.$3 : DateTime.now();
      final waited = DateTime.now().difference(firstSeenAt);
      if (rounds < _holeGiveUpRounds && waited < _holeGiveUpAfter) {
        _holeStreak[key] = (signature, rounds, firstSeenAt);
        continue;
      }
      _holeStreak.remove(key);
      devLog(
        () =>
            'xVeil[sync]: giving up on hole ${first.$1}-${first.$2} of '
            '${author.substring(0, 8)} after $rounds beacons / '
            '${waited.inSeconds}s — flooring past it',
      );
      await _owner._storage.applyAuthorSyncFloor(peer.hex, author, first.$2);
      changed = true;
    }
    // Forget counters for authors whose holes are gone, so a NEW hole later
    // starts its own count instead of inheriting an old one.
    _holeStreak.removeWhere(
      (key, _) =>
          key.startsWith('${peer.hex}|') &&
          !sync.holes.containsKey(key.split('|')[1]),
    );
    return changed;
  }

  void sendBestEffort(NodeId peer, {bool force = false}) {
    unawaited(
      _send(peer, force: force).catchError((_) {
        // Advisory reconciliation must not abort another in-flight operation.
      }),
    );
  }

  /// Re-ship events authored by us above the peer's bounded, clamped high-water.
  Future<void> handle(NodeId peer, String body) async {
    final now = DateTime.now();
    final lastActed = _lastActedAt[peer.hex];
    if (lastActed != null && now.difference(lastActed) < _actInterval) {
      sendBestEffort(peer);
      return;
    }
    _lastActedAt[peer.hex] = now;

    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final highWater = json['hw'];
    if (highWater is! Map) return;
    final selfHex = await _owner._selfHex();

    // A peer may void only a prefix of its own authenticated author stream.
    // The prefix takes the same bound as any other sequence off the wire: a
    // floor is monotonic and permanent, so one absurd number would retire
    // gap-fill for that author in this conversation for good — the peer's
    // later messages would all sit below a floor claiming they no longer exist
    // at the source, and nothing could ever be re-requested again.
    final floors = json['fl'];
    if (floors is Map) {
      final declared = floors[peer.hex];
      if (declared is int && declared > 0 && isAcceptableWireSeq(declared)) {
        await _owner._storage.applyAuthorSyncFloor(
          peer.hex,
          peer.hex,
          declared,
        );
      }
    }

    final claimed = highWater[selfHex];
    var peerHighWater = claimed is int && claimed >= 0 ? claimed : 0;
    // Anti-forgery: a peer cannot acknowledge a sequence we never emitted.
    final ours = await _owner._storage.conversationSync(peer.hex);
    final ourMax = ours.highWater[selfHex] ?? 0;
    if (peerHighWater > ourMax) peerHighWater = ourMax;

    final events = await _owner._storage.loadEventsSince(
      peer.hex,
      selfHex,
      peerHighWater,
      limit: _reshipCap,
    );
    if (events.isNotEmpty) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} peerHw(me)=$peerHighWater '
            'reship=${events.length}',
      );
      final byId = {
        for (final message in await _owner._storage.loadMessages(peer.hex))
          message.id: message,
      };
      for (final event in events) {
        switch (event.kind) {
          case EventKind.post:
          case EventKind.filePost:
            final stored = byId[event.id];
            final isFile =
                event.kind == EventKind.filePost || (stored?.isFile ?? false);
            if (isFile) {
              if (stored == null) continue;
              final contentId = stored.fileContentId ?? stored.fileId;
              final served = contentId == null
                  ? null
                  : _owner._serving[contentId];
              if (served != null) {
                final manifest = served.manifest.withEvent(
                  msgId: event.id,
                  author: selfHex,
                  seq: event.seq,
                  ts: event.ts,
                );
                await _owner._sendContentManifest(peer, manifest);
                continue;
              }
              // Legacy transfers heal by querying only the missing chunks.
              if (stored.fileId == null) continue;
              await _owner._send(
                peer,
                fileQueryEnvelope(
                  transferId: event.id,
                  name: stored.fileName,
                  seq: event.seq,
                  sentAtMs: event.ts,
                ).encode(),
              );
              continue;
            }
            final recommendation = parseSpaceRecommendationMessage(
              event.body ?? '',
            );
            await _owner._send(
              peer,
              (recommendation == null
                      ? WireEnvelope.message(
                          event.body ?? '',
                          id: event.id,
                          sentAtMs: event.ts,
                          seq: event.seq,
                          replyTo: event.replyTo,
                          forwardedFrom: event.forwardedFrom,
                          customEmoji: stored?.customEmoji ?? const [],
                        )
                      : WireEnvelope.spaceRecommendation(
                          recommendation,
                          id: event.id,
                          sentAtMs: event.ts,
                          seq: event.seq,
                        ))
                  .encode(),
            );
          case EventKind.edit:
            if (event.target == null) continue;
            await _owner._send(
              peer,
              WireEnvelope.edit(
                event.target!,
                event.body ?? '',
                seq: event.seq,
                customEmoji: event.customEmoji,
              ).encode(),
            );
          case EventKind.void_:
            await _owner._send(peer, WireEnvelope.voidSeq(event.seq).encode());
          case EventKind.delete:
          case EventKind.clear:
            continue;
        }
      }
    }
    sendBestEffort(peer);
  }
}
