import '../core/ids.dart';
import 'group.dart';
import 'group_policy.dart';
import 'space_moderation.dart';

/// What one accepted control row did, as a closed vocabulary the UI turns into
/// a sentence.
///
/// The vocabulary is finer than [ControlOp] only where one op produces visibly
/// different events, and coarser where several ops share a sentence.
///
/// [other] is a UI fallback that [describeControlEntry] never returns, and that
/// is deliberate on both counts. [ControlOp.fromName] is nullable, so an op a
/// newer peer signed and this build has no name for never becomes a
/// [ControlEntry] in the first place — there is nothing here to be neutral
/// about. Meanwhile the switch below carries no `default`, so adding a
/// [ControlOp] later is a compile error until someone decides what it reads as
/// and who may read it. Routing the unknown to [other] would have traded that
/// forced decision for a silent shrug.
enum SpaceActionKind {
  memberAdded,
  memberRemoved,
  memberLeft,
  roleChanged,
  ownershipTransferred,
  memberMuted,
  memberUnmuted,
  memberBanned,
  moderationApplied,
  moderationRevoked,
  channelCreated,
  channelUpdated,
  spaceRenamed,
  spaceDescriptionChanged,
  spaceProfileMediaChanged,
  rulesPublished,
  rulesAccepted,
  accessPolicyChanged,
  retentionChanged,
  spaceArchived,
  spaceDeleted,
  spaceRestored,
  postPinChanged,
  recommendationCampaignChanged,
  recommendationPolicyChanged,
  encryptionRotated,
  checkpointRecorded,
  authorityWithdrawn,
  authorityReturned,
  other,
}

/// One control row translated into what it did and who may learn that.
///
/// [requiredPermission] is part of the description, not an afterthought: the
/// same mapping that decides how a row reads decides who may read it, so the
/// two can never drift apart in a later edit.
///
/// Payload fields are null whenever the signed row genuinely carries nothing
/// more — including when the payload is encrypted for a restricted channel. A
/// reader therefore cannot tell an absent detail from a withheld one, which is
/// exactly the property an opaque envelope is supposed to give.
final class SpaceActionDescriptor {
  const SpaceActionDescriptor({
    required this.kind,
    required this.requiredPermission,
    this.target,
    this.role,
    this.channelId,
    this.channelName,
    this.text,
    this.moderationKind,
  });

  final SpaceActionKind kind;
  final SpacePermission requiredPermission;

  /// The member the row acts on, when it acts on one.
  final NodeId? target;
  final GroupRole? role;

  /// Set when the row is scoped to one channel. The permission check binds it,
  /// so a channel-scoped moderator reads their own channel's history and
  /// nothing else.
  final NodeId? channelId;
  final String? channelName;

  /// A short free-text detail already carried in the clear by the row itself
  /// (currently only a new Space name). Long or structured payloads stay out.
  final String? text;
  final SpaceModerationKind? moderationKind;
}

/// One row of the rendered log: either a described action or a withheld one.
///
/// A withheld row keeps its position and its timestamp and drops everything
/// else — no author, no kind, no payload. Redaction by construction is the
/// point: there is no field for a careless UI to render, while the row itself
/// stays, so ordering and counts remain honest and a member can still tell
/// that something happened.
final class SpaceActionLogItem {
  const SpaceActionLogItem.visible({
    required this.stableId,
    required this.createdAtMs,
    required NodeId this.author,
    required SpaceActionDescriptor this.descriptor,
  });

  const SpaceActionLogItem.withheld({
    required this.stableId,
    required this.createdAtMs,
  }) : author = null,
       descriptor = null;

  /// The row's durable identity, `<authorHex>:<seq>` — the same pair every
  /// other log in this project uses. It is not derived from the payload, so a
  /// withheld row can carry it without leaking anything.
  final String stableId;
  final int createdAtMs;
  final NodeId? author;
  final SpaceActionDescriptor? descriptor;

