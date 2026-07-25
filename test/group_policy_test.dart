import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_epoch.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_recommendation.dart';
import 'package:xveil/domain/space_join_request.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

final _owner = _id(1);
final _admin = _id(2);
final _bob = _id(3);
final _carol = _id(4);
final _eve = _id(9);

int _t = 1000;
ControlEntry _e(
  NodeId author,
  int seq,
  ControlOp op, {
  NodeId? target,
  GroupRole? role,
  String? text,
  int policyVersion = 0,
}) => ControlEntry(
  author: author,
  seq: seq,
  prevHash: '',
  op: op,
  target: target,
  role: role,
  text: text,
  policyVersion: policyVersion,
  createdAtMs: _t++,
  signature: Uint8List(0),
);

/// Verifier that accepts everything (signatures tested via canonicalBytes).
bool _ok(ControlEntry e) => true;

GroupState _fold(
  List<ControlEntry> log, {
  bool Function(ControlEntry) verify = _ok,
}) => foldControlLog(owner: _owner, entries: log, verify: verify).state;

void main() {
  setUp(() => _t = 1000);

  test('genesis: owner is the sole member', () {
    final s = _fold(const []);
    expect(s.roleOf(_owner), GroupRole.owner);
    expect(s.members.length, 1);
  });

  test('owner adds an admin, admin adds a member', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _admin, role: GroupRole.admin),
      _e(_admin, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
    ]);
    expect(s.roleOf(_admin), GroupRole.admin);
    expect(s.roleOf(_bob), GroupRole.member);
    expect(s.members.length, 3);
  });

  test('an admin cannot mint another admin (role >= own rank rejected)', () {
    final r = foldControlLog(
      owner: _owner,
      entries: [
        _e(
          _owner,
          0,
          ControlOp.addMember,
          target: _admin,
          role: GroupRole.admin,
        ),
        _e(_admin, 0, ControlOp.addMember, target: _eve, role: GroupRole.admin),
      ],
      verify: _ok,
    );
    expect(r.state.isMember(_eve), isFalse);
    expect(r.rejected.length, 1);
  });

  test('a member cannot perform control ops', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(
        _owner,
        1,
        ControlOp.addMember,
        target: _carol,
        role: GroupRole.member,
      ),
      _e(_bob, 0, ControlOp.removeMember, target: _carol), // bob is a member
    ]);
    expect(s.isMember(_carol), isTrue, reason: 'the member op was rejected');
  });

  test('an admin cannot remove the owner or a peer admin', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _admin, role: GroupRole.admin),
      _e(_owner, 1, ControlOp.addMember, target: _bob, role: GroupRole.admin),
      _e(_admin, 0, ControlOp.removeMember, target: _owner), // owner: rejected
      _e(_admin, 1, ControlOp.removeMember, target: _bob), // peer: rejected
    ]);
    expect(s.roleOf(_owner), GroupRole.owner);
    expect(s.isMember(_bob), isTrue);
  });

  test('remove + ban rotate the epoch', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(
        _owner,
        1,
        ControlOp.addMember,
        target: _carol,
        role: GroupRole.member,
      ),
      _e(_owner, 2, ControlOp.ban, target: _bob),
      _e(_owner, 3, ControlOp.removeMember, target: _carol),
    ]);
    expect(s.isMember(_bob), isFalse);
    expect(s.isMember(_carol), isFalse);
    expect(s.epoch, 2);
  });

  test('mute/unmute toggles a member flag', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(_owner, 1, ControlOp.mute, target: _bob),
    ]);
    expect(s.memberOf(_bob)!.muted, isTrue);
    final s2 = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(_owner, 1, ControlOp.mute, target: _bob),
      _e(_owner, 2, ControlOp.unmute, target: _bob),
    ]);
    expect(s2.memberOf(_bob)!.muted, isFalse);
  });

  test('setPolicy is owner-only; bumps the policy version', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _admin, role: GroupRole.admin),
      _e(_admin, 0, ControlOp.setPolicy), // rejected
      _e(_owner, 1, ControlOp.setPolicy),
    ]);
    expect(s.policyVersion, 1);
  });

  test(
    'Space description is a signed folded setting and members cannot edit it',
    () {
      final result = foldControlLog(
        owner: _owner,
        entries: [
          _e(
            _owner,
            0,
            ControlOp.addMember,
            target: _bob,
            role: GroupRole.member,
          ),
          _e(_bob, 0, ControlOp.setDescription, text: 'forged summary'),
          _e(
            _owner,
            1,
            ControlOp.setDescription,
            text: 'Protocol research and field notes',
          ),
          _e(
            _owner,
            2,
            ControlOp.setDescription,
            target: _bob,
            text: 'ambiguous payload',
          ),
        ],
        verify: _ok,
        initialDescription: 'Genesis summary',
      );

      expect(result.state.description, 'Protocol research and field notes');
      expect(result.rejected, hasLength(2));
      expect(result.rejected.first.author, _bob);
      final accepted = result.accepted.last;
      expect(ControlEntry.fromJson(accepted.toJson())?.text, accepted.text);
      expect(
        utf8.decode(accepted.canonicalBytes()),
        contains('setDescription'),
      );
    },
  );

  test(
    'Space profile media is a signed folded setting with a strict payload',
    () {
      final avatar = 'a' * 64;
      final cover = 'b' * 64;
      final result = foldControlLog(
        owner: _owner,
        entries: [
          _e(
            _owner,
            0,
            ControlOp.addMember,
            target: _bob,
            role: GroupRole.member,
          ),
          // A plain member cannot re-point the profile.
          _e(
            _bob,
            0,
            ControlOp.setProfileMedia,
            text: encodeSpaceProfileMedia(avatarContentId: 'f' * 64),
          ),
          _e(
            _owner,
            1,
            ControlOp.setProfileMedia,
            text: encodeSpaceProfileMedia(
              avatarContentId: avatar,
              coverContentId: cover,
            ),
          ),
          // Garbage payloads are rejected instead of folding into state.
          _e(_owner, 2, ControlOp.setProfileMedia, text: '{"avatar":"nope"}'),
        ],
        verify: _ok,
        initialAvatarContentId: 'e' * 64,
      );
      expect(result.state.avatarContentId, avatar);
      expect(result.state.coverContentId, cover);
      expect(result.rejected, hasLength(2));

      final cleared = foldControlLog(
        owner: _owner,
        entries: [
          _e(_owner, 0, ControlOp.setProfileMedia, text: '{}'),
        ],
        verify: _ok,
        initialAvatarContentId: 'e' * 64,
        initialCoverContentId: 'd' * 64,
      );
      expect(cleared.state.avatarContentId, isNull);
      expect(cleared.state.coverContentId, isNull);

      final genesis = foldControlLog(
        owner: _owner,
        entries: const [],
        verify: _ok,
        initialAvatarContentId: 'e' * 64,
      );
      expect(
        genesis.state.avatarContentId,
        'e' * 64,
        reason: 'the genesis manifest seeds the folded profile',
      );
    },
  );

  test(
    'ownership transfer is atomic and leaves exactly one effective owner',
    () {
      final add = ControlEntry(
        version: 2,
        groupId: _owner,
        author: _owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.addMember,
        target: _bob,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: _t++,
        signature: Uint8List(0),
      );
      final transfer = ControlEntry(
        version: 6,
        groupId: _owner,
        author: _owner,
        seq: 1,
        prevHash: controlEntryHash(add),
        op: ControlOp.transferOwnership,
        target: _bob,
        role: null,
        policyVersion: 0,
        createdAtMs: _t++,
        signature: Uint8List(0),
      );
      final newOwnerPolicy = ControlEntry(
        version: 2,
        groupId: _owner,
        author: _bob,
        seq: 0,
        prevHash: '',
        op: ControlOp.setPolicy,
        target: null,
        role: null,
        policyVersion: 0,
        createdAtMs: _t++,
        signature: Uint8List(0),
      );
      final result = foldControlLog(
        owner: _owner,
        entries: [add, transfer, newOwnerPolicy],
        verify: _ok,
      );

      expect(result.rejected, isEmpty);
      expect(result.state.roleOf(_owner), GroupRole.admin);
      expect(result.state.roleOf(_bob), GroupRole.owner);
      expect(
        result.state.members.values.where(
          (member) => member.role == GroupRole.owner,
        ),
        hasLength(1),
      );
      expect(
        result.state.policyVersion,
        1,
        reason: 'authority moves immediately',
      );
      expect(
        canApply(
          authorRole: GroupRole.admin,
          op: ControlOp.transferOwnership,
          targetRole: GroupRole.member,
        ),
        isFalse,
      );
    },
  );

  test('ownership transfer is a strict v6 wire operation', () {
    final valid = ControlEntry(
      version: 6,
      groupId: _owner,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.transferOwnership,
      target: _bob,
      role: null,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(64),
    );
    expect(valid.isStructurallyValid, isTrue);
    expect(
      ControlEntry.fromJson(valid.toJson())?.op,
      ControlOp.transferOwnership,
    );
    expect(
      ControlEntry(
        version: 2,
        groupId: _owner,
        author: _owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.transferOwnership,
        target: _bob,
        role: null,
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(64),
      ).isStructurallyValid,
      isFalse,
    );
  });

  test('stale or future policy context is rejected deterministically', () {
    final result = foldControlLog(
      owner: _owner,
      entries: [
        _e(_owner, 0, ControlOp.setPolicy),
        _e(
          _owner,
          1,
          ControlOp.addMember,
          target: _bob,
          role: GroupRole.member,
        ),
        _e(
          _owner,
          2,
          ControlOp.addMember,
          target: _carol,
          role: GroupRole.member,
          policyVersion: 1,
        ),
      ],
      verify: _ok,
    );

    expect(result.state.isMember(_bob), isFalse);
    expect(result.state.isMember(_carol), isTrue);
    expect(result.rejected, hasLength(1));
  });

  test('SpaceAcl is the shared publish, distribute and management gate', () {
    final state = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _admin, role: GroupRole.admin),
      _e(_owner, 1, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(_owner, 2, ControlOp.mute, target: _bob),
    ]);
    final acl = SpaceAcl(state);

    expect(acl.allows(_bob, SpacePermission.view), isTrue);
    expect(acl.allows(_bob, SpacePermission.distributeContent), isTrue);
    expect(
      acl.authorize(_bob, SpacePermission.publishMessages).denial,
      SpaceAuthorizationDenial.muted,
    );
    expect(acl.allows(_admin, SpacePermission.manageMembers), isTrue);
    expect(acl.allows(_admin, SpacePermission.manageSettings), isFalse);
    expect(acl.allows(_owner, SpacePermission.manageSettings), isTrue);
    expect(
      acl.authorize(_eve, SpacePermission.view).denial,
      SpaceAuthorizationDenial.notMember,
    );
    expect(
      acl
          .authorizeControl(_admin, ControlOp.removeMember, target: _owner)
          .denial,
      SpaceAuthorizationDenial.protectedTarget,
    );
    expect(
      acl
          .authorizeControl(_admin, ControlOp.removeMember, target: _bob)
          .allowed,
      isTrue,
    );
  });

  test(
    'v8 moderation restrictions are time-aware and revocation is audited',
    () {
      final add = ControlEntry(
        version: 2,
        groupId: _owner,
        author: _owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.addMember,
        target: _bob,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 1000,
        signature: Uint8List(0),
      );
      final action = SpaceModerationAction(
        kind: SpaceModerationKind.restrictMessages,
        target: _bob,
        scope: SpaceModerationScope.space,
        reason: 'Repeated flooding',
        createdAtMs: 1100,
        expiresAtMs: 2000,
      );
      final moderate = ControlEntry(
        version: 8,
        groupId: _owner,
        author: _owner,
        seq: 1,
        prevHash: controlEntryHash(add),
        op: ControlOp.moderate,
        target: _bob,
        role: null,
        moderationAction: action,
        policyVersion: 0,
        createdAtMs: 1100,
        signature: Uint8List(0),
      );
      final revoke = ControlEntry(
        version: 8,
        groupId: _owner,
        author: _owner,
        seq: 2,
        prevHash: controlEntryHash(moderate),
        op: ControlOp.revokeModeration,
        target: _bob,
        role: null,
        moderationRevocation: SpaceModerationRevocation(
          actionAuthor: _owner,
          actionSeq: 1,
          reason: 'Restriction reviewed',
          revokedAtMs: 1200,
        ),
        policyVersion: 0,
        createdAtMs: 1200,
        signature: Uint8List(0),
      );
      final result = foldControlLog(
        owner: _owner,
        entries: [add, moderate, revoke],
        verify: _ok,
      );

      expect(result.rejected, isEmpty);
      final record = result.state.moderationRecords['${_owner.hex}:1']!;
      expect(record.revokedBy, _owner);
      expect(record.revocationReason, 'Restriction reviewed');
      expect(record.isActiveAt(1150), isTrue);
      expect(record.isActiveAt(1250), isFalse);
      expect(
        SpaceAcl(
          result.state,
        ).allows(_bob, SpacePermission.publishMessages, atMs: 1150),
        isFalse,
      );
      expect(
        SpaceAcl(
          result.state,
        ).allows(_bob, SpacePermission.publishMessages, atMs: 1250),
        isTrue,
      );
      expect(
        ControlEntry.fromJson(moderate.toJson())?.moderationAction?.reason,
        action.reason,
      );
    },
  );

  test('permanent ban blocks re-add until its signed revocation', () {
    final add = ControlEntry(
      version: 2,
      groupId: _owner,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1000,
      signature: Uint8List(0),
    );
    final ban = ControlEntry(
      version: 8,
      groupId: _owner,
      author: _owner,
      seq: 1,
      prevHash: controlEntryHash(add),
      op: ControlOp.moderate,
      target: _bob,
      role: null,
      moderationAction: SpaceModerationAction(
        kind: SpaceModerationKind.permanentBan,
        target: _bob,
        scope: SpaceModerationScope.space,
        reason: 'Account compromise',
        createdAtMs: 1100,
      ),
      postBoundary: const SpacePostBoundary(seq: -1, hash: ''),
      policyVersion: 0,
      createdAtMs: 1100,
      signature: Uint8List(0),
    );
    final blockedAdd = ControlEntry(
      version: 2,
      groupId: _owner,
      author: _owner,
      seq: 2,
      prevHash: controlEntryHash(ban),
      op: ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1200,
      signature: Uint8List(0),
    );
    final blocked = foldControlLog(
      owner: _owner,
      entries: [add, ban, blockedAdd],
      verify: _ok,
    );
    expect(blocked.state.isMember(_bob), isFalse);
    expect(blocked.rejected, contains(blockedAdd));

    final revoke = ControlEntry(
      version: 8,
      groupId: _owner,
      author: _owner,
      seq: 2,
      prevHash: controlEntryHash(ban),
      op: ControlOp.revokeModeration,
      target: _bob,
      role: null,
      moderationRevocation: SpaceModerationRevocation(
        actionAuthor: _owner,
        actionSeq: 1,
        reason: 'Identity recovered',
        revokedAtMs: 1300,
      ),
      policyVersion: 0,
      createdAtMs: 1300,
      signature: Uint8List(0),
    );
    final reAdd = ControlEntry(
      version: 2,
      groupId: _owner,
      author: _owner,
      seq: 3,
      prevHash: controlEntryHash(revoke),
      op: ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1400,
      signature: Uint8List(0),
    );
    final restored = foldControlLog(
      owner: _owner,
      entries: [add, ban, revoke, reAdd],
      verify: _ok,
    );
    expect(restored.rejected, isEmpty);
    expect(restored.state.isMember(_bob), isTrue);
    expect(restored.state.epoch, 1);
  });

  test('distinct same-seq control rows quarantine both fork branches', () {
    final r = foldControlLog(
      owner: _owner,
      entries: [
        _e(
          _owner,
          0,
          ControlOp.addMember,
          target: _bob,
          role: GroupRole.member,
        ),
        _e(
          _owner,
          0,
          ControlOp.addMember,
          target: _carol,
          role: GroupRole.member,
        ), // dup seq 0
      ],
      verify: _ok,
    );
    expect(r.rejected.length, 2);
    expect(r.state.members.length, 1);
  });

  test('byte-identical redelivery deduplicates without becoming a fork', () {
    final entry = _e(
      _owner,
      0,
      ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
    );
    final result = foldControlLog(
      owner: _owner,
      entries: [entry, entry],
      verify: _ok,
    );
    expect(result.rejected, isEmpty);
    expect(result.state.isMember(_bob), isTrue);
  });

  test('control v2 enforces exact predecessor and refuses downgrade', () {
    final add = ControlEntry(
      version: 2,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1000,
      signature: Uint8List(0),
    );
    final remove = ControlEntry(
      version: 2,
      author: _owner,
      seq: 1,
      prevHash: controlEntryHash(add),
      op: ControlOp.removeMember,
      target: _bob,
      role: null,
      policyVersion: 0,
      createdAtMs: 1001,
      signature: Uint8List(0),
    );
    final valid = foldControlLog(
      owner: _owner,
      entries: [remove, add],
      verify: _ok,
    );
    expect(valid.rejected, isEmpty);
    expect(valid.state.isMember(_bob), isFalse);

    final badLink = ControlEntry.fromJson({
      ...remove.toJson(),
      'prev': List.filled(64, '0').join(),
    })!;
    final broken = foldControlLog(
      owner: _owner,
      entries: [add, badLink],
      verify: _ok,
    );
    expect(broken.rejected, contains(badLink));
    expect(broken.state.isMember(_bob), isTrue);

    final legacyDowngrade = _e(_owner, 1, ControlOp.removeMember, target: _bob);
    final downgraded = foldControlLog(
      owner: _owner,
      entries: [add, legacyDowngrade],
      verify: _ok,
    );
    expect(downgraded.rejected, contains(legacyDowngrade));
    expect(downgraded.state.isMember(_bob), isTrue);
  });

  test('a bad signature drops the entry', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
    ], verify: (e) => false);
    expect(s.isMember(_bob), isFalse);
  });

  test('fold is order-independent by (ts,author,seq) — same state', () {
    final a = _e(
      _owner,
      0,
      ControlOp.addMember,
      target: _admin,
      role: GroupRole.admin,
    );
    final b = _e(
      _admin,
      0,
      ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
    );
    final s1 = _fold([a, b]);
    final s2 = _fold([b, a]); // reversed input; ts ordering restores it
    expect(s1.members.keys.toSet(), s2.members.keys.toSet());
    expect(s2.roleOf(_bob), GroupRole.member);
  });

  test('same-author seq remains causal when wall clock moves backwards', () {
    final add = _e(
      _owner,
      0,
      ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
    );
    final remove = ControlEntry.fromJson({
      ..._e(_owner, 1, ControlOp.removeMember, target: _bob).toJson(),
      'ts': add.createdAtMs - 1,
    })!;

    final result = foldControlLog(
      owner: _owner,
      entries: [remove, add],
      verify: _ok,
    );
    expect(result.rejected, isEmpty);
    expect(
      result.state.isMember(_bob),
      isFalse,
      reason: 'seq 0 add must precede seq 1 revoke despite clock rollback',
    );
  });

  test('manifest + control entry json round-trip', () {
    final m = GroupManifest(
      groupId: _owner,
      owner: _owner,
      genesisPubKey: Uint8List.fromList(List.filled(32, 7)),
      name: 'Family',
      createdAtMs: 42,
    );
    final back = GroupManifest.fromJson(m.toJson())!;
    expect(back.name, 'Family');
    expect(back.groupId, _owner);
    expect(back.owner, _owner);
    expect(back.genesisPubKey.length, 32);

    final e = ControlEntry(
      author: _owner,
      seq: 5,
      prevHash: '',
      op: ControlOp.setRole,
      target: _bob,
      role: GroupRole.admin,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(64),
      authorPubKey: Uint8List.fromList(List.filled(32, 5)),
    );
    final eBack = ControlEntry.fromJson(e.toJson())!;
    expect(eBack.seq, 5);
    expect(eBack.op, ControlOp.setRole);
    expect(eBack.role, GroupRole.admin);
    expect(eBack.target, _bob);
    expect(eBack.authorPubKey.length, 32, reason: 'pubKey survives json');
    expect(eBack.signature.length, 64);
    expect(GroupManifest.fromJson('nope'), isNull);
    expect(ControlEntry.fromJson({'seq': 'x'}), isNull);
  });

  test('revocation boundary is signed and restricted to revoke operations', () {
    final boundary = SpacePostBoundary(seq: 4, hash: 'a' * 64);
    final revoke = ControlEntry(
      version: 3,
      groupId: _owner,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.mute,
      target: _bob,
      role: null,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
      postBoundary: boundary,
    );
    expect(revoke.isStructurallyValid, isTrue);
    expect(ControlEntry.fromJson(revoke.toJson())?.postBoundary?.seq, 4);
    expect(utf8.decode(revoke.canonicalBytes()), contains('postBoundary'));

    final grant = ControlEntry(
      version: 2,
      groupId: _owner,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
      postBoundary: boundary,
    );
    expect(grant.isStructurallyValid, isFalse);
  });

  test(
    'control checkpoint V4 is signed, round-trips and does not mutate ACL',
    () {
      final checkpoint = SpaceControlCheckpoint(const []);
      final entry = ControlEntry(
        version: 4,
        groupId: _owner,
        author: _owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.checkpoint,
        target: null,
        role: null,
        controlCheckpoint: checkpoint,
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );
      expect(entry.isStructurallyValid, isTrue);
      final decoded = ControlEntry.fromJson(entry.toJson());
      expect(decoded?.controlCheckpoint?.merkleRoot, checkpoint.merkleRoot);
      expect(
        utf8.decode(entry.canonicalBytes()),
        contains('controlCheckpoint'),
      );

      final folded = foldControlLog(
        owner: _owner,
        entries: [entry],
        verify: _ok,
      );
      expect(folded.rejected, isEmpty);
      expect(folded.accepted, hasLength(1));
      expect(folded.state.members.keys, {_owner.hex});
      expect(folded.state.policyVersion, 0);

      final wrongVersion = ControlEntry(
        version: 3,
        groupId: _owner,
        author: _owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.checkpoint,
        target: null,
        role: null,
        controlCheckpoint: checkpoint,
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(64),
        authorPubKey: Uint8List(32),
      );
      expect(wrongVersion.isStructurallyValid, isFalse);
    },
  );

  test('Space post pin V12 is strict, admin-only and folds by root id', () {
    final spaceId = _id(7);
    final pin = SpacePostPin(
      spaceId: spaceId,
      postAuthor: _bob,
      postSeq: 4,
      rootHash: 'ab' * 32,
      pinned: true,
      changedAtMs: 1200,
    );
    final entry = ControlEntry(
      version: 12,
      groupId: spaceId,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.setPostPin,
      target: null,
      role: null,
      postPin: pin,
      policyVersion: 0,
      createdAtMs: 1200,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );

    expect(entry.isStructurallyValid, isTrue);
    expect(ControlEntry.fromJson(entry.toJson())?.postPin?.postId, pin.postId);
    final folded = foldControlLog(owner: _owner, entries: [entry], verify: _ok);
    expect(folded.rejected, isEmpty);
    expect(folded.state.postPinFor(pin.postId)?.pinned, isTrue);
    expect(
      canApply(authorRole: GroupRole.admin, op: ControlOp.setPostPin),
      isTrue,
    );
    expect(
      canApply(authorRole: GroupRole.member, op: ControlOp.setPostPin),
      isFalse,
    );

    final extraPayload = {...pin.toJson(), 'unexpected': true};
    expect(SpacePostPin.fromJson(extraPayload), isNull);
    expect(
      ControlEntry(
        version: 11,
        groupId: spaceId,
        author: _owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.setPostPin,
        target: null,
        role: null,
        postPin: pin,
        policyVersion: 0,
        createdAtMs: 1200,
        signature: Uint8List(64),
      ).isStructurallyValid,
      isFalse,
    );
  });

  test('restricted moderation V14 is opaque and bound to current epoch', () {
    final spaceId = _id(7);
    final channelId = _id(8);
    final encrypted = GroupEncryptedPayload(
      nonce: Uint8List(12),
      cipherText: Uint8List.fromList([1, 2, 3]),
      mac: Uint8List(16),
    );
    final descriptor = GroupEpochDescriptor(
      groupId: channelId,
      epoch: 1,
      keyCommitment: 'ab' * 32,
      envelopeRoot: 'cd' * 32,
      recipientCount: 1,
    );
    final create = ControlEntry(
      version: 5,
      groupId: spaceId,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.createChannel,
      target: null,
      role: null,
      channelControl: SpaceChannelControlEnvelope(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        keyDescriptor: descriptor,
        encryptedControl: encrypted,
      ),
      policyVersion: 0,
      createdAtMs: 1000,
      signature: Uint8List(64),
    );
    final moderation = ControlEntry(
      version: 14,
      groupId: spaceId,
      author: _owner,
      seq: 1,
      prevHash: controlEntryHash(create),
      op: ControlOp.moderate,
      target: null,
      role: null,
      channelModeration: SpaceChannelModerationEnvelope(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        encryptedAction: encrypted,
      ),
      policyVersion: 0,
      createdAtMs: 1001,
      signature: Uint8List(64),
    );
    expect(moderation.isStructurallyValid, isTrue);
    expect(moderation.target, isNull);
    expect(moderation.moderationAction, isNull);
    expect(
      ControlEntry.fromJson(moderation.toJson())?.channelModeration?.channelId,
      channelId,
    );
    final folded = foldControlLog(
      owner: _owner,
      entries: [create, moderation],
      verify: _ok,
    );
    expect(folded.rejected, isEmpty);
    expect(folded.state.protectedModeration, contains('${_owner.hex}:1'));
    expect(folded.state.moderationRecords, isEmpty);

    final staleEpoch = ControlEntry(
      version: 14,
      groupId: spaceId,
      author: _owner,
      seq: 2,
      prevHash: controlEntryHash(moderation),
      op: ControlOp.moderate,
      target: null,
      role: null,
      channelModeration: SpaceChannelModerationEnvelope(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 2,
        encryptedAction: encrypted,
      ),
      policyVersion: 0,
      createdAtMs: 1002,
      signature: Uint8List(64),
    );
    final failClosed = foldControlLog(
      owner: _owner,
      entries: [create, moderation, staleEpoch],
      verify: _ok,
    );
    expect(failClosed.rejected, contains(staleEpoch));
    expect(failClosed.state.protectedModeration, hasLength(1));
  });

  test('Space recommendation campaign V13 creates once and only revokes', () {
    final spaceId = _id(7);
    final campaign = SpaceRecommendationCampaign(
      campaignId: 'ab' * 32,
      spaceId: spaceId,
      createdBy: _owner,
      text: 'Пригласите тех, кому будет полезно сообщество',
      joinCode: SpaceJoinCode.encode(
        SpaceJoinTicket(
          ticketId: 'cd' * 32,
          spaceId: spaceId,
          approver: _owner,
          spaceName: 'Public lab',
          createdAtMs: 1000,
          expiresAtMs: 1000 + const Duration(days: 7).inMilliseconds,
        ),
      ),
      createdAtMs: 1200,
      changedAtMs: 1200,
      active: true,
    );
    final create = ControlEntry(
      version: 13,
      groupId: spaceId,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.setRecommendationCampaign,
      target: null,
      role: null,
      recommendationCampaign: campaign,
      policyVersion: 0,
      createdAtMs: 1200,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    final revoked = SpaceRecommendationCampaign(
      campaignId: campaign.campaignId,
      spaceId: spaceId,
      createdBy: _owner,
      text: campaign.text,
      joinCode: '',
      createdAtMs: 1200,
      changedAtMs: 1300,
      active: false,
    );
    final revoke = ControlEntry(
      version: 13,
      groupId: spaceId,
      author: _owner,
      seq: 1,
      prevHash: controlEntryHash(create),
      op: ControlOp.setRecommendationCampaign,
      target: null,
      role: null,
      recommendationCampaign: revoked,
      policyVersion: 0,
      createdAtMs: 1300,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );

    expect(create.isStructurallyValid, isTrue);
    expect(
      ControlEntry.fromJson(
        create.toJson(),
      )?.recommendationCampaign?.campaignId,
      campaign.campaignId,
    );
    final folded = foldControlLog(
      owner: _owner,
      entries: [create, revoke],
      verify: _ok,
    );
    expect(folded.rejected, isEmpty);
    expect(
      folded.state.recommendationCampaignFor(campaign.campaignId)?.active,
      isFalse,
    );
    expect(
      canApply(
        authorRole: GroupRole.admin,
        op: ControlOp.setRecommendationCampaign,
      ),
      isTrue,
    );
    expect(
      canApply(
        authorRole: GroupRole.member,
        op: ControlOp.setRecommendationCampaign,
      ),
      isFalse,
    );

    final attemptedReactivation = ControlEntry(
      version: 13,
      groupId: spaceId,
      author: _owner,
      seq: 2,
      prevHash: controlEntryHash(revoke),
      op: ControlOp.setRecommendationCampaign,
      target: null,
      role: null,
      recommendationCampaign: SpaceRecommendationCampaign(
        campaignId: campaign.campaignId,
        spaceId: spaceId,
        createdBy: _owner,
        text: campaign.text,
        joinCode: campaign.joinCode,
        createdAtMs: 1200,
        changedAtMs: 1400,
        active: true,
      ),
      policyVersion: 0,
      createdAtMs: 1400,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    final failClosed = foldControlLog(
      owner: _owner,
      entries: [create, revoke, attemptedReactivation],
      verify: _ok,
    );
    expect(failClosed.rejected, contains(attemptedReactivation));
    expect(
      failClosed.state.recommendationCampaignFor(campaign.campaignId)?.active,
      isFalse,
    );
  });

  test('Space recommendation policy V21 forms a signed revision chain', () {
    final spaceId = _id(7);
    final firstPolicy = SpaceRecommendationPolicy(
      spaceId: spaceId,
      revision: 1,
      previousPolicyHash: '',
      changedBy: _owner,
      changedAtMs: 1200,
      enabled: false,
    );
    final first = ControlEntry(
      version: 21,
      groupId: spaceId,
      author: _owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.setRecommendationPolicy,
      target: null,
      role: null,
      recommendationPolicy: firstPolicy,
      policyVersion: 0,
      createdAtMs: 1200,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    final secondPolicy = SpaceRecommendationPolicy(
      spaceId: spaceId,
      revision: 2,
      previousPolicyHash: firstPolicy.policyHash,
      changedBy: _owner,
      changedAtMs: 1300,
      enabled: true,
    );
    final second = ControlEntry(
      version: 21,
      groupId: spaceId,
      author: _owner,
      seq: 1,
      prevHash: controlEntryHash(first),
      op: ControlOp.setRecommendationPolicy,
      target: null,
      role: null,
      recommendationPolicy: secondPolicy,
      policyVersion: 0,
      createdAtMs: 1300,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );

    expect(first.isStructurallyValid, isTrue);
    expect(
      ControlEntry.fromJson(first.toJson())?.recommendationPolicy?.enabled,
      isFalse,
    );
    final folded = foldControlLog(
      owner: _owner,
      entries: [first, second],
      verify: _ok,
    );
    expect(folded.rejected, isEmpty);
    expect(folded.state.recommendationsEnabled, isTrue);
    expect(folded.state.recommendationPolicyHistory, hasLength(2));
    expect(
      canApply(
        authorRole: GroupRole.admin,
        op: ControlOp.setRecommendationPolicy,
      ),
      isTrue,
    );
    expect(
      canApply(
        authorRole: GroupRole.member,
        op: ControlOp.setRecommendationPolicy,
      ),
      isFalse,
    );

    final stalePolicy = SpaceRecommendationPolicy(
      spaceId: spaceId,
      revision: 3,
      previousPolicyHash: firstPolicy.policyHash,
      changedBy: _owner,
      changedAtMs: 1400,
      enabled: false,
    );
    final stale = ControlEntry(
      version: 21,
      groupId: spaceId,
      author: _owner,
      seq: 2,
      prevHash: controlEntryHash(second),
      op: ControlOp.setRecommendationPolicy,
      target: null,
      role: null,
      recommendationPolicy: stalePolicy,
      policyVersion: 0,
      createdAtMs: 1400,
      signature: Uint8List(64),
      authorPubKey: Uint8List(32),
    );
    final failClosed = foldControlLog(
      owner: _owner,
      entries: [first, second, stale],
      verify: _ok,
    );
    expect(failClosed.rejected, contains(stale));
    expect(failClosed.state.recommendationsEnabled, isTrue);
    expect(failClosed.state.recommendationPolicyHistory, hasLength(2));
  });

  test('withSignature fills sig + pubKey, leaving canonicalBytes stable', () {
    final unsigned = _e(
      _owner,
      0,
      ControlOp.addMember,
      target: _bob,
      role: GroupRole.member,
    );
    final before = unsigned.canonicalBytes();
    final signed = unsigned.withSignature(
      Uint8List(64),
      Uint8List.fromList(List.filled(32, 9)),
    );
    expect(
      signed.canonicalBytes(),
      before,
      reason: 'the pubKey is NOT in the signed payload',
    );
    expect(signed.authorPubKey.length, 32);
  });
}
