// Group policy evaluation (groups epic, phase 0, brick 1): fold an ordered
// control-log into the current membership/roles/policy state, applying each
// entry ONLY when its author is permitted the op against the state that
// preceded it. Pure and deterministic — the same log yields the same state on
// every device, so a peer that ships an invalid op can't move anyone else's
// view (the op is dropped, not shown, and — at the transport layer — not
// relayed).
//
// Permission model (v1, from the agreed design):
//  - owner: everything. The genesis starts as owner and may transfer that
//    effective role atomically; no log prefix may contain zero owners.
//  - admin: add/remove/mute/unmute/ban members, rotate epoch; may set a
//    member's role up to (but not including) their own rank; cannot touch
//    a peer of equal-or-higher rank.
//  - member: no control ops.
// A V20 setPolicy may be authored by a manageRoles delegate, but only through
// the capability-ceiling transition check below. Older V17-V19 rows remain
// owner-only so their deployed authorization meaning never changes.

import 'dart:collection';

import '../core/ids.dart';
import 'group.dart';
import 'group_epoch.dart';
import 'space_access.dart';
import 'space_channel.dart';
import 'space_lifecycle.dart';
import 'space_join_request.dart';
import 'space_moderation.dart';
import 'space_post.dart';
import 'space_recommendation.dart';
import 'space_retention.dart';
import 'space_rules.dart';

export 'space_access.dart';

/// The folded group state after replaying a (validated) control-log prefix.
class GroupState {
  GroupState._(
    this.members,
    this.epoch,
    this.policyVersion,
    this.accessPolicy,
    this.accessPolicyHistory,
    this.name,
    this.description,
    this.epochDescriptor,
    this.channels,
    this.protectedChannels,
    this.rulesHistory,
    this.rulesAcceptances,
    this.moderationRecords,
    this.protectedModeration,
    this.protectedRetention,
    this.retentionHistory,
    this.postPins,
    this.recommendationCampaigns,
    this.lifecycleState,
    this.lifecycleTransition,
    this.lifecycleTransitionHash,
  );

  /// nodeId hex -> member.
  final Map<String, GroupMember> members;

  /// The current key epoch (bumped by rotateEpoch — bans/leaves rotate).
  final int epoch;

  /// The current policy version (bumped by setPolicy).
  final int policyVersion;

  /// Latest accepted custom access snapshot and its immutable audit history.
  /// Null/empty is the compatible legacy policy made only of built-in roles.
  final SpaceAccessPolicy? accessPolicy;
  final List<SpaceAccessPolicy> accessPolicyHistory;

  /// The current display name (genesis manifest name, updated by setName).
  final String name;

  /// The current Space summary (genesis manifest description, updated by the
  /// signed control log). Legacy groups use an empty value.
  final String description;

  /// Signed recipient-envelope root for the current key epoch. Null means the
  /// legacy cleartext epoch or an epoch waiting for an authorized rekey.
  final GroupEpochDescriptor? epochDescriptor;

  /// channel id hex -> latest accepted signed channel state.
  final Map<String, SpaceChannel> channels;

  /// Latest accepted opaque restricted/secret channel revision. Metadata and
  /// ACL are intentionally absent from the global fold; authorized devices
  /// decrypt and validate them in GroupService.
  final Map<String, SpaceChannelControlEnvelope> protectedChannels;

  /// Immutable accepted revisions keyed by their monotonically increasing
  /// version. The current rules are [currentRules].
  final Map<int, SpaceRulesVersion> rulesHistory;

  /// Latest acknowledgement by member node-id. An acknowledgement of an older
  /// revision is retained as audit evidence and means re-acceptance is due.
  final Map<String, SpaceRulesAcceptance> rulesAcceptances;

  /// Immutable signed moderation actions keyed by their control-row id. A
  /// revocation annotates a record but never removes the original evidence.
  final Map<String, SpaceModerationRecord> moderationRecords;

  /// Accepted opaque restricted-channel moderation evidence keyed by the
  /// enclosing control-row id. Semantic enforcement happens only after an
  /// authorized device decrypts and validates the action.
  final Map<String, SpaceChannelModerationEnvelope> protectedModeration;

  /// Accepted opaque restricted-channel retention evidence keyed by the
  /// enclosing control-row id. The pure fold proves owner authority and the
  /// channel epoch; authorized devices decrypt the semantic policy later.
  final Map<String, SpaceChannelRetentionEnvelope> protectedRetention;

  /// Every accepted signed revision, retained for audit and irreversible
  /// expiry evaluation. A later relaxed policy cannot resurrect an item that
  /// expired while an earlier destructive revision was active.
  final List<SpaceRetentionRevision> retentionHistory;

  /// Latest accepted community-wide pin state keyed by publication root id.
  /// The payload also binds the exact root hash; materialization must verify it
  /// before exposing a pin so a stale control row cannot attach to new content.
  final Map<String, SpacePostPin> postPins;

  /// Latest signed state for every recommendation campaign. Revoked rows stay
  /// present as audit evidence but are never distributable.
  final Map<String, SpaceRecommendationCampaign> recommendationCampaigns;

  /// Signed Space lifecycle state. Group chats never author lifecycle ops and
  /// therefore remain [SpaceLifecycleState.active].
  final SpaceLifecycleState lifecycleState;
  final SpaceLifecycleTransition? lifecycleTransition;
  final String? lifecycleTransitionHash;

  bool get isArchived => lifecycleState == SpaceLifecycleState.archived;
  bool get isDeleted => lifecycleState == SpaceLifecycleState.deleted;
  bool get isActive => lifecycleState == SpaceLifecycleState.active;

  SpaceRulesVersion? get currentRules =>
      rulesHistory.isEmpty ? null : rulesHistory[rulesHistory.length];

  SpaceRulesAcceptance? rulesAcceptanceOf(NodeId member) =>
      rulesAcceptances[member.hex];

  bool requiresRulesAcceptance(NodeId member) {
    final current = currentRules;
    if (current == null || !isMember(member)) return false;
    return rulesAcceptances[member.hex]?.rulesVersion != current.version;
  }

  Iterable<SpaceModerationRecord> activeModerationFor(
    NodeId member,
    int atMs,
  ) => moderationRecords.values.where(
    (record) => record.action.target == member && record.isActiveAt(atMs),
  );

  bool isBannedAt(NodeId member, int atMs) => activeModerationFor(
    member,
    atMs,
  ).any((record) => record.action.kind.removesMembership);

  bool isModeratedContentRemoved({
    required SpaceModerationReferenceKind kind,
    required NodeId author,
    required int seq,
    required int atMs,
    NodeId? channelId,
  }) => spaceModerationRemovesContent(
    moderationRecords.values,
    kind: kind,
    author: author,
    seq: seq,
    atMs: atMs,
    channelId: channelId,
  );

  SpaceRetentionPolicy effectiveRetentionPolicy([NodeId? channelId]) {
    SpaceRetentionPolicy space = const SpaceRetentionPolicy(
      mode: SpaceRetentionMode.keepForever,
    );
    SpaceRetentionPolicy? channel;
    for (final revision in retentionHistory) {
      final policy = revision.policy;
      if (policy.channelId == null) {
        space = policy;
      } else if (policy.channelId == channelId) {
        channel = policy.mode == SpaceRetentionMode.inherit ? null : policy;
      }
    }
    return channel ?? space;
  }

  bool isRetentionExpired({
    required int createdAtMs,
    required int atMs,
    NodeId? channelId,
  }) => spaceRetentionRemoves(
    revisions: retentionHistory,
    createdAtMs: createdAtMs,
    atMs: atMs,
    channelId: channelId,
  );

  bool isRetentionMediaExpired({
    required int createdAtMs,
    required int atMs,
    NodeId? channelId,
  }) => spaceRetentionRemovesMedia(
    revisions: retentionHistory,
    createdAtMs: createdAtMs,
    atMs: atMs,
    channelId: channelId,
  );

  GroupMember? memberOf(NodeId id) => members[id.hex];
  bool isMember(NodeId id) => members.containsKey(id.hex);
  GroupRole? roleOf(NodeId id) => members[id.hex]?.role;
  Set<String> customRoleIdsOf(NodeId id) =>
      accessPolicy?.roleIdsFor(id) ?? const {};
  Set<SpacePermissionGrant> customGrantsOf(NodeId id) =>
      accessPolicy?.grantsFor(id) ?? const {};
  Set<SpacePermissionDenial> customDenialsOf(NodeId id) =>
      accessPolicy?.denialsFor(id) ?? const {};
  Set<SpacePermission> customPermissionsOf(NodeId id) =>
      accessPolicy?.permissionsFor(id) ?? const {};
  SpacePostPin? postPinFor(String postId) => postPins[postId];
  SpaceRecommendationCampaign? recommendationCampaignFor(String campaignId) =>
      recommendationCampaigns[campaignId];

