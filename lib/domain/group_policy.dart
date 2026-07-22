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
// setPolicy is owner-only. An op an author lacks the rank for is rejected.

import 'dart:collection';

import '../core/ids.dart';
import 'group.dart';
import 'group_epoch.dart';
import 'space_channel.dart';
import 'space_lifecycle.dart';
import 'space_moderation.dart';
import 'space_retention.dart';
import 'space_rules.dart';

/// The folded group state after replaying a (validated) control-log prefix.
class GroupState {
  GroupState._(
    this.members,
    this.epoch,
    this.policyVersion,
    this.name,
    this.description,
    this.epochDescriptor,
    this.channels,
    this.protectedChannels,
    this.rulesHistory,
    this.rulesAcceptances,
    this.moderationRecords,
    this.retentionHistory,
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

  /// Every accepted signed revision, retained for audit and irreversible
  /// expiry evaluation. A later relaxed policy cannot resurrect an item that
  /// expired while an earlier destructive revision was active.
  final List<SpaceRetentionRevision> retentionHistory;

  /// Signed Space lifecycle state. Group chats never author lifecycle ops and
  /// therefore remain [SpaceLifecycleState.active].
  final SpaceLifecycleState lifecycleState;
  final SpaceLifecycleTransition? lifecycleTransition;
  final String? lifecycleTransitionHash;

  bool get isArchived => lifecycleState == SpaceLifecycleState.archived;

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
  }) => moderationRecords.values.any((record) {
    if (!record.isActiveAt(atMs)) return false;
    final action = record.action;
    final reference = action.reference;
    return reference != null &&
        reference.kind == kind &&
        reference.author == author &&
        reference.seq == seq &&
        (reference.channelId == null || reference.channelId == channelId);
  });

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

  GroupMember? memberOf(NodeId id) => members[id.hex];
  bool isMember(NodeId id) => members.containsKey(id.hex);
  GroupRole? roleOf(NodeId id) => members[id.hex]?.role;

  /// The initial state of a group: the owner (genesis) is the sole member.
  factory GroupState.genesis(NodeId owner, [String name = '']) => GroupState._(
    {owner.hex: GroupMember(nodeId: owner, role: GroupRole.owner)},
    0,
    0,
    name,
    '',
    null,
    const {},
    const {},
    const {},
    const {},
    const {},
    const [],
    SpaceLifecycleState.active,
    null,
    null,
  );
}

/// Stable authorization vocabulary for Space v1. Scopes that do not yet have
/// a wire object are still named here so service/API checks converge on one
/// policy surface instead of growing ad-hoc role comparisons.
enum SpacePermission {
  view,
  distributeContent,
  publishMessages,
  publishPosts,
  enterVoice,
  manageMembers,
  manageRoles,
  moderate,
  manageSettings,
  manageEncryption,
  manageStorage,
  manageChannels,
}

/// Deterministic Space authorization evaluated by every local node. V1 keeps
/// the existing owner/admin/member roles; channel overrides and explicit deny
/// entries can extend this class without bypassing callers.
final class SpaceAcl {
  const SpaceAcl(this.state);

  final GroupState state;

