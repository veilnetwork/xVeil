import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_policy.dart';

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
}) =>
    ControlEntry(
      author: author,
      seq: seq,
      prevHash: '',
      op: op,
      target: target,
      role: role,
      policyVersion: 0,
      createdAtMs: _t++,
      signature: Uint8List(0),
    );

/// Verifier that accepts everything (signatures tested via canonicalBytes).
bool _ok(ControlEntry e) => true;

GroupState _fold(List<ControlEntry> log,
        {bool Function(ControlEntry) verify = _ok}) =>
    foldControlLog(owner: _owner, entries: log, verify: verify).state;

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
        _e(_owner, 0, ControlOp.addMember,
            target: _admin, role: GroupRole.admin),
        _e(_admin, 0, ControlOp.addMember,
            target: _eve, role: GroupRole.admin),
      ],
      verify: _ok,
    );
    expect(r.state.isMember(_eve), isFalse);
    expect(r.rejected.length, 1);
  });

  test('a member cannot perform control ops', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(_owner, 1, ControlOp.addMember,
          target: _carol, role: GroupRole.member),
      _e(_bob, 0, ControlOp.removeMember, target: _carol), // bob is a member
    ]);
    expect(s.isMember(_carol), isTrue, reason: 'the member op was rejected');
  });

  test('an admin cannot remove the owner or a peer admin', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember,
          target: _admin, role: GroupRole.admin),
      _e(_owner, 1, ControlOp.addMember,
          target: _bob, role: GroupRole.admin),
      _e(_admin, 0, ControlOp.removeMember, target: _owner), // owner: rejected
      _e(_admin, 1, ControlOp.removeMember, target: _bob), // peer: rejected
    ]);
    expect(s.roleOf(_owner), GroupRole.owner);
    expect(s.isMember(_bob), isTrue);
  });

  test('remove + ban rotate the epoch', () {
    final s = _fold([
      _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member),
      _e(_owner, 1, ControlOp.addMember,
          target: _carol, role: GroupRole.member),
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
      _e(_owner, 0, ControlOp.addMember,
          target: _admin, role: GroupRole.admin),
      _e(_admin, 0, ControlOp.setPolicy), // rejected
      _e(_owner, 1, ControlOp.setPolicy),
    ]);
    expect(s.policyVersion, 1);
  });

  test('a duplicate/replayed seq is dropped', () {
    final r = foldControlLog(
      owner: _owner,
      entries: [
        _e(_owner, 0, ControlOp.addMember,
            target: _bob, role: GroupRole.member),
        _e(_owner, 0, ControlOp.addMember,
            target: _carol, role: GroupRole.member), // dup seq 0
      ],
      verify: _ok,
    );
    // Only the first seq-0 applied; the replay is rejected.
    expect(r.rejected.length, 1);
    expect(r.state.members.length, 2);
  });

  test('a bad signature drops the entry', () {
    final s = _fold(
      [
        _e(_owner, 0, ControlOp.addMember,
            target: _bob, role: GroupRole.member),
      ],
      verify: (e) => false,
    );
    expect(s.isMember(_bob), isFalse);
  });

  test('fold is order-independent by (ts,author,seq) — same state', () {
    final a = _e(_owner, 0, ControlOp.addMember,
        target: _admin, role: GroupRole.admin);
    final b = _e(_admin, 0, ControlOp.addMember,
        target: _bob, role: GroupRole.member);
    final s1 = _fold([a, b]);
    final s2 = _fold([b, a]); // reversed input; ts ordering restores it
    expect(s1.members.keys.toSet(), s2.members.keys.toSet());
    expect(s2.roleOf(_bob), GroupRole.member);
  });

  test('manifest + control entry json round-trip', () {
    final m = GroupManifest(
      groupId: _owner,
      genesisPubKey: Uint8List.fromList(List.filled(32, 7)),
      name: 'Family',
      createdAtMs: 42,
    );
    final back = GroupManifest.fromJson(m.toJson())!;
    expect(back.name, 'Family');
    expect(back.groupId, _owner);
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

  test('withSignature fills sig + pubKey, leaving canonicalBytes stable', () {
    final unsigned =
        _e(_owner, 0, ControlOp.addMember, target: _bob, role: GroupRole.member);
    final before = unsigned.canonicalBytes();
    final signed = unsigned.withSignature(
        Uint8List(64), Uint8List.fromList(List.filled(32, 9)));
    expect(signed.canonicalBytes(), before,
        reason: 'the pubKey is NOT in the signed payload');
    expect(signed.authorPubKey.length, 32);
  });
}
