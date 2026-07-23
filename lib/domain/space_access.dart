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

/// Where one custom-role permission applies.
///
/// [space] is the root scope. [category] and [channel] bind a concrete signed
/// channel id. The remaining values are explicit functional areas, so audit
/// and management surfaces never need to infer whether a broad permission was
/// intended for publications, moderation or another subsystem.
enum SpacePermissionScopeKind {
  space,
  category,
  channel,
  posts,
  moderation,
  members,
  roles,
  settings,
  encryption,
  storage;

  static SpacePermissionScopeKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }

  bool get requiresTarget =>
      this == SpacePermissionScopeKind.category ||
      this == SpacePermissionScopeKind.channel;

  /// Reject meaningless combinations at the signed-policy boundary. A future
  /// permission can extend this exhaustive mapping without changing existing
  /// canonical rows.
  bool supports(SpacePermission permission) => switch (this) {
    SpacePermissionScopeKind.space => true,
    SpacePermissionScopeKind.category ||
    SpacePermissionScopeKind.channel => switch (permission) {
      SpacePermission.view ||
      SpacePermission.distributeContent ||
      SpacePermission.publishMessages ||
      SpacePermission.enterVoice ||
      SpacePermission.manageChannels ||
      SpacePermission.moderate ||
      SpacePermission.manageEncryption ||
      SpacePermission.manageStorage => true,
      _ => false,
    },
    SpacePermissionScopeKind.posts => switch (permission) {
      SpacePermission.publishPosts ||
      SpacePermission.managePosts ||
      SpacePermission.manageRecommendations => true,
      _ => false,
    },
    SpacePermissionScopeKind.moderation =>
      permission == SpacePermission.moderate,
    SpacePermissionScopeKind.members =>
      permission == SpacePermission.manageMembers,
    SpacePermissionScopeKind.roles => permission == SpacePermission.manageRoles,
    SpacePermissionScopeKind.settings =>
      permission == SpacePermission.manageSettings,
    SpacePermissionScopeKind.encryption =>
      permission == SpacePermission.manageEncryption,
    SpacePermissionScopeKind.storage => switch (permission) {
      SpacePermission.distributeContent ||
      SpacePermission.manageStorage => true,
      _ => false,
    },
  };
}

/// One deterministic permission area. Only category/channel scopes carry a
/// target; functional scopes deliberately have no loosely typed payload.
final class SpacePermissionScope {
  const SpacePermissionScope({required this.kind, this.targetId});

  const SpacePermissionScope.space()
    : kind = SpacePermissionScopeKind.space,
      targetId = null;

  final SpacePermissionScopeKind kind;
  final NodeId? targetId;

