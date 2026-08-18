import '../core/ids.dart';
import 'group_payload.dart';
import 'space_discovery.dart' show kSpacePublicClockSkew;

/// The floor is a minute because a group's disappearing window is this same
/// signed policy, and a window measured in days is retention rather than
/// disappearance.
///
/// Lowering it is a one-sided compatibility step, and the side it falls on is
/// worth stating. A build that still carries the old day-long floor rejects a
/// minute-long policy as structurally invalid, drops the revision, and so keeps
/// the messages FOREVER — the opposite of what its author asked for, silently.
/// It cannot fail the other way: no build deletes earlier than its own floor
/// allows. So the window is a promise about the devices that understand it, and
/// the picker says so rather than implying a guarantee across the whole group.
const int kMinSpaceRetentionMs = 60 * 1000;
const int kMaxSpaceRetentionMs = 100 * 365 * 24 * 60 * 60 * 1000;
const int kMaxSpaceDeletionGraceMs = 365 * 24 * 60 * 60 * 1000;

/// A window at or below this is a disappearing window rather than a retention
/// policy, and the difference is what happens to the bytes. Retention can
/// afford a grace period before physical deletion — a week is nothing against
/// a year. A minute-long window cannot: hiding a message at read time while
/// its ciphertext sits on disk for another week is not the thing the user
/// asked for. Authoring clamps the grace to zero below this line.
const int kDisappearingWindowCeilingMs = 24 * 60 * 60 * 1000;

/// Bounds on the hide-after-read half of a policy: one minute to four weeks.
/// The ceiling is a bound on what a signed row may CLAIM, not a policy about
/// taste — without it one row could carry a number whose expiry arithmetic
/// overflows every clock downstream.
const int kMinHideAfterReadMs = 60 * 1000;
const int kMaxHideAfterReadMs = 28 * 24 * 60 * 60 * 1000;

/// The windows a group's picker offers, in the scale the feature is actually
/// about. Anything longer is still reachable through the custom entry — these
/// are the ones worth one tap, not the ones that exist.
const List<Duration> kGroupDisappearingPresets = <Duration>[
  Duration(minutes: 1),
  Duration(minutes: 5),
  Duration(minutes: 30),
  Duration(minutes: 60),
];

/// A Space retention rule is a distinct signed policy, not a generic JSON bag.
/// `inherit` is valid only for a channel and removes its explicit override.
enum SpaceRetentionMode {
  inherit,
  keepForever,
  deleteAfter;