  bool get isVisible => descriptor != null;
}

/// Map one control row onto what it did, with no reference to any viewer.
///
/// Kept free of ACL and localization so the op→meaning→permission table is
/// checkable on its own; [spaceActionLog] adds the viewer, the screen adds the
/// words.
SpaceActionDescriptor describeControlEntry(ControlEntry entry) {
  switch (entry.op) {
    case ControlOp.addMember:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.memberAdded,
        requiredPermission: SpacePermission.manageMembers,
        target: entry.target,
        role: entry.role,
      );
    case ControlOp.removeMember:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.memberRemoved,
        requiredPermission: SpacePermission.manageMembers,
        target: entry.target,
      );
    case ControlOp.leave:
      // Self-removal is still roster history, so it answers to the same right
      // as any other membership change.
      return SpaceActionDescriptor(
        kind: SpaceActionKind.memberLeft,
        requiredPermission: SpacePermission.manageMembers,
        target: entry.target ?? entry.author,
      );
    case ControlOp.setRole:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.roleChanged,
        requiredPermission: SpacePermission.manageRoles,
        target: entry.target,
        role: entry.role,
      );
    case ControlOp.transferOwnership:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.ownershipTransferred,
        requiredPermission: SpacePermission.manageRoles,
        target: entry.target,
      );
    case ControlOp.setPolicy:
      // The access policy is the role table itself.
      return SpaceActionDescriptor(
        kind: SpaceActionKind.accessPolicyChanged,
        requiredPermission: SpacePermission.manageRoles,
      );
    case ControlOp.revokeAuthority:
      // A retroactive change to who held authority, and therefore to the role
      // table, which is why it answers to the same right as a role change.
      return SpaceActionDescriptor(
        kind: entry.authorityBoundary?.restore == true
            ? SpaceActionKind.authorityReturned
            : SpaceActionKind.authorityWithdrawn,
        requiredPermission: SpacePermission.manageRoles,
        target: entry.target,
      );
    case ControlOp.mute:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.memberMuted,
        requiredPermission: SpacePermission.moderate,
        target: entry.target,
      );
    case ControlOp.unmute:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.memberUnmuted,
        requiredPermission: SpacePermission.moderate,
        target: entry.target,
      );
    case ControlOp.ban:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.memberBanned,
        requiredPermission: SpacePermission.moderate,
        target: entry.target,
      );
    case ControlOp.moderate:
      // A restricted-channel action names its channel in the clear even though
      // the action itself is sealed, so the row can still be scoped correctly.
      return SpaceActionDescriptor(
        kind: SpaceActionKind.moderationApplied,
        requiredPermission: SpacePermission.moderate,
        target: entry.moderationAction?.target ?? entry.target,
        channelId:
            entry.moderationAction?.channelId ??
            entry.channelModeration?.channelId,
        moderationKind: entry.moderationAction?.kind,
      );
    case ControlOp.revokeModeration:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.moderationRevoked,
        requiredPermission: SpacePermission.moderate,
        target: entry.target,
      );
    case ControlOp.createChannel:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.channelCreated,
        requiredPermission: SpacePermission.manageChannels,
        channelId: entry.channel?.channelId ?? entry.channelControl?.channelId,
        channelName: entry.channel?.name,
      );
    case ControlOp.updateChannel:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.channelUpdated,
        requiredPermission: SpacePermission.manageChannels,
        channelId: entry.channel?.channelId ?? entry.channelControl?.channelId,
        channelName: entry.channel?.name,
      );
    case ControlOp.setName:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.spaceRenamed,
        requiredPermission: SpacePermission.manageSettings,
        text: entry.text,
      );
    case ControlOp.setDescription:
      // The description itself can run to kilobytes; the row says only that it
      // changed.
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.spaceDescriptionChanged,
        requiredPermission: SpacePermission.manageSettings,
      );
    case ControlOp.setProfileMedia:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.spaceProfileMediaChanged,
        requiredPermission: SpacePermission.manageSettings,
      );
    case ControlOp.publishRules:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.rulesPublished,
        requiredPermission: SpacePermission.manageSettings,
      );
    case ControlOp.acceptRules:
      // Who has acknowledged the rules is roster bookkeeping, not a settings
      // change: it answers to manageMembers so the people who chase compliance
      // can actually see it.
      return SpaceActionDescriptor(
        kind: SpaceActionKind.rulesAccepted,
        requiredPermission: SpacePermission.manageMembers,
        target: entry.author,
      );
    case ControlOp.setRetention:
      return SpaceActionDescriptor(
        kind: SpaceActionKind.retentionChanged,
        requiredPermission: SpacePermission.manageStorage,
        channelId:
            entry.retentionPolicy?.channelId ?? entry.channelRetention?.channelId,
      );
    case ControlOp.archiveSpace:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.spaceArchived,
        requiredPermission: SpacePermission.manageSettings,
      );
    case ControlOp.deleteSpace:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.spaceDeleted,
        requiredPermission: SpacePermission.manageSettings,
      );
    case ControlOp.restoreSpace:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.spaceRestored,
        requiredPermission: SpacePermission.manageSettings,
      );
    case ControlOp.setPostPin:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.postPinChanged,
        requiredPermission: SpacePermission.managePosts,
      );
    case ControlOp.setRecommendationCampaign:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.recommendationCampaignChanged,
        requiredPermission: SpacePermission.manageRecommendations,
      );
    case ControlOp.setRecommendationPolicy:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.recommendationPolicyChanged,
        requiredPermission: SpacePermission.manageRecommendations,
      );
    case ControlOp.rotateEpoch:
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.encryptionRotated,
        requiredPermission: SpacePermission.manageEncryption,
      );
    case ControlOp.checkpoint:
      // A checkpoint is a Merkle root over rows the reader is already gated on
      // one by one, so it discloses nothing further.
      return const SpaceActionDescriptor(
        kind: SpaceActionKind.checkpointRecorded,
        requiredPermission: SpacePermission.view,
      );
  }
}

