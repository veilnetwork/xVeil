import '../core/ids.dart';
import 'group_payload.dart';

const int kMinSpaceRetentionMs = 24 * 60 * 60 * 1000;
const int kMaxSpaceRetentionMs = 100 * 365 * 24 * 60 * 60 * 1000;
const int kMaxSpaceDeletionGraceMs = 365 * 24 * 60 * 60 * 1000;

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
    this.physicalDeletionGraceMs = 7 * 24 * 60 * 60 * 1000,
    this.includeArchivedChannels = true,
    this.preservePinned = true,
    this.preserveModerationEvidence = true,
  });

  final SpaceRetentionMode mode;
  final NodeId? channelId;
  final int? retentionMs;

  /// Expire media references while retaining the signed message/publication
  /// text. This modifier is valid only with a bounded `deleteAfter` policy.
  /// It has a distinct wire version so an older client cannot mistake the
  /// policy for full-history deletion.
  final bool mediaOnly;
  final int physicalDeletionGraceMs;
  final bool includeArchivedChannels;
  final bool preservePinned;
  final bool preserveModerationEvidence;

  bool get isStructurallyValid =>
      physicalDeletionGraceMs >= 0 &&
      physicalDeletionGraceMs <= kMaxSpaceDeletionGraceMs &&
      preservePinned &&
      preserveModerationEvidence &&
      switch (mode) {
        SpaceRetentionMode.inherit =>
          channelId != null && retentionMs == null && !mediaOnly,
        SpaceRetentionMode.keepForever => retentionMs == null && !mediaOnly,
        SpaceRetentionMode.deleteAfter =>
          retentionMs != null &&
              retentionMs! >= kMinSpaceRetentionMs &&
              retentionMs! <= kMaxSpaceRetentionMs,
      };

  Map<String, dynamic> toJson() => {
    'v': mediaOnly ? 2 : 1,
    'mode': mode.name,
    if (channelId != null) 'channel': channelId!.hex,
    if (retentionMs != null) 'retentionMs': retentionMs,
    if (mediaOnly) 'mediaOnly': true,
    'graceMs': physicalDeletionGraceMs,
    'archives': includeArchivedChannels,
    'pins': preservePinned,
    'moderation': preserveModerationEvidence,
  };

  static SpaceRetentionPolicy? fromJson(Object? value) {
    if (value is! Map ||
        (value['v'] != 1 && value['v'] != 2) ||
        value['mode'] is! String ||
        value['graceMs'] is! int ||
        value['archives'] is! bool ||
        value['pins'] is! bool ||
        value['moderation'] is! bool) {
      return null;
    }
    final version = value['v'] as int;
    if ((version == 1 && value.containsKey('mediaOnly')) ||
        (version == 2 && value['mediaOnly'] != true)) {
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
        mediaOnly: version == 2,
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

/// One immutable accepted policy revision. [activatedAtMs] is monotonically
/// clamped during the deterministic fold so a backward wall-clock step cannot
/// reorder or resurrect history on another device.
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
/// predecessor"). The cut re-anchors the fold at `throughSeq + 1`. It is not a
/// signed wire object: locally it is written only by the retention sweep, and
/// a remote hint is merged only after the receiver has re-validated the
/// claimed boundary against its own fold of the signed retention revisions.
class SpaceRetentionCut {
  const SpaceRetentionCut({
    required this.scope,
    required this.author,
    required this.throughSeq,
    required this.throughCreatedAtMs,
  });

  final String scope;
  final NodeId author;
  final int throughSeq;
  final int throughCreatedAtMs;

  bool get isStructurallyValid =>
      scope.isNotEmpty &&
      scope.length <= 512 &&
      throughSeq >= 0 &&
      throughCreatedAtMs > 0;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'scope': scope,
    'a': author.hex,
    's': throughSeq,
    't': throughCreatedAtMs,
  };

  static SpaceRetentionCut? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['scope'] is! String ||
        value['a'] is! String ||
        value['s'] is! int ||
        value['t'] is! int) {
      return null;
    }
    try {
      final cut = SpaceRetentionCut(
        scope: value['scope'] as String,
        author: NodeId.fromHex(value['a'] as String),
        throughSeq: value['s'] as int,
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
