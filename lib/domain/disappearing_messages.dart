import '../core/ids.dart';
import 'chat.dart';

/// The shared "messages disappear after N" setting of one conversation.
///
/// It is deliberately NOT the same thing as [Contact.retentionDays]. Retention
/// is a housekeeping preference: mine, local, never told to anyone, measured in
/// days. Disappearing messages is a promise BOTH sides keep — the whole point
/// is that the copy on the other device goes too — so it is announced, it is
/// adopted from the peer, and it is measured in seconds because "30 seconds
/// after I send it" is a thing people actually ask for and "0 days" is not.
///
/// [ttlSeconds] has no per-message state anywhere. A message is gone when its
/// own post time plus the window has passed, which means a device that was
/// switched off for a week does not need a catch-up protocol: it applies the
/// same arithmetic to the history it syncs and arrives at the same answer as
/// everyone else.
///
/// [hideAfterReadSeconds] is the OTHER clock, and it is deliberately a weaker
/// thing — see its own doc.
class DisappearingSetting {
  const DisappearingSetting({
    required this.ttlSeconds,
    required this.setAtMs,
    required this.setBy,
    this.hideAfterReadSeconds,
  });

  /// How long a message lives, in seconds. `null` means off — messages stay
  /// until something else removes them.
  final int? ttlSeconds;

  /// When this setting was made, ms since epoch, by whichever side made it.
  final int setAtMs;

  /// Hex node id of the side that made it. Only used to break an exact
  /// timestamp tie, and only so that BOTH sides break it the same way.
  final String setBy;

  /// How long a message stays on screen after THIS device first showed it.
  /// `null` means off.
  ///
  /// Three things make it a different kind of promise from [ttlSeconds], and
  /// the name says all three out loud.
  ///
  /// It HIDES rather than deletes. The row stays in the store and, in a
  /// channel, in the signed log — what stops is the showing. Removing it would
  /// mean re-anchoring a hash chain around a moment only one device witnessed.
  ///
  /// Its clock is LOCAL. This app has no read receipts — `MessageStatus` runs
  /// sending / sent / delivered / failed, and `markRead` mirrors only to the
  /// reader's own devices — so no one can know when anyone else read anything.
  /// Each device therefore counts from when it first showed the message: the
  /// sender's copy from sending, the reader's from opening the chat. Same rule
  /// everywhere, different moments, and that is the truthful shape.
  ///
  /// It is a REQUEST. A device that does not honour it is not misbehaving in
  /// any way the protocol could detect, let alone prevent. Anything that reads
  /// a screen can keep what it read.
  ///
  /// So: use [ttlSeconds] for a guarantee about bytes, this for a courtesy
  /// about attention. The two compose — whichever comes first wins — because
  /// they answer different questions.
  final int? hideAfterReadSeconds;

  bool get hidesAfterRead => (hideAfterReadSeconds ?? 0) > 0;

  Duration? get hideWindow =>
      hidesAfterRead ? Duration(seconds: hideAfterReadSeconds!) : null;

  /// Whether a message this device first showed at [firstSeenAt] should now be
  /// off screen. A message never shown has no clock running and is never
  /// hidden by this rule — which is the whole difference from [ttlSeconds],
  /// and the reason the two are worth having together.
  bool isHiddenAfterRead(DateTime? firstSeenAt, DateTime now) {
    final w = hideWindow;
    if (w == null || firstSeenAt == null) return false;
    return !now.isBefore(firstSeenAt.add(w));
  }

  /// Off, as of never. The state a conversation is in before anyone chose.
  static const DisappearingSetting off = DisappearingSetting(
    ttlSeconds: null,
    setAtMs: 0,
    setBy: '',
  );

  bool get isOn => (ttlSeconds ?? 0) > 0;

  Duration? get window => isOn ? Duration(seconds: ttlSeconds!) : null;