  static SpaceRetentionMode? fromName(String? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

class SpaceRetentionPolicy {
  const SpaceRetentionPolicy({
    required this.mode,
    this.channelId,
    this.retentionMs,
    this.mediaOnly = false,
    this.hideAfterReadMs,
    this.physicalDeletionGraceMs = 7 * 24 * 60 * 60 * 1000,
    this.includeArchivedChannels = true,
    this.preservePinned = true,
    this.preserveModerationEvidence = true,
  });

  /// The policy a picker produces for a chosen window.
  ///
  /// The grace period is the whole reason this exists rather than a plain
  /// constructor call at each call site. Its default of a week is right for a
  /// retention rule and wrong for a disappearing one: below
  /// [kDisappearingWindowCeilingMs] the message leaves the screen in a minute
  /// and its ciphertext would sit on disk until next Tuesday. Callers that
  /// genuinely want a long window keep the default by passing a long one.
  factory SpaceRetentionPolicy.forWindow(Duration window, {NodeId? channelId}) {
    final ms = window.inMilliseconds;
    return SpaceRetentionPolicy(
      mode: SpaceRetentionMode.deleteAfter,
      channelId: channelId,
      retentionMs: ms,
      physicalDeletionGraceMs: ms <= kDisappearingWindowCeilingMs
          ? 0
          : 7 * 24 * 60 * 60 * 1000,
    );
  }

  final SpaceRetentionMode mode;
  final NodeId? channelId;
  final int? retentionMs;

  /// Expire media references while retaining the signed message/publication
  /// text. This modifier is valid only with a bounded `deleteAfter` policy.
  /// It has a distinct wire version so an older client cannot mistake the
  /// policy for full-history deletion.
  final bool mediaOnly;

  /// The read-clock half: hide a message from the interface this long after
  /// the member's device first SHOWED it. Null is off.
  ///
  /// Everything that makes it different from [retentionMs] is deliberate. It
  /// HIDES — the signed log keeps the row, sync and serve still carry it, and
  /// only presentation stops. Its clock is LOCAL to each member's device,
  /// because nothing in this protocol knows when anyone else read anything.
  /// And it is a REQUEST: a member's build that ignores it is not detectable,
  /// let alone stoppable. It rides the same signed revision as the deletion
  /// half so there is one timeline, one authority (`manageStorage`) and one
  /// audit trail for both.
  ///
  /// Orthogonal to [mode]: `keepForever` + a read window is a meaningful
  /// policy ("never delete, but tidy the screen"), so validity does not tie
  /// the two together. Only `inherit` excludes it, because inherit's whole
  /// meaning is "this channel has no opinion of its own".
  final int? hideAfterReadMs;
  final int physicalDeletionGraceMs;
  final bool includeArchivedChannels;
  final bool preservePinned;
  final bool preserveModerationEvidence;

  bool get isStructurallyValid =>
      physicalDeletionGraceMs >= 0 &&
      physicalDeletionGraceMs <= kMaxSpaceDeletionGraceMs &&
      preservePinned &&
      preserveModerationEvidence &&
      (hideAfterReadMs == null ||
          (hideAfterReadMs! >= kMinHideAfterReadMs &&
              hideAfterReadMs! <= kMaxHideAfterReadMs)) &&
      switch (mode) {
        SpaceRetentionMode.inherit =>
          channelId != null &&
              retentionMs == null &&
              !mediaOnly &&
              hideAfterReadMs == null,
        SpaceRetentionMode.keepForever => retentionMs == null && !mediaOnly,
        SpaceRetentionMode.deleteAfter =>
          retentionMs != null &&
              retentionMs! >= kMinSpaceRetentionMs &&
              retentionMs! <= kMaxSpaceRetentionMs,
      };

  /// v3 only when the read window is set, so every revision an old build CAN
  /// represent keeps the wire shape that build expects. A v3 row is rejected
  /// whole by a pre-read-window build (unknown version), which drops that one
  /// revision and keeps the previous policy — under-hiding, never a surprise
  /// deletion. The one-sidedness is the same as the retention floor's, and
  /// like there, the UI owes the author a sentence about it.
  Map<String, dynamic> toJson() => {
    'v': hideAfterReadMs != null
        ? 3
        : mediaOnly
        ? 2
        : 1,
    'mode': mode.name,
    if (channelId != null) 'channel': channelId!.hex,
    if (retentionMs != null) 'retentionMs': retentionMs,
    if (mediaOnly) 'mediaOnly': true,
    if (hideAfterReadMs != null) 'hideReadMs': hideAfterReadMs,
    'graceMs': physicalDeletionGraceMs,
    'archives': includeArchivedChannels,
    'pins': preservePinned,
    'moderation': preserveModerationEvidence,
  };

  static SpaceRetentionPolicy? fromJson(Object? value) {
    if (value is! Map ||
        (value['v'] != 1 && value['v'] != 2 && value['v'] != 3) ||
        value['mode'] is! String ||
        value['graceMs'] is! int ||
        value['archives'] is! bool ||
        value['pins'] is! bool ||
        value['moderation'] is! bool) {
      return null;
    }
    final version = value['v'] as int;
    // Each version means exactly one field shape. A v1 row carrying mediaOnly,
    // a v2 row without it, a v3 row without its window or a v1/v2 row WITH one
    // are all malformed — accepting any of them would let one encoder's bug
    // read as a different policy on half the fleet.
    if ((version == 1 && value.containsKey('mediaOnly')) ||
        (version == 2 && value['mediaOnly'] != true) ||
        (version == 3
            ? value['hideReadMs'] is! int
            : value.containsKey('hideReadMs'))) {
      return null;
    }
    final mode = SpaceRetentionMode.fromName(value['mode'] as String);
    if (mode == null) return null;
    try {
      final policy = SpaceRetentionPolicy(
        mode: mode,
        channelId: value['channel'] is String
            ? NodeId.fromHex(value['channel'] as String)
            : null,
        retentionMs: value['retentionMs'] is int
            ? value['retentionMs'] as int
            : null,
        mediaOnly: version == 2 || (version == 3 && value['mediaOnly'] == true),
        hideAfterReadMs: version == 3 ? value['hideReadMs'] as int : null,
        physicalDeletionGraceMs: value['graceMs'] as int,
        includeArchivedChannels: value['archives'] as bool,
        preservePinned: value['pins'] as bool,
        preserveModerationEvidence: value['moderation'] as bool,
      );
      return policy.isStructurallyValid ? policy : null;
    } catch (_) {
      return null;
    }
  }
}

/// Whether a signed retention revision claiming to have been authored at
/// [claimedMs] may join this device's retention timeline while its clock reads
/// [nowMs].
///
/// `setRetention` carries the author's own `createdAtMs`, bounded by the wire
/// format only by `>= 0`, and the builders clamp each revision's activation
/// monotonically up to the newest one seen so far. That clamp is what turns one
/// unbelievable stamp into a standstill: it lifts EVERY later revision to the
/// same year, so the replay in [_spaceRetentionExpires] stops at the first one
/// and never reaches the rest — and no later revision can undo it, because a
/// corrective policy is lifted to that year too. The whole line stops deleting,
/// at every holder, until the year arrives, with nothing to notice.
///
/// It is not an owner-only lever either: `setRetention` is authorized by
/// `manageStorage`, which a custom role can carry, so the one permission meant
/// to manage retention can permanently disable it — including for the owner,
/// and including after the delegate is stripped of the role.
///
/// A revision that fails this test is EXCLUDED from the timeline rather than
/// clamped into it, and the difference is the whole fix. Clamping the claim to
/// `now` would move the activation on every evaluation, so a `deleteAfter`
/// boundary would slide forward with the clock and still never retire anything
/// — the same standstill, quieter. Exclusion is also its own deferral: the
/// timeline is rebuilt from the signed log on every call, so a revision genuinely
/// dated ahead joins it the moment its time arrives, exactly as its author asked.
/// What exclusion adds over the old behaviour is that the excluded row no longer
/// raises the monotone floor, so the honest revisions AFTER it keep their own
/// stamps and take effect now — which is what makes the mistake recoverable.
///
/// One-sided, on the existing tolerance, like the rest of this series. A stamp
/// in the past is honoured: it can only move a boundary earlier, which expires
/// less, and a device back from a week offline must keep last Tuesday's policy.
bool spaceRetentionRevisionBelievable(int claimedMs, int nowMs) =>
    claimedMs <= nowMs + kSpacePublicClockSkew.inMilliseconds;

/// One immutable accepted policy revision. [activatedAtMs] is monotonically
/// clamped during the deterministic fold so a backward wall-clock step cannot
/// reorder or resurrect history on another device. Revisions the local clock
/// cannot believe are left out of the fold entirely, so the value here is never
/// one no clock could have produced (see [spaceRetentionRevisionBelievable]).
class SpaceRetentionRevision {
  const SpaceRetentionRevision({
    required this.policy,
    required this.activatedAtMs,
    required this.author,
    required this.authorSeq,
  });

  final SpaceRetentionPolicy policy;
  final int activatedAtMs;
  final NodeId author;
  final int authorSeq;
}

/// Opaque retention revision for one restricted channel.
///
/// The outer signed control row exposes only the already-public opaque channel
/// id and epoch needed for routing/key selection. The actual mode, interval
/// and deletion posture stay authenticated under that channel epoch key.
class SpaceChannelRetentionEnvelope {
  const SpaceChannelRetentionEnvelope({
    required this.spaceId,
    required this.channelId,
    required this.channelEpoch,
    required this.encryptedPolicy,
  });

  final NodeId spaceId;
  final NodeId channelId;
  final int channelEpoch;
  final GroupEncryptedPayload encryptedPolicy;

  bool get isStructurallyValid =>
      channelEpoch > 0 &&
      channelEpoch <= 0xffffffff &&
      encryptedPolicy.isStructurallyValid;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'sid': spaceId.hex,
    'cid': channelId.hex,
    'epoch': channelEpoch,
    'enc': encryptedPolicy.toJson(),
  };

  static SpaceChannelRetentionEnvelope? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final sid = value['sid'];
    final cid = value['cid'];
    final epoch = value['epoch'];
    final encrypted = GroupEncryptedPayload.fromJson(value['enc']);
    if (sid is! String ||
        cid is! String ||
        epoch is! int ||
        encrypted == null) {
      return null;
    }
    try {
      final envelope = SpaceChannelRetentionEnvelope(
        spaceId: NodeId.fromHex(sid),
        channelId: NodeId.fromHex(cid),
        channelEpoch: epoch,
        encryptedPolicy: encrypted,
      );
      return envelope.isStructurallyValid ? envelope : null;
    } catch (_) {
      return null;
    }
  }
}

