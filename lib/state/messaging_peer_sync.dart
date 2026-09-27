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

/// The floor map a beacon carries, under every name the peer may know us by.
///
/// It declares OUR OWN stream — the prefix that no longer exists here, so the
/// peer stops asking for it — and the peer looks it up under the only address
/// it has for us, the IDENTITY. We label our rows with the DEVICE we run on,
/// and for a sovereign identity with more than one device those are different
/// strings, so the declaration was never found: the peer went on re-requesting
/// sequences we had told it were gone, and healed only by the give-up path
/// several rounds later.
///
/// Unlike the high-water half of the same mismatch, this one is fixable at the
/// SENDER, because the key names US and we know both of our own names. Sending
/// both also means a peer on an older build starts finding it with no change
/// of its own.
///
/// Pure, so the shape is testable without a conversation that has lost data —
/// a floor only exists after real loss at the source, and a clear does not
/// make one (tombstones keep their seq slot).
Map<String, int> floorDeclaration({
  required String selfHex,
  required String? identityHex,
  required int ownFloor,
}) {
  if (ownFloor <= 0) return const {};
  return {
    selfHex: ownFloor,
    if (identityHex != null && identityHex != selfHex) identityHex: ownFloor,
  };
}

/// How many of my latest sent messages a beacon names when another device of
/// mine may have written in the same chat.
const kOwnEchoWindow = 100;

/// The most of my own messages one answer hands back.
const kOwnEchoCap = 50;

/// The short name a message id travels under in an echo ask.
///
/// Hashed, not truncated: ids are not all random (a file id is the content
/// id's prefix, a test writes `m1`), and a truncated one could collide with a
/// neighbour for good.
String ownEchoKey(String messageId) => crypto.sha256
    .convert(utf8.encode(messageId))
    .toString()
    .substring(0, 8);

/// Which of MY messages the counterpart holds and the asking device of mine
/// does not.
///
/// THE COUNTERPART IS THE ONLY OTHER HOLDER. Each device of an identity numbers
/// its own stream, and the counterpart files them all under one author, so the
/// seq gap-fill cannot say what a device of mine missed from its sibling — and
/// the sibling itself may be gone for good (measured on the stand: nine
/// messages a device wrote before it died, held by the counterpart, never seen
/// by its sibling).
///
/// [held] is the asker's keys for its newest [kOwnEchoWindow] sent messages
/// BY TIME, and [sinceMs] the time of the oldest of them. Only what the
/// counterpart holds from AFTER that moment is a candidate: anything older is
/// outside the asker's window whether it holds it or not, and handing it back
/// would resurrect a history the device dropped. By time, not by position:
/// neither side's log is in time order (a gap-filled row lands where it
/// arrives), and a positional anchor handed back 50 messages the asker already
/// held — measured on the stand, 50 of 53 — while the cap cut off the three it
/// was missing.
///
/// The NEWEST [cap] of them, for the same reason: what a device just missed is
/// what the person is looking for.
///
/// [untilMs], when given, closes the window from above (exclusive): an OLDER
/// page of the asker's history, see [ownEchoPage].
///
/// Pure, so the selection is testable without two devices and a peer.
List<T> ownEchoesMissing<T>({
  required List<T> theirs,
  required String Function(T) keyOf,
  required int Function(T) tsOf,
  required Set<String> held,
  required int sinceMs,
  int? untilMs,
  int cap = kOwnEchoCap,
}) {
  if (held.isEmpty) return const [];
  final missing = [
    for (final m in theirs)
      if (tsOf(m) > sinceMs &&
          (untilMs == null || tsOf(m) < untilMs) &&
          !held.contains(keyOf(m)))
        m,
  ]..sort((a, b) => tsOf(a).compareTo(tsOf(b)));
  return missing.length > cap
      ? missing.sublist(missing.length - cap)
      : missing;
}

