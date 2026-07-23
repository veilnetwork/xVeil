import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/space_channel.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

void main() {
  final owner = _id(1);
  final bob = _id(2);
  final carol = _id(3);
  final space = _id(9);
  const roleId =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const groupId =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  SpaceAccessPolicy policy({
    int revision = 1,
    String previous = '',
    NodeId? author,
    Set<SpacePermission> permissions = const {SpacePermission.manageChannels},
  }) => SpaceAccessPolicy(
    spaceId: space,
    revision: revision,
    previousPolicyHash: previous,
    changedBy: author ?? owner,
    changedAtMs: 12,
    roles: [
      SpaceRoleDefinition(
        roleId: roleId,
        name: 'Channel steward',
        permissions: permissions,
      ),
    ],
    groups: [
      SpaceMemberGroup(
        groupId: groupId,
        name: 'Editors',
        members: [bob],
        roleIds: const [roleId],
      ),
    ],
    directAssignments: [
      SpaceMemberRoleAssignment(member: carol, roleIds: const [roleId]),
    ],
  );

  test(
    'policy JSON is canonical, round-trips and resolves group/direct roles',
    () {
      final value = policy();
      final decoded = SpaceAccessPolicy.fromJson(
        jsonDecode(jsonEncode(value.toJson())),
      );

      expect(value.isStructurallyValid, isTrue);
      expect(decoded?.policyHash, value.policyHash);
      expect(decoded?.permissionsFor(bob), {SpacePermission.manageChannels});
      expect(decoded?.permissionsFor(carol), {SpacePermission.manageChannels});
    },
  );

  test(
    'legacy role encoding stays byte-compatible while V18 scopes round-trip',
    () {
      final legacy = policy();
      final legacyJson = jsonEncode(legacy.toJson());
      final legacyDecoded = SpaceAccessPolicy.fromJson(jsonDecode(legacyJson));
      expect(legacyDecoded?.schemaVersion, 1);
      expect(jsonEncode(legacyDecoded?.toJson()), legacyJson);
      expect(
        (legacyDecoded!.roles.single.toJson()).containsKey('permissions'),
        isTrue,
      );
      expect(
        legacyDecoded.roles.single.toJson().containsKey('grants'),
        isFalse,
      );

      final category = _id(4);
      final channel = _id(5);
      final scoped = SpaceAccessPolicy(
        spaceId: space,
        schemaVersion: 2,
        revision: 1,
        previousPolicyHash: '',
        changedBy: owner,
        changedAtMs: 12,
        roles: [
          SpaceRoleDefinition(
            roleId: roleId,
            name: 'Scoped steward',
            grants: [
              SpacePermissionGrant(
                permission: SpacePermission.manageChannels,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.category,
                  targetId: category,
                ),
              ),
              SpacePermissionGrant(
                permission: SpacePermission.manageStorage,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.channel,
                  targetId: channel,
                ),
              ),
              const SpacePermissionGrant(
                permission: SpacePermission.managePosts,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.posts,
                ),
              ),
            ],
          ),
        ],
        groups: const [],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: const [roleId]),
        ],
      );
      final scopedDecoded = SpaceAccessPolicy.fromJson(
        jsonDecode(jsonEncode(scoped.toJson())),
      );

      expect(scoped.isStructurallyValid, isTrue);
      expect(scopedDecoded?.policyHash, scoped.policyHash);
      expect(scopedDecoded?.schemaVersion, 2);
      expect(
        scopedDecoded?.roles.single.toJson().containsKey('grants'),
        isTrue,
      );
      expect(
        scopedDecoded?.hasValidScopeTargets(
          categoryIds: {category.hex},
          channelIds: {channel.hex},
        ),
        isTrue,
      );
      expect(
        scopedDecoded?.hasValidScopeTargets(
          categoryIds: {category.hex},
          channelIds: const {},
        ),
        isFalse,
      );
      expect(
        scopedDecoded?.allows(
          bob,
          SpacePermission.manageChannels,
          categoryId: category,
        ),
        isTrue,
      );
      expect(
        scopedDecoded?.allows(
          bob,
          SpacePermission.manageChannels,
          channelId: channel,
        ),
        isFalse,
      );
      expect(
        scopedDecoded?.allows(
          bob,
          SpacePermission.manageStorage,
          channelId: channel,
        ),
        isTrue,
      );
      expect(scopedDecoded?.allows(bob, SpacePermission.managePosts), isTrue);
    },
  );

  test('V18 category grant authorizes only that signed channel subtree', () {
    final category = SpaceChannel(
      spaceId: space,
      channelId: _id(4),
      kind: SpaceChannelKind.category,
      name: 'Operations',
      description: '',
      position: 0,
      isDefault: false,
      archived: false,
      history: SpaceChannelHistory.full,
      createdBy: owner,
      createdAtMs: 11,
    );
    final inside = SpaceChannel(
      spaceId: space,
      channelId: _id(5),
      kind: SpaceChannelKind.text,
      name: 'Inside',
      description: '',
      categoryId: category.channelId,
      position: 1,
      isDefault: true,
      archived: false,
      history: SpaceChannelHistory.full,
      createdBy: owner,
      createdAtMs: 12,
    );
    final outside = SpaceChannel(
      spaceId: space,
      channelId: _id(6),
      kind: SpaceChannelKind.text,
      name: 'Outside',
      description: '',
      position: 2,
      isDefault: false,
      archived: false,
      history: SpaceChannelHistory.full,
      createdBy: owner,
      createdAtMs: 13,
    );
    ControlEntry ownerEntry(
      int seq,
      ControlOp op, {
      NodeId? target,
      GroupRole? role,
      SpaceChannel? channel,
      SpaceAccessPolicy? accessPolicy,
      required String previous,
      required int policyVersion,
    }) => ControlEntry(
      version: accessPolicy != null ? 18 : 2,
      groupId: space,
      author: owner,
      seq: seq,
      prevHash: previous,
      op: op,
      target: target,
      role: role,
      channel: channel,
      accessPolicy: accessPolicy,
      policyVersion: policyVersion,
      createdAtMs: accessPolicy?.changedAtMs ?? channel?.createdAtMs ?? 10,
      signature: Uint8List(0),
    );

    final addBob = ownerEntry(
      0,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
      previous: '',
      policyVersion: 0,
    );
    final createCategory = ownerEntry(
      1,
      ControlOp.createChannel,
      channel: category,
      previous: controlEntryHash(addBob),
      policyVersion: 0,
    );
    final createInside = ownerEntry(
      2,
      ControlOp.createChannel,
      channel: inside,
      previous: controlEntryHash(createCategory),
      policyVersion: 0,
    );
    final createOutside = ownerEntry(
      3,
      ControlOp.createChannel,
      channel: outside,
      previous: controlEntryHash(createInside),
      policyVersion: 0,
    );
    final scopedPolicy = SpaceAccessPolicy(
      spaceId: space,
      schemaVersion: 2,
      revision: 1,
      previousPolicyHash: '',
      changedBy: owner,
      changedAtMs: 14,
      roles: [
        SpaceRoleDefinition(
          roleId: roleId,
          name: 'Operations steward',
          grants: [
            SpacePermissionGrant(
              permission: SpacePermission.manageChannels,
              scope: SpacePermissionScope(
                kind: SpacePermissionScopeKind.category,
                targetId: category.channelId,
              ),
            ),
          ],
        ),
      ],
      groups: const [],
      directAssignments: [
        SpaceMemberRoleAssignment(member: bob, roleIds: const [roleId]),
      ],
    );
    final setPolicy = ownerEntry(
      4,
      ControlOp.setPolicy,
      accessPolicy: scopedPolicy,
      previous: controlEntryHash(createOutside),
      policyVersion: 0,
    );
    final editInside = ControlEntry(
      version: 2,
      groupId: space,
      author: bob,
      seq: 0,
      prevHash: '',
      op: ControlOp.updateChannel,
      target: null,
      role: null,
      channel: inside.copyWith(name: 'Inside updated'),
      policyVersion: 1,
      createdAtMs: 15,
      signature: Uint8List(0),
    );
    final editOutside = ControlEntry(
      version: 2,
      groupId: space,
      author: bob,
      seq: 1,
      prevHash: controlEntryHash(editInside),
      op: ControlOp.updateChannel,
      target: null,
      role: null,
      channel: outside.copyWith(
        name: 'Outside forged',
        categoryId: category.channelId,
      ),
      policyVersion: 1,
      createdAtMs: 16,
      signature: Uint8List(0),
    );

    final folded = foldControlLog(
      owner: owner,
      entries: [
        addBob,
        createCategory,
        createInside,
        createOutside,
        setPolicy,
        editInside,
        editOutside,
      ],
      verify: (_) => true,
    );

    expect(setPolicy.isStructurallyValid, isTrue);
    expect(folded.rejected, contains(editOutside));
    expect(folded.rejected, isNot(contains(editInside)));
    expect(folded.state.channels[inside.channelId.hex]?.name, 'Inside updated');
    expect(folded.state.channels[outside.channelId.hex]?.name, 'Outside');
    expect(
      SpaceAcl(folded.state).allows(
        bob,
        SpacePermission.manageChannels,
        channelId: inside.channelId,
      ),
      isTrue,
    );
    expect(
      SpaceAcl(folded.state).allows(
        bob,
        SpacePermission.manageChannels,
        channelId: outside.channelId,
      ),
      isFalse,
    );
  });

  test(
    'V18 fold rejects permission targets outside the signed channel tree',
    () {
      final unknown = _id(88);
      final addBob = ControlEntry(
        version: 2,
        groupId: space,
        author: owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 10,
        signature: Uint8List(0),
      );
      final invalidPolicy = SpaceAccessPolicy(
        spaceId: space,
        schemaVersion: 2,
        revision: 1,
        previousPolicyHash: '',
        changedBy: owner,
        changedAtMs: 11,
        roles: [
          SpaceRoleDefinition(
            roleId: roleId,
            name: 'Unknown channel',
            grants: [
              SpacePermissionGrant(
                permission: SpacePermission.manageChannels,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.channel,
                  targetId: unknown,
                ),
              ),
            ],
          ),
        ],
        groups: const [],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: const [roleId]),
        ],
      );
      final setPolicy = ControlEntry(
        version: 18,
        groupId: space,
        author: owner,
        seq: 1,
        prevHash: controlEntryHash(addBob),
        op: ControlOp.setPolicy,
        target: null,
        role: null,
        accessPolicy: invalidPolicy,
        policyVersion: 0,
        createdAtMs: invalidPolicy.changedAtMs,
        signature: Uint8List(0),
      );

      final folded = foldControlLog(
        owner: owner,
        entries: [addBob, setPolicy],
        verify: (_) => true,
      );

      expect(setPolicy.isStructurallyValid, isTrue);
      expect(folded.rejected, contains(setPolicy));
      expect(folded.state.accessPolicy, isNull);
    },
  );

  test('V17 policy delegates a control permission through the same fold', () {
    final addBob = ControlEntry(
      version: 2,
      groupId: space,
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 10,
      signature: Uint8List(0),
    );
    final addCarol = ControlEntry(
      version: 2,
      groupId: space,
      author: owner,
      seq: 1,
      prevHash: controlEntryHash(addBob),
      op: ControlOp.addMember,
      target: carol,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 11,
      signature: Uint8List(0),
    );
    final access = policy();
    final setPolicy = ControlEntry(
      version: 17,
      groupId: space,
      author: owner,
      seq: 2,
      prevHash: controlEntryHash(addCarol),
      op: ControlOp.setPolicy,
      target: null,
      role: null,
      accessPolicy: access,
      policyVersion: 0,
      createdAtMs: access.changedAtMs,
      signature: Uint8List(0),
    );
    final channel = SpaceChannel(
      spaceId: space,
      channelId: _id(8),
      name: 'Operations',
      description: '',
      kind: SpaceChannelKind.text,
      access: SpaceChannelAccess.space,
      history: SpaceChannelHistory.full,
      createdBy: bob,
      createdAtMs: 13,
      position: 1,
      isDefault: true,
      archived: false,
    );
    final delegated = ControlEntry(
      version: 2,
      groupId: space,
      author: bob,
      seq: 0,
      prevHash: '',
      op: ControlOp.createChannel,
      target: null,
      role: null,
      channel: channel,
      policyVersion: 1,
      createdAtMs: 13,
      signature: Uint8List(0),
    );

    final folded = foldControlLog(
      owner: owner,
      entries: [addBob, addCarol, setPolicy, delegated],
      verify: (_) => true,
    );

    expect(setPolicy.isStructurallyValid, isTrue);
    expect(folded.rejected, isEmpty);
    expect(folded.state.accessPolicy?.policyHash, access.policyHash);
    expect(
      SpaceAcl(folded.state).allows(bob, SpacePermission.manageChannels),
      isTrue,
    );
    expect(folded.state.channels[channel.channelId.hex], channel);
  });

  test('non-owner cannot replace policy to escalate their own permissions', () {
    final first = policy(permissions: const {SpacePermission.manageRoles});
    final addBob = ControlEntry(
      version: 2,
      groupId: space,
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 10,
      signature: Uint8List(0),
    );
    final addCarol = ControlEntry(
      version: 2,
      groupId: space,
      author: owner,
      seq: 1,
      prevHash: controlEntryHash(addBob),
      op: ControlOp.addMember,
      target: carol,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 11,
      signature: Uint8List(0),
    );
    final linkedSetFirst = ControlEntry(
      version: 17,
      groupId: space,
      author: owner,
      seq: 2,
      prevHash: controlEntryHash(addCarol),
      op: ControlOp.setPolicy,
      target: null,
      role: null,
      accessPolicy: first,
      policyVersion: 0,
      createdAtMs: first.changedAtMs,
      signature: Uint8List(0),
    );
    final forged = policy(
      revision: 2,
      previous: first.policyHash,
      author: bob,
      permissions: const {
        SpacePermission.manageRoles,
        SpacePermission.manageStorage,
      },
    );
    final setForged = ControlEntry(
      version: 17,
      groupId: space,
      author: bob,
      seq: 0,
      prevHash: '',
      op: ControlOp.setPolicy,
      target: null,
      role: null,
      accessPolicy: forged,
      policyVersion: 1,
      createdAtMs: forged.changedAtMs,
      signature: Uint8List(0),
    );

    final folded = foldControlLog(
      owner: owner,
      entries: [addBob, addCarol, linkedSetFirst, setForged],
      verify: (_) => true,
    );

    expect(folded.rejected, contains(setForged));
    expect(folded.state.accessPolicy?.policyHash, first.policyHash);
    expect(
      SpaceAcl(folded.state).allows(bob, SpacePermission.manageStorage),
      isFalse,
    );
  });

  test(
    'V20 delegates only lower roles and rejects self or peer escalation',
    () {
      const managerRoleId =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      const publisherRoleId =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      const storageRoleId =
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      final managerRole = SpaceRoleDefinition(
        roleId: managerRoleId,
        name: 'Role manager',
        permissions: const {
          SpacePermission.manageRoles,
          SpacePermission.managePosts,
        },
      );
      final publisherRole = SpaceRoleDefinition(
        roleId: publisherRoleId,
        name: 'Publisher',
        permissions: const {SpacePermission.publishPosts},
      );
      final first = SpaceAccessPolicy(
        spaceId: space,
        revision: 1,
        previousPolicyHash: '',
        changedBy: owner,
        changedAtMs: 12,
        roles: [managerRole, publisherRole],
        groups: const [],
        directAssignments: [
          SpaceMemberRoleAssignment(
            member: bob,
            roleIds: const [managerRoleId],
          ),
        ],
      );
      final addBob = ControlEntry(
        version: 2,
        groupId: space,
        author: owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 10,
        signature: Uint8List(0),
      );
      final addCarol = ControlEntry(
        version: 2,
        groupId: space,
        author: owner,
        seq: 1,
        prevHash: controlEntryHash(addBob),
        op: ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 11,
        signature: Uint8List(0),
      );
      final setFirst = ControlEntry(
        version: 17,
        groupId: space,
        author: owner,
        seq: 2,
        prevHash: controlEntryHash(addCarol),
        op: ControlOp.setPolicy,
        target: null,
        role: null,
        accessPolicy: first,
        policyVersion: 0,
        createdAtMs: first.changedAtMs,
        signature: Uint8List(0),
      );
      final base = foldControlLog(
        owner: owner,
        entries: [addBob, addCarol, setFirst],
        verify: (_) => true,
      );
      expect(base.rejected, isEmpty);
      final acl = SpaceAcl(base.state);

      SpaceAccessPolicy next({
        List<SpaceRoleDefinition>? roles,
        List<SpaceMemberRoleAssignment>? direct,
      }) => SpaceAccessPolicy(
        spaceId: space,
        revision: 2,
        previousPolicyHash: first.policyHash,
        changedBy: bob,
        changedAtMs: 20,
        roles: roles ?? [managerRole, publisherRole],
        groups: const [],
        directAssignments:
            direct ??
            [
              SpaceMemberRoleAssignment(
                member: bob,
                roleIds: const [managerRoleId],
              ),
              SpaceMemberRoleAssignment(
                member: carol,
                roleIds: const [publisherRoleId],
              ),
            ],
      );

      final lower = next();
      final delegated = ControlEntry(
        version: 20,
        groupId: space,
        author: bob,
        seq: 0,
        prevHash: '',
        op: ControlOp.setPolicy,
        target: null,
        role: null,
        accessPolicy: lower,
        policyVersion: 1,
        createdAtMs: lower.changedAtMs,
        signature: Uint8List(0),
      );
      final accepted = foldControlLog(
        owner: owner,
        entries: [addBob, addCarol, setFirst, delegated],
        verify: (_) => true,
      );
      expect(delegated.isStructurallyValid, isTrue);
      expect(
        ControlEntry.fromJson(
          jsonDecode(jsonEncode(delegated.toJson())),
        )?.canonicalBytes(),
        delegated.canonicalBytes(),
      );
      expect(accepted.rejected, isEmpty);
      expect(accepted.state.customRoleIdsOf(carol), contains(publisherRoleId));

      final self = next(
        direct: [
          SpaceMemberRoleAssignment(
            member: bob,
            roleIds: const [managerRoleId, publisherRoleId],
          ),
        ],
      );
      expect(
        acl.authorizePolicyChange(bob, self).denial,
        SpaceAuthorizationDenial.selfEscalation,
      );
      final forgedSelf = ControlEntry(
        version: 20,
        groupId: space,
        author: bob,
        seq: 0,
        prevHash: '',
        op: ControlOp.setPolicy,
        target: null,
        role: null,
        accessPolicy: self,
        policyVersion: 1,
        createdAtMs: self.changedAtMs,
        signature: Uint8List(0),
      );
      final rejectedSelf = foldControlLog(
        owner: owner,
        entries: [addBob, addCarol, setFirst, forgedSelf],
        verify: (_) => true,
      );
      expect(rejectedSelf.rejected, contains(forgedSelf));
      expect(rejectedSelf.state.accessPolicy?.policyHash, first.policyHash);

      final peer = next(
        direct: [
          SpaceMemberRoleAssignment(
            member: bob,
            roleIds: const [managerRoleId],
          ),
          SpaceMemberRoleAssignment(
            member: carol,
            roleIds: const [managerRoleId],
          ),
        ],
      );
      expect(
        acl.authorizePolicyChange(bob, peer).denial,
        SpaceAuthorizationDenial.protectedTarget,
      );

      final storageRole = SpaceRoleDefinition(
        roleId: storageRoleId,
        name: 'Storage manager',
        permissions: const {SpacePermission.manageStorage},
      );
      final outside = next(roles: [managerRole, publisherRole, storageRole]);
      expect(
        acl.authorizePolicyChange(bob, outside).denial,
        SpaceAuthorizationDenial.permissionCeiling,
      );
    },
  );

  test('V19 denial snapshots are canonical without changing V17/V18 bytes', () {
    final category = _id(4);
    final legacyV18 = SpaceAccessPolicy(
      spaceId: space,
      schemaVersion: 2,
      revision: 1,
      previousPolicyHash: '',
      changedBy: owner,
      changedAtMs: 20,
      roles: [
        SpaceRoleDefinition(
          roleId: roleId,
          name: 'Scoped',
          grants: [
            const SpacePermissionGrant(
              permission: SpacePermission.manageChannels,
              scope: SpacePermissionScope.space(),
            ),
          ],
        ),
      ],
      groups: const [],
      directAssignments: [
        SpaceMemberRoleAssignment(member: bob, roleIds: const [roleId]),
      ],
    );
    final legacyBytes = jsonEncode(legacyV18.toJson());
    expect(legacyBytes, isNot(contains('"denies"')));
    expect(
      jsonEncode(SpaceAccessPolicy.fromJson(jsonDecode(legacyBytes))!.toJson()),
      legacyBytes,
    );

    final denied = SpaceAccessPolicy(
      spaceId: space,
      schemaVersion: 3,
      revision: 1,
      previousPolicyHash: '',
      changedBy: owner,
      changedAtMs: 21,
      roles: [
        SpaceRoleDefinition(
          roleId: roleId,
          name: 'Scoped',
          grants: [
            const SpacePermissionGrant(
              permission: SpacePermission.manageChannels,
              scope: SpacePermissionScope.space(),
            ),
          ],
          denials: [
            SpacePermissionDenial(
              permission: SpacePermission.manageChannels,
              scope: SpacePermissionScope(
                kind: SpacePermissionScopeKind.category,
                targetId: category,
              ),
            ),
          ],
        ),
      ],
      groups: const [],
      directAssignments: [
        SpaceMemberRoleAssignment(member: bob, roleIds: const [roleId]),
      ],
    );
    final deniedJson = jsonEncode(denied.toJson());
    final decoded = SpaceAccessPolicy.fromJson(jsonDecode(deniedJson));
    final v19 = ControlEntry(
      version: 19,
      groupId: space,
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.setPolicy,
      target: null,
      role: null,
      accessPolicy: denied,
      policyVersion: 0,
      createdAtMs: denied.changedAtMs,
      signature: Uint8List(0),
    );
    final wrongVersion = ControlEntry(
      version: 18,
      groupId: space,
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.setPolicy,
      target: null,
      role: null,
      accessPolicy: denied,
      policyVersion: 0,
      createdAtMs: denied.changedAtMs,
      signature: Uint8List(0),
    );
    final wrongSchema = SpaceAccessPolicy(
      spaceId: space,
      schemaVersion: 2,
      revision: denied.revision,
      previousPolicyHash: denied.previousPolicyHash,
      changedBy: denied.changedBy,
      changedAtMs: denied.changedAtMs,
      roles: denied.roles,
      groups: denied.groups,
      directAssignments: denied.directAssignments,
    );

    expect(denied.isStructurallyValid, isTrue);
    expect(decoded?.policyHash, denied.policyHash);
    expect(jsonEncode(decoded?.toJson()), deniedJson);
    expect(v19.isStructurallyValid, isTrue);
    expect(
      ControlEntry.fromJson(
        jsonDecode(jsonEncode(v19.toJson())),
      )?.canonicalBytes(),
      v19.canonicalBytes(),
    );
    expect(wrongVersion.isStructurallyValid, isFalse);
    expect(wrongSchema.isStructurallyValid, isFalse);
  });

  test(
    'V19 deny wins across inherited group/direct roles except for owner',
    () {
      final admin = _id(7);
      final categoryId = _id(4);
      final insideId = _id(5);
      final outsideId = _id(6);
      const denialRoleId =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final category = SpaceChannel(
        spaceId: space,
        channelId: categoryId,
        kind: SpaceChannelKind.category,
        name: 'Operations',
        description: '',
        position: 0,
        isDefault: false,
        archived: false,
        history: SpaceChannelHistory.full,
        createdBy: owner,
        createdAtMs: 12,
      );
      final inside = SpaceChannel(
        spaceId: space,
        channelId: insideId,
        kind: SpaceChannelKind.text,
        name: 'Inside',
        description: '',
        categoryId: categoryId,
        position: 1,
        isDefault: true,
        archived: false,
        history: SpaceChannelHistory.full,
        createdBy: owner,
        createdAtMs: 13,
      );
      final outside = SpaceChannel(
        spaceId: space,
        channelId: outsideId,
        kind: SpaceChannelKind.text,
        name: 'Outside',
        description: '',
        position: 2,
        isDefault: false,
        archived: false,
        history: SpaceChannelHistory.full,
        createdBy: owner,
        createdAtMs: 14,
      );
      ControlEntry ownerEntry(
        int seq,
        ControlOp op, {
        NodeId? target,
        GroupRole? role,
        SpaceChannel? channel,
        SpaceAccessPolicy? accessPolicy,
        required String previous,
        required int policyVersion,
      }) => ControlEntry(
        version: accessPolicy == null ? 2 : 19,
        groupId: space,
        author: owner,
        seq: seq,
        prevHash: previous,
        op: op,
        target: target,
        role: role,
        channel: channel,
        accessPolicy: accessPolicy,
        policyVersion: policyVersion,
        createdAtMs: accessPolicy?.changedAtMs ?? channel?.createdAtMs ?? 10,
        signature: Uint8List(0),
      );

      final addAdmin = ownerEntry(
        0,
        ControlOp.addMember,
        target: admin,
        role: GroupRole.admin,
        previous: '',
        policyVersion: 0,
      );
      final addBob = ownerEntry(
        1,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
        previous: controlEntryHash(addAdmin),
        policyVersion: 0,
      );
      final createCategory = ownerEntry(
        2,
        ControlOp.createChannel,
        channel: category,
        previous: controlEntryHash(addBob),
        policyVersion: 0,
      );
      final createInside = ownerEntry(
        3,
        ControlOp.createChannel,
        channel: inside,
        previous: controlEntryHash(createCategory),
        policyVersion: 0,
      );
      final createOutside = ownerEntry(
        4,
        ControlOp.createChannel,
        channel: outside,
        previous: controlEntryHash(createInside),
        policyVersion: 0,
      );
      final access = SpaceAccessPolicy(
        spaceId: space,
        schemaVersion: 3,
        revision: 1,
        previousPolicyHash: '',
        changedBy: owner,
        changedAtMs: 20,
        roles: [
          SpaceRoleDefinition(
            roleId: roleId,
            name: 'All channels',
            grants: [
              const SpacePermissionGrant(
                permission: SpacePermission.manageChannels,
                scope: SpacePermissionScope.space(),
              ),
            ],
          ),
          SpaceRoleDefinition(
            roleId: denialRoleId,
            name: 'Operations blocked',
            grants: const [],
            denials: [
              SpacePermissionDenial(
                permission: SpacePermission.manageChannels,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.category,
                  targetId: categoryId,
                ),
              ),
            ],
          ),
        ],
        groups: [
          SpaceMemberGroup(
            groupId: groupId,
            name: 'Channel managers',
            members: [admin, bob],
            roleIds: const [roleId],
          ),
        ],
        directAssignments: [
          SpaceMemberRoleAssignment(
            member: admin,
            roleIds: const [denialRoleId],
          ),
          SpaceMemberRoleAssignment(member: bob, roleIds: const [denialRoleId]),
          SpaceMemberRoleAssignment(
            member: owner,
            roleIds: const [denialRoleId],
          ),
        ],
      );
      final setPolicy = ownerEntry(
        5,
        ControlOp.setPolicy,
        accessPolicy: access,
        previous: controlEntryHash(createOutside),
        policyVersion: 0,
      );
      final deniedEdit = ControlEntry(
        version: 2,
        groupId: space,
        author: admin,
        seq: 0,
        prevHash: '',
        op: ControlOp.updateChannel,
        target: null,
        role: null,
        channel: inside.copyWith(name: 'Forbidden edit'),
        policyVersion: 1,
        createdAtMs: 21,
        signature: Uint8List(0),
      );
      final folded = foldControlLog(
        owner: owner,
        entries: [
          addAdmin,
          addBob,
          createCategory,
          createInside,
          createOutside,
          setPolicy,
          deniedEdit,
        ],
        verify: (_) => true,
      );
      final acl = SpaceAcl(folded.state);

      expect(setPolicy.isStructurallyValid, isTrue);
      expect(folded.rejected, contains(deniedEdit));
      expect(
        acl
            .authorize(
              admin,
              SpacePermission.manageChannels,
              channelId: insideId,
            )
            .denial,
        SpaceAuthorizationDenial.explicitlyDenied,
      );
      expect(
        acl.allows(bob, SpacePermission.manageChannels, channelId: insideId),
        isFalse,
      );
      expect(
        acl.allows(bob, SpacePermission.manageChannels, channelId: outsideId),
        isTrue,
      );
      expect(
        acl.allows(owner, SpacePermission.manageChannels, channelId: insideId),
        isTrue,
      );
      expect(acl.allowsAnyScope(bob, SpacePermission.manageChannels), isTrue);
    },
  );
}
