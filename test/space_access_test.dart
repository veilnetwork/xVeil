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
}