/// Which of MY messages the asking device holds with an OLDER text than the
/// counterpart's.
///
/// The echo above brings back what a device is missing, and nothing brought
/// back an EDIT it missed: the message is held, so it is "already held", and
/// the old text stays for good. Measured on the stand after a load run: six
/// messages edited on one device showed the edit on the sibling that made it
/// and on the counterpart, and the original on the other device of mine.
///
/// [heldEdits] is the asker's edit seq per key, for the messages it holds
/// edited; absent means it holds the original. An edit numbers past every
/// edit of its message already held (so the counterpart keeps the higher
/// seq), which makes a higher seq here the LATER text: one the asker made
/// itself and has not yet reached the counterpart is not overwritten.
///
/// Pure, so the selection is testable without two devices and a peer.
List<T> ownEchoesEdited<T>({
  required List<T> theirs,
  required String Function(T) keyOf,
  required int Function(T) tsOf,
  required int? Function(T) editSeqOf,
  required Set<String> held,
  required Map<String, int> heldEdits,
  required int sinceMs,
  int? untilMs,
  int cap = kOwnEchoCap,
}) {
  final stale = [
    for (final m in theirs)
      if (editSeqOf(m) case final seq?)
        if (tsOf(m) > sinceMs &&
            (untilMs == null || tsOf(m) < untilMs) &&
            held.contains(keyOf(m)) &&
            seq > (heldEdits[keyOf(m)] ?? -1))
          m,
  ]..sort((a, b) => tsOf(a).compareTo(tsOf(b)));
  return stale.length > cap ? stale.sublist(stale.length - cap) : stale;
}

/// Which page of my sent history the [round]-th ask names.
///
/// Page 0 is the newest [kOwnEchoWindow] messages and is what nearly every
/// ask carries: what a device just missed is what matters. Every 4th ask names
/// one OLDER page instead, walking them in turn, so a device eventually
/// reconciles its whole history with the counterpart — measured on the stand:
/// nine messages a device wrote before it died, four days older than its
/// sibling's newest hundred, never came back.
///
/// Pure, so the rotation is testable without a clock.
int ownEchoPage({required int round, required int pages}) {
  if (pages <= 1 || round % 4 != 0) return 0;
  return 1 + ((round ~/ 4) - 1) % (pages - 1);
}