  /// The initial state of a group: the owner (genesis) is the sole member.
  factory GroupState.genesis(NodeId owner, [String name = '']) => GroupState._(
    {owner.hex: GroupMember(nodeId: owner, role: GroupRole.owner)},
    0,
    0,
    null,
    const [],
    name,
    '',
    null,
    const {},
    const {},
    const {},
    const {},
    const {},
    const {},
    const {},
    const [],
    const {},
    const {},
    SpaceLifecycleState.active,
    null,
    null,
  );
}

/// Stable, local reason for an authorization refusal.
///
/// The reason is deliberately not sent to an untrusted peer: node ingress
/// keeps its silent-drop behaviour and may only use this value for local logs
/// and tests.
enum SpaceAuthorizationDenial {
  notMember,
  deleted,
  archived,
  muted,
  moderated,
  explicitlyDenied,
  insufficientPermission,
  protectedTarget,
  selfEscalation,
  permissionCeiling,
}

/// Typed result shared by API, background work, log folding and media grants.
final class SpaceAuthorizationDecision {
  const SpaceAuthorizationDecision.allow() : allowed = true, denial = null;

  const SpaceAuthorizationDecision.deny(this.denial) : allowed = false;

  final bool allowed;
  final SpaceAuthorizationDenial? denial;
}

/// Deterministic Space authorization gate evaluated by every local node.
///
/// UI affordances may consult it, but authority belongs here: API/service
/// mutations, background work, sync/materialization and media delivery all
/// call the same evaluator. Protocol-specific signature, freshness and replay
/// checks remain layered around this decision.
final class SpaceAcl {
  const SpaceAcl(this.state);

  final GroupState state;

