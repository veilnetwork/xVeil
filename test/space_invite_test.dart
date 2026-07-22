import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/space_invite.dart';

NodeId _id(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

void main() {
  test('minimal Space invite round-trips without membership material', () {
    final invite = SpaceInvite(
      inviteId: 'ab' * 32,
      spaceId: _id(1),
      inviter: _id(2),
      invitee: _id(3),
      spaceName: '',
      visibility: SpaceVisibility.secret,
      role: GroupRole.member,
      createdAtMs: 100,
      expiresAtMs: 200,
    );
    final decoded = SpaceInvite.fromJson(invite.toJson());
    expect(decoded?.inviteId, invite.inviteId);
    expect(decoded?.invitee, invite.invitee);
    expect(decoded?.spaceName, isEmpty);
    expect(invite.toJson(), isNot(contains('members')));
    expect(invite.toJson(), isNot(contains('keys')));
  });

  test('owner grants, overlong TTL and malformed decisions fail closed', () {
    final base = SpaceInvite(
      inviteId: 'cd' * 32,
      spaceId: _id(1),
      inviter: _id(2),
      invitee: _id(3),
      spaceName: 'Veil lab',
      visibility: SpaceVisibility.private,
      role: GroupRole.owner,
      createdAtMs: 100,
      expiresAtMs: 200,
    );
    expect(SpaceInvite.fromJson(base.toJson()), isNull);
    final tooLong = Map<String, dynamic>.from(base.toJson())
      ..['role'] = GroupRole.member.name
      ..['expiresAt'] = 100 + const Duration(days: 31).inMilliseconds;
    expect(SpaceInvite.fromJson(tooLong), isNull);
    final wrongTypes = Map<String, dynamic>.from(base.toJson())..['role'] = 7;
    expect(() => SpaceInvite.fromJson(wrongTypes), returnsNormally);
    expect(SpaceInvite.fromJson(wrongTypes), isNull);
    expect(
      SpaceInviteDecision.fromJson({
        'v': 1,
        'id': 'short',
        'space': _id(1).hex,
        'accepted': true,
        'decidedAt': 100,
      }),
      isNull,
    );
  });
}