  bool allows(
    NodeId actor,
    SpacePermission permission, {
    int? atMs,
    NodeId? channelId,
  }) {
    final member = state.memberOf(actor);
    if (member == null) return false;
    // A current mutation has no historical timestamp and is closed while the
    // Space is archived. Read/materialization paths deliberately evaluate the
    // author's permission at the signed content timestamp; the lifecycle head
    // separately proves that the row belongs to the archived readable prefix.
    if (state.isArchived &&
        atMs == null &&
        permission != SpacePermission.view &&
        permission != SpacePermission.distributeContent) {
      return false;
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
    return switch (permission) {
      SpacePermission.view || SpacePermission.distributeContent => true,
      SpacePermission.publishMessages => !member.muted && !blocksMessages,
      SpacePermission.publishPosts => !member.muted && !blocksPosts,
      SpacePermission.enterVoice => !blocksVoice,
      SpacePermission.manageMembers ||
      SpacePermission.manageRoles ||
      SpacePermission.moderate ||
      SpacePermission.manageEncryption =>
        member.role.rank >= GroupRole.admin.rank,
      SpacePermission.manageChannels =>
        member.role.rank >= GroupRole.admin.rank,
      SpacePermission.manageSettings ||
      SpacePermission.manageStorage => member.role == GroupRole.owner,
    };
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
  var name = initialName;
  var description = initialDescription;
  GroupEpochDescriptor? epochDescriptor;
  final channels = <String, SpaceChannel>{};
  final protectedChannels = <String, SpaceChannelControlEnvelope>{};
  final rulesHistory = <int, SpaceRulesVersion>{};
  final rulesAcceptances = <String, SpaceRulesAcceptance>{};
  final moderationRecords = <String, SpaceModerationRecord>{};
  final retentionHistory = <SpaceRetentionRevision>[];
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
    final moderationTargetsRemovedContent =
        e.op == ControlOp.moderate &&
        {
          SpaceModerationKind.deleteMessage,
          SpaceModerationKind.deletePost,
        }.contains(e.moderationAction?.kind);
    final authorized = e.op == ControlOp.revokeModeration
        ? revocationRecord != null &&
              revocationRecord.revokedAtMs == null &&
              revocationRecord.action.target == e.target &&
              !{
                SpaceModerationKind.deleteMessage,
                SpaceModerationKind.deletePost,
              }.contains(revocationRecord.action.kind) &&
              (targetRole == null
                  ? authorRole == GroupRole.owner &&
                        revocationRecord.action.kind.removesMembership
                  : canApply(
                      authorRole: authorRole,
                      op: ControlOp.revokeModeration,
                      targetRole: targetRole,
                    ))
        : moderationTargetsRemovedContent && targetRole == null
        ? authorRole == GroupRole.owner
        : canApply(
            authorRole: authorRole,
            op: e.op,
            targetRole: targetRole,
            newRole: e.role,
          );
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
    } else if (e.moderationAction != null || e.moderationRevocation != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.setRetention) {
      final policy = e.retentionPolicy;
      final channel = policy?.channelId == null
          ? null
          : channels[policy!.channelId!.hex];
      if (e.version != 9 ||
          policy == null ||
          !policy.isStructurallyValid ||
          (policy.channelId != null && channel == null)) {
        rejected.add(e);
        continue;
      }
    } else if (e.retentionPolicy != null) {
      rejected.add(e);
      continue;
    }
    if (e.op == ControlOp.archiveSpace || e.op == ControlOp.restoreSpace) {
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
      if (e.version != 10 ||
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
                      lifecycleTransition.contentBoundaryJson()))) {
        rejected.add(e);
        continue;
      }
    } else if (e.lifecycleTransition != null) {
      rejected.add(e);
      continue;
    }
    final descriptor = e.epochDescriptor;
    GroupEpochDescriptor? usableDescriptor = descriptor;
    final moderationRemovesMember =
        e.op == ControlOp.moderate &&
        e.moderationAction!.kind.removesMembership;
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
        policyVersion++;
      case ControlOp.setRetention:
        final activatedAt = e.createdAtMs < lastRetentionActivationMs
            ? lastRetentionActivationMs
            : e.createdAtMs;
        lastRetentionActivationMs = activatedAt;
        retentionHistory.add(
          SpaceRetentionRevision(
            policy: e.retentionPolicy!,
            activatedAtMs: activatedAt,
            author: e.author,
            authorSeq: e.seq,
          ),
        );
      case ControlOp.archiveSpace:
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
        final action = e.moderationAction!;
        final actionId = '${e.author.hex}:${e.seq}';
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
        if (previous == null ||
            !previous.sameIdentity(channel) ||
            (channel.categoryId != null &&
                (category == null ||
                    category.kind != SpaceChannelKind.category ||
                    category.archived)) ||
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
      name,
      description,
      epochDescriptor,
      Map.unmodifiable(channels),
      Map.unmodifiable(protectedChannels),
      Map.unmodifiable(rulesHistory),
      Map.unmodifiable(rulesAcceptances),
      Map.unmodifiable(moderationRecords),
      List.unmodifiable(retentionHistory),
      lifecycleState,
      lifecycleTransition,
      lifecycleTransitionHash,
    ),
    rejected,
    List.unmodifiable(accepted),
  );
}
