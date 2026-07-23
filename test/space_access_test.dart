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
