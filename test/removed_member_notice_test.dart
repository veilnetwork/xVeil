import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_membership.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

final owner = _id(1);
final bob = _id(2);
final carol = _id(3);

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _fakeSovereignSignature(Uint8List publicKey, Uint8List message) {
  final digest = sha256.convert([...publicKey, ...message]).bytes;
  return Uint8List.fromList([...digest, ...digest]);
}

/// The same deterministic fake the group suites use: the "public key" is the
/// node id, signatures are a fixed marker, verification accepts well-formed.
class _FakeSigner implements GroupSigner {
  _FakeSigner(this._self);
  final NodeId _self;

  @override
  NodeId get selfId => _self;
  @override
  Uint8List get selfPubKey => _self.bytes;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) => value.withSignature(
    _fakeSovereignSignature(selfPubKey, value.canonicalBytes()),
  );
  @override
  ControlEntry signControl(ControlEntry u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupMessage signMessage(GroupMessage u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupReaction signReaction(GroupReaction u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  SpacePost signPost(SpacePost u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest u) =>
      u.withSignature(Uint8List(64), u.requester.bytes);
  @override
  GroupCallSignal signCallSignal(GroupCallSignal u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal u) =>
      u.withSignature(Uint8List(64), u.appellant.bytes);
  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision u,
  ) => u.withSignature(Uint8List(64), u.reviewer.bytes);
  @override
  bool verifyControl(ControlEntry e) =>
      e.signature.length == 64 && e.authorPubKey.length == 32;
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
  @override
  bool verifyCallSignal(GroupCallSignal s) =>
      s.signature.length == 64 && s.authorPubKey.length == 32;
  @override
  bool verifyModerationAppeal(SpaceModerationAppeal appeal) =>
      appeal.signature.length == 64 && appeal.authorPubKey.length == 32;
  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision decision) =>
      decision.signature.length == 64 && decision.authorPubKey.length == 32;
  @override
  bool verifyMessage(GroupMessage m) =>
      m.signature.length == 64 && m.authorPubKey.length == 32;
  @override
  bool verifyReaction(GroupReaction r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
  @override
  bool verifyPost(SpacePost post) =>
      post.signature.length == 64 && post.authorPubKey.length == 32;
  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(Uint8List.fromList(value.genesisPubKey)) &&
      _bytesEqual(
        _fakeSovereignSignature(value.genesisPubKey, value.canonicalBytes()),
        value.signature,
      );
  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(
    Uint8List message,
  ) => (
    signature: _fakeSovereignSignature(selfPubKey, message),
    publicKey: selfPubKey,
  );
  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      signer == NodeId(Uint8List.fromList(publicKey)) &&
      _bytesEqual(_fakeSovereignSignature(publicKey, message), signature);
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      algorithm == 'ed25519' &&
      nodeId == NodeId(Uint8List.fromList(publicKey)) &&
      _bytesEqual(_fakeSovereignSignature(publicKey, message), signature);
}

Future<GroupService> _service(
  NodeId self,
  List<(NodeId, String)> outbound, {
  bool epochs = true,
}) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  return GroupService(
    storage,
    _FakeSigner(self),
    send: (peer, _, json) async => outbound.add((peer, json)),
    epochService: epochs
        ? GroupEpochService(LoopbackMailboxCrypto(senderForOpen: self))
        : null,
  );
}

/// The frames a fanout produced, keyed by recipient.
Map<NodeId, Map<String, dynamic>> _framesBy(List<(NodeId, String)> outbound) =>
    {
      for (final entry in outbound)
        entry.$1: jsonDecode(entry.$2) as Map<String, dynamic>,
    };

/// Every op carried by a wire frame's control list.
List<String> _ops(Map<String, dynamic> frame) => [
  for (final raw in frame['c'] as List? ?? const []) '${(raw as Map)['op']}',
];

