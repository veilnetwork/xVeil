// Value and sweep-result types of the group service, split out of
// `group_service.dart` mechanically: no API, behaviour or privacy boundary
// changes. `part` keeps them in the same library, so the library-private
// classes below stay private exactly as before.
part of 'group_service.dart';

/// A protected-channel revision prepared entirely in memory. The caller owns
/// [transientKey] and must wipe it after the containing bundle is committed or
/// abandoned; [bundle] keeps its own copy for deniable local persistence.
final class _PreparedProtectedChannelRevision {
  const _PreparedProtectedChannelRevision({
    required this.bundle,
    required this.controls,
    required this.transientKey,
  });

  final GroupBundle bundle;
  final List<ControlEntry> controls;
  final Uint8List transientKey;
}

/// One source-bound, single-use delivery challenge. It is deliberately held
/// only in RAM: persisting receipt tokens would create durable interaction
/// metadata and would let stale acknowledgements survive an identity restart.
final class _PendingSpaceReceipt {
  _PendingSpaceReceipt({
    required this.spaceId,
    required this.peer,
    required this.createdAtMs,
    this.repairFingerprint,
  }) : elapsed = Stopwatch()..start();

  final NodeId spaceId;
  final NodeId peer;
  final int createdAtMs;
  final String? repairFingerprint;
  final Stopwatch elapsed;
}

/// Metadata recovered from a valid, source-bound delivery challenge.
///
/// A nullable wrapper is intentionally not enough: a full snapshot has no
/// repair fingerprint, while an invalid/replayed token has no accepted
/// receipt at all.
final class _AcceptedSpaceReceipt {
  const _AcceptedSpaceReceipt({required this.repairFingerprint});

  final String? repairFingerprint;
}

/// A consumed repair challenge whose receiver still advertised the exact same
/// missing-object set. Remembering only this opaque token + content fingerprint
/// keeps replayed durable ACKs from restarting the same ping-pong, while a
/// fresh sync request without the old token remains free to retry.
final class _StalledSpaceReceipt {
  const _StalledSpaceReceipt({
    required this.spaceId,
    required this.peer,
    required this.repairFingerprint,
    required this.createdAtMs,
  });

  final NodeId spaceId;
  final NodeId peer;
  final String repairFingerprint;
  final int createdAtMs;
}

/// A bounded protocol confirmation that [peer] reported a caught-up sync
/// vector after acknowledging a source-bound receipt. This is not a remote
/// storage attestation; local frontier changes and TTL expiry invalidate it.
final class _SpaceHolderProof {
  const _SpaceHolderProof({
    required this.spaceId,
    required this.peer,
    required this.frontier,
    required this.confirmedAtMs,
  });

  final NodeId spaceId;
  final NodeId peer;
  final String frontier;
  final int confirmedAtMs;
}

/// Holder-side half of a content completion challenge. The original signed
/// request is retained only in RAM so a later live receipt can be matched to
/// the exact requester/group/CID/nonce without persisting a read trail.
final class _PendingContentReceipt {
  _PendingContentReceipt({required this.request, required this.createdAtMs})
    : elapsed = Stopwatch()..start();

  final GroupContentRequest request;
  final int createdAtMs;
  final Stopwatch elapsed;
}

/// Requester-side half used to route a verified-store receipt back only to an
/// actual byte source. One entry replaces the previous attempt for the same
/// (Space, CID, holder), keeping fanout bounded even across retries.
final class _OutboundContentRequest {
  const _OutboundContentRequest({
    required this.request,
    required this.holder,
    required this.createdAtMs,
  });

  final GroupContentRequest request;
  final NodeId holder;
  final int createdAtMs;
}

/// A bounded runtime confirmation that [peer] held/received one complete,
/// content-addressed blob. It is protocol evidence, not a Byzantine-proof
/// storage attestation: TTL, current authorization and the live reference set
/// constrain every aggregate that consumes it.
final class _ContentHolderProof {
  const _ContentHolderProof({
    required this.spaceId,
    required this.contentId,
    required this.peer,
    required this.confirmedAtMs,
  });