  /// Which of two announcements a conversation ends up holding.
  ///
  /// Last writer wins, and an exact tie goes to the lexicographically larger
  /// node id. The tie-break exists for one reason: two people who tap the
  /// menu in the same millisecond must not end up each keeping their own
  /// answer, because then one side deletes and the other does not, and the
  /// setting has quietly stopped being a promise.
  static DisappearingSetting winner(
    DisappearingSetting a,
    DisappearingSetting b,
  ) {
    if (a.setAtMs != b.setAtMs) return a.setAtMs > b.setAtMs ? a : b;
    return a.setBy.compareTo(b.setBy) >= 0 ? a : b;
  }

  /// Whether a message posted at [sentAt] has run out of time by [now].
  ///
  /// The clock that governs is the message's ORIGINAL post time, exactly like
  /// retention: editing a message must not buy it another window, or an
  /// automated edit would keep anything alive forever.
  bool hasExpired(DateTime sentAt, DateTime now) {
    final w = window;
    if (w == null) return false;
    return !now.isBefore(sentAt.add(w));
  }

  /// The instant before which everything in this conversation is already gone.
  /// `null` when the setting is off.
  DateTime? cutoffAt(DateTime now) {
    final w = window;
    return w == null ? null : now.subtract(w);
  }

  /// v2 only when there is something a v1 reader could not carry. An old build
  /// drops the unknown `rttl` and keeps the post-time window, which is the
  /// safe direction: it under-hides rather than over-promising, and the
  /// guarantee half of the setting survives intact.
  Map<String, Object?> toWireJson() => {
    'v': hidesAfterRead ? 2 : 1,
    'ttl': ttlSeconds ?? 0,
    'ts': setAtMs,
    if (hidesAfterRead) 'rttl': hideAfterReadSeconds,
  };

  /// Decode a peer's announcement. [from] is the sender — taken from the
  /// envelope, never from the body, so a peer cannot announce a setting in
  /// somebody else's name.
  ///
  /// Returns `null` for anything malformed. A garbled announcement must leave
  /// the conversation on the window it already had: silently falling back to
  /// "off" would turn a corrupt frame into a way to disable someone's
  /// disappearing messages.
  /// [now] is injectable for tests; production reads the wall clock.
  /// The same rules as [fromWireJson], for the MIRRORED form a linked device
  /// of this identity sends over the device-sync bridge.
  ///
  /// Same rules is the point. This half had none: it checked that `dsa` was an
  /// `int` and took `dtl`, `har` and `dsb` verbatim. A sibling — authenticated,
  /// but a sibling running an old build, a corrupted store, or a device
  /// somebody else now holds — could therefore mirror a window the direct wire
  /// would have refused outright: a stamp years ahead, which last-writer-wins
  /// turns into a permanent victory over every honest update after it, with a
  /// one-second TTL under it that deletes almost the whole conversation
  /// (report14 X14-M5). The outer gate does not cover this: it ranks the
  /// EVENT's timestamp, not the policy stamp inside the payload.
  ///
  /// Field names differ because the mirrored payload carries the contact's
  /// stored columns rather than the wire's abbreviations, and `dsb` names the
  /// ORIGINAL setter — the peer whose announcement this device recorded — so
  /// it comes from the payload here where the wire takes it from the envelope.
  ///
  /// Null means "no answer in this event": the caller leaves the window it
  /// already has, which is also what a REFUSAL must do. A malformed policy
  /// takes the policy down, not the alias or mute state travelling beside it.
  static DisappearingSetting? fromMirrorJson(
    Map<String, Object?> json, {
    DateTime? now,
  }) {
    final setAt = json['dsa'];
    if (setAt is! int || setAt < 0) return null;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (setAt > nowMs + kDisappearingClockSkew.inMilliseconds) return null;

    // Absent or zero is "off", which is a real answer and not a malformation:
    // a device that turned the window off mirrors exactly that. Out of range
    // is a malformation.
    final ttl = json['dtl'];
    if (ttl != null &&
        (ttl is! int || ttl < 0 || ttl > kDisappearingMaxSeconds)) {
      return null;
    }
    final hide = json['har'];
    if (hide != null &&
        (hide is! int || hide <= 0 || hide > kDisappearingMaxSeconds)) {
      return null;
    }
    final by = json['dsb'];
    if (by != null && by is! String) return null;

    final ttlSeconds = ttl is int && ttl > 0 ? ttl : null;
    return DisappearingSetting(
      ttlSeconds: ttlSeconds,
      setAtMs: setAt,
      setBy: by is String ? by : '',
      hideAfterReadSeconds: hide as int?,
    );
  }