  bool get isStructurallyValid =>
      kind.requiresTarget ? targetId != null : targetId == null;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    if (targetId != null) 'target': targetId!.hex,
  };

  static SpacePermissionScope? fromJson(Object? value) {
    if (value is! Map || value['kind'] is! String) return null;
    final kind = SpacePermissionScopeKind.fromName(value['kind'] as String);
    if (kind == null) return null;
    final rawTarget = value['target'];
    if (rawTarget != null && rawTarget is! String) return null;
    try {
      final scope = SpacePermissionScope(
        kind: kind,
        targetId: rawTarget is String ? NodeId.fromHex(rawTarget) : null,
      );
      return scope.isStructurallyValid ? scope : null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SpacePermissionScope &&
      other.kind == kind &&
      other.targetId == targetId;

  @override
  int get hashCode => Object.hash(kind, targetId);
}

/// One positive permission rule. It keeps the deployed V18 representation;
/// explicit denials use a separate V19/schema-3 rule type below.
final class SpacePermissionGrant {
  const SpacePermissionGrant({required this.permission, required this.scope});

  final SpacePermission permission;
  final SpacePermissionScope scope;

  bool get isStructurallyValid =>
      scope.isStructurallyValid && scope.kind.supports(permission);

  Map<String, dynamic> toJson() => {
    'permission': permission.name,
    'scope': scope.toJson(),
  };

  static SpacePermissionGrant? fromJson(Object? value) {
    if (value is! Map ||
        value['permission'] is! String ||
        value['scope'] == null) {
      return null;
    }
    final permission = SpacePermission.fromName(value['permission'] as String);
    final scope = SpacePermissionScope.fromJson(value['scope']);
    if (permission == null || scope == null) return null;
    final grant = SpacePermissionGrant(permission: permission, scope: scope);
    return grant.isStructurallyValid ? grant : null;
  }

  @override
  bool operator ==(Object other) =>
      other is SpacePermissionGrant &&
      other.permission == permission &&
      other.scope == scope;

  @override
  int get hashCode => Object.hash(permission, scope);
}

/// One explicit permission denial.
///
/// A separate type and JSON list keep V17/V18 snapshots byte-compatible.
/// During evaluation any applicable denial wins over any positive grant,
/// regardless of whether either rule arrived through a group or direct role.
final class SpacePermissionDenial {
  const SpacePermissionDenial({required this.permission, required this.scope});

  final SpacePermission permission;
  final SpacePermissionScope scope;

  bool get isStructurallyValid =>
      scope.isStructurallyValid && scope.kind.supports(permission);

  Map<String, dynamic> toJson() => {
    'permission': permission.name,
    'scope': scope.toJson(),
  };

  static SpacePermissionDenial? fromJson(Object? value) {
    if (value is! Map ||
        value['permission'] is! String ||
        value['scope'] == null) {
      return null;
    }
    final permission = SpacePermission.fromName(value['permission'] as String);
    final scope = SpacePermissionScope.fromJson(value['scope']);
    if (permission == null || scope == null) return null;
    final denial = SpacePermissionDenial(permission: permission, scope: scope);
    return denial.isStructurallyValid ? denial : null;
  }

  @override
  bool operator ==(Object other) =>
      other is SpacePermissionDenial &&
      other.permission == permission &&
      other.scope == scope;

  @override
  int get hashCode => Object.hash(permission, scope);
}

int _comparePermissionRules(
  SpacePermission leftPermission,
  SpacePermissionScope leftScope,
  SpacePermission rightPermission,
  SpacePermissionScope rightScope,
) {
  final permission = leftPermission.index.compareTo(rightPermission.index);
  if (permission != 0) return permission;
  final kind = leftScope.kind.index.compareTo(rightScope.kind.index);
  if (kind != 0) return kind;
  return (leftScope.targetId?.hex ?? '').compareTo(
    rightScope.targetId?.hex ?? '',
  );
}

final RegExp _spaceAccessId = RegExp(r'^[0-9a-f]{64}$');

/// One named permission set. Membership is deliberately stored elsewhere so a
/// role can be reused by groups and direct member assignments.
final class SpaceRoleDefinition {
  SpaceRoleDefinition({
    required this.roleId,
    required this.name,
    Iterable<SpacePermission>? permissions,
    Iterable<SpacePermissionGrant>? grants,
    Iterable<SpacePermissionDenial>? denials,
  }) : _legacyPermissionsEncoding = grants == null && denials == null,
       _hasConflictingSources =
           permissions != null && (grants != null || denials != null),
       grants = List.unmodifiable(
         grants ??
             (permissions ?? const <SpacePermission>[]).map(
               (permission) => SpacePermissionGrant(
                 permission: permission,
                 scope: const SpacePermissionScope.space(),
               ),
             ),
       ),
       denials = List.unmodifiable(denials ?? const <SpacePermissionDenial>[]);

  final String roleId;
  final String name;
  final List<SpacePermissionGrant> grants;
  final List<SpacePermissionDenial> denials;
  final bool _legacyPermissionsEncoding;
  final bool _hasConflictingSources;

  Set<SpacePermission> get permissions =>
      Set.unmodifiable(grants.map((grant) => grant.permission));
  Set<SpacePermission> get deniedPermissions =>
      Set.unmodifiable(denials.map((denial) => denial.permission));

  /// V17 used the `permissions` array. Any role authored with `grants` needs
  /// V18 even when its selected scopes happen to be Space-wide.
  bool get usesScopedEncoding => !_legacyPermissionsEncoding;
  bool get usesDenyEncoding => denials.isNotEmpty;

  bool get isStructurallyValid =>
      _spaceAccessId.hasMatch(roleId) &&
      name == name.trim() &&
      name.isNotEmpty &&
      name.length <= 80 &&
      !_hasConflictingSources &&
      grants.length + denials.length > 0 &&
      grants.length + denials.length <= 512 &&
      grants.every((grant) => grant.isStructurallyValid) &&
      grants.toSet().length == grants.length &&
      denials.every((denial) => denial.isStructurallyValid) &&
      denials.toSet().length == denials.length;

  Map<String, dynamic> toJson() {
    final sortedGrants = grants.toList()
      ..sort((left, right) {
        return _comparePermissionRules(
          left.permission,
          left.scope,
          right.permission,
          right.scope,
        );
      });
    final sortedDenials = denials.toList()
      ..sort((left, right) {
        return _comparePermissionRules(
          left.permission,
          left.scope,
          right.permission,
          right.scope,
        );
      });
    return {
      'id': roleId,
      'name': name,
      if (_legacyPermissionsEncoding)
        'permissions':
            (permissions.toList()..sort((a, b) => a.index.compareTo(b.index)))
                .map((permission) => permission.name)
                .toList(growable: false)
      else
        'grants': sortedGrants
            .map((grant) => grant.toJson())
            .toList(growable: false),
      if (sortedDenials.isNotEmpty)
        'denies': sortedDenials
            .map((denial) => denial.toJson())
            .toList(growable: false),
    };
  }

  static SpaceRoleDefinition? fromJson(Object? value) {
    if (value is! Map || value['id'] is! String || value['name'] is! String) {
      return null;
    }
    final rawPermissions = value['permissions'];
    final rawGrants = value['grants'];
    final rawDenials = value['denies'];
    if ((rawPermissions is List) == (rawGrants is List) ||
        (rawDenials != null && rawDenials is! List) ||
        (rawPermissions is List && rawDenials != null)) {
      return null;
    }
    late final SpaceRoleDefinition role;
    if (rawPermissions is List) {
      final permissions = <SpacePermission>{};
      for (final raw in rawPermissions) {
        if (raw is! String) return null;
        final permission = SpacePermission.fromName(raw);
        if (permission == null || !permissions.add(permission)) return null;
      }
      role = SpaceRoleDefinition(
        roleId: value['id'] as String,
        name: value['name'] as String,
        permissions: permissions,
      );
    } else {
      final grants = <SpacePermissionGrant>[];
      for (final raw in rawGrants as List) {
        final grant = SpacePermissionGrant.fromJson(raw);
        if (grant == null) return null;
        grants.add(grant);
      }
      final denials = <SpacePermissionDenial>[];
      for (final raw in rawDenials as List? ?? const []) {
        final denial = SpacePermissionDenial.fromJson(raw);
        if (denial == null) return null;
        denials.add(denial);
      }
      role = SpaceRoleDefinition(
        roleId: value['id'] as String,
        name: value['name'] as String,
        grants: grants,
        denials: denials,
      );
    }
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
    this.schemaVersion = 1,
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
  final int schemaVersion;
  final int revision;
  final String previousPolicyHash;
  final NodeId changedBy;
  final int changedAtMs;
  final List<SpaceRoleDefinition> roles;
  final List<SpaceMemberGroup> groups;
  final List<SpaceMemberRoleAssignment> directAssignments;

  bool get isStructurallyValid {
    if ((schemaVersion != 1 && schemaVersion != 2 && schemaVersion != 3) ||
        revision < 1 ||
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
        ) ||
        (schemaVersion == 1 && roles.any((role) => role.usesScopedEncoding)) ||
        (schemaVersion < 3 && roles.any((role) => role.usesDenyEncoding))) {
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
    for (final grant in grantsFor(member)) {
      result.add(grant.permission);
    }
    return result;
  }

  Set<SpacePermissionGrant> grantsFor(NodeId member) {
    final result = <SpacePermissionGrant>{};
    for (final roleId in roleIdsFor(member)) {
      final definition = role(roleId);
      if (definition != null) result.addAll(definition.grants);
    }
    return result;
  }

  Set<SpacePermissionDenial> denialsFor(NodeId member) {
    final result = <SpacePermissionDenial>{};
    for (final roleId in roleIdsFor(member)) {
      final definition = role(roleId);
      if (definition != null) result.addAll(definition.denials);
    }
    return result;
  }

  bool hasAnyGrant(NodeId member, SpacePermission permission) =>
      grantsFor(member).any((grant) => grant.permission == permission);

  bool denies(
    NodeId member,
    SpacePermission permission, {
    NodeId? channelId,
    NodeId? categoryId,
  }) => denialsFor(member).any(
    (denial) =>
        denial.permission == permission &&
        _scopeApplies(
          denial.scope,
          channelId: channelId,
          categoryId: categoryId,
        ),
  );

  bool allows(
    NodeId member,
    SpacePermission permission, {
    NodeId? channelId,
    NodeId? categoryId,
  }) {
    if (denies(
      member,
      permission,
      channelId: channelId,
      categoryId: categoryId,
    )) {
      return false;
    }
    for (final grant in grantsFor(member)) {
      if (grant.permission != permission) continue;
      if (_scopeApplies(
        grant.scope,
        channelId: channelId,
        categoryId: categoryId,
      )) {
        return true;
      }
    }
    return false;
  }

  bool hasValidScopeTargets({
    required Set<String> categoryIds,
    required Set<String> channelIds,
  }) {
    for (final role in roles) {
      final scopes = [
        ...role.grants.map((grant) => grant.scope),
        ...role.denials.map((denial) => denial.scope),
      ];
      for (final scope in scopes) {
        final target = scope.targetId?.hex;
        if (scope.kind == SpacePermissionScopeKind.category &&
            (target == null || !categoryIds.contains(target))) {
          return false;
        }
        if (scope.kind == SpacePermissionScopeKind.channel &&
            (target == null || !channelIds.contains(target))) {
          return false;
        }
      }
    }
    return true;
  }

  bool get usesScopedEncoding => schemaVersion >= 2;
  bool get usesDenyEncoding => schemaVersion >= 3;

  Uint8List canonicalBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  String get policyHash => crypto.sha256.convert(canonicalBytes()).toString();

  Map<String, dynamic> toJson() => {
    'space': spaceId.hex,
    if (schemaVersion >= 2) 'schema': schemaVersion,
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
        (value.containsKey('schema') && value['schema'] is! int) ||
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
        schemaVersion: value['schema'] is int ? value['schema'] as int : 1,
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

bool _scopeApplies(
  SpacePermissionScope scope, {
  required NodeId? channelId,
  required NodeId? categoryId,
}) => switch (scope.kind) {
  SpacePermissionScopeKind.space => true,
  SpacePermissionScopeKind.category =>
    scope.targetId == categoryId ||
        (categoryId == null && scope.targetId == channelId),
  SpacePermissionScopeKind.channel => scope.targetId == channelId,
  // Structural validation proves that a functional scope matches the
  // permission being evaluated.
  SpacePermissionScopeKind.posts ||
  SpacePermissionScopeKind.moderation ||
  SpacePermissionScopeKind.members ||
  SpacePermissionScopeKind.roles ||
  SpacePermissionScopeKind.settings ||
  SpacePermissionScopeKind.encryption ||
  SpacePermissionScopeKind.storage => true,
};
