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
}
