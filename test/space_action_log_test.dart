import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/space_action_log.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_lifecycle.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/features/spaces/space_recent_actions_screen.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/l10n/app_localizations_ru.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

final _space = _id(9);
final _owner = _id(1);
final _admin = _id(2);
final _plain = _id(3);
final _outsider = _id(4);

const _roleId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// A row good enough to describe. Structural validity belongs to the wire
/// format's own tests; this file is about what a row *means* and who may read
/// it.
ControlEntry _row(
  ControlOp op, {
  NodeId? author,
  int seq = 0,
  NodeId? target,
  GroupRole? role,
  String? text,
  SpaceChannel? channel,
  int createdAtMs = 1000,
}) => ControlEntry(
  groupId: _space,
  author: author ?? _owner,
  seq: seq,
  prevHash: '',
  op: op,
  target: target,
  role: role,
  text: text,
  channel: channel,
  policyVersion: 0,
  createdAtMs: createdAtMs,
  signature: Uint8List(0),
);

/// Owner plus one admin plus one ordinary member — the three standings the
/// built-in roles distinguish.
GroupState _roster() => foldControlLog(
  owner: _owner,
  entries: [
    _row(ControlOp.addMember, target: _admin, role: GroupRole.admin),
    _row(
      ControlOp.addMember,
      seq: 1,
      target: _plain,
      role: GroupRole.member,
      createdAtMs: 1001,
    ),
  ],
  verify: (_) => true,
).state;

SpaceActionLogItem _find(List<SpaceActionLogItem> log, String stableId) =>
    log.firstWhere((item) => item.stableId == stableId);