/// A clear watermark re-spelled in the names THIS device uses.
///
/// A clear travels as a per-author seq watermark and as nothing else, so the
/// names in it decide everything. They are the SENDER's names, and the two
/// sides do not use the same ones: each labels its own rows with the device it
/// runs on (`transport.nodeId()`) and the other side's rows with the address it
/// knows that side by — the IDENTITY. For a pair where at least one side is a
/// sovereign identity with more than one device, every key in an arriving
/// watermark is a string this device has never used, the receiver's bounding
/// drops all of them, and a clear-for-everyone erases nothing at all.
///
/// Measured on the stand (2026-09-21) with a controlled experiment: the frame
/// arrives, is acked on first receipt, and 29 messages stay put.
///
/// The translation needs nothing this device does not already know:
///
///  * OUR half is whatever the sender filed under the name it knows us by —
///    our identity — falling back to our device name for a sender whose two
///    names are one string. It is re-filed under the name our own rows carry.
///  * THEIR half is the remaining key. A 1:1 watermark names two streams and
///    we have just accounted for one of them, so the other is theirs, whatever
///    it is called. It is re-filed under the name we give their rows.
///
/// FAIL CLOSED on ambiguity: more than one leftover key means the watermark
/// does not describe a pair, and no leftover key is an honest "nothing of
/// theirs". Either way their half is dropped rather than guessed at — a clear
/// is not reversible.
///
/// Pure, because the decision IS the whole of what can be wrong here.
Map<String, int> clearWatermarkInOurNames({
  required Map<String, int> watermark,
  required String theirLabel,
  required String ourLabel,
  required String? ourIdentity,
}) {
  final out = <String, int>{};
  final ourNames = {ourLabel, ?ourIdentity};
  final ours = watermark[ourIdentity] ?? watermark[ourLabel];
  if (ours != null) out[ourLabel] = ours;
  final leftover = [
    for (final e in watermark.entries)
      if (!ourNames.contains(e.key)) e,
  ];
  if (leftover.length == 1) out[theirLabel] = leftover.single.value;
  return out;
}

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

  /// When this device last named its own messages to the peer. An echo is
  /// taken only as the answer to such an ask, so a counterpart cannot write
  /// "my" messages into this chat unprompted.
  final Map<String, DateTime> _ownAskedAt = {};

  /// Message id -> an edit seq the counterpart handed back whose text this
  /// device already showed. Its own row keeps a different number (an edit
  /// mirrored before edits carried their seq was numbered here), and without
  /// this the counterpart would hand the same text back on every ask. In
  /// memory: after a restart it costs one more hand-back per message.
  final Map<String, int> _ownEditSettled = {};

  /// Asks made to each peer, for [ownEchoPage].
  final Map<String, int> _ownAskRounds = {};

  /// Echo answers already given, per peer: the ask and answer's signature, how
  /// many times, and when first. Every device of the identity asks under the same
  /// peer name, so several are kept, as for [_reshipRounds].
  final Map<String, Map<String, ({int rounds, DateTime at})>> _ownAnswered =
      {};
  static const _ownAskTtl = Duration(minutes: 15);
  static const _reshipCap = 100;

  /// Re-ship rounds at one unchanged peer high-water before we stop.
  ///
  /// A peer that asks from the same mark twice after we answered it did not
  /// absorb the answer, and asking a third time will not change that. The
  /// case that made it real: a device whose rows came from a mirror under
  /// locally allocated numbers holds those messages already, drops every
  /// re-shipped copy as a duplicate, and its mark never moves — measured on
  /// the stand as 99-100 messages re-shipped on every beacon. A genuinely
  /// missed message is new to the peer and lands in the first round.
  static const _reshipRoundsWithoutProgress = 2;

  /// How long re-shipping stays withheld from a mark that stopped moving.
  static const _reshipPause = Duration(minutes: 10);
  /// Per peer, per MARK: every device of an identity beacons under the same
  /// peer name, and a sibling that is up to date interleaves its own mark with
  /// the stuck one — tracked as one sequence, "the same mark twice in a row"
  /// never happened (measured: 118 and 27 alternating, 91 re-shipped each
  /// time the 27 came round).
  final Map<String, Map<int, ({int rounds, DateTime at})>> _reshipRounds = {};

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

  /// A hole given up on is asked for again this often…
  ///
  /// Giving up floors past it, and nothing asks for those seqs again: the
  /// peer re-ships from our high-water, which now sits above them. The only
  /// other route is a sibling's mirror, and under load that was lost too —
  /// measured on the stand, five of the counterpart's messages missing on one
  /// device for good, held by the counterpart and by the other device, with no
  /// hole left to name them. The owner's rule is that a device pulls what it
  /// missed from the counterpart.
  static const _gaveUpRetryEvery = Duration(hours: 1);

  /// …at most this many times (a day of hourly asks), since a source that
  /// erased them for itself only will never have them.
  static const _gaveUpMaxTries = 24;

  /// Ranges remembered per conversation; the oldest go first.
  static const _gaveUpMaxRanges = 16;

  /// Per (peer, author, lo): when this range was last asked for again.
  final Map<String, DateTime> _gaveUpTriedAt = {};

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
    final identityHex = await _owner.selfIdentityHex?.call();
    final declaredFloor = floorDeclaration(
      selfHex: selfHex,
      identityHex: identityHex,
      ownFloor: ownFloor,
    );
    if (throttled) return; // judged above; the wire frame is what we skip
    final ownAsk = await _ownEchoAsk(peer);
    final retry = await _givenUpDue(peer);
    final body = jsonEncode({
      // A range given up on, asked for again: this one beacon claims that
      // author only up to just below it, and the peer re-ships from there.
      'hw': retry == null
          ? sync.highWater
          : {...sync.highWater, retry.author: retry.from - 1},
      if (holes.isNotEmpty) 'holes': holes,
      if (declaredFloor.isNotEmpty) 'fl': declaredFloor,
      if (ownAsk != null) 'ow': ownAsk.keys,
      if (ownAsk != null) 'os': ownAsk.sinceMs,
      if (ownAsk?.untilMs != null) 'ou': ownAsk!.untilMs,
      if (ownAsk != null && ownAsk.edits.isNotEmpty) 'oe': ownAsk.edits,
      'ep': now.millisecondsSinceEpoch,
    });
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
  /// The floor written here is the SAME field an author uses to declare its
  /// own early history gone, and the two claims are not the same: this one
  /// says how long we waited, not what still exists at the source. Once
  /// written they are indistinguishable, and the seqs inside the gap are never
  /// requested again — the peer re-ships from our high-water, so nothing
  /// offers them either. They are not refused: the floor is read only by
  /// `conversationSync`, never on the store path, so a copy arriving by any
  /// route is still stored. See `Storage.applyAuthorSyncFloor`, which now
  /// names both writers.
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
      await _rememberGivenUp(peer, author, first.$1, first.$2);
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
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // One of my own messages handed back. Before the throttle: they come in a
    // burst, one frame each, and the throttle is for beacons.
    final echo = json['echo'];
    if (echo is Map) {
      await _applyOwnEcho(peer, echo);
      return;
    }

    // The service clock, like every other ladder here (and so a test can step
    // it); in the app it is the wall clock.
    final now = _owner._now();
    final lastActed = _lastActedAt[peer.hex];
    if (lastActed != null && now.difference(lastActed) < _actInterval) {
      sendBestEffort(peer);
      return;
    }
    _lastActedAt[peer.hex] = now;

    final highWater = json['hw'];
    if (highWater is! Map) return;
    final selfHex = await _owner._selfHex();

    final ownAsk = json['ow'], ownSince = json['os'], ownUntil = json['ou'];
    final ownEdits = json['oe'];
    if (ownAsk is List && ownSince is int) {
      await _answerOwnEchoAsk(
        peer,
        ownAsk,
        ownSince,
        ownUntil is int ? ownUntil : null,
        edits: {
          if (ownEdits is Map)
            for (final e in ownEdits.entries)
              if (e.key is String && e.value is int)
                e.key as String: e.value as int,
        },
      );
    }

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

    // WHAT THE PEER CALLS US, not what we call ourselves.
    //
    // Our own rows are labelled with `transport.nodeId()`; the peer labels the
    // same rows with the address it knows us by, which is the IDENTITY. For an
    // ordinary identity those are one string and this changes nothing. For a
    // sovereign identity with more than one device they differ, and the
    // lookup below missed every time — so the peer read as having acknowledged
    // NOTHING, and we re-shipped the whole conversation on every round.
    //
    // Measured on the stand (2026-09-21), once a minute, in both directions:
    //   xVeil[sync]: <- 636e6538 peerHw(me)=0 reship=13
    //
    // Fixed HERE rather than at the sender, because the sender cannot do it:
    // it labels the peer's stream by the peer's identity and does not know the
    // peer's device id to label it with instead. Only the receiver knows both
    // of its own names.
    final identityHex = await _owner.selfIdentityHex?.call();
    var claimed = highWater[selfHex];
    if (identityHex != null && identityHex != selfHex) {
      final byIdentity = highWater[identityHex];
      if (byIdentity is int && (claimed is! int || byIdentity > claimed)) {
        claimed = byIdentity;
      }
    }
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
    // EVERY beacon, not only the ones that re-ship.
    //
    // This line used to fire only when there was something to send, so a
    // healthy exchange and a silent one looked identical from outside — and
    // after fixing the re-ship loop the measurement could not tell "nothing
    // to re-ship" from "no beacon arrived". A `reship=0` is the evidence that
    // the round happened AND cost nothing.
    var withheld = false;
    if (events.isNotEmpty) {
      final at = _owner._now();
      final marks = _reshipRounds[peer.hex] ??= {};
      final prev = marks[peerHighWater];
      final fresh = prev == null || at.difference(prev.at) >= _reshipPause;
      if (!fresh && prev.rounds >= _reshipRoundsWithoutProgress) {
        withheld = true;
      } else {
        // A mark older than the pause starts over, so it is retried.
        marks[peerHighWater] = (rounds: fresh ? 1 : prev.rounds + 1, at: at);
        // Bounded: only the marks this peer actually sits at matter.
        if (marks.length > 8) marks.remove(marks.keys.first);
      }
    }
    devLog(
      () =>
          'xVeil[sync]: <- ${peer.short} peerHw(me)=$peerHighWater '
          'reship=${withheld ? 0 : events.length}'
          '${withheld ? ' (withheld: ${events.length} re-shipped twice from '
                    'this mark without it moving)' : ''}',
    );
    if (events.isNotEmpty && !withheld) {
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

  String _givenUpKey(NodeId peer) => 'syncgaveup:${peer.hex}';

  /// author -> [[lo, hi, tries], ...] for one conversation.
  Future<Map<String, List<List<int>>>> _loadGivenUp(NodeId peer) async {
    try {
      final raw = await _owner._storage.getSetting(_givenUpKey(peer));
      if (raw == null || raw.isEmpty) return {};
      final d = jsonDecode(raw);
      if (d is! Map) return {};
      return {
        for (final e in d.entries)
          if (e.key is String && e.value is List)
            e.key as String: [
              for (final r in e.value as List)
                if (r is List && r.length == 3 && r.every((x) => x is int))
                  r.cast<int>(),
            ],
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveGivenUp(
    NodeId peer,
    Map<String, List<List<int>>> ranges,
  ) async {
    ranges.removeWhere((_, v) => v.isEmpty);
    await _owner._storage.putSetting(
      _givenUpKey(peer),
      ranges.isEmpty ? '' : jsonEncode(ranges),
    );
  }

  Future<void> _rememberGivenUp(
    NodeId peer,
    String author,
    int lo,
    int hi,
  ) async {
    try {
      final ranges = await _loadGivenUp(peer);
      final list = ranges[author] ??= [];
      list.add([lo, hi, 0]);
      final total = ranges.values.fold<int>(0, (n, v) => n + v.length);
      if (total > _gaveUpMaxRanges) list.removeAt(0);
      // Not straight away: the waiting that just ended is the first try.
      _gaveUpTriedAt['${peer.hex}|$author|$lo'] = _owner._now();
      await _saveGivenUp(peer, ranges);
    } catch (_) {
      // Advisory: without it the range is lost as it was before.
    }
  }

  /// The one range given up on that is due to be asked for again, from its
  /// first seq still missing; null when none is. A range whose every seq has
  /// since arrived — by a mirror, a re-ship, any route — is forgotten, and so
  /// is one asked for [_gaveUpMaxTries] times.
  Future<({String author, int from})?> _givenUpDue(NodeId peer) async {
    try {
      final ranges = await _loadGivenUp(peer);
      if (ranges.isEmpty) return null;
      final now = _owner._now();
      var changed = false;
      ({String author, int from})? due;
      for (final e in ranges.entries) {
        final author = e.key;
        final keep = <List<int>>[];
        for (final r in e.value) {
          final lo = r[0], hi = r[1], tries = r[2];
          final key = '${peer.hex}|$author|$lo';
          final last = _gaveUpTriedAt[key];
          if (due != null ||
              (last != null && now.difference(last) < _gaveUpRetryEvery)) {
            keep.add(r);
            continue;
          }
          final held = {
            for (final ev in await _owner._storage.loadEventsSince(
              peer.hex,
              author,
              lo - 1,
              limit: hi - lo + 1,
            ))
              ev.seq,
          };
          int? from;
          for (var q = lo; q <= hi; q++) {
            if (!held.contains(q)) {
              from = q;
              break;
            }
          }
          if (from == null || tries >= _gaveUpMaxTries) {
            _gaveUpTriedAt.remove(key);
            changed = true;
            devLog(
              () =>
                  'xVeil[sync]: -> ${peer.short} given-up range $lo-$hi of '
                  '${author.substring(0, 8)} '
                  '${from == null ? 'filled since' : 'dropped after $tries tries'}',
            );
            continue;
          }
          _gaveUpTriedAt[key] = now;
          keep.add([lo, hi, tries + 1]);
          changed = true;
          due = (author: author, from: from);
          devLog(
            () =>
                'xVeil[sync]: -> ${peer.short} asking again for $from-$hi of '
                '${author.substring(0, 8)} (given up on, try ${tries + 1})',
          );
        }
        e.value
          ..clear()
          ..addAll(keep);
      }
      if (changed) await _saveGivenUp(peer, ranges);
      return due;
    } catch (_) {
      return null;
    }
  }

  /// The keys of my newest sent messages in this chat, and the time of the
  /// oldest of them, when a device of mine other than this one may have
  /// written in it too; null otherwise.
  Future<
    ({List<String> keys, Map<String, int> edits, int sinceMs, int? untilMs})?
  >
  _ownEchoAsk(NodeId peer) async {
    try {
      final siblings = await _owner.myOtherDevices?.call() ?? const <NodeId>[];
      if (siblings.isEmpty) return null;
      // BY TIME: the log is in arrival order, and "the last hundred" of it is
      // not the newest hundred once gap-fill and mirrors have filled it in.
      final sent = [
        for (final m in await _owner._storage.loadMessages(peer.hex))
          if (m.direction == MessageDirection.outgoing) m,
      ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (sent.isEmpty) return null;
      final round = _ownAskRounds[peer.hex] = (_ownAskRounds[peer.hex] ?? 0) + 1;
      final pages = (sent.length + kOwnEchoWindow - 1) ~/ kOwnEchoWindow;
      final page = ownEchoPage(round: round, pages: pages);
      // Page p is the p-th hundred counted back from the newest, and it runs
      // up to where the NEWER page starts — so consecutive pages meet, and what
      // the counterpart holds between two of my messages is inside one of them.
      final end = sent.length - page * kOwnEchoWindow;
      final start = end > kOwnEchoWindow ? end - kOwnEchoWindow : 0;
      final window = sent.sublist(start, end);
      final editSeqs = await _owner._storage.editSeqs(peer.hex);
      _ownAskedAt[peer.hex] = _owner._now();
      return (
        keys: [for (final m in window) ownEchoKey(m.id)],
        // What I hold EDITED, and at which edit: the counterpart hands back a
        // later text than this one — see [ownEchoesEdited].
        edits: {
          for (final m in window)
            if (editSeqs[m.id] case final seq?)
              ownEchoKey(m.id): (_ownEditSettled[m.id] ?? 0) > seq
                  ? _ownEditSettled[m.id]!
                  : seq,
        },
        // The OLDEST page is open below. What the counterpart holds from
        // before my first message here is history this device was not
        // present for — a device linked later, whose sibling that wrote it is
        // gone (measured: nine messages four days older than the device
        // itself). It cannot bring back what was dropped here: a deletion or
        // a retention cut leaves a tombstone the store refuses, and my own
        // clear bounds the conversation by time in the fold.
        sinceMs: start == 0
            ? 0
            : window.first.timestamp.millisecondsSinceEpoch,
        untilMs: page == 0
            ? null
            : sent[end].timestamp.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null; // advisory: a beacon goes out without it
    }
  }

  /// Hand a device of the peer back what the peer sent me that this device
  /// of theirs does not hold.
  ///
  /// Only messages the peer AUTHORED — carrying the peer's seq, never a marker
  /// this device wrote into the chat itself — and only as many as
  /// [kOwnEchoCap]. The same answer to the same ask is given twice and then
  /// not again for [_reshipPause]: a message the asker deleted on purpose
  /// stays missing from its list, and would otherwise be handed back on every
  /// beacon.
  Future<void> _answerOwnEchoAsk(
    NodeId peer,
    List<dynamic> ask,
    int sinceMs,
    int? untilMs, {
    Map<String, int> edits = const {},
  }) async {
    final held = <String>{
      for (final k in ask.take(kOwnEchoWindow))
        if (k is String && k.length == 8) k,
    };
    if (held.isEmpty) return;
    final theirs = [
      for (final m in await _owner._storage.loadMessages(peer.hex))
        if (m.direction == MessageDirection.incoming &&
            m.seq != null &&
            (m.author == null || m.author == peer.hex) &&
            !m.body.startsWith('sys:'))
          m,
    ];
    final missing = ownEchoesMissing(
      theirs: theirs,
      keyOf: (m) => ownEchoKey(m.id),
      tsOf: (m) => m.timestamp.millisecondsSinceEpoch,
      held: held,
      sinceMs: sinceMs,
      untilMs: untilMs,
    );
    final editSeqs = await _owner._storage.editSeqs(peer.hex);
    final edited = ownEchoesEdited(
      theirs: theirs,
      keyOf: (m) => ownEchoKey(m.id),
      tsOf: (m) => m.timestamp.millisecondsSinceEpoch,
      editSeqOf: (m) => editSeqs[m.id],
      held: held,
      heldEdits: edits,
      sinceMs: sinceMs,
      untilMs: untilMs,
    );
    if (edited.isNotEmpty) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} own-echo ask -> '
            '${edited.length} later edit(s) handed back',
      );
    }
    for (final m in edited) {
      await _owner._send(
        peer,
        WireEnvelope.sync(
          jsonEncode({
            'echo': {
              'id': m.id,
              'b': m.body,
              'ts': m.timestamp.millisecondsSinceEpoch,
              // The edit's seq: marks this as a later TEXT of a message the
              // asker holds, not a message it is missing.
              'e': editSeqs[m.id],
              if (m.customEmoji.isNotEmpty)
                'ce': encodeInlineCustomEmoji(m.customEmoji),
            },
          }),
        ).encode(),
      );
    }
    if (missing.isEmpty) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} own-echo ask of ${held.length} '
            '-> nothing missing',
      );
      return;
    }
    // THE SAME ANSWER, not the same ask. An asker that went away keeps its
    // list, while the messages it is missing keep arriving here — keyed by the
    // ask alone, the answer "nothing yet" silenced the real one for ten
    // minutes (measured on the stand: the ask came in, was answered empty,
    // three messages arrived, and the same list was then withheld).
    //
    // And TWICE before withholding, as the re-ship does: the answer is live
    // and can be lost, and the asker that lost it asks again with the very
    // same list (measured: an answer sent while the asker was shutting down,
    // eleven minutes for three messages).
    final signature = ownEchoKey(
      '$sinceMs:${(held.toList()..sort()).join()}:'
      '${[for (final m in missing) m.id].join(',')}',
    );
    final now = _owner._now();
    final answered = _ownAnswered[peer.hex] ??= {};
    final prev = answered[signature];
    final fresh = prev == null || now.difference(prev.at) >= _reshipPause;
    if (!fresh && prev.rounds >= _reshipRoundsWithoutProgress) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} own-echo answer of '
            '${missing.length} withheld (given ${prev.rounds}x already)',
      );
      return;
    }
    answered[signature] = (
      rounds: fresh ? 1 : prev.rounds + 1,
      at: fresh ? now : prev.at,
    );
    if (answered.length > 8) answered.remove(answered.keys.first);
    devLog(
      () =>
          'xVeil[sync]: <- ${peer.short} own-echo ask of ${held.length} '
          '-> ${missing.length} handed back',
    );
    for (final m in missing) {
      final cid = m.fileContentId;
      await _owner._send(
        peer,
        WireEnvelope.sync(
          jsonEncode({
            'echo': {
              'id': m.id,
              'b': m.body,
              'ts': m.timestamp.millisecondsSinceEpoch,
              if (m.customEmoji.isNotEmpty)
                'ce': encodeInlineCustomEmoji(m.customEmoji),
              'cid': ?cid,
              if (m.fileName != null) 'fn': m.fileName,
              if (m.fileSize != null) 'fs': m.fileSize,
            },
          }),
        ).encode(),
      );
    }
  }

  /// Store one of my own messages the peer handed back, as sent by me.
  ///
  /// Taken only as the answer to an ask this device made recently, and through
  /// the same path a sibling's mirror takes — so a message deleted here stays
  /// deleted and a block still holds. DELIVERED: the peer holding it is the
  /// proof, and a `sent` row would be re-sent by the outbox to the peer that
  /// just handed it over.
  Future<void> _applyOwnEcho(NodeId peer, Map<dynamic, dynamic> echo) async {
    final asked = _ownAskedAt[peer.hex];
    if (asked == null || _owner._now().difference(asked) > _ownAskTtl) return;
    final id = echo['id'], body = echo['b'], ts = echo['ts'];
    if (id is! String || id.isEmpty || body is! String || ts is! int) return;
    final editSeq = echo['e'];
    if (editSeq is int) {
      await _applyOwnEchoEdit(peer, id, body, editSeq, echo['ce']);
      return;
    }
    final cid = echo['cid'], name = echo['fn'], size = echo['fs'];
    // SAID, not swallowed: a refusal here is a message the person will not
    // see, and "why not" is the first question anyone asks about it.
    final String? refused;
    if (await _owner._hasMessage(peer, id)) {
      refused = 'already held';
    } else if (await _owner._storage.isMessageDeleted(peer.hex, id)) {
      refused = 'deleted here';
    } else {
      refused = null;
    }
    if (refused != null) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} own message $id handed back, '
            'not stored — $refused',
      );
      return;
    }
    // MINE, under the name the peer files it by. Left empty, the store took
    // the conversation — the PEER — for its author and numbered the row in the
    // peer's stream from a counter the peer's own events never move; an edit
    // of it then landed in that stream at a number from mine, where it can sit
    // on a slot the peer's real message is still owed. Never this DEVICE's
    // name: a row numbered in my own stream is re-shipped as a new send.
    final identity = await _owner.selfIdentityHex?.call();
    final selfHex = await _owner._selfHex();
    final stored = await _owner._deviceMirror.applyMessage(
      author: identity != null && identity != selfHex ? identity : null,
      peer: peer,
      msgId: id,
      direction: MessageDirection.outgoing,
      body: body,
      tsMs: ts,
      status: MessageStatus.delivered,
      fileContentId: cid is String && cid.isNotEmpty ? cid : null,
      fileName: name is String ? name : null,
      fileSize: size is int ? size : null,
      customEmoji: parseInlineCustomEmoji(body, echo['ce']),
    );
    devLog(
      () =>
          'xVeil[sync]: <- ${peer.short} own message $id handed back '
          '${stored ? 'by the peer' : '— REFUSED by the mirror path'}',
    );
  }

  /// A later text of one of my messages, which the peer holds and this device
  /// missed (see [ownEchoesEdited]). Through the path a sibling's mirrored
  /// edit takes, at the edit's own seq — so it is idempotent, and a deletion
  /// here still wins. Refused when this device holds the same edit or a
  /// later one: the ask said which, but the answer may cross a newer edit.
  Future<void> _applyOwnEchoEdit(
    NodeId peer,
    String id,
    String body,
    int seq,
    Object? customEmoji,
  ) async {
    final held = await _owner._storage.loadMessageById(peer.hex, id);
    final heldSeq = (await _owner._storage.editSeqs(peer.hex))[id];
    final String? refused;
    if (held == null) {
      refused = 'not held';
    } else if (held.direction != MessageDirection.outgoing) {
      refused = 'not mine';
    } else if (heldSeq != null && heldSeq >= seq) {
      refused = 'a later edit is held';
    } else if (held.body == body) {
      _ownEditSettled[id] = seq;
      if (_ownEditSettled.length > 4096) {
        _ownEditSettled.remove(_ownEditSettled.keys.first);
      }
      refused = 'this text is already shown';
    } else {
      refused = null;
    }
    if (refused != null) {
      devLog(
        () =>
            'xVeil[sync]: <- ${peer.short} edit of own message $id handed '
            'back, not applied — $refused',
      );
      return;
    }
    await _owner._deviceMirror.applyEdit(
      peer: peer,
      msgId: id,
      body: body,
      // The number is from MY stream. A row of mine stored before echoes
      // carried an author is filed under the peer, and an edit at that number
      // would land in the peer's stream; numbered locally, it cannot.
      seq: held!.author == peer.hex ? null : seq,
      customEmoji: parseInlineCustomEmoji(body, customEmoji),
    );
    devLog(
      () =>
          'xVeil[sync]: <- ${peer.short} edit of own message $id handed back '
          'by the peer',
    );
  }
}