/// Assert on the ACTUAL frame contents: a departure notice carries the signed
/// control rows and nothing that could ever be opened with a key.
void _expectNoKeyMaterial(Map<String, dynamic> frame, {required String who}) {
  for (final field in ['ke', 'cke']) {
    final value = frame[field];
    expect(
      value == null || (value as List).isEmpty,
      isTrue,
      reason: '$who must receive no $field epoch envelope: $value',
    );
  }
  for (final field in ['g', 'r', 'p', 'pc', 'pr']) {
    final value = frame[field];
    expect(
      value == null || (value as List).isEmpty,
      isTrue,
      reason: '$who must receive no $field content rows: $value',
    );
  }
}

void main() {
  test('a removed group member is a recipient of the delta that removes them, '
      'and that delta carries no key material', () async {
    final ownerOut = <(NodeId, String)>[];
    final ownerSvc = await _service(owner, ownerOut);
    final bobOut = <(NodeId, String)>[];
    final bobSvc = await _service(bob, bobOut);
    addTearDown(ownerSvc.dispose);
    addTearDown(bobSvc.dispose);

    final gid = await ownerSvc.createGroup('Crew');
    for (final peer in [bob, carol]) {
      expect(
        await ownerSvc.addControlOp(
          gid,
          ControlOp.addMember,
          target: peer,
          role: GroupRole.member,
        ),
        isTrue,
      );
    }
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(gid))!, recipient: bob),
      ),
      isTrue,
    );
    expect((await bobSvc.stateOf(gid))!.isMember(bob), isTrue);
    final epochBefore = (await bobSvc.stateOf(gid))!.epoch;

    ownerOut.clear();
    expect(
      await ownerSvc.addControlOp(gid, ControlOp.removeMember, target: bob),
      isTrue,
    );

    final frames = _framesBy(ownerOut);
    expect(
      frames.keys,
      contains(bob),
      reason: 'the removed member must learn about their own removal',
    );
    expect(
      frames.keys,
      contains(carol),
      reason: 'positive control: members who remain still get the delta',
    );
    expect(
      _ops(frames[bob]!),
      contains(ControlOp.removeMember.name),
      reason: 'the delta shipped to the target must carry the removal row',
    );
    _expectNoKeyMaterial(frames[bob]!, who: 'a removed member');
    expect(
      (frames[carol]!['ke'] as List?) ?? const [],
      isNotEmpty,
      reason:
          'positive control: the members who remain DO get the new epoch '
          'envelope, so an empty "ke" for bob means suppression, not that '
          'this removal rotated no key at all',
    );

    // The receiving side projects it.
    expect(
      await bobSvc.ingestGroupEntry(
        owner,
        ownerOut.firstWhere((entry) => entry.$1 == bob).$2,
      ),
      isTrue,
    );
    final bobState = (await bobSvc.stateOf(gid))!;
    expect(bobState.isMember(bob), isFalse);
    expect(bobState.epoch, greaterThan(epochBefore));

    // And bob's own send path now says no instead of yes. (The API surface
    // that turns this decision into a 400 is pinned in
    // test/group_api_adapter_test.dart.)
    expect(
      await bobSvc.postMessage(gid, 'still here?', broadcast: false),
      isFalse,
      reason: 'a removed member must be refused, not acknowledged',
    );
  });

  test(
    'a permanently banned Space member receives the ban and no key material, '
    'and their own projection flips to banned',
    () async {
      final ownerOut = <(NodeId, String)>[];
      final ownerSvc = await _service(owner, ownerOut);
      final bobOut = <(NodeId, String)>[];
      final bobSvc = await _service(bob, bobOut);
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Builders',
        visibility: SpaceVisibility.private,
      );
      for (final peer in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobSvc.spaceMemberships()).single.status,
        SpaceMembershipStatus.active,
      );

      ownerOut.clear();
      expect(
        await ownerSvc.moderateSpace(
          spaceId,
          kind: SpaceModerationKind.permanentBan,
          target: bob,
          scope: SpaceModerationScope.space,
          reason: 'repeated abuse',
        ),
        isNotNull,
      );

      final frames = _framesBy(ownerOut);
      expect(
        frames.keys,
        contains(bob),
        reason: 'a banned member must learn about their own ban',
      );
      expect(
        frames.keys,
        contains(carol),
        reason: 'positive control: members who remain still get the delta',
      );
      expect(_ops(frames[bob]!), contains(ControlOp.moderate.name));
      _expectNoKeyMaterial(frames[bob]!, who: 'a banned member');

      expect(
        await bobSvc.ingestGroupEntry(
          owner,
          ownerOut.firstWhere((entry) => entry.$1 == bob).$2,
        ),
        isTrue,
      );
      final projection = (await bobSvc.spaceMemberships()).single;
      expect(projection.status, SpaceMembershipStatus.banned);
      expect(projection.isMember, isFalse);
      expect(
        await bobSvc.postMessage(spaceId, 'ban? what ban', broadcast: false),
        isFalse,
      );
    },
  );

  test(
    'a departure notice carries the control rows and nothing else, even when '
    'the delta it rides on is full of content the target could still open',
    () async {
      // No epoch service on purpose: nothing is encrypted, so every ordinary
      // per-peer content filter in the fanout says "yes, ship it". If the
      // removed target were served by that ordinary tailoring, this delta
      // would hand them the message rows too.
      final ownerOut = <(NodeId, String)>[];
      final ownerSvc = await _service(owner, ownerOut, epochs: false);
      final bobOut = <(NodeId, String)>[];
      final bobSvc = await _service(bob, bobOut, epochs: false);
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final gid = await ownerSvc.createGroup('Clear crew');
      for (final peer in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            gid,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      expect(
        await ownerSvc.postMessage(gid, 'members only', broadcast: false),
        isTrue,
      );
      final message = (await ownerSvc.load(gid))!.messages.single;
      expect(message.isEncrypted, isFalse, reason: 'probe precondition');
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson((await ownerSvc.load(gid))!, recipient: bob),
        ),
        isTrue,
      );
      expect(
        await bobSvc.postMessage(gid, 'while a member', broadcast: false),
        isTrue,
        reason: 'probe precondition: nothing else is in bob\'s way here',
      );

      expect(
        await ownerSvc.addControlOp(gid, ControlOp.removeMember, target: bob),
        isTrue,
      );
      final removal = (await ownerSvc.load(
        gid,
      ))!.control.lastWhere((entry) => entry.op == ControlOp.removeMember);

      ownerOut.clear();
      await ownerSvc.broadcastDelta(
        gid,
        control: [removal],
        messages: [message],
      );
      final frames = _framesBy(ownerOut);
      expect(frames.keys, contains(bob));
      expect(frames.keys, contains(carol));
      expect(
        (frames[carol]!['g'] as List?) ?? const [],
        isNotEmpty,
        reason:
            'positive control: a member DOES get the message rows, so an '
            'empty "g" for bob means suppression, not an empty delta',
      );
      _expectNoKeyMaterial(frames[bob]!, who: 'a removed member');
      expect(_ops(frames[bob]!), contains(ControlOp.removeMember.name));
      expect(
        frames[bob]!.containsKey('rcpt'),
        isFalse,
        reason: 'a removed member is not a replication holder',
      );

      // The refusal below must come from MEMBERSHIP, not from a key bob
      // happens not to hold: this group has no encryption at all, and bob's
      // identical send succeeded a moment ago.
      expect(
        await bobSvc.ingestGroupEntry(
          owner,
          ownerOut.firstWhere((entry) => entry.$1 == bob).$2,
        ),
        isTrue,
      );
      expect((await bobSvc.stateOf(gid))!.isMember(bob), isFalse);
      expect(
        await bobSvc.postMessage(gid, 'after removal', broadcast: false),
        isFalse,
        reason: 'a removed member must be refused, not acknowledged',
      );
    },
  );

  test('a leave is never fanned back to the person who left', () async {
    final ownerOut = <(NodeId, String)>[];
    final ownerSvc = await _service(owner, ownerOut);
    final bobOut = <(NodeId, String)>[];
    final bobSvc = await _service(bob, bobOut);
    addTearDown(ownerSvc.dispose);
    addTearDown(bobSvc.dispose);

    final gid = await ownerSvc.createGroup('Crew');
    for (final peer in [bob, carol]) {
      expect(
        await ownerSvc.addControlOp(
          gid,
          ControlOp.addMember,
          target: peer,
          role: GroupRole.member,
        ),
        isTrue,
      );
    }
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(gid))!, recipient: bob),
      ),
      isTrue,
    );

    bobOut.clear();
    expect(await bobSvc.leaveGroup(gid), isTrue);
    expect(
      _framesBy(bobOut).keys,
      contains(owner),
      reason: 'the members who remain are told',
    );
    expect(_framesBy(bobOut).keys, isNot(contains(bob)));

    // The shared fanout itself must not treat a self-authored leave as a
    // membership-ending decision that needs delivering back to its author.
    final leaveRow = (await bobSvc.load(
      gid,
    ))!.control.lastWhere((entry) => entry.op == ControlOp.leave);
    expect(
      await ownerSvc.ingestGroupEntry(
        bob,
        bobOut.firstWhere((entry) => entry.$1 == owner).$2,
      ),
      isTrue,
    );
    ownerOut.clear();
    await ownerSvc.broadcastDelta(gid, control: [leaveRow]);
    expect(
      _framesBy(ownerOut).keys,
      isNot(contains(bob)),
      reason: 'a leave must not be fanned back to the person who left',
    );
    expect(
      _framesBy(ownerOut).keys,
      contains(carol),
      reason: 'positive control: the fanout did run',
    );
  });

  test(
    'a member whose admission is unmade by an authority withdrawal is a '
    'recipient of the delta that unmakes it, and that delta carries no key '
    'material',
    () async {
      // The withdrawal names BOB. Nothing in this log ever names dave in a
      // removeMember, a ban or a moderate row — and dave still stops being a
      // member the instant the boundary reaches back over bob's `addMember`.
      final t0 = DateTime.utc(2026, 8, 12, 8).millisecondsSinceEpoch;
      final boundaryMs = t0 + const Duration(hours: 6).inMilliseconds;
      final dave = _id(8);

      final ownerOut = <(NodeId, String)>[];
      var ownerWall = t0;
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async => ownerOut.add((peer, json)),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Withdrawal',
        visibility: SpaceVisibility.private,
      );
      for (final (peer, role) in [
        (bob, GroupRole.admin),
        (carol, GroupRole.member),
      ]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: role,
          ),
          isTrue,
        );
      }

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: bob),
        ),
      )..debugWallClockMs = () => t0 + const Duration(hours: 8).inMilliseconds;
      addTearDown(bobSvc.dispose);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await bobSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: dave,
          role: GroupRole.member,
        ),
        isTrue,
        reason: 'probe precondition: the admin\'s admission of dave is valid',
      );
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      expect((await ownerSvc.stateOf(spaceId))!.isMember(dave), isTrue);

      final daveStorage = FakeHvContainer().storage();
      await daveStorage.open(password: 'pw', createIfMissing: true);
      final daveSvc = GroupService(
        daveStorage,
        _FakeSigner(dave),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: dave),
        ),
      )..debugWallClockMs = () => t0 + const Duration(hours: 9).inMilliseconds;
      addTearDown(daveSvc.dispose);
      expect(
        await daveSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: dave,
          ),
        ),
        isTrue,
      );
      expect((await daveSvc.stateOf(spaceId))!.isMember(dave), isTrue);

      ownerWall = t0 + const Duration(hours: 10).inMilliseconds;
      ownerOut.clear();
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: boundaryMs,
        ),
        isTrue,
      );

      final after = (await ownerSvc.stateOf(spaceId))!;
      expect(
        after.isMember(dave),
        isFalse,
        reason:
            'probe precondition: the withdrawal really did end dave\'s '
            'membership, without naming him anywhere',
      );
      expect(
        after.isMember(bob),
        isTrue,
        reason:
            'positive control: the person the withdrawal DOES name keeps his '
            'membership, so he is served by the ordinary recipient list',
      );
      final rowsNamingDave = [
        for (final entry in (await ownerSvc.load(spaceId))!.control)
          if (entry.target == dave || entry.moderationAction?.target == dave)
            entry.op,
      ];
      expect(
        rowsNamingDave,
        [ControlOp.addMember],
        reason:
            'the whole point: the only row in this log that names dave is the '
            'admission the withdrawal unmakes — no removeMember, no ban and '
            'no moderate ever mentions him, so the name-based extraction has '
            'nothing to find',
      );

      final frames = _framesBy(ownerOut);
      expect(
        frames.keys,
        contains(carol),
        reason: 'positive control: members who remain still get the delta',
      );
      expect(
        frames.keys,
        contains(bob),
        reason: 'positive control: the named, still-a-member target gets it',
      );
      expect(
        frames.keys,
        contains(dave),
        reason:
            'a member the withdrawal takes out of the Space must learn about '
            'it — nothing else in this log will ever tell him',
      );
      expect(
        _ops(frames[dave]!),
        contains(ControlOp.revokeAuthority.name),
        reason: 'the delta shipped to dave must carry the withdrawal row',
      );
      _expectNoKeyMaterial(
        frames[dave]!,
        who: 'a member unmade by a withdrawal',
      );
      expect(
        frames[dave]!.containsKey('rcpt'),
        isFalse,
        reason: 'a member who is out is not a replication holder',
      );
      expect(
        (frames[carol]!['ke'] as List?) ?? const [],
        isNotEmpty,
        reason:
            'positive control: the members who remain DO get the epoch '
            'envelope this withdrawal rotates, so an empty "ke" for dave '
            'means suppression, not that nothing was sealed at all',
      );

      expect(
        await daveSvc.ingestGroupEntry(
          owner,
          ownerOut.lastWhere((entry) => entry.$1 == dave).$2,
        ),
        isTrue,
      );
      expect((await daveSvc.stateOf(spaceId))!.isMember(dave), isFalse);
      expect(
        await daveSvc.postMessage(spaceId, 'still here?', broadcast: false),
        isFalse,
        reason: 'a member who is out must be refused, not acknowledged',
      );
    },
  );

  test(
    'a withdrawal notice carries the control rows and nothing else, even when '
    'the delta it rides on is full of content the target could still open',
    () async {
      // No epoch service on purpose, for the same reason as the removal case
      // above: nothing is encrypted, so every ordinary per-peer content filter
      // says "yes, ship it". Suppression here is a property of how the notice
      // is BUILT, not a side effect of a key the target happens not to hold —
      // `_epochEnvelopesFor` returns empty for a departed target either way,
      // so an assertion about `ke` alone would prove nothing.
      final t0 = DateTime.utc(2026, 8, 12, 8).millisecondsSinceEpoch;
      final boundaryMs = t0 + const Duration(hours: 6).inMilliseconds;
      final dave = _id(8);

      final ownerOut = <(NodeId, String)>[];
      var ownerWall = t0;
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async => ownerOut.add((peer, json)),
      )..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Clear withdrawal',
        visibility: SpaceVisibility.private,
      );
      for (final (peer, role) in [
        (bob, GroupRole.admin),
        (carol, GroupRole.member),
      ]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: role,
          ),
          isTrue,
        );
      }

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(hours: 8).inMilliseconds;
      addTearDown(bobSvc.dispose);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await bobSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: dave,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );

      expect(
        await ownerSvc.postMessage(spaceId, 'members only', broadcast: false),
        isTrue,
      );
      final message = (await ownerSvc.load(spaceId))!.messages.single;
      expect(message.isEncrypted, isFalse, reason: 'probe precondition');

      final daveStorage = FakeHvContainer().storage();
      await daveStorage.open(password: 'pw', createIfMissing: true);
      final daveSvc = GroupService(daveStorage, _FakeSigner(dave))
        ..debugWallClockMs = () => t0 + const Duration(hours: 9).inMilliseconds;
      addTearDown(daveSvc.dispose);
      expect(
        await daveSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: dave,
          ),
        ),
        isTrue,
      );
      expect(
        await daveSvc.postMessage(spaceId, 'while a member', broadcast: false),
        isTrue,
        reason: 'probe precondition: nothing else is in dave\'s way here',
      );

      ownerWall = t0 + const Duration(hours: 10).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: boundaryMs,
        ),
        isTrue,
      );
      expect((await ownerSvc.stateOf(spaceId))!.isMember(dave), isFalse);
      final withdrawal = (await ownerSvc.load(
        spaceId,
      ))!.control.lastWhere((entry) => entry.op == ControlOp.revokeAuthority);

      ownerOut.clear();
      await ownerSvc.broadcastDelta(
        spaceId,
        control: [withdrawal],
        messages: [message],
      );
      final frames = _framesBy(ownerOut);
      expect(frames.keys, contains(dave));
      expect(frames.keys, contains(carol));
      expect(
        (frames[carol]!['g'] as List?) ?? const [],
        isNotEmpty,
        reason:
            'positive control: a member DOES get the message rows, so an '
            'empty "g" for dave means suppression, not an empty delta',
      );
      _expectNoKeyMaterial(
        frames[dave]!,
        who: 'a member unmade by a withdrawal',
      );
      expect(_ops(frames[dave]!), contains(ControlOp.revokeAuthority.name));
      expect(
        frames[dave]!.containsKey('rcpt'),
        isFalse,
        reason: 'a member who is out is not a replication holder',
      );

      // The refusal below must come from MEMBERSHIP, not from a key dave
      // happens not to hold: this Space has no encryption at all, and dave's
      // identical send succeeded a moment ago.
      expect(
        await daveSvc.ingestGroupEntry(
          owner,
          ownerOut.lastWhere((entry) => entry.$1 == dave).$2,
        ),
        isTrue,
      );
      expect((await daveSvc.stateOf(spaceId))!.isMember(dave), isFalse);
      expect(
        await daveSvc.postMessage(spaceId, 'after the line', broadcast: false),
        isFalse,
        reason: 'a member who is out must be refused, not acknowledged',
      );
    },
  );

  test(
    'a catch-up delta carrying both the admission and the removal still names '
    'the person it is about',
    () async {
      // The one shape a before/after membership diff structurally cannot see:
      // this delta carries the rows that put bob in AND took him out, so the
      // log without them never held him as a member and there is no difference
      // to notice. He is still exactly the person this delta is about. This is
      // what keeps the naming derivation load-bearing next to the fold diff.
      final ownerOut = <(NodeId, String)>[];
      final ownerSvc = await _service(owner, ownerOut);
      final bobOut = <(NodeId, String)>[];
      final bobSvc = await _service(bob, bobOut);
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final gid = await ownerSvc.createGroup('Catch-up');
      for (final peer in [carol, bob]) {
        expect(
          await ownerSvc.addControlOp(
            gid,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      expect(
        await ownerSvc.addControlOp(gid, ControlOp.removeMember, target: bob),
        isTrue,
      );
      expect((await ownerSvc.stateOf(gid))!.isMember(bob), isFalse);

      final log = (await ownerSvc.load(gid))!.control;
      final admission = log.lastWhere(
        (entry) => entry.op == ControlOp.addMember && entry.target == bob,
      );
      final removal = log.lastWhere(
        (entry) => entry.op == ControlOp.removeMember,
      );

      ownerOut.clear();
      await ownerSvc.broadcastDelta(gid, control: [admission, removal]);
      final frames = _framesBy(ownerOut);
      expect(
        frames.keys,
        contains(carol),
        reason: 'positive control: the fanout did run',
      );
      expect(
        frames.keys,
        contains(bob),
        reason:
            'the removal names bob, and a delta that both admits and removes '
            'him leaves no membership difference for a fold diff to see',
      );
      expect(_ops(frames[bob]!), contains(ControlOp.removeMember.name));
      _expectNoKeyMaterial(frames[bob]!, who: 'a caught-up removed member');

      expect(
        await bobSvc.ingestGroupEntry(
          owner,
          ownerOut.lastWhere((entry) => entry.$1 == bob).$2,
        ),
        isTrue,
      );
      expect((await bobSvc.stateOf(gid))!.isMember(bob), isFalse);
    },
  );
}