  SpaceAuthorizationDecision authorize(
    NodeId actor,
    SpacePermission permission, {
    int? atMs,
    NodeId? channelId,
    NodeId? categoryId,
  }) {
    final member = state.memberOf(actor);
    if (member == null) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.notMember,
      );
    }
    // Recoverable deletion keeps the signed roster only so the owner can
    // restore it. Current content and mutation APIs must reveal nothing.
    if (state.isDeleted && atMs == null) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.deleted,
      );
    }
    // A current mutation has no historical timestamp and is closed while the
    // Space is archived. Read/materialization paths deliberately evaluate the
    // author's permission at the signed content timestamp; the lifecycle head
    // separately proves that the row belongs to the archived readable prefix.
    if (state.isArchived &&
        atMs == null &&
        permission != SpacePermission.view &&
        permission != SpacePermission.distributeContent) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.archived,
      );
    }
    final effectiveAt = atMs ?? DateTime.now().millisecondsSinceEpoch;
    final actions = state.activeModerationFor(actor, effectiveAt);
    bool appliesToChannel(SpaceModerationAction action) =>
        action.scope != SpaceModerationScope.channel ||
        action.channelId == channelId;
    final blocksMessages = actions.any(
      (record) =>
          record.action.kind.blocksMessages && appliesToChannel(record.action),
    );
    final blocksPosts = actions.any((record) => record.action.kind.blocksPosts);
    final blocksVoice = actions.any(
      (record) =>
          record.action.kind.blocksVoice && appliesToChannel(record.action),
    );
    final publicChannel = channelId == null
        ? null
        : state.channels[channelId.hex];
    final effectiveCategoryId =
        categoryId ??
        (publicChannel?.kind == SpaceChannelKind.category
            ? publicChannel?.channelId
            : publicChannel?.categoryId);
    final explicitlyDenied =
        member.role != GroupRole.owner &&
        (state.accessPolicy?.denies(
              actor,
              permission,
              channelId: channelId,
              categoryId: effectiveCategoryId,
            ) ??
            false);
    if (explicitlyDenied) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.explicitlyDenied,
      );
    }
    bool customAllows(SpacePermission permission) =>
        state.accessPolicy?.allows(
          actor,
          permission,
          channelId: channelId,
          categoryId: effectiveCategoryId,
        ) ??
        false;
    bool builtInOrCustom(bool builtIn, SpacePermission permission) =>
        builtIn || customAllows(permission);
    final denial = switch (permission) {
      SpacePermission.view || SpacePermission.distributeContent => null,
      SpacePermission.publishMessages when member.muted =>
        SpaceAuthorizationDenial.muted,
      SpacePermission.publishMessages when blocksMessages =>
        SpaceAuthorizationDenial.moderated,
      SpacePermission.publishMessages => null,
      SpacePermission.publishPosts when member.muted =>
        SpaceAuthorizationDenial.muted,
      SpacePermission.publishPosts when blocksPosts =>
        SpaceAuthorizationDenial.moderated,
      SpacePermission.publishPosts => null,
      SpacePermission.managePosts =>
        builtInOrCustom(member.role.rank >= GroupRole.admin.rank, permission)
            ? null
            : SpaceAuthorizationDenial.insufficientPermission,
      SpacePermission.manageRecommendations =>
        builtInOrCustom(member.role.rank >= GroupRole.admin.rank, permission)
            ? null
            : SpaceAuthorizationDenial.insufficientPermission,
      SpacePermission.enterVoice when blocksVoice =>
        SpaceAuthorizationDenial.moderated,
      SpacePermission.enterVoice => null,
      SpacePermission.manageMembers ||
      SpacePermission.manageRoles ||
      SpacePermission.moderate ||
      SpacePermission.manageEncryption =>
        builtInOrCustom(member.role.rank >= GroupRole.admin.rank, permission)
            ? null
            : SpaceAuthorizationDenial.insufficientPermission,
      SpacePermission.manageChannels =>
        builtInOrCustom(member.role.rank >= GroupRole.admin.rank, permission)
            ? null
            : SpaceAuthorizationDenial.insufficientPermission,
      SpacePermission.manageSettings || SpacePermission.manageStorage =>
        builtInOrCustom(member.role == GroupRole.owner, permission)
            ? null
            : SpaceAuthorizationDenial.insufficientPermission,
    };
    return denial == null
        ? const SpaceAuthorizationDecision.allow()
        : SpaceAuthorizationDecision.deny(denial);
  }

  bool allows(
    NodeId actor,
    SpacePermission permission, {
    int? atMs,
    NodeId? channelId,
    NodeId? categoryId,
  }) => authorize(
    actor,
    permission,
    atMs: atMs,
    channelId: channelId,
    categoryId: categoryId,
  ).allowed;

  /// Whether a management surface has at least one usable target. This is for
  /// showing category/channel-scoped controls; the eventual mutation must call
  /// [allows] again with its exact target.
  bool allowsAnyScope(NodeId actor, SpacePermission permission) {
    if (allows(actor, permission)) return true;
    if (state.memberOf(actor) == null || state.isDeleted || state.isArchived) {
      return false;
    }
    for (final channel in state.channels.values) {
      final categoryId = channel.kind == SpaceChannelKind.category
          ? channel.channelId
          : channel.categoryId;
      if (allows(
        actor,
        permission,
        channelId: channel.channelId,
        categoryId: categoryId,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Authorize a current control mutation against this complete folded state.
  ///
  /// Moving a channel crosses both its old and new scopes. A scoped delegate
  /// therefore needs a grant on both sides, while a built-in admin remains
  /// authorized by the rank model.
  SpaceAuthorizationDecision authorizeControl(
    NodeId author,
    ControlOp op, {
    NodeId? target,
    GroupRole? newRole,
    NodeId? channelId,
    NodeId? categoryId,
    NodeId? previousChannelId,
    NodeId? previousCategoryId,
    bool protectedModeration = false,
    bool moderationTargetsRemovedContent = false,
    bool revokesRemovedMember = false,
  }) {
    final member = state.memberOf(author);
    if (member == null) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.notMember,
      );
    }
    if (state.isDeleted && op != ControlOp.restoreSpace) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.deleted,
      );
    }
    if (state.isArchived &&
        op != ControlOp.restoreSpace &&
        op != ControlOp.deleteSpace) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.archived,
      );
    }
    if (state.isActive && op == ControlOp.restoreSpace) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.insufficientPermission,
      );
    }
    return authorizeControlContext(
      author: author,
      authorRole: member.role,
      policy: state.accessPolicy,
      op: op,
      targetRole: target == null ? null : state.roleOf(target),
      newRole: newRole,
      target: target,
      channelId: channelId,
      categoryId: categoryId,
      previousChannelId: previousChannelId,
      previousCategoryId: previousCategoryId,
      protectedModeration: protectedModeration,
      moderationTargetsRemovedContent: moderationTargetsRemovedContent,
      revokesRemovedMember: revokesRemovedMember,
    );
  }

  /// Authorize one complete access-policy transition.
  ///
  /// The current policy is always the source of the actor's authority. A
  /// delegate cannot bootstrap new authority inside [nextPolicy], cannot touch
  /// their own effective roles, and cannot create, edit, remove or assign a
  /// role outside their current capability envelope. `manageRoles` itself is
  /// the strict boundary, so every role a delegate manages is below them.
  SpaceAuthorizationDecision authorizePolicyChange(
    NodeId author,
    SpaceAccessPolicy nextPolicy,
  ) {
    final control = authorizeControl(author, ControlOp.setPolicy);
    if (!control.allowed) return control;
    final member = state.memberOf(author);
    if (member == null) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.notMember,
      );
    }
    return authorizePolicyChangeContext(
      author: author,
      authorRole: member.role,
      policy: state.accessPolicy,
      nextPolicy: nextPolicy,
      members: state.members,
      channels: state.channels,
    );
  }

  /// Whether [role] is strictly below the actor's current management ceiling.
  /// Used by editors only; [authorizePolicyChange] remains authoritative.
  bool canDelegateRole(NodeId actor, SpaceRoleDefinition role) {
    final member = state.memberOf(actor);
    if (member == null ||
        !authorizeControl(actor, ControlOp.setPolicy).allowed) {
      return false;
    }
    return member.role == GroupRole.owner ||
        _roleWithinCeiling(
          actor: actor,
          authorRole: member.role,
          policy: state.accessPolicy,
          role: role,
          channels: state.channels,
        );
  }

  /// Conservative editor predicate for one grant/deny scope.
  bool canDelegateRule(
    NodeId actor,
    SpacePermission permission,
    SpacePermissionScope scope,
  ) {
    final member = state.memberOf(actor);
    if (member == null ||
        !authorizeControl(actor, ControlOp.setPolicy).allowed) {
      return false;
    }
    if (member.role == GroupRole.owner) return true;
    if (permission == SpacePermission.manageRoles) return false;
    var applies = false;
    for (final context in _permissionContexts(state.channels)) {
      if (!scope.appliesTo(
        channelId: context.channelId,
        categoryId: context.categoryId,
      )) {
        continue;
      }
      applies = true;
      if (!_allowsPermissionInContext(
        actor: actor,
        actorRole: member.role,
        policy: state.accessPolicy,
        permission: permission,
        channelId: context.channelId,
        categoryId: context.categoryId,
      )) {
        return false;
      }
    }
    return applies;
  }

  bool canManageAccessRole(NodeId actor, SpaceRoleDefinition role) {
    final member = state.memberOf(actor);
    if (member == null ||
        !authorizeControl(actor, ControlOp.setPolicy).allowed) {
      return false;
    }
    if (member.role == GroupRole.owner) return true;
    if (!canDelegateRole(actor, role)) return false;
    final policy = state.accessPolicy;
    if (policy == null) return true;
    for (final target in state.members.values) {
      if (!policy.roleIdsFor(target.nodeId).contains(role.roleId)) continue;
      if (!_canManagePolicyTarget(actor, target, policy)) {
        return false;
      }
    }
    return true;
  }

  bool canManageAccessGroup(NodeId actor, SpaceMemberGroup group) {
    final member = state.memberOf(actor);
    if (member == null ||
        !authorizeControl(actor, ControlOp.setPolicy).allowed) {
      return false;
    }
    if (member.role == GroupRole.owner) return true;
    final policy = state.accessPolicy;
    if (policy == null) return false;
    for (final roleId in group.roleIds) {
      final role = policy.role(roleId);
      if (role == null || !canDelegateRole(actor, role)) return false;
    }
    for (final targetId in group.members) {
      final target = state.memberOf(targetId);
      if (target == null || !_canManagePolicyTarget(actor, target, policy)) {
        return false;
      }
    }
    return true;
  }

  bool canManageDirectRolesOf(NodeId actor, NodeId targetId) {
    final member = state.memberOf(actor);
    final target = state.memberOf(targetId);
    if (member == null ||
        target == null ||
        !authorizeControl(actor, ControlOp.setPolicy).allowed) {
      return false;
    }
    if (member.role == GroupRole.owner) return true;
    final policy = state.accessPolicy;
    if (!_canManagePolicyTarget(actor, target, policy)) {
      return false;
    }
    final direct = policy?.directAssignments
        .where((assignment) => assignment.member == targetId)
        .firstOrNull;
    for (final roleId in direct?.roleIds ?? const <String>[]) {
      final role = policy?.role(roleId);
      if (role == null || !canDelegateRole(actor, role)) return false;
    }
    return true;
  }

  bool canManagePolicyTarget(NodeId actor, NodeId targetId) {
    final member = state.memberOf(actor);
    final target = state.memberOf(targetId);
    if (member == null ||
        target == null ||
        !authorizeControl(actor, ControlOp.setPolicy).allowed) {
      return false;
    }
    return member.role == GroupRole.owner ||
        _canManagePolicyTarget(actor, target, state.accessPolicy);
  }

  bool allowsControl(
    NodeId author,
    ControlOp op, {
    NodeId? target,
    GroupRole? newRole,
    NodeId? channelId,
    NodeId? categoryId,
    NodeId? previousChannelId,
    NodeId? previousCategoryId,
    bool protectedModeration = false,
    bool moderationTargetsRemovedContent = false,
    bool revokesRemovedMember = false,
  }) => authorizeControl(
    author,
    op,
    target: target,
    newRole: newRole,
    channelId: channelId,
    categoryId: categoryId,
    previousChannelId: previousChannelId,
    previousCategoryId: previousCategoryId,
    protectedModeration: protectedModeration,
    moderationTargetsRemovedContent: moderationTargetsRemovedContent,
    revokesRemovedMember: revokesRemovedMember,
  ).allowed;

  /// Low-level form used while the control log is being folded and no complete
  /// [GroupState] exists yet. All rank, custom-policy and protected-target
  /// decisions still converge here.
  static SpaceAuthorizationDecision authorizeControlContext({
    required NodeId author,
    required GroupRole authorRole,
    required SpaceAccessPolicy? policy,
    required ControlOp op,
    GroupRole? targetRole,
    GroupRole? newRole,
    NodeId? target,
    NodeId? channelId,
    NodeId? categoryId,
    NodeId? previousChannelId,
    NodeId? previousCategoryId,
    bool protectedModeration = false,
    bool moderationTargetsRemovedContent = false,
    bool revokesRemovedMember = false,
    bool allowDelegatedPolicy = true,
  }) {
    final builtIn = roleAllowsControl(
      authorRole: authorRole,
      op: op,
      targetRole: targetRole,
      newRole: newRole,
    );
    final custom = customPolicyAllowsControl(
      policy: policy,
      author: author,
      op: op,
      targetRole: targetRole,
      newRole: newRole,
      target: target,
      channelId: channelId,
      categoryId: categoryId,
    );
    final sourceExplicitlyDenied =
        op == ControlOp.updateChannel &&
        previousChannelId != null &&
        (policy?.denies(
              author,
              SpacePermission.manageChannels,
              channelId: previousChannelId,
              categoryId: previousCategoryId,
            ) ??
            false);
    final explicitlyDenied =
        authorRole != GroupRole.owner &&
        (customPolicyDeniesControl(
              policy: policy,
              author: author,
              op: op,
              channelId: channelId,
              categoryId: categoryId,
            ) ||
            sourceExplicitlyDenied);
    final sourceScopeAllows =
        op != ControlOp.updateChannel ||
        previousChannelId == null ||
        (policy?.allows(
              author,
              SpacePermission.manageChannels,
              channelId: previousChannelId,
              categoryId: previousCategoryId,
            ) ??
            false);
    final delegatedPolicy =
        allowDelegatedPolicy &&
        op == ControlOp.setPolicy &&
        (authorRole.rank >= GroupRole.admin.rank ||
            (policy?.allows(author, SpacePermission.manageRoles) ?? false));
    final allowed =
        !explicitlyDenied &&
        (protectedModeration
            ? authorRole.rank >= GroupRole.admin.rank ||
                  (policy?.allows(
                        author,
                        SpacePermission.moderate,
                        channelId: channelId,
                        categoryId: categoryId,
                      ) ??
                      false)
            : moderationTargetsRemovedContent && targetRole == null
            ? authorRole == GroupRole.owner
            : op == ControlOp.revokeModeration && targetRole == null
            ? revokesRemovedMember && authorRole == GroupRole.owner
            : builtIn || delegatedPolicy || (custom && sourceScopeAllows));
    if (allowed) return const SpaceAuthorizationDecision.allow();
    final rankProtected =
        targetRole != null && targetRole.rank >= authorRole.rank ||
        newRole != null && newRole.rank >= authorRole.rank ||
        target == author &&
            {
              ControlOp.removeMember,
              ControlOp.ban,
              ControlOp.mute,
              ControlOp.unmute,
              ControlOp.moderate,
              ControlOp.revokeModeration,
            }.contains(op);
    return SpaceAuthorizationDecision.deny(
      explicitlyDenied
          ? SpaceAuthorizationDenial.explicitlyDenied
          : rankProtected
          ? SpaceAuthorizationDenial.protectedTarget
          : SpaceAuthorizationDenial.insufficientPermission,
    );
  }

  static bool customPolicyDeniesControl({
    required SpaceAccessPolicy? policy,
    required NodeId author,
    required ControlOp op,
    NodeId? channelId,
    NodeId? categoryId,
  }) {
    if (policy == null) return false;
    bool denied(SpacePermission permission) => policy.denies(
      author,
      permission,
      channelId: channelId,
      categoryId: categoryId,
    );
    return switch (op) {
      ControlOp.setName ||
      ControlOp.setDescription ||
      ControlOp.publishRules => denied(SpacePermission.manageSettings),
      ControlOp.createChannel ||
      ControlOp.updateChannel => denied(SpacePermission.manageChannels),
      ControlOp.setRetention => denied(SpacePermission.manageStorage),
      ControlOp.setPostPin => denied(SpacePermission.managePosts),
      ControlOp.setRecommendationCampaign => denied(
        SpacePermission.manageRecommendations,
      ),
      ControlOp.rotateEpoch => denied(SpacePermission.manageEncryption),
      ControlOp.addMember ||
      ControlOp.removeMember ||
      ControlOp.ban ||
      ControlOp.mute ||
      ControlOp.unmute => denied(SpacePermission.manageMembers),
      ControlOp.moderate ||
      ControlOp.revokeModeration => denied(SpacePermission.moderate),
      ControlOp.setPolicy => denied(SpacePermission.manageRoles),
      ControlOp.setRole ||
      ControlOp.transferOwnership ||
      ControlOp.archiveSpace ||
      ControlOp.deleteSpace ||
      ControlOp.restoreSpace ||
      ControlOp.checkpoint ||
      ControlOp.acceptRules ||
      ControlOp.leave => false,
    };
  }

  /// Custom-role control authorization for routine operations. V20 policy
  /// edits use the stricter transition-aware gate above; ownership/lifecycle
  /// changes and built-in role promotion remain non-delegable here.
  static bool customPolicyAllowsControl({
    required SpaceAccessPolicy? policy,
    required NodeId author,
    required ControlOp op,
    GroupRole? targetRole,
    GroupRole? newRole,
    NodeId? target,
    NodeId? channelId,
    NodeId? categoryId,
  }) {
    if (policy == null) return false;
    bool has(SpacePermission permission) => policy.allows(
      author,
      permission,
      channelId: channelId,
      categoryId: categoryId,
    );
    switch (op) {
      case ControlOp.setName:
      case ControlOp.setDescription:
      case ControlOp.publishRules:
        return has(SpacePermission.manageSettings);
      case ControlOp.createChannel:
      case ControlOp.updateChannel:
        return has(SpacePermission.manageChannels);
      case ControlOp.setRetention:
        return has(SpacePermission.manageStorage);
      case ControlOp.setPostPin:
        return has(SpacePermission.managePosts);
      case ControlOp.setRecommendationCampaign:
        return has(SpacePermission.manageRecommendations);
      case ControlOp.rotateEpoch:
        return has(SpacePermission.manageEncryption);
      case ControlOp.addMember:
        return has(SpacePermission.manageMembers) &&
            (newRole ?? GroupRole.member) == GroupRole.member;
      case ControlOp.removeMember:
      case ControlOp.ban:
      case ControlOp.mute:
      case ControlOp.unmute:
        return has(SpacePermission.manageMembers) &&
            target != author &&
            targetRole == GroupRole.member;
      case ControlOp.moderate:
      case ControlOp.revokeModeration:
        return has(SpacePermission.moderate) &&
            target != author &&
            targetRole == GroupRole.member;
      case ControlOp.setPolicy:
      case ControlOp.setRole:
      case ControlOp.transferOwnership:
      case ControlOp.archiveSpace:
      case ControlOp.deleteSpace:
      case ControlOp.restoreSpace:
      case ControlOp.checkpoint:
      case ControlOp.acceptRules:
      case ControlOp.leave:
        return false;
    }
  }

  /// Role-level rule used during the causal control-log fold. Targets at the
  /// same or a higher rank are protected and an actor can never grant a role
  /// at or above their own rank.
  static bool roleAllowsControl({
    required GroupRole authorRole,
    required ControlOp op,
    GroupRole? targetRole,
    GroupRole? newRole,
  }) {
    switch (op) {
      case ControlOp.setPolicy:
      case ControlOp.setRetention:
      case ControlOp.archiveSpace:
      case ControlOp.deleteSpace:
      case ControlOp.restoreSpace:
        return authorRole == GroupRole.owner;
      case ControlOp.transferOwnership:
        return authorRole == GroupRole.owner &&
            targetRole != null &&
            targetRole != GroupRole.owner;
      case ControlOp.setName:
      case ControlOp.setDescription:
      case ControlOp.rotateEpoch:
      case ControlOp.createChannel:
      case ControlOp.updateChannel:
      case ControlOp.setPostPin:
      case ControlOp.setRecommendationCampaign:
        return authorRole.rank >= GroupRole.admin.rank;
      case ControlOp.publishRules:
        return authorRole == GroupRole.owner;
      case ControlOp.checkpoint:
        // A checkpoint cannot mutate or grant authority. Any active member may
        // commit the signed causal cut they observed; post authorization is
        // still reconstructed and checked independently from its leaves.
        return true;
      case ControlOp.acceptRules:
        // A member may only acknowledge for themselves. Shape/current-version
        // checks happen in the fold; the operation grants no authority.
        return true;
      case ControlOp.moderate:
      case ControlOp.revokeModeration:
        if (targetRole == null) return false;
        return authorRole.rank >= GroupRole.admin.rank &&
            targetRole.rank < authorRole.rank;
      case ControlOp.addMember:
        final role = newRole ?? GroupRole.member;
        return authorRole.rank >= GroupRole.admin.rank &&
            role.rank < authorRole.rank;
      case ControlOp.setRole:
        if (newRole == null || targetRole == null) return false;
        return authorRole.rank >= GroupRole.admin.rank &&
            targetRole.rank < authorRole.rank &&
            newRole.rank < authorRole.rank;
      case ControlOp.removeMember:
      case ControlOp.ban:
      case ControlOp.mute:
      case ControlOp.unmute:
        if (targetRole == null) return false;
        return authorRole.rank >= GroupRole.admin.rank &&
            targetRole.rank < authorRole.rank;
      case ControlOp.leave:
        return authorRole != GroupRole.owner;
    }
  }

  /// Pure policy-transition gate used by both the live service and causal fold.
  static SpaceAuthorizationDecision authorizePolicyChangeContext({
    required NodeId author,
    required GroupRole authorRole,
    required SpaceAccessPolicy? policy,
    required SpaceAccessPolicy nextPolicy,
    required Map<String, GroupMember> members,
    required Map<String, SpaceChannel> channels,
  }) {
    if (authorRole == GroupRole.owner) {
      return const SpaceAuthorizationDecision.allow();
    }
    if (!_allowsPermissionInContext(
      actor: author,
      actorRole: authorRole,
      policy: policy,
      permission: SpacePermission.manageRoles,
    )) {
      return const SpaceAuthorizationDecision.deny(
        SpaceAuthorizationDenial.insufficientPermission,
      );
    }

    final currentRoles = {
      for (final role in policy?.roles ?? const <SpaceRoleDefinition>[])
        role.roleId: role,
    };
    final nextRoles = {for (final role in nextPolicy.roles) role.roleId: role};
    final changedRoleIds = <String>{...currentRoles.keys, ...nextRoles.keys}
        .where((roleId) {
          final current = currentRoles[roleId];
          final next = nextRoles[roleId];
          return current == null ||
              next == null ||
              !_sameRoleDefinition(current, next);
        })
        .toSet();

    bool withinCeiling(SpaceRoleDefinition role) => _roleWithinCeiling(
      actor: author,
      authorRole: authorRole,
      policy: policy,
      role: role,
      channels: channels,
    );

    for (final roleId in changedRoleIds) {
      final current = currentRoles[roleId];
      final next = nextRoles[roleId];
      if ((current != null && !withinCeiling(current)) ||
          (next != null && !withinCeiling(next))) {
        return const SpaceAuthorizationDecision.deny(
          SpaceAuthorizationDenial.permissionCeiling,
        );
      }
      for (final target in members.values) {
        final affected =
            (policy?.roleIdsFor(target.nodeId).contains(roleId) ?? false) ||
            nextPolicy.roleIdsFor(target.nodeId).contains(roleId);
        if (!affected) continue;
        if (target.nodeId == author) {
          return const SpaceAuthorizationDecision.deny(
            SpaceAuthorizationDenial.selfEscalation,
          );
        }
        if (_policyTargetProtected(
          target: target,
          currentPolicy: policy,
          nextPolicy: nextPolicy,
        )) {
          return const SpaceAuthorizationDecision.deny(
            SpaceAuthorizationDenial.protectedTarget,
          );
        }
      }
    }

    for (final target in members.values) {
      final currentIds = policy?.roleIdsFor(target.nodeId) ?? const <String>{};
      final nextIds = nextPolicy.roleIdsFor(target.nodeId);
      if (_sameSet(currentIds, nextIds)) continue;
      if (target.nodeId == author) {
        return const SpaceAuthorizationDecision.deny(
          SpaceAuthorizationDenial.selfEscalation,
        );
      }
      if (_policyTargetProtected(
        target: target,
        currentPolicy: policy,
        nextPolicy: nextPolicy,
      )) {
        return const SpaceAuthorizationDecision.deny(
          SpaceAuthorizationDenial.protectedTarget,
        );
      }
      final changedAssignments = <String>{...currentIds, ...nextIds}
        ..removeWhere(
          (roleId) => currentIds.contains(roleId) && nextIds.contains(roleId),
        );
      for (final roleId in changedAssignments) {
        final current = currentRoles[roleId];
        final next = nextRoles[roleId];
        if ((current != null && !withinCeiling(current)) ||
            (next != null && !withinCeiling(next))) {
          return const SpaceAuthorizationDecision.deny(
            SpaceAuthorizationDenial.permissionCeiling,
          );
        }
      }
    }
    return const SpaceAuthorizationDecision.allow();
  }

  bool _canManagePolicyTarget(
    NodeId actor,
    GroupMember target,
    SpaceAccessPolicy? policy,
  ) =>
      target.nodeId != actor &&
      !_policyTargetProtected(
        target: target,
        currentPolicy: policy,
        nextPolicy: policy,
      );

  static bool _policyTargetProtected({
    required GroupMember target,
    required SpaceAccessPolicy? currentPolicy,
    required SpaceAccessPolicy? nextPolicy,
  }) {
    if (target.role != GroupRole.member) return true;
    return _allowsPermissionInContext(
          actor: target.nodeId,
          actorRole: target.role,
          policy: currentPolicy,
          permission: SpacePermission.manageRoles,
        ) ||
        _allowsPermissionInContext(
          actor: target.nodeId,
          actorRole: target.role,
          policy: nextPolicy,
          permission: SpacePermission.manageRoles,
        );
  }

  static bool _roleWithinCeiling({
    required NodeId actor,
    required GroupRole authorRole,
    required SpaceAccessPolicy? policy,
    required SpaceRoleDefinition role,
    required Map<String, SpaceChannel> channels,
  }) {
    for (final context in _permissionContexts(channels)) {
      for (final permission in SpacePermission.values) {
        if (!role.allows(
          permission,
          channelId: context.channelId,
          categoryId: context.categoryId,
        )) {
          continue;
        }
        if (permission == SpacePermission.manageRoles ||
            !_allowsPermissionInContext(
              actor: actor,
              actorRole: authorRole,
              policy: policy,
              permission: permission,
              channelId: context.channelId,
              categoryId: context.categoryId,
            )) {
          return false;
        }
      }
    }
    return true;
  }

  static Iterable<({NodeId? channelId, NodeId? categoryId})>
  _permissionContexts(Map<String, SpaceChannel> channels) sync* {
    yield (channelId: null, categoryId: null);
    for (final channel in channels.values) {
      yield (
        channelId: channel.channelId,
        categoryId: channel.kind == SpaceChannelKind.category
            ? channel.channelId
            : channel.categoryId,
      );
    }
  }

  static bool _allowsPermissionInContext({
    required NodeId actor,
    required GroupRole actorRole,
    required SpaceAccessPolicy? policy,
    required SpacePermission permission,
    NodeId? channelId,
    NodeId? categoryId,
  }) {
    if (actorRole == GroupRole.owner) return true;
    if (policy?.denies(
          actor,
          permission,
          channelId: channelId,
          categoryId: categoryId,
        ) ??
        false) {
      return false;
    }
    final builtIn = switch (permission) {
      SpacePermission.view ||
      SpacePermission.distributeContent ||
      SpacePermission.publishMessages ||
      SpacePermission.publishPosts ||
      SpacePermission.enterVoice => true,
      SpacePermission.managePosts ||
      SpacePermission.manageRecommendations ||
      SpacePermission.manageMembers ||
      SpacePermission.manageRoles ||
      SpacePermission.moderate ||
      SpacePermission.manageEncryption ||
      SpacePermission.manageChannels => actorRole.rank >= GroupRole.admin.rank,
      SpacePermission.manageSettings || SpacePermission.manageStorage => false,
    };
    return builtIn ||
        (policy?.allows(
              actor,
              permission,
              channelId: channelId,
              categoryId: categoryId,
            ) ??
            false);
  }

  static bool _sameRoleDefinition(
    SpaceRoleDefinition left,
    SpaceRoleDefinition right,
  ) =>
      left.roleId == right.roleId &&
      left.name == right.name &&
      left.usesScopedEncoding == right.usesScopedEncoding &&
      _sameSet(left.grants.toSet(), right.grants.toSet()) &&
      _sameSet(left.denials.toSet(), right.denials.toSet());

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);
}