void main() {
  test('every control op is described, and none falls through to generic', () {
    for (final op in ControlOp.values) {
      final descriptor = describeControlEntry(_row(op));
      expect(
        descriptor.kind,
        isNot(SpaceActionKind.other),
        reason: '$op must have a decided meaning, not the escape hatch',
      );
    }
    // Distinct ops may share a sentence, but the table must not collapse to a
    // handful of kinds.
    final kinds = {
      for (final op in ControlOp.values) describeControlEntry(_row(op)).kind,
    };
    expect(kinds.length, greaterThanOrEqualTo(20));
  });

  test('the owner reads every row', () {
    final log = spaceActionLog(
      control: [
        for (final op in ControlOp.values) _row(op, seq: op.index),
      ],
      state: _roster(),
      viewer: _owner,
    );
    expect(log.length, ControlOp.values.length);
    expect(log.every((item) => item.isVisible), isTrue);
  });

  test('an admin reads membership and moderation but not owner settings', () {
    final control = [
      _row(ControlOp.addMember, seq: 0, target: _plain, role: GroupRole.member),
      _row(ControlOp.setRole, seq: 1, target: _plain, role: GroupRole.admin),
      _row(ControlOp.ban, seq: 2, target: _plain),
      _row(ControlOp.createChannel, seq: 3),
      _row(ControlOp.setPostPin, seq: 4),
      _row(ControlOp.rotateEpoch, seq: 5),
      _row(ControlOp.setPolicy, seq: 6),
      _row(ControlOp.setName, seq: 7, text: 'Renamed'),
      _row(ControlOp.setRetention, seq: 8),
    ];
    final log = spaceActionLog(
      control: control,
      state: _roster(),
      viewer: _admin,
    );
    bool visible(int seq) => _find(log, '${_owner.hex}:$seq').isVisible;

    expect(visible(0), isTrue, reason: 'manageMembers');
    expect(visible(1), isTrue, reason: 'manageRoles');
    expect(visible(2), isTrue, reason: 'moderate');
    expect(visible(3), isTrue, reason: 'manageChannels');
    expect(visible(4), isTrue, reason: 'managePosts');
    expect(visible(5), isTrue, reason: 'manageEncryption');
    expect(visible(6), isTrue, reason: 'manageRoles');
    // manageSettings and manageStorage are owner-only built-ins, so an admin
    // is told that something happened and nothing more.
    expect(visible(7), isFalse, reason: 'manageSettings is owner-only');
    expect(visible(8), isFalse, reason: 'manageStorage is owner-only');
  });

  test('an ordinary member reads only what needs no right beyond view', () {
    final control = [
      _row(ControlOp.addMember, seq: 0, target: _plain, role: GroupRole.member),
      _row(ControlOp.ban, seq: 1, target: _plain),
      _row(ControlOp.setName, seq: 2, text: 'Renamed'),
      _row(ControlOp.checkpoint, seq: 3),
    ];
    final log = spaceActionLog(
      control: control,
      state: _roster(),
      viewer: _plain,
    );
    expect(_find(log, '${_owner.hex}:0').isVisible, isFalse);
    expect(_find(log, '${_owner.hex}:1').isVisible, isFalse);
    expect(_find(log, '${_owner.hex}:2').isVisible, isFalse);
    expect(_find(log, '${_owner.hex}:3').isVisible, isTrue);
  });

  test('a withheld row keeps its place and gives up nothing', () {
    final control = [
      _row(
        ControlOp.ban,
        seq: 0,
        author: _admin,
        target: _plain,
        createdAtMs: 5000,
      ),
      _row(ControlOp.checkpoint, seq: 1, createdAtMs: 4000),
    ];
    final log = spaceActionLog(
      control: control,
      state: _roster(),
      viewer: _plain,
    );

    // The count and the order are the honest part: the row is present and
    // still newest.
    expect(log.length, 2);
    expect(log.first.stableId, '${_admin.hex}:0');
    expect(log.first.createdAtMs, 5000);

    final withheld = log.first;
    expect(withheld.isVisible, isFalse);
    expect(withheld.descriptor, isNull);
    // Naming the author would say who moderates, which is exactly the fact the
    // moderate right is protecting.
    expect(withheld.author, isNull);
  });

  test('the same row reads in full for a viewer who holds the right', () {
    final control = [
      _row(ControlOp.ban, seq: 0, author: _admin, target: _plain),
    ];
    final withRight = spaceActionLog(
      control: control,
      state: _roster(),
      viewer: _owner,
    ).single;
    final withoutRight = spaceActionLog(
      control: control,
      state: _roster(),
      viewer: _plain,
    ).single;

    expect(withRight.isVisible, isTrue);
    expect(withRight.descriptor!.kind, SpaceActionKind.memberBanned);
    expect(withRight.descriptor!.target, _plain);
    expect(withRight.author, _admin);
    expect(withoutRight.isVisible, isFalse);
    // Same row, same position, same identity — only the contents differ.
    expect(withoutRight.stableId, withRight.stableId);
    expect(withoutRight.createdAtMs, withRight.createdAtMs);
  });

  test('a non-member is shown no log at all', () {
    final log = spaceActionLog(
      control: [_row(ControlOp.checkpoint)],
      state: _roster(),
      viewer: _outsider,
    );
    // Not even withheld rows: a stranger must not learn how busy a Space is.
    expect(log, isEmpty);
  });

  test('rows come back newest first, with ties broken deterministically', () {
    final control = [
      _row(ControlOp.checkpoint, seq: 0, createdAtMs: 100),
      _row(ControlOp.checkpoint, seq: 2, createdAtMs: 300),
      _row(ControlOp.checkpoint, seq: 1, createdAtMs: 200),
      _row(ControlOp.checkpoint, seq: 3, author: _admin, createdAtMs: 300),
    ];
    final log = spaceActionLog(
      control: control,
      state: _roster(),
      viewer: _owner,
    );
    expect(
      log.map((item) => item.createdAtMs).toList(),
      [300, 300, 200, 100],
    );
    // _admin's hex sorts above _owner's, so the tie resolves the same way on
    // every device.
    expect(log[0].stableId, '${_admin.hex}:3');
    expect(log[1].stableId, '${_owner.hex}:2');
  });

  test('a channel-scoped right opens that channel and no other', () {
    final inside = SpaceChannel(
      spaceId: _space,
      channelId: _id(5),
      kind: SpaceChannelKind.text,
      name: 'Inside',
      description: '',
      position: 0,
      isDefault: true,
      archived: false,
      history: SpaceChannelHistory.full,
      createdBy: _owner,
      createdAtMs: 11,
    );
    final outside = SpaceChannel(
      spaceId: _space,
      channelId: _id(6),
      kind: SpaceChannelKind.text,
      name: 'Outside',
      description: '',
      position: 1,
      isDefault: false,
      archived: false,
      history: SpaceChannelHistory.full,
      createdBy: _owner,
      createdAtMs: 12,
    );
    ControlEntry ownerEntry(
      int seq,
      ControlOp op, {
      NodeId? target,
      GroupRole? role,
      SpaceChannel? channel,
      SpaceAccessPolicy? accessPolicy,
      required String previous,
    }) => ControlEntry(
      version: accessPolicy != null ? 18 : 2,
      groupId: _space,
      author: _owner,
      seq: seq,
      prevHash: previous,
      op: op,
      target: target,
      role: role,
      channel: channel,
      accessPolicy: accessPolicy,
      policyVersion: 0,
      createdAtMs: accessPolicy?.changedAtMs ?? channel?.createdAtMs ?? 10,
      signature: Uint8List(0),
    );

    final addPlain = ownerEntry(
      0,
      ControlOp.addMember,
      target: _plain,
      role: GroupRole.member,
      previous: '',
    );
    final createInside = ownerEntry(
      1,
      ControlOp.createChannel,
      channel: inside,
      previous: controlEntryHash(addPlain),
    );
    final createOutside = ownerEntry(
      2,
      ControlOp.createChannel,
      channel: outside,
      previous: controlEntryHash(createInside),
    );
    final setPolicy = ownerEntry(
      3,
      ControlOp.setPolicy,
      accessPolicy: SpaceAccessPolicy(
        spaceId: _space,
        schemaVersion: 2,
        revision: 1,
        previousPolicyHash: '',
        changedBy: _owner,
        changedAtMs: 13,
        roles: [
          SpaceRoleDefinition(
            roleId: _roleId,
            name: 'Inside steward',
            grants: [
              SpacePermissionGrant(
                permission: SpacePermission.manageChannels,
                scope: SpacePermissionScope(
                  kind: SpacePermissionScopeKind.channel,
                  targetId: inside.channelId,
                ),
              ),
            ],
          ),
        ],
        groups: const [],
        directAssignments: [
          SpaceMemberRoleAssignment(member: _plain, roleIds: const [_roleId]),
        ],
      ),
      previous: controlEntryHash(createOutside),
    );

    final control = [addPlain, createInside, createOutside, setPolicy];
    final folded = foldControlLog(
      owner: _owner,
      entries: control,
      verify: (_) => true,
    );
    expect(folded.rejected, isEmpty);

    final log = spaceActionLog(
      control: control,
      state: folded.state,
      viewer: _plain,
    );
    expect(
      _find(log, '${_owner.hex}:1').isVisible,
      isTrue,
      reason: 'the steward manages Inside',
    );
    expect(
      _find(log, '${_owner.hex}:2').isVisible,
      isFalse,
      reason: 'Outside is somebody else\'s channel',
    );
  });

  test('archiving a Space does not blank the history it already has', () {
    final add = ControlEntry(
      version: 2,
      groupId: _space,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: _plain,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 100,
      signature: Uint8List(0),
    );
    final archive = ControlEntry(
      version: 10,
      groupId: _space,
      author: _owner,
      seq: 1,
      prevHash: controlEntryHash(add),
      op: ControlOp.archiveSpace,
      target: null,
      role: null,
      lifecycleTransition: SpaceLifecycleTransition(
        spaceId: _space,
        state: SpaceLifecycleState.archived,
        previousTransitionHash: '',
        controlCheckpoint: SpaceControlCheckpoint(const []),
        contentPolicyVersion: 0,
        messageHeads: const [],
        postHeads: const [],
        reactionHeads: const [],
        changedAtMs: 200,
      ),
      policyVersion: 0,
      createdAtMs: 200,
      signature: Uint8List(0),
    );
    final folded = foldControlLog(
      owner: _owner,
      entries: [add, archive],
      verify: (_) => true,
    );
    expect(folded.state.isArchived, isTrue, reason: 'fixture must archive');

    final log = spaceActionLog(
      control: [add, archive],
      state: folded.state,
      viewer: _owner,
    );
    // Judging a frozen Space's rows live would deny every management right and
    // wipe the owner's own history the moment they archive.
    expect(log.every((item) => item.isVisible), isTrue);
  });

  test('every kind reads as a sentence in both languages', () {
    final en = AppL10nEn();
    final ru = AppL10nRu();
    final english = <String>{};
    final russian = <String>{};
    for (final kind in SpaceActionKind.values) {
      final descriptor = SpaceActionDescriptor(
        kind: kind,
        requiredPermission: SpacePermission.view,
      );
      final enTitle = spaceActionTitle(en, descriptor, 'Alice');
      final ruTitle = spaceActionTitle(ru, descriptor, 'Алиса');
      expect(enTitle.trim(), isNotEmpty, reason: '$kind has no English text');
      expect(ruTitle.trim(), isNotEmpty, reason: '$kind has no Russian text');
      english.add(enTitle);
      russian.add(ruTitle);
    }
    // Two different administrative events must never render identically.
    expect(english.length, SpaceActionKind.values.length);
    expect(russian.length, SpaceActionKind.values.length);
  });

  test('a described row surfaces its clear-text detail, and only that', () {
    final en = AppL10nEn();
    final renamed = describeControlEntry(
      _row(ControlOp.setName, text: 'New name'),
    );
    expect(spaceActionDetail(en, renamed), contains('New name'));

    // A description can run to kilobytes, so the row says only that it moved.
    final described = describeControlEntry(
      _row(ControlOp.setDescription, text: 'a secret paragraph'),
    );
    expect(described.text, isNull);
    expect(spaceActionDetail(en, described), isNull);
  });
}