/// A local record of a physically deleted retention-expired chain prefix.
///
/// Message rows form strict per-`(scope, author)` hash chains, so deleting an
/// expired prefix would otherwise hide the whole retained suffix ("missing
/// predecessor"). The cut re-anchors the fold at the first surviving row whose
/// `prevHash` equals [throughHash] — the hash of the last physically deleted
/// row. Matching on the hash (not `throughSeq + 1`) is required because an
/// author's seq is global across channels, so a single chain scope legitimately
/// has seq gaps; a seq-contiguity assumption would hide the retained suffix.
/// It is not a signed wire object: locally it is written only by the retention
/// sweep, and a remote hint is merged only after the receiver re-validates the
/// claimed boundary against its own fold of the signed retention revisions AND
/// its own chain matches [throughHash].
class SpaceRetentionCut {
  const SpaceRetentionCut({
    required this.scope,
    required this.author,
    required this.throughSeq,
    required this.throughHash,
    required this.throughCreatedAtMs,
  });

  final String scope;
  final NodeId author;
  final int throughSeq;

  /// Hash of the last deleted row; the retained anchor's `prevHash` must equal
  /// this. Empty only for a legacy cut that predates hash re-anchoring.
  final String throughHash;
  final int throughCreatedAtMs;

  static final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');

