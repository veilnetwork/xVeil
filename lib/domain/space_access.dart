import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';

/// Stable authorization vocabulary shared by the signed policy, fold, service,
/// API and UI. A serialized permission is its enum name, never its index.
enum SpacePermission {
  view,
  distributeContent,
  publishMessages,
  publishPosts,
  managePosts,
  manageRecommendations,
  enterVoice,
  manageMembers,
  manageRoles,
  moderate,
  manageSettings,
  manageEncryption,
  manageStorage,
  manageChannels;

  static SpacePermission? fromName(String? value) {
    for (final permission in values) {
      if (permission.name == value) return permission;
    }
    return null;
  }
}

final RegExp _spaceAccessId = RegExp(r'^[0-9a-f]{64}$');

/// One named permission set. Membership is deliberately stored elsewhere so a
/// role can be reused by groups and direct member assignments.
final class SpaceRoleDefinition {
  SpaceRoleDefinition({
    required this.roleId,
    required this.name,
    required Iterable<SpacePermission> permissions,
  }) : permissions = Set.unmodifiable(permissions);

  final String roleId;
  final String name;
  final Set<SpacePermission> permissions;

  bool get isStructurallyValid =>
      _spaceAccessId.hasMatch(roleId) &&
      name == name.trim() &&
      name.isNotEmpty &&
      name.length <= 80 &&
      permissions.isNotEmpty &&
      permissions.length <= SpacePermission.values.length;

  Map<String, dynamic> toJson() => {
    'id': roleId,
    'name': name,
    'permissions':
        (permissions.toList()..sort((a, b) => a.index.compareTo(b.index)))
            .map((permission) => permission.name)
            .toList(growable: false),
  };

  static SpaceRoleDefinition? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['permissions'] is! List) {
      return null;
    }
    final permissions = <SpacePermission>{};
    for (final raw in value['permissions'] as List) {
      if (raw is! String) return null;
      final permission = SpacePermission.fromName(raw);
      if (permission == null || !permissions.add(permission)) return null;
    }
    final role = SpaceRoleDefinition(
      roleId: value['id'] as String,
      name: value['name'] as String,
      permissions: permissions,
    );
    return role.isStructurallyValid ? role : null;
  }
}

/// A reusable set of participants with one or more assigned custom roles.
final class SpaceMemberGroup {
  SpaceMemberGroup({
    required this.groupId,
    required this.name,
    required Iterable<NodeId> members,
    required Iterable<String> roleIds,
  }) : members = List.unmodifiable(members),
       roleIds = List.unmodifiable(roleIds);

  final String groupId;
  final String name;
  final List<NodeId> members;
  final List<String> roleIds;

  bool get isStructurallyValid {
    if (!_spaceAccessId.hasMatch(groupId) ||
        name != name.trim() ||
        name.isEmpty ||
        name.length > 80 ||
        members.length > 4096 ||
        roleIds.isEmpty ||
        roleIds.length > 128) {
      return false;
    }
    final memberIds = members.map((member) => member.hex).toSet();
    final roles = roleIds.toSet();
    return memberIds.length == members.length &&
        roles.length == roleIds.length &&
        roleIds.every(_spaceAccessId.hasMatch);
  }

  Map<String, dynamic> toJson() => {
    'id': groupId,
    'name': name,
    'members': (members.map((member) => member.hex).toList()..sort()),
    'roles': (roleIds.toList()..sort()),
  };

  static SpaceMemberGroup? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['members'] is! List ||
        value['roles'] is! List) {
      return null;
    }
    try {
      final members = <NodeId>[];
      for (final raw in value['members'] as List) {
        if (raw is! String) return null;
        members.add(NodeId.fromHex(raw));
      }
      final roles = <String>[];
      for (final raw in value['roles'] as List) {
        if (raw is! String) return null;
        roles.add(raw);
      }
      final group = SpaceMemberGroup(
        groupId: value['id'] as String,
        name: value['name'] as String,
        members: members,
        roleIds: roles,
      );
      return group.isStructurallyValid ? group : null;
    } catch (_) {
      return null;
    }
  }
}

/// Direct custom-role assignment for one participant. It is distinct from the
/// built-in owner/admin/member standing folded from membership control rows.
final class SpaceMemberRoleAssignment {
  SpaceMemberRoleAssignment({
    required this.member,
    required Iterable<String> roleIds,
  }) : roleIds = List.unmodifiable(roleIds);

  final NodeId member;
  final List<String> roleIds;

  bool get isStructurallyValid =>
      roleIds.isNotEmpty &&
      roleIds.length <= 128 &&
      roleIds.toSet().length == roleIds.length &&
      roleIds.every(_spaceAccessId.hasMatch);

  Map<String, dynamic> toJson() => {
    'member': member.hex,
    'roles': (roleIds.toList()..sort()),
  };

  static SpaceMemberRoleAssignment? fromJson(Object? value) {
    if (value is! Map ||
        value['member'] is! String ||
        value['roles'] is! List) {
      return null;
    }
    try {
      final roles = <String>[];
      for (final raw in value['roles'] as List) {
        if (raw is! String) return null;
        roles.add(raw);
      }
      final assignment = SpaceMemberRoleAssignment(
        member: NodeId.fromHex(value['member'] as String),
        roleIds: roles,
      );
      return assignment.isStructurallyValid ? assignment : null;
    } catch (_) {
      return null;
    }
  }
}

