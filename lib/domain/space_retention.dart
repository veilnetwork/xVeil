import '../core/ids.dart';

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
    this.physicalDeletionGraceMs = 7 * 24 * 60 * 60 * 1000,
    this.includeArchivedChannels = true,
    this.preservePinned = true,
    this.preserveModerationEvidence = true,
  });

  final SpaceRetentionMode mode;
  final NodeId? channelId;
  final int? retentionMs;
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
        SpaceRetentionMode.inherit => channelId != null && retentionMs == null,
        SpaceRetentionMode.keepForever => retentionMs == null,
        SpaceRetentionMode.deleteAfter =>
          retentionMs != null &&
              retentionMs! >= kMinSpaceRetentionMs &&
              retentionMs! <= kMaxSpaceRetentionMs,
      };

  Map<String, dynamic> toJson() => {
    'v': 1,
    'mode': mode.name,
    if (channelId != null) 'channel': channelId!.hex,
    if (retentionMs != null) 'retentionMs': retentionMs,
    'graceMs': physicalDeletionGraceMs,
    'archives': includeArchivedChannels,
    'pins': preservePinned,
    'moderation': preserveModerationEvidence,
  };

  static SpaceRetentionPolicy? fromJson(Object? value) {
    if (value is! Map ||
        value['v'] != 1 ||
        value['mode'] is! String ||
        value['graceMs'] is! int ||
        value['archives'] is! bool ||
        value['pins'] is! bool ||
        value['moderation'] is! bool) {
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

/// Returns true once any accepted policy interval has retired the item. Every
/// revision is replayed, so changing a destructive rule back to "forever"
/// freezes future expiry but never resurrects data already retired earlier.
bool spaceRetentionRemoves({
  required Iterable<SpaceRetentionRevision> revisions,
  required int createdAtMs,
  required int atMs,
  NodeId? channelId,
}) {
  SpaceRetentionPolicy space = const SpaceRetentionPolicy(
    mode: SpaceRetentionMode.keepForever,
  );
  SpaceRetentionPolicy? channel;

  bool expiredAt(int boundaryMs) {
    final effective = channel ?? space;
    return effective.mode == SpaceRetentionMode.deleteAfter &&
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