  bool get isStructurallyValid =>
      scope.isNotEmpty &&
      scope.length <= 512 &&
      throughSeq >= 0 &&
      (throughHash.isEmpty || _hashPattern.hasMatch(throughHash)) &&
      throughCreatedAtMs > 0;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'scope': scope,
    'a': author.hex,
    's': throughSeq,
    if (throughHash.isNotEmpty) 'h': throughHash,
    't': throughCreatedAtMs,
  };

  static SpaceRetentionCut? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['scope'] is! String ||
        value['a'] is! String ||
        value['s'] is! int ||
        (value['h'] != null && value['h'] is! String) ||
        value['t'] is! int) {
      return null;
    }
    try {
      final cut = SpaceRetentionCut(
        scope: value['scope'] as String,
        author: NodeId.fromHex(value['a'] as String),
        throughSeq: value['s'] as int,
        throughHash: value['h'] as String? ?? '',
        throughCreatedAtMs: value['t'] as int,
      );
      return cut.isStructurallyValid ? cut : null;
    } catch (_) {
      return null;
    }
  }
}

String retentionCutKey(String scope, NodeId author) => '$scope|${author.hex}';

/// Returns true once any accepted policy interval has retired the item. Every
/// revision is replayed, so changing a destructive rule back to "forever"
/// freezes future expiry but never resurrects data already retired earlier.
bool spaceRetentionRemoves({
  required Iterable<SpaceRetentionRevision> revisions,
  required int createdAtMs,
  required int atMs,
  NodeId? channelId,
}) => _spaceRetentionExpires(
  revisions: revisions,
  createdAtMs: createdAtMs,
  atMs: atMs,
  channelId: channelId,
  media: false,
);

/// Returns true once media attached to the item has expired under any accepted
/// bounded policy. A full-history rule also expires media; a media-only rule
/// does not expire the surrounding signed text. Replaying every revision keeps
/// both effects irreversible when a later policy is relaxed.
bool spaceRetentionRemovesMedia({
  required Iterable<SpaceRetentionRevision> revisions,
  required int createdAtMs,
  required int atMs,
  NodeId? channelId,
}) => _spaceRetentionExpires(
  revisions: revisions,
  createdAtMs: createdAtMs,
  atMs: atMs,
  channelId: channelId,
  media: true,
);

bool _spaceRetentionExpires({
  required Iterable<SpaceRetentionRevision> revisions,
  required int createdAtMs,
  required int atMs,
  required NodeId? channelId,
  required bool media,
}) {
  SpaceRetentionPolicy space = const SpaceRetentionPolicy(
    mode: SpaceRetentionMode.keepForever,
  );
  SpaceRetentionPolicy? channel;

  bool expiredAt(int boundaryMs) {
    final effective = channel ?? space;
    return effective.mode == SpaceRetentionMode.deleteAfter &&
        (media || !effective.mediaOnly) &&
        createdAtMs <= boundaryMs - effective.retentionMs!;
  }

  for (final revision in revisions) {
    // Still a `break` and not a `continue`: activations are non-decreasing by
    // construction, so a revision that has not activated yet is followed only
    // by revisions that have not activated yet. What changed is which rows are
    // in this list at all — a stamp no clock here could have produced is not
    // one of them, so it can no longer carry the honest revisions behind it
    // past this line (see [spaceRetentionRevisionBelievable]).
    if (revision.activatedAtMs > atMs) break;
    if (expiredAt(revision.activatedAtMs)) return true;
    final policy = revision.policy;
    if (policy.channelId == null) {
      space = policy;
    } else if (policy.channelId == channelId) {
      channel = policy.mode == SpaceRetentionMode.inherit ? null : policy;
    }
    if (expiredAt(revision.activatedAtMs)) return true;
  }
  return expiredAt(atMs);
}