  static DisappearingSetting? fromWireJson(
    Map<String, Object?> json,
    NodeId from, {
    DateTime? now,
  }) {
    final ttl = json['ttl'];
    final ts = json['ts'];
    if (ttl is! int || ts is! int || ttl < 0 || ts < 0) return null;
    if (ttl > kDisappearingMaxSeconds) return null;
    // A stamp our clock could not have produced is refused.
    //
    // `winner` is last-writer-wins on this field, so a far-future `ts` is not
    // an odd value in a record — it is a permanent victory. An authenticated
    // contact could announce `ttl = 1` dated years ahead: the aggressive sweep
    // starts deleting the conversation immediately, and every honest update
    // after it LOSES the comparison for as long as the claim says. There was no
    // upper bound at all, so `9223372036854775807` was accepted too, and the
    // marker `DateTime` built from it downstream threw — after the frame had
    // been ACKed and deduped.
    //
    // A Space already refuses exactly this, one-sided, on the same five
    // minutes: see `spaceRetentionRevisionBelievable`. The direct path is the
    // half that never got it. Past stamps stay honoured — a device back from a
    // week offline must keep last Tuesday's setting, and an early stamp can
    // only expire less.
    //
    // Refusing rather than clamping to `now` is deliberate, for the reason that
    // function's doc gives: a clamped claim moves on every evaluation. And a
    // refusal here means the conversation keeps the window it already had,
    // which is what this parser promises for anything it cannot believe.
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (ts > nowMs + kDisappearingClockSkew.inMilliseconds) return null;
    // Absent is off. Present and malformed is a REJECT of the whole
    // announcement, not a silent fallback: the same reasoning as above, one
    // level down. A peer must not be able to clear someone's read-window by
    // sending a window this build cannot parse.
    final rttl = json['rttl'];
    if (rttl != null &&
        (rttl is! int || rttl <= 0 || rttl > kDisappearingMaxSeconds)) {
      return null;
    }
    return DisappearingSetting(
      ttlSeconds: ttl == 0 ? null : ttl,
      setAtMs: ts,
      setBy: from.hex,
      hideAfterReadSeconds: rttl as int?,
    );
  }
}

/// How far ahead of this device's clock an announcement may be stamped.
///
/// Five minutes, and one-sided, matching `spaceRetentionRevisionBelievable`
/// for a Space. The two are the same policy for the same danger, and the value
/// is repeated rather than imported so a domain file about direct messages does
/// not depend on the Space-discovery module.
const Duration kDisappearingClockSkew = Duration(minutes: 5);

/// Ceiling on an announced window: four weeks.
///
/// Not a policy about how long people may want their messages to live — it is
/// a bound on what an announcement may claim. Without it a peer could send a
/// window of billions of seconds, and every expiry arithmetic downstream would
/// overflow into a date the platform's own [DateTime] cannot hold.
const int kDisappearingMaxSeconds = 28 * 24 * 60 * 60;

/// The windows the UI offers. Kept beside the model rather than in the widget
/// so the wire validator, the tests and the menu cannot drift apart.
const List<int> kDisappearingPresets = <int>[
  30, // 30 seconds
  5 * 60,
  60 * 60,
  8 * 60 * 60,
  24 * 60 * 60,
  7 * 24 * 60 * 60,
  kDisappearingMaxSeconds,
];

/// The read-window presets: minutes, and shorter than the post-time list.
///
/// The clock starts when the message is on screen, so a day here would mean a
/// day of the reader's attention rather than a day of calendar — which is not
/// a thing anyone means. Longer values stay reachable through the custom
/// entry.
const List<int> kHideAfterReadPresets = <int>[60, 5 * 60, 30 * 60, 60 * 60];