/// Whether [author] (at [authorRole]) may apply [op] to [targetRole] under the
/// current state. Pure predicate — the fold uses it, and tests hit it directly.
bool canApply({
  required GroupRole authorRole,
  required ControlOp op,
  GroupRole? targetRole, // the target's CURRENT role, if it's a member
  GroupRole? newRole, // the requested role for addMember/setRole
}) {
  return SpaceAcl.roleAllowsControl(
    authorRole: authorRole,
    op: op,
    targetRole: targetRole,
    newRole: newRole,
  );
}

/// The outcome of folding a log: the resulting state plus the entries that
/// were REJECTED (invalid author perms / bad chaining / duplicate seq), for
/// diagnostics — a rejected entry is never applied.
class GroupFoldResult {
  const GroupFoldResult(this.state, this.rejected, [this.accepted = const []]);
  final GroupState state;
  final List<ControlEntry> rejected;
  final List<ControlEntry> accepted;
}

/// Replay [entries] over the genesis state. Entries are grouped by author and
/// applied in per-author seq order (author_seq is the ordering the design
/// fixes; cross-author order falls out of seq+time, but permission checks make
/// the fold convergent regardless of interleaving because a rejected op simply
/// doesn't apply). [verify] checks an entry's signature (injected so this stays
/// pure — the app passes the native ed25519 verifier; tests pass a fake).
GroupFoldResult foldControlLog({
  required NodeId owner,
  required List<ControlEntry> entries,
  required bool Function(ControlEntry entry) verify,
  String initialName = '',
  String initialDescription = '',
}) {
  final members = <String, GroupMember>{
    // Genesis owner predates every possible message timestamp, including the
    // deterministic timestamp 0 used by tests/imports.
    owner.hex: GroupMember(
      nodeId: owner,
      role: GroupRole.owner,
      joinedAtMs: -1,
    ),
  };
  var epoch = 0;
  var policyVersion = 0;
  SpaceAccessPolicy? accessPolicy;
  final accessPolicyHistory = <SpaceAccessPolicy>[];
  var name = initialName;
  var description = initialDescription;
  GroupEpochDescriptor? epochDescriptor;
  final channels = <String, SpaceChannel>{};
  final protectedChannels = <String, SpaceChannelControlEnvelope>{};
  final rulesHistory = <int, SpaceRulesVersion>{};
  final rulesAcceptances = <String, SpaceRulesAcceptance>{};
  final moderationRecords = <String, SpaceModerationRecord>{};
  final protectedModeration = <String, SpaceChannelModerationEnvelope>{};
  final protectedRetention = <String, SpaceChannelRetentionEnvelope>{};
  final retentionHistory = <SpaceRetentionRevision>[];
  final postPins = <String, SpacePostPin>{};
  final recommendationCampaigns = <String, SpaceRecommendationCampaign>{};
  var lifecycleState = SpaceLifecycleState.active;
  SpaceLifecycleTransition? lifecycleTransition;
  String? lifecycleTransitionHash;
  var lastRetentionActivationMs = 0;
  final rejected = <ControlEntry>[];
  final accepted = <ControlEntry>[];

  // Verify before fork selection: an invalid signature with a deliberately
  // small hash must never suppress the valid row for the same `(author,seq)`.
  // Multiple byte-identical deliveries deduplicate. Two distinct valid signed
  // rows for the same identity are equivocation: fail closed by rejecting the
  // fork point and every later row from that author. ACL authority must not be
  // picked by an arbitrary hash lottery, even a deterministic one.
  final byIdentity = <String, List<ControlEntry>>{};
  for (final e in entries) {
    if (!e.isStructurallyValid || !verify(e)) {
      rejected.add(e);
      continue;
    }
    byIdentity.putIfAbsent('${e.author.hex}:${e.seq}', () => []).add(e);
  }

  final byAuthor = <String, List<ControlEntry>>{};
  final forkedAt = <String, int>{};
  for (final candidates in byIdentity.values) {
    final distinct = <String, ControlEntry>{
      for (final candidate in candidates)
        controlEntryHash(candidate): candidate,
    };
    if (distinct.length > 1) {
      rejected.addAll(candidates);
      final sample = candidates.first;
      final current = forkedAt[sample.author.hex];
      if (current == null || sample.seq < current) {
        forkedAt[sample.author.hex] = sample.seq;
      }
      continue;
    }
    final winner = distinct.values.single;
    byAuthor.putIfAbsent(winner.author.hex, () => []).add(winner);
  }

  // Deterministic causal merge: each author's seq order is inviolable even if
  // wall clock moves backwards between two signed operations. Across authors,
  // select the earliest current head by (createdAtMs, author hex, seq). A plain
  // global timestamp sort would reorder seq 1 before seq 0 after a clock step,
  // rejecting the earlier operation and diverging membership across devices.
  final ordered = <ControlEntry>[];
  for (final list in byAuthor.values) {
    list.sort((a, b) => a.seq.compareTo(b.seq));
  }
  int compareHeads(ControlEntry a, ControlEntry b) {
    final t = a.createdAtMs.compareTo(b.createdAtMs);
    if (t != 0) return t;
    final h = a.author.hex.compareTo(b.author.hex);
    if (h != 0) return h;
    return a.seq.compareTo(b.seq);
  }

  final heads = SplayTreeSet<({String author, int index, ControlEntry entry})>(
    (a, b) => compareHeads(a.entry, b.entry),
  );
  for (final author in byAuthor.keys) {
    heads.add((author: author, index: 0, entry: byAuthor[author]!.first));
  }
  while (heads.isNotEmpty) {
    final head = heads.first;
    heads.remove(head);
    ordered.add(head.entry);
    final nextIndex = head.index + 1;
    final authored = byAuthor[head.author]!;
    if (nextIndex < authored.length) {
      heads.add((
        author: head.author,
        index: nextIndex,
        entry: authored[nextIndex],
      ));
    }
  }

  final lastSeq = <String, int>{};
  final lastEntry = <String, ControlEntry>{};
  for (final e in ordered) {
    final forkSeq = forkedAt[e.author.hex];
    if (forkSeq != null && e.seq >= forkSeq) {
      rejected.add(e);
      continue;
    }
    // Legacy V1 only promised monotonic seq. V2 is contiguous and binds the
    // exact previous accepted signed row. Once an author emits V2 it can never
    // downgrade back to V1.
    final prev = lastSeq[e.author.hex];
    final predecessor = lastEntry[e.author.hex];
    final v2ChainInvalid =
        e.version >= 2 &&
        (predecessor == null
            ? e.seq != 0 || e.prevHash.isNotEmpty
            : e.seq != predecessor.seq + 1 ||
                  e.prevHash != controlEntryHash(predecessor));
    final legacyOrderInvalid =
        e.version == 1 &&
        (prev != null && (e.seq <= prev || (predecessor?.version ?? 1) >= 2));
    if (v2ChainInvalid || legacyOrderInvalid) {
      rejected.add(e);
      continue;
    }
    final authorRole = members[e.author.hex]?.role;
    if (authorRole == null) {
      rejected.add(e); // author isn't a member
      continue;
    }
    if (e.policyVersion != policyVersion) {
      rejected.add(e); // stale/future authorization context: fail closed
      continue;
    }
    if ((lifecycleState == SpaceLifecycleState.archived &&
            e.op != ControlOp.restoreSpace &&
            e.op != ControlOp.deleteSpace) ||
        (lifecycleState == SpaceLifecycleState.deleted &&
            e.op != ControlOp.restoreSpace) ||
        (lifecycleState == SpaceLifecycleState.active &&
            e.op == ControlOp.restoreSpace)) {
      rejected.add(e);
      continue;
    }
    final targetRole = e.target == null ? null : members[e.target!.hex]?.role;
    final revocationRecord = e.op == ControlOp.revokeModeration
        ? moderationRecords[e.moderationRevocation?.actionId]
        : null;
    final controlChannelId =
        e.channel?.channelId ??
        e.channelControl?.channelId ??
        e.retentionPolicy?.channelId ??
        e.channelRetention?.channelId ??
        e.moderationAction?.channelId ??
        e.channelModeration?.channelId ??
        revocationRecord?.action.channelId;
    final currentControlChannel = controlChannelId == null
        ? null
        : channels[controlChannelId.hex];
    final controlCategoryId = e.channel != null
        ? e.channel!.kind == SpaceChannelKind.category
              ? e.channel!.channelId
              : e.channel!.categoryId
        : currentControlChannel?.kind == SpaceChannelKind.category
        ? currentControlChannel?.channelId
        : currentControlChannel?.categoryId;
    final moderationTargetsRemovedContent =
        e.op == ControlOp.moderate &&
        {
          SpaceModerationKind.deleteMessage,
          SpaceModerationKind.deletePost,
        }.contains(e.moderationAction?.kind);
    final protectsModeration =
        e.op == ControlOp.moderate &&
        e.version == 14 &&
        e.channelModeration != null;
    final controlDecision = SpaceAcl.authorizeControlContext(
      author: e.author,
      authorRole: authorRole,
      policy: accessPolicy,
      op: e.op,
      targetRole: targetRole,
      newRole: e.role,
      target: e.target,
      channelId: controlChannelId,
      categoryId: controlCategoryId,
      previousChannelId: e.op == ControlOp.updateChannel
          ? currentControlChannel?.channelId
          : null,
      previousCategoryId: e.op != ControlOp.updateChannel
          ? null
          : currentControlChannel?.kind == SpaceChannelKind.category
          ? currentControlChannel?.channelId
          : currentControlChannel?.categoryId,
      protectedModeration: protectsModeration,
      moderationTargetsRemovedContent: moderationTargetsRemovedContent,
      revokesRemovedMember:
          revocationRecord?.action.kind.removesMembership == true,
      allowDelegatedPolicy: e.version == 20,
    );
    final authorized = e.op == ControlOp.revokeModeration
        ? revocationRecord != null &&
              revocationRecord.revokedAtMs == null &&
              revocationRecord.action.target == e.target &&
              !{
                SpaceModerationKind.deleteMessage,
                SpaceModerationKind.deletePost,
              }.contains(revocationRecord.action.kind) &&
              controlDecision.allowed
        : controlDecision.allowed;
    if (!authorized) {
      rejected.add(e);
      continue;
    }
    final isTextSetting =
        e.op == ControlOp.setName || e.op == ControlOp.setDescription;
    if (isTextSetting) {
      if (e.text == null ||
          e.target != null ||
          e.role != null ||
          e.epochDescriptor != null ||
          e.channel != null ||
          e.channelControl != null ||
          e.postBoundary != null ||
          e.controlCheckpoint != null) {
        rejected.add(e);
        continue;
      }
    } else if (e.text != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.createChannel || e.op == ControlOp.updateChannel) {
      final channel = e.channel;
      final channelControl = e.channelControl;
      if ((channel == null) == (channelControl == null) ||
          e.groupId == null ||
          (channel != null &&
              (channel.spaceId != e.groupId ||
                  channel.access != SpaceChannelAccess.space)) ||
          (channelControl != null &&
              (channelControl.spaceId != e.groupId ||
                  !channelControl.isStructurallyValid)) ||
          e.target != null ||
          e.role != null ||
          e.text != null ||
          e.epochDescriptor != null) {
        rejected.add(e);
        continue;
      }
    } else if (e.channel != null || e.channelControl != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.checkpoint) {
      if (e.controlCheckpoint == null ||
          e.target != null ||
          e.role != null ||
          e.text != null ||
          e.epochDescriptor != null ||
          e.channel != null ||
          e.channelControl != null ||
          e.postBoundary != null) {
        rejected.add(e);
        continue;
      }
    } else if (e.controlCheckpoint != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.publishRules) {
      final rules = e.rules;
      final expectedVersion = rulesHistory.length + 1;
      if (rules == null ||
          e.version != 7 ||
          rules.author != e.author ||
          rules.publishedAtMs != e.createdAtMs ||
          rules.version != expectedVersion ||
          rules.previousVersion !=
              (expectedVersion == 1 ? null : expectedVersion - 1) ||
          e.rulesAcceptance != null) {
        rejected.add(e);
        continue;
      }
    } else if (e.op == ControlOp.acceptRules) {
      final acceptance = e.rulesAcceptance;
      final current = rulesHistory.isEmpty
          ? null
          : rulesHistory[rulesHistory.length];
      if (acceptance == null ||
          e.version != 7 ||
          e.rules != null ||
          acceptance.acceptedAtMs != e.createdAtMs ||
          current == null ||
          acceptance.rulesVersion != current.version) {
        rejected.add(e);
        continue;
      }
    } else if (e.rules != null || e.rulesAcceptance != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.moderate) {
      final action = e.moderationAction;
      final protected = e.channelModeration;
      if (protected != null) {
        final channel = protectedChannels[protected.channelId.hex];
        if (e.version != 14 ||
            protected.spaceId != e.groupId ||
            channel == null ||
            channel.channelEpoch != protected.channelEpoch ||
            e.target != null ||
            e.moderationRevocation != null) {
          rejected.add(e);
          continue;
        }
      } else {
        final channel = action?.channelId == null
            ? null
            : channels[action!.channelId!.hex];
        final channelKindValid =
            action?.scope != SpaceModerationScope.channel ||
            (channel != null &&
                !channel.archived &&
                switch (action!.kind) {
                  SpaceModerationKind.restrictVoice =>
                    channel.kind == SpaceChannelKind.voice,
                  SpaceModerationKind.deleteMessage ||
                  SpaceModerationKind.restrictMessages ||
                  SpaceModerationKind.mute =>
                    channel.kind == SpaceChannelKind.text,
                  _ => false,
                });
        if (action == null ||
            e.version != 8 ||
            action.target != e.target ||
            action.createdAtMs != e.createdAtMs ||
            !channelKindValid ||
            (action.kind == SpaceModerationKind.deleteMessage &&
                action.scope == SpaceModerationScope.channel &&
                action.reference?.channelId != action.channelId) ||
            e.moderationRevocation != null) {
          rejected.add(e);
          continue;
        }
      }
    } else if (e.op == ControlOp.revokeModeration) {
      final revocation = e.moderationRevocation;
      if (e.version != 8 ||
          revocation == null ||
          revocation.revokedAtMs != e.createdAtMs ||
          revocationRecord == null ||
          e.moderationAction != null) {
        rejected.add(e);
        continue;
      }
    } else if (e.moderationAction != null ||
        e.moderationRevocation != null ||
        e.channelModeration != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.setRetention) {
      final policy = e.retentionPolicy;
      final protected = e.channelRetention;
      if (protected != null) {
        final channel = protectedChannels[protected.channelId.hex];
        if (e.version != 15 ||
            policy != null ||
            protected.spaceId != e.groupId ||
            channel == null ||
            channel.channelEpoch != protected.channelEpoch) {
          rejected.add(e);
          continue;
        }
      } else {
        final channel = policy?.channelId == null
            ? null
            : channels[policy!.channelId!.hex];
        if (policy == null ||
            e.version != (policy.mediaOnly ? 16 : 9) ||
            !policy.isStructurallyValid ||
            (policy.channelId != null && channel == null)) {
          rejected.add(e);
          continue;
        }
      }
    } else if (e.retentionPolicy != null || e.channelRetention != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.archiveSpace ||
        e.op == ControlOp.deleteSpace ||
        e.op == ControlOp.restoreSpace) {
      final transition = e.lifecycleTransition;
      // The checkpoint is the owner's observed causal frontier, not a promise
      // that no concurrent row existed on another offline author chain. Every
      // committed head must resolve to one exact accepted signed row. A later
      // merge may add an unseen concurrent no-op checkpoint without invalidating
      // this transition; unseen policy changes still fail closed through pv.
      final checkpointResolves =
          transition != null &&
          transition.controlCheckpoint.heads.every(
            (head) => accepted.any(
              (entry) =>
                  entry.author == head.author &&
                  entry.seq == head.seq &&
                  controlEntryHash(entry) == head.hash,
            ),
          );
      final expectedPrevious = lifecycleTransitionHash ?? '';
      final restoring = e.op == ControlOp.restoreSpace;
      final deleting = e.op == ControlOp.deleteSpace;
      final previousRecovery = lifecycleTransition?.recoveryDeadlineMs;
      final expectedVersion =
          deleting ||
              (restoring && lifecycleState == SpaceLifecycleState.deleted)
          ? 11
          : 10;
      if (e.version != expectedVersion ||
          transition == null ||
          transition.spaceId != e.groupId ||
          transition.changedAtMs != e.createdAtMs ||
          transition.previousTransitionHash != expectedPrevious ||
          transition.contentPolicyVersion !=
              (restoring ? policyVersion + 1 : policyVersion) ||
          !checkpointResolves ||
          (restoring &&
              (lifecycleTransition == null ||
                  transition.contentBoundaryJson() !=
                      lifecycleTransition.contentBoundaryJson())) ||
          (deleting && transition.recoveryDeadlineMs == null) ||
          (restoring &&
              lifecycleState == SpaceLifecycleState.deleted &&
              (previousRecovery == null ||
                  transition.recoveryDeadlineMs != previousRecovery ||
                  transition.changedAtMs > previousRecovery)) ||
          (restoring &&
              lifecycleState == SpaceLifecycleState.archived &&
              transition.recoveryDeadlineMs != null)) {
        rejected.add(e);
        continue;
      }
    } else if (e.lifecycleTransition != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.setRecommendationCampaign) {
      final campaign = e.recommendationCampaign;
      var capabilityValid = campaign?.active == false;
      if (campaign?.active == true) {
        try {
          final ticket = SpaceJoinCode.parse(campaign!.joinCode);
          capabilityValid =
              ticket.spaceId == campaign.spaceId &&
              ticket.approver == campaign.createdBy &&
              !ticket.isExpiredAt(campaign.createdAtMs) &&
              ticket.createdAtMs <= campaign.createdAtMs;
        } catch (_) {
          capabilityValid = false;
        }
      }
      final previous = campaign == null
          ? null
          : recommendationCampaigns[campaign.campaignId];
      final creates = previous == null && campaign?.active == true;
      final revokes =
          previous != null &&
          previous.active &&
          campaign?.active == false &&
          campaign!.spaceId == previous.spaceId &&
          campaign.createdBy == previous.createdBy &&
          campaign.text == previous.text &&
          campaign.createdAtMs == previous.createdAtMs;
      if (e.version != 13 ||
          campaign == null ||
          campaign.spaceId != e.groupId ||
          !capabilityValid ||
          campaign.changedAtMs != e.createdAtMs ||
          (creates && campaign.createdBy != e.author) ||
          (!creates && !revokes)) {
        rejected.add(e);
        continue;
      }
    } else if (e.recommendationCampaign != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.setPolicy &&
        (e.version == 17 ||
            e.version == 18 ||
            e.version == 19 ||
            e.version == 20)) {
      final next = e.accessPolicy;
      final expectedRevision = (accessPolicy?.revision ?? 0) + 1;
      final expectedPrevious = accessPolicy?.policyHash ?? '';
      final categoryIds = {
        for (final channel in channels.values)
          if (channel.kind == SpaceChannelKind.category) channel.channelId.hex,
      };
      final channelIds = {
        for (final channel in channels.values)
          if (channel.kind != SpaceChannelKind.category) channel.channelId.hex,
        ...protectedChannels.keys,
      };
      if (next == null ||
          (e.version == 17 && next.schemaVersion != 1) ||
          (e.version == 18 && next.schemaVersion != 2) ||
          (e.version == 19 && next.schemaVersion != 3) ||
          (e.version == 20 &&
              (next.schemaVersion < 1 || next.schemaVersion > 3)) ||
          next.revision != expectedRevision ||
          next.previousPolicyHash != expectedPrevious ||
          !next.hasValidScopeTargets(
            categoryIds: categoryIds,
            channelIds: channelIds,
          ) ||
          next.groups.any(
            (group) =>
                group.members.any((member) => !members.containsKey(member.hex)),
          ) ||
          next.directAssignments.any(
            (assignment) => !members.containsKey(assignment.member.hex),
          )) {
        rejected.add(e);
        continue;
      }
      final policyDecision = SpaceAcl.authorizePolicyChangeContext(
        author: e.author,
        authorRole: authorRole,
        policy: accessPolicy,
        nextPolicy: next,
        members: members,
        channels: channels,
      );
      if (!policyDecision.allowed) {
        rejected.add(e);
        continue;
      }
    }
    final descriptor = e.epochDescriptor;
    GroupEpochDescriptor? usableDescriptor = descriptor;
    final moderationRemovesMember =
        e.op == ControlOp.moderate &&
        e.moderationAction?.kind.removesMembership == true;
    final canEstablishEpoch =
        e.op == ControlOp.removeMember ||
        e.op == ControlOp.ban ||
        moderationRemovesMember ||
        e.op == ControlOp.rotateEpoch;
    if (descriptor != null) {
      final expectedRecipients =
          e.op == ControlOp.removeMember ||
              e.op == ControlOp.ban ||
              moderationRemovesMember
          ? members.length - 1
          : members.length;
      if (!canEstablishEpoch ||
          e.groupId == null ||
          descriptor.groupId != e.groupId) {
        rejected.add(e);
        continue;
      }
      if (descriptor.epoch != epoch + 1 ||
          descriptor.recipientCount != expectedRecipients) {
        if (e.op == ControlOp.removeMember ||
            e.op == ControlOp.ban ||
            moderationRemovesMember) {
          // A concurrent, deterministically-earlier departure can invalidate
          // this author's precomputed epoch/count. Membership removal still
          // applies; its stale key proposal is ignored and the state fails
          // closed until a fresh rotate. Dropping the whole signed removal
          // would resurrect a member merely because two admins acted at once.
          usableDescriptor = null;
        } else {
          rejected.add(e);
          continue;
        }
      }
    }
    // Apply.
    switch (e.op) {
      case ControlOp.addMember:
        final id = e.target;
        if (id == null ||
            members.containsKey(id.hex) ||
            moderationRecords.values.any(
              (record) =>
                  record.action.target == id &&
                  record.action.kind.removesMembership &&
                  record.isActiveAt(e.createdAtMs),
            )) {
          rejected.add(e);
          continue;
        }
        members[id.hex] = GroupMember(
          nodeId: id,
          role: e.role ?? GroupRole.member,
          joinedAtMs: e.createdAtMs,
        );
      case ControlOp.removeMember:
      case ControlOp.ban:
        members.remove(e.target!.hex);
        epoch++; // a departure rotates the epoch (agreed design)
        epochDescriptor = usableDescriptor;
      case ControlOp.setRole:
        final m = members[e.target!.hex]!;
        members[e.target!.hex] = m.copyWith(role: e.role);
      case ControlOp.transferOwnership:
        final previousOwner = members[e.author.hex]!;
        final nextOwner = members[e.target!.hex]!;
        members[e.author.hex] = previousOwner.copyWith(role: GroupRole.admin);
        members[e.target!.hex] = nextOwner.copyWith(
          role: GroupRole.owner,
          muted: false,
        );
      case ControlOp.mute:
        final m = members[e.target!.hex]!;
        members[e.target!.hex] = m.copyWith(muted: true);
      case ControlOp.unmute:
        final m = members[e.target!.hex]!;
        members[e.target!.hex] = m.copyWith(muted: false);
      case ControlOp.rotateEpoch:
        epoch++;
        epochDescriptor = usableDescriptor;
      case ControlOp.setPolicy:
        final next = e.accessPolicy;
        if (next != null) {
          accessPolicy = next;
          accessPolicyHistory.add(next);
        }
        policyVersion++;
      case ControlOp.setRetention:
        final activatedAt = e.createdAtMs < lastRetentionActivationMs
            ? lastRetentionActivationMs
            : e.createdAtMs;
        lastRetentionActivationMs = activatedAt;
        final protected = e.channelRetention;
        if (protected != null) {
          protectedRetention['${e.author.hex}:${e.seq}'] = protected;
          break;
        }
        retentionHistory.add(
          SpaceRetentionRevision(
            policy: e.retentionPolicy!,
            activatedAtMs: activatedAt,
            author: e.author,
            authorSeq: e.seq,
          ),
        );
      case ControlOp.setPostPin:
        final pin = e.postPin!;
        postPins[pin.postId] = pin;
      case ControlOp.setRecommendationCampaign:
        final campaign = e.recommendationCampaign!;
        recommendationCampaigns[campaign.campaignId] = campaign;
      case ControlOp.archiveSpace:
      case ControlOp.deleteSpace:
      case ControlOp.restoreSpace:
        lifecycleState = e.lifecycleTransition!.state;
        lifecycleTransition = e.lifecycleTransition;
        lifecycleTransitionHash = controlEntryHash(e);
        policyVersion++;
      case ControlOp.setName:
        name = e.text ?? name;
      case ControlOp.setDescription:
        description = e.text ?? description;
      case ControlOp.publishRules:
        rulesHistory[e.rules!.version] = e.rules!;
      case ControlOp.acceptRules:
        rulesAcceptances[e.author.hex] = e.rulesAcceptance!;
      case ControlOp.moderate:
        final actionId = '${e.author.hex}:${e.seq}';
        final protected = e.channelModeration;
        if (protected != null) {
          protectedModeration[actionId] = protected;
          break;
        }
        final action = e.moderationAction!;
        moderationRecords[actionId] = SpaceModerationRecord(
          actionId: actionId,
          actor: e.author,
          actionSeq: e.seq,
          action: action,
        );
        if (action.kind.removesMembership) {
          members.remove(action.target.hex);
          epoch++;
          epochDescriptor = usableDescriptor;
        }
      case ControlOp.revokeModeration:
        final revocation = e.moderationRevocation!;
        moderationRecords[revocation.actionId] = revocationRecord!.revoke(
          actor: e.author,
          revocation: revocation,
        );
      case ControlOp.createChannel:
        final protected = e.channelControl;
        if (protected != null) {
          if (channels.containsKey(protected.channelId.hex) ||
              protectedChannels.containsKey(protected.channelId.hex) ||
              protected.channelEpoch != 1) {
            rejected.add(e);
            continue;
          }
          protectedChannels[protected.channelId.hex] = protected;
          break;
        }
        final channel = e.channel!;
        final category = channel.categoryId == null
            ? null
            : channels[channel.categoryId!.hex];
        final hasTextChannel = channels.values.any(
          (value) => value.kind == SpaceChannelKind.text && !value.archived,
        );
        if (channels.containsKey(channel.channelId.hex) ||
            protectedChannels.containsKey(channel.channelId.hex) ||
            channel.createdBy != e.author ||
            channel.createdAtMs != e.createdAtMs ||
            (channel.categoryId != null &&
                (category == null ||
                    category.kind != SpaceChannelKind.category ||
                    category.archived)) ||
            (channel.kind == SpaceChannelKind.text &&
                !hasTextChannel &&
                !channel.isDefault)) {
          rejected.add(e);
          continue;
        }
        if (channel.isDefault) {
          for (final existing in channels.entries.toList()) {
            if (existing.value.isDefault) {
              channels[existing.key] = existing.value.copyWith(
                isDefault: false,
              );
            }
          }
        }
        channels[channel.channelId.hex] = channel;
      case ControlOp.updateChannel:
        final protected = e.channelControl;
        if (protected != null) {
          final previous = protectedChannels[protected.channelId.hex];
          if (previous == null ||
              channels.containsKey(protected.channelId.hex) ||
              protected.channelEpoch != previous.channelEpoch + 1) {
            rejected.add(e);
            continue;
          }
          protectedChannels[protected.channelId.hex] = protected;
          break;
        }
        final channel = e.channel!;
        final previous = channels[channel.channelId.hex];
        final category = channel.categoryId == null
            ? null
            : channels[channel.categoryId!.hex];
        final otherDefault = channels.values.any(
          (value) =>
              value.channelId != channel.channelId &&
              value.kind == SpaceChannelKind.text &&
              value.isDefault &&
              !value.archived,
        );
        final hasActiveChildren = channels.values.any(
          (value) => value.categoryId == channel.channelId && !value.archived,
        );
        if (previous == null ||
            !previous.sameIdentity(channel) ||
            (channel.categoryId != null &&
                (category == null ||
                    category.kind != SpaceChannelKind.category ||
                    category.archived)) ||
            (previous.kind == SpaceChannelKind.category &&
                !previous.archived &&
                channel.archived &&
                hasActiveChildren) ||
            (previous.isDefault &&
                (!channel.isDefault || channel.archived) &&
                !otherDefault)) {
          rejected.add(e);
          continue;
        }
        if (channel.isDefault) {
          for (final existing in channels.entries.toList()) {
            if (existing.key != channel.channelId.hex &&
                existing.value.isDefault) {
              channels[existing.key] = existing.value.copyWith(
                isDefault: false,
              );
            }
          }
        }
        channels[channel.channelId.hex] = channel;
      case ControlOp.checkpoint:
        // Signed no-op: its payload is consumed by causal post validation.
        break;
      case ControlOp.leave:
        // The author removes themselves; their departure rotates the epoch too.
        members.remove(e.author.hex);
        epoch++;
        // The departing author must not choose a future key it would know.
        // Remaining admins publish a separate rotateEpoch descriptor.
        epochDescriptor = null;
    }
    lastSeq[e.author.hex] = e.seq;
    lastEntry[e.author.hex] = e;
    accepted.add(e);
  }

  return GroupFoldResult(
    GroupState._(
      members,
      epoch,
      policyVersion,
      accessPolicy,
      List.unmodifiable(accessPolicyHistory),
      name,
      description,
      epochDescriptor,
      Map.unmodifiable(channels),
      Map.unmodifiable(protectedChannels),
      Map.unmodifiable(rulesHistory),
      Map.unmodifiable(rulesAcceptances),
      Map.unmodifiable(moderationRecords),
      Map.unmodifiable(protectedModeration),
      Map.unmodifiable(protectedRetention),
      List.unmodifiable(retentionHistory),
      Map.unmodifiable(postPins),
      Map.unmodifiable(recommendationCampaigns),
      lifecycleState,
      lifecycleTransition,
      lifecycleTransitionHash,
    ),
    rejected,
    List.unmodifiable(accepted),
  );
}