/// One complete signed access-policy snapshot.
///
/// Full snapshots make every revision atomic: no accepted prefix can contain a
/// group that points at a missing role. [previousPolicyHash] binds revisions
/// even when several owner devices race on independent author chains.
final class SpaceAccessPolicy {
  SpaceAccessPolicy({
    required this.spaceId,
    required this.revision,
    required this.previousPolicyHash,
    required this.changedBy,
    required this.changedAtMs,
    required Iterable<SpaceRoleDefinition> roles,
    required Iterable<SpaceMemberGroup> groups,
    required Iterable<SpaceMemberRoleAssignment> directAssignments,
  }) : roles = List.unmodifiable(roles),
       groups = List.unmodifiable(groups),
       directAssignments = List.unmodifiable(directAssignments);

  final NodeId spaceId;
  final int revision;
  final String previousPolicyHash;
  final NodeId changedBy;
  final int changedAtMs;
  final List<SpaceRoleDefinition> roles;
  final List<SpaceMemberGroup> groups;
  final List<SpaceMemberRoleAssignment> directAssignments;

  bool get isStructurallyValid {
    if (revision < 1 ||
        changedAtMs < 0 ||
        (revision == 1
            ? previousPolicyHash.isNotEmpty
            : !_spaceAccessId.hasMatch(previousPolicyHash)) ||
        roles.length > 128 ||
        groups.length > 128 ||
        directAssignments.length > 4096 ||
        roles.any((role) => !role.isStructurallyValid) ||
        groups.any((group) => !group.isStructurallyValid) ||
        directAssignments.any(
          (assignment) => !assignment.isStructurallyValid,
        )) {
      return false;
    }
    final roleIds = roles.map((role) => role.roleId).toSet();
    final groupIds = groups.map((group) => group.groupId).toSet();
    final roleNames = roles.map((role) => role.name.toLowerCase()).toSet();
    final groupNames = groups.map((group) => group.name.toLowerCase()).toSet();
    final assignedMembers = directAssignments
        .map((assignment) => assignment.member.hex)
        .toSet();
    if (roleIds.length != roles.length ||
        groupIds.length != groups.length ||
        roleNames.length != roles.length ||
        groupNames.length != groups.length ||
        assignedMembers.length != directAssignments.length) {
      return false;
    }
    return groups.every((group) => group.roleIds.every(roleIds.contains)) &&
        directAssignments.every(
          (assignment) => assignment.roleIds.every(roleIds.contains),
        );
  }

  SpaceRoleDefinition? role(String roleId) {
    for (final candidate in roles) {
      if (candidate.roleId == roleId) return candidate;
    }
    return null;
  }

  Set<String> roleIdsFor(NodeId member) {
    final result = <String>{};
    for (final assignment in directAssignments) {
      if (assignment.member == member) result.addAll(assignment.roleIds);
    }
    for (final group in groups) {
      if (group.members.contains(member)) result.addAll(group.roleIds);
    }
    return result;
  }

  Set<SpacePermission> permissionsFor(NodeId member) {
    final result = <SpacePermission>{};
    for (final roleId in roleIdsFor(member)) {
      final definition = role(roleId);
      if (definition != null) result.addAll(definition.permissions);
    }
    return result;
  }

  Uint8List canonicalBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  String get policyHash => crypto.sha256.convert(canonicalBytes()).toString();

  Map<String, dynamic> toJson() => {
    'space': spaceId.hex,
    'revision': revision,
    'previous': previousPolicyHash,
    'changedBy': changedBy.hex,
    'changedAt': changedAtMs,
    'roles': (roles.toList()..sort((a, b) => a.roleId.compareTo(b.roleId)))
        .map((role) => role.toJson())
        .toList(growable: false),
    'groups': (groups.toList()..sort((a, b) => a.groupId.compareTo(b.groupId)))
        .map((group) => group.toJson())
        .toList(growable: false),
    'direct':
        (directAssignments.toList()
              ..sort((a, b) => a.member.hex.compareTo(b.member.hex)))
            .map((assignment) => assignment.toJson())
            .toList(growable: false),
  };

  static SpaceAccessPolicy? fromJson(Object? value) {
    if (value is! Map ||
        value['space'] is! String ||
        value['revision'] is! int ||
        value['previous'] is! String ||
        value['changedBy'] is! String ||
        value['changedAt'] is! int ||
        value['roles'] is! List ||
        value['groups'] is! List ||
        value['direct'] is! List) {
      return null;
    }
    try {
      final roles = <SpaceRoleDefinition>[];
      for (final raw in value['roles'] as List) {
        final role = SpaceRoleDefinition.fromJson(raw);
        if (role == null) return null;
        roles.add(role);
      }
      final groups = <SpaceMemberGroup>[];
      for (final raw in value['groups'] as List) {
        final group = SpaceMemberGroup.fromJson(raw);
        if (group == null) return null;
        groups.add(group);
      }
      final direct = <SpaceMemberRoleAssignment>[];
      for (final raw in value['direct'] as List) {
        final assignment = SpaceMemberRoleAssignment.fromJson(raw);
        if (assignment == null) return null;
        direct.add(assignment);
      }
      final policy = SpaceAccessPolicy(
        spaceId: NodeId.fromHex(value['space'] as String),
        revision: value['revision'] as int,
        previousPolicyHash: value['previous'] as String,
        changedBy: NodeId.fromHex(value['changedBy'] as String),
        changedAtMs: value['changedAt'] as int,
        roles: roles,
        groups: groups,
        directAssignments: direct,
      );
      return policy.isStructurallyValid ? policy : null;
    } catch (_) {
      return null;
    }
  }
}