/// The rendered log, newest first, with every row the viewer may not read
/// replaced by a withheld one rather than dropped.
///
/// Membership is checked once for the whole surface; each row is then judged on
/// its own right. Rows are judged **at the timestamp they were signed at**: an
/// archived Space closes mutations, and [SpaceAcl] refuses management
/// permissions with a null `atMs` for exactly that reason, so judging live
/// would blank an admin's entire history the moment a Space is archived.
List<SpaceActionLogItem> spaceActionLog({
  required List<ControlEntry> control,
  required GroupState state,
  required NodeId viewer,
}) {
  final acl = SpaceAcl(state);
  // A deleted Space must reveal nothing, and a non-member has no standing at
  // all. Both fall out of the live `view` check, which is why it stays live.
  if (!acl.allows(viewer, SpacePermission.view)) return const [];
  final items = <SpaceActionLogItem>[];
  for (final entry in control) {
    final stableId = '${entry.author.hex}:${entry.seq}';
    final descriptor = describeControlEntry(entry);
    final visible = acl.allows(
      viewer,
      descriptor.requiredPermission,
      atMs: entry.createdAtMs,
      channelId: descriptor.channelId,
    );
    items.add(
      visible
          ? SpaceActionLogItem.visible(
              stableId: stableId,
              createdAtMs: entry.createdAtMs,
              author: entry.author,
              descriptor: descriptor,
            )
          : SpaceActionLogItem.withheld(
              stableId: stableId,
              createdAtMs: entry.createdAtMs,
            ),
    );
  }
  items.sort((left, right) {
    final byTime = right.createdAtMs.compareTo(left.createdAtMs);
    return byTime != 0 ? byTime : right.stableId.compareTo(left.stableId);
  });
  return List.unmodifiable(items);
}