  final NodeId spaceId;
  final String contentId;
  final NodeId peer;
  final int confirmedAtMs;
}

final class _PendingPublicFeedObject {
  _PendingPublicFeedObject({
    required this.spaceId,
    required this.holder,
    required this.manifestHash,
    required this.objectHash,
    required this.createdAtMs,
  });

  final NodeId spaceId;
  final NodeId holder;
  final String manifestHash;
  final String objectHash;
  final int createdAtMs;
  final Completer<Uint8List?> completer = Completer<Uint8List?>();
  final Map<int, Uint8List> parts = <int, Uint8List>{};
  int? count;
  int? totalBytes;
}

class GroupLogCompaction {
  const GroupLogCompaction({
    required this.messagesBefore,
    required this.messagesAfter,
    required this.postsBefore,
    required this.postsAfter,
    required this.controlBefore,
    required this.controlAfter,
    required this.reactionsBefore,
    required this.reactionsAfter,
  });

  final int messagesBefore;
  final int messagesAfter;
  final int postsBefore;
  final int postsAfter;
  final int controlBefore;
  final int controlAfter;
  final int reactionsBefore;
  final int reactionsAfter;

  bool get changed =>
      messagesBefore != messagesAfter ||
      postsBefore != postsAfter ||
      controlBefore != controlAfter ||
      reactionsBefore != reactionsAfter;
}

class SpaceDeletionSweep {
  const SpaceDeletionSweep({
    required this.scanned,
    required this.purged,
    required this.pending,
    required this.failed,
  });

  final int scanned;
  final int purged;
  final int pending;
  final int failed;
}

class SharedContentGcSweep {
  const SharedContentGcSweep({
    required this.stored,
    required this.referenced,
    required this.unreachable,
    required this.marked,
    required this.purged,
    required this.failed,
    required this.complete,
  });

  final int stored;
  final int referenced;
  final int unreachable;
  final int marked;
  final int purged;
  final int failed;
  final bool complete;
}

class SpaceRetentionSweep {
  const SpaceRetentionSweep({
    required this.scanned,
    required this.messagesDeleted,
    required this.postsDeleted,
    required this.reactionsDeleted,
    required this.cutsRecorded,
    required this.failed,
    required this.complete,
  });

  final int scanned;
  final int messagesDeleted;
  final int postsDeleted;
  final int reactionsDeleted;
  final int cutsRecorded;
  final int failed;
  final bool complete;

  int get deleted => messagesDeleted + postsDeleted + reactionsDeleted;
}

class ScheduledSpacePostSweep {
  const ScheduledSpacePostSweep({
    required this.scanned,
    required this.published,
    required this.failed,
    required this.reconciled,
  });

  final int scanned;
  final int published;
  final int failed;
  final int reconciled;
}

/// Result of an idempotent local legacy-group -> signed-Space migration.
class SpaceManifestMigration {
  const SpaceManifestMigration({
    required this.scanned,
    required this.upgraded,
    required this.alreadyCurrent,
    required this.notOwner,
    required this.failed,
  });

  final int scanned;
  final int upgraded;
  final int alreadyCurrent;
  final int notOwner;
  final int failed;
}

/// One locally retained moderation action the current identity may appeal.
/// It remains discoverable after a ban hides the Space from the normal list.
class SpaceModerationAppealCandidate {
  const SpaceModerationAppealCandidate({
    required this.spaceId,
    required this.spaceName,
    required this.record,
  });

  final NodeId spaceId;
  final String spaceName;
  final SpaceModerationRecord record;
}

/// Ships a group snapshot [bundleJson] durably to [peer] (direct fanout, v1).
typedef GroupSnapshotSender =
    Future<void> Function(NodeId peer, NodeId groupId, String bundleJson);

typedef SpaceInviteSender =
    Future<void> Function(NodeId peer, String inviteId, String inviteJson);
typedef SpaceInviteDecisionSender =
    Future<void> Function(NodeId peer, String inviteId, String decisionJson);
typedef SpaceJoinRequestSender =
    Future<void> Function(NodeId peer, String requestId, String requestJson);
