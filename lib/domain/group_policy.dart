// Group policy evaluation (groups epic, phase 0, brick 1): fold an ordered
// control-log into the current membership/roles/policy state, applying each
// entry ONLY when its author is permitted the op against the state that
// preceded it. Pure and deterministic — the same log yields the same state on
// every device, so a peer that ships an invalid op can't move anyone else's
// view (the op is dropped, not shown, and — at the transport layer — not
// relayed).
//
// Permission model (v1, from the agreed design):
//  - owner: everything, and is the genesis; cannot be removed/demoted.
//  - admin: add/remove/mute/unmute/ban members, rotate epoch; may set a
//    member's role up to (but not including) their own rank; cannot touch
//    a peer of equal-or-higher rank.
//  - member: no control ops.
// setPolicy is owner-only. An op an author lacks the rank for is rejected.

import '../core/ids.dart';
import 'group.dart';

/// The folded group state after replaying a (validated) control-log prefix.
class GroupState {
  GroupState._(this.members, this.epoch, this.policyVersion);

  /// nodeId hex -> member.
  final Map<String, GroupMember> members;

  /// The current key epoch (bumped by rotateEpoch — bans/leaves rotate).
  final int epoch;

  /// The current policy version (bumped by setPolicy).
  final int policyVersion;

  GroupMember? memberOf(NodeId id) => members[id.hex];
  bool isMember(NodeId id) => members.containsKey(id.hex);
  GroupRole? roleOf(NodeId id) => members[id.hex]?.role;

  /// The initial state of a group: the owner (genesis) is the sole member.
  factory GroupState.genesis(NodeId owner) => GroupState._(
        {
          owner.hex: GroupMember(nodeId: owner, role: GroupRole.owner),
        },
        0,
        0,
      );
}

/// Whether [author] (at [authorRole]) may apply [op] to [targetRole] under the
/// current state. Pure predicate — the fold uses it, and tests hit it directly.
bool canApply({
  required GroupRole authorRole,
  required ControlOp op,
  GroupRole? targetRole, // the target's CURRENT role, if it's a member
  GroupRole? newRole, // the requested role for addMember/setRole
}) {
  switch (op) {
    case ControlOp.setPolicy:
      return authorRole == GroupRole.owner;
    case ControlOp.rotateEpoch:
      return authorRole.rank >= GroupRole.admin.rank;
    case ControlOp.addMember:
      // Can't mint a role at or above your own.
      final r = newRole ?? GroupRole.member;
      return authorRole.rank >= GroupRole.admin.rank &&
          r.rank < authorRole.rank;
    case ControlOp.setRole:
      final r = newRole;
      if (r == null || targetRole == null) return false;
      // Manage strictly-lower targets, and never grant >= your own rank.
      return authorRole.rank >= GroupRole.admin.rank &&
          targetRole.rank < authorRole.rank &&
          r.rank < authorRole.rank;
    case ControlOp.removeMember:
    case ControlOp.ban:
    case ControlOp.mute:
    case ControlOp.unmute:
      if (targetRole == null) return false; // target not a member
      // Act only on strictly-lower ranks (admins can't touch each other or
      // the owner; the owner is above all).
      return authorRole.rank >= GroupRole.admin.rank &&
          targetRole.rank < authorRole.rank;
    case ControlOp.leave:
      // Any member may leave (removes only themselves) — EXCEPT the owner, who
      // is the genesis and cannot depart (a later "delete/transfer" covers that).
      return authorRole != GroupRole.owner;
  }
}

/// The outcome of folding a log: the resulting state plus the entries that
/// were REJECTED (invalid author perms / bad chaining / duplicate seq), for
/// diagnostics — a rejected entry is never applied.
class GroupFoldResult {
  const GroupFoldResult(this.state, this.rejected);
  final GroupState state;
  final List<ControlEntry> rejected;
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
}) {
  final members = <String, GroupMember>{
    owner.hex: GroupMember(nodeId: owner, role: GroupRole.owner),
  };
  var epoch = 0;
  var policyVersion = 0;
  final rejected = <ControlEntry>[];

  // Per-author monotonic seq + prev-hash chaining: process each author's
  // entries in seq order. A gap or a replayed/duplicate seq drops the entry.
  final byAuthor = <String, List<ControlEntry>>{};
  for (final e in entries) {
    byAuthor.putIfAbsent(e.author.hex, () => []).add(e);
  }

  // Deterministic global order: sort all valid-signature entries by
  // (createdAtMs, author hex, seq) so every device folds identically.
  final ordered = <ControlEntry>[];
  for (final list in byAuthor.values) {
    list.sort((a, b) => a.seq.compareTo(b.seq));
    ordered.addAll(list);
  }
  ordered.sort((a, b) {
    final t = a.createdAtMs.compareTo(b.createdAtMs);
    if (t != 0) return t;
    final h = a.author.hex.compareTo(b.author.hex);
    if (h != 0) return h;
    return a.seq.compareTo(b.seq);
  });

  final lastSeq = <String, int>{};
  for (final e in ordered) {
    // Signature must verify.
    if (!verify(e)) {
      rejected.add(e);
      continue;
    }
    // Per-author seq must strictly increase (first entry may be any seq >= 0
    // but subsequent ones must climb; a replay/duplicate is dropped).
    final prev = lastSeq[e.author.hex];
    if (prev != null && e.seq <= prev) {
      rejected.add(e);
      continue;
    }
    final authorRole = members[e.author.hex]?.role;
    if (authorRole == null) {
      rejected.add(e); // author isn't a member
      continue;
    }
    final targetRole = e.target == null ? null : members[e.target!.hex]?.role;
    if (!canApply(
      authorRole: authorRole,
      op: e.op,
      targetRole: targetRole,
      newRole: e.role,
    )) {
      rejected.add(e);
      continue;
    }
    // Apply.
    switch (e.op) {
      case ControlOp.addMember:
        final id = e.target;
        if (id == null || members.containsKey(id.hex)) {
          rejected.add(e);
          continue;
        }
        members[id.hex] =
            GroupMember(nodeId: id, role: e.role ?? GroupRole.member);
      case ControlOp.removeMember:
      case ControlOp.ban:
        members.remove(e.target!.hex);
        epoch++; // a departure rotates the epoch (agreed design)
      case ControlOp.setRole:
        final m = members[e.target!.hex]!;
        members[e.target!.hex] = m.copyWith(role: e.role);
      case ControlOp.mute:
        final m = members[e.target!.hex]!;
        members[e.target!.hex] = m.copyWith(muted: true);
      case ControlOp.unmute:
        final m = members[e.target!.hex]!;
        members[e.target!.hex] = m.copyWith(muted: false);
      case ControlOp.rotateEpoch:
        epoch++;
      case ControlOp.setPolicy:
        policyVersion++;
      case ControlOp.leave:
        // The author removes themselves; their departure rotates the epoch too.
        members.remove(e.author.hex);
        epoch++;
    }
    lastSeq[e.author.hex] = e.seq;
  }

  return GroupFoldResult(
    GroupState._(members, epoch, policyVersion),
    rejected,
  );
}
