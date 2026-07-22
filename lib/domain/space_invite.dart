import '../core/ids.dart';
import 'group.dart';

/// A small consent proposal sent to one accepted contact.
///
/// It deliberately carries no control log, member roster, messages or epoch
/// envelopes. The authenticated Veil transport binds [inviter] to the sender;
/// authority is decided later by the signed Space control entry that grants
/// membership after the recipient accepts.
class SpaceInvite {
  const SpaceInvite({
    required this.inviteId,
    required this.spaceId,
    required this.inviter,
    required this.invitee,
    required this.spaceName,
    required this.visibility,
    required this.role,
    required this.createdAtMs,
    required this.expiresAtMs,
  });

  final String inviteId;
  final NodeId spaceId;
  final NodeId inviter;
  final NodeId invitee;
  final String spaceName;
  final SpaceVisibility visibility;
  final GroupRole role;
  final int createdAtMs;
  final int expiresAtMs;

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(inviteId) &&
      (visibility == SpaceVisibility.secret
          ? spaceName.isEmpty
          : spaceName.trim().isNotEmpty) &&
      spaceName.length <= 160 &&
      role != GroupRole.owner &&
      createdAtMs >= 0 &&
      expiresAtMs > createdAtMs &&
      expiresAtMs - createdAtMs <= const Duration(days: 30).inMilliseconds;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': inviteId,
    'space': spaceId.hex,
    'from': inviter.hex,
    'to': invitee.hex,
    'name': spaceName,
    'visibility': visibility.name,
    'role': role.name,
    'createdAt': createdAtMs,
    'expiresAt': expiresAtMs,
  };

  static SpaceInvite? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final id = value['id'];
    final space = value['space'];
    final from = value['from'];
    final to = value['to'];
    final name = value['name'];
    final createdAt = value['createdAt'];
    final expiresAt = value['expiresAt'];
    final visibilityName = value['visibility'];
    final roleName = value['role'];
    if (id is! String ||
        space is! String ||
        from is! String ||
        to is! String ||
        name is! String ||
        createdAt is! int ||
        expiresAt is! int ||
        visibilityName is! String ||
        roleName is! String) {
      return null;
    }
    final visibility = SpaceVisibility.fromName(visibilityName);
    final role = GroupRole.fromName(roleName);
    if (visibility == null || role == null) {
      return null;
    }
    try {
      final invite = SpaceInvite(
        inviteId: id,
        spaceId: NodeId.fromHex(space),
        inviter: NodeId.fromHex(from),
        invitee: NodeId.fromHex(to),
        spaceName: name,
        visibility: visibility,
        role: role,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
      );
      return invite.isStructurallyValid ? invite : null;
    } catch (_) {
      return null;
    }
  }
}

/// Local inbox record. [acceptedAtMs] means the user consented and the client
/// is waiting for a verifiable membership-grant snapshot from [invite.inviter].
class PendingSpaceInvite {
  const PendingSpaceInvite({required this.invite, this.acceptedAtMs});

  final SpaceInvite invite;
  final int? acceptedAtMs;

  bool get accepted => acceptedAtMs != null;

  Map<String, dynamic> toJson() => {
    'invite': invite.toJson(),
    if (acceptedAtMs != null) 'acceptedAt': acceptedAtMs,
  };

  static PendingSpaceInvite? fromJson(Object? value) {
    if (value is! Map) return null;
    final invite = SpaceInvite.fromJson(value['invite']);
    final acceptedAt = value['acceptedAt'];
    if (invite == null || (acceptedAt != null && acceptedAt is! int)) {
      return null;
    }
    if (acceptedAt is int &&
        (acceptedAt < invite.createdAtMs || acceptedAt > invite.expiresAtMs)) {
      return null;
    }
    return PendingSpaceInvite(invite: invite, acceptedAtMs: acceptedAt as int?);
  }
}

/// Authenticated recipient decision. A decline only clears the sender's local
/// proposal; an acceptance still grants nothing until an authorized signed
/// `addMember` entry is produced and verified by normal Space folding.
class SpaceInviteDecision {
  const SpaceInviteDecision({
    required this.inviteId,
    required this.spaceId,
    required this.accepted,
    required this.decidedAtMs,
  });

  final String inviteId;
  final NodeId spaceId;
  final bool accepted;
  final int decidedAtMs;

  bool get isStructurallyValid =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(inviteId) && decidedAtMs >= 0;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': inviteId,
    'space': spaceId.hex,
    'accepted': accepted,
    'decidedAt': decidedAtMs,
  };

  static SpaceInviteDecision? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final id = value['id'];
    final space = value['space'];
    final accepted = value['accepted'];
    final decidedAt = value['decidedAt'];
    if (id is! String ||
        space is! String ||
        accepted is! bool ||
        decidedAt is! int) {
      return null;
    }
    try {
      final decision = SpaceInviteDecision(
        inviteId: id,
        spaceId: NodeId.fromHex(space),
        accepted: accepted,
        decidedAtMs: decidedAt,
      );
      return decision.isStructurallyValid ? decision : null;
    } catch (_) {
      return null;
    }
  }
}