typedef SpaceJoinDecisionSender =
    Future<void> Function(NodeId peer, String requestId, String decisionJson);
typedef SpaceModerationAppealSender =
    Future<void> Function(NodeId peer, String appealId, String appealJson);
typedef SpaceModerationAppealDecisionSender =
    Future<void> Function(NodeId peer, String appealId, String decisionJson);
typedef SpaceAbuseReportSender =
    Future<void> Function(NodeId peer, String reportId, String reportJson);
typedef SpaceAbuseReportDecisionSender =
    Future<void> Function(NodeId peer, String reportId, String decisionJson);
typedef SpaceRecommendationSender =
    Future<String?> Function(NodeId peer, SpaceRecommendationCard card);
typedef SpaceRecommendationRevoker =
    Future<bool> Function(NodeId peer, String messageId);
typedef SpacePublicFeedRequestSender =
    Future<void> Function(NodeId holder, String requestJson);
typedef SpacePublicFeedChunkSender =
    Future<void> Function(NodeId requester, String chunkJson);
typedef SpacePublicMediaGrantRequestSender =
    Future<void> Function(NodeId holder, String requestJson);

/// Point-in-time transport view used only when an observability snapshot is
/// explicitly requested. Implementations must return active sessions only.
typedef ActivePeerSnapshotReader = Future<Set<NodeId>> Function();

typedef GroupCallFrameSender =
    Future<void> Function(
      NodeId peer,
      GroupCallSignal signal,
      String frameJson,
    );

class SpaceDiscoveryPublishSweep {
  const SpaceDiscoveryPublishSweep({
    required this.spacesScanned,
    required this.spacesPublished,
    required this.recordsPublished,
    required this.failures,
    required this.available,
  });

  final int spacesScanned;
  final int spacesPublished;
  final int recordsPublished;
  final int failures;
  final bool available;

  bool get complete => available && failures == 0;
}

/// Exact material prepared by an owner before it may advertise itself as a
/// public holder. The DHT payload is small; the content-addressed feed pages
/// remain on the holder and are served by the dedicated public-feed path.
class SpacePublicDiscoveryPublication {
  const SpacePublicDiscoveryPublication({
    required this.discovery,
    required this.feed,
  });

  final SpacePublicDiscoveryPayload discovery;
  final SpacePublicFeedProjection feed;
}

/// A merged public-discovery result that retains the independently verified
/// holders needed to fetch the committed feed and its media. Returning only a
/// descriptor is sufficient for rendering a card but would strand the next
/// operation without an authenticated source.
class SpacePublicDiscoveryResult {
  SpacePublicDiscoveryResult({
    required this.descriptor,
    required Iterable<SpacePublicHolderAnnouncement> holders,
  }) : holders = List<SpacePublicHolderAnnouncement>.unmodifiable(holders);

  final SpacePublicDescriptor descriptor;
  final List<SpacePublicHolderAnnouncement> holders;
}

enum SpacePublicDiscoverySearchStatus { available, partialQuorum, unavailable }

class SpacePublicDiscoverySearchOutcome {
  SpacePublicDiscoverySearchOutcome({
    required this.status,
    required Iterable<SpacePublicDiscoveryResult> results,
  }) : results = List<SpacePublicDiscoveryResult>.unmodifiable(results);

  final SpacePublicDiscoverySearchStatus status;
  final List<SpacePublicDiscoveryResult> results;
}

/// One active device-local subscription to an owner-signed public projection.
///
/// This is deliberately not a [GroupBundle]: it contains no membership,
/// control log, channel, epoch or write authority. [stale] only describes
/// whether the short network availability proof has expired; the stored
/// signatures remain independently verifiable at [verifiedAtMs] for offline
/// reading.
class SpacePublicSubscriptionView {
  const SpacePublicSubscriptionView({
    required this.subscription,
    required this.descriptor,
    required this.feed,
    required this.verifiedAtMs,
    required this.stale,
  });

  final SpaceSubscription subscription;
  final SpacePublicDescriptor descriptor;
  final SpacePublicFeedProjection feed;
  final int verifiedAtMs;
  final bool stale;
}
