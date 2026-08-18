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

  Duration? get window =>
      isOn ? Duration(seconds: ttlSeconds!) : null;

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
  static DisappearingSetting? fromWireJson(
    Map<String, Object?> json,
    NodeId from,
  ) {
    final ttl = json['ttl'];
    final ts = json['ts'];
    if (ttl is! int || ts is! int || ttl < 0 || ts < 0) return null;
    if (ttl > kDisappearingMaxSeconds) return null;
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
const List<int> kHideAfterReadPresets = <int>[
  60,
  5 * 60,
  30 * 60,
  60 * 60,
];
