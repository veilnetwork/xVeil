import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_epoch.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/state/group_epoch_service.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

NodeId _id(int byte) => NodeId.fromHex(_hash(byte));

void main() {
  test('binary group epoch payload binds group, epoch and commitment', () {
    final key = Uint8List.fromList(List.generate(32, (index) => index));
    final payload = encodeGroupEpochKeyPayload(
      groupId: _id(10),
      epoch: 7,
      key: key,
    );
    expect(payload.length, 101);
    final opened = decodeGroupEpochKeyPayload(payload);
    expect(opened, isNotNull);
    expect(opened!.groupId, _id(10));
    expect(opened.epoch, 7);
    expect(opened.key, key);
    expect(
      opened.keyCommitment,
      groupEpochKeyCommitment(groupId: _id(10), epoch: 7, key: key),
    );

    final tampered = Uint8List.fromList(payload)..[50] ^= 1;
    expect(decodeGroupEpochKeyPayload(tampered), isNull);
  });

  test('recipient envelopes use canonical Merkle inclusion proofs', () {
    final sealSet = buildGroupEpochSealSet(
      groupId: _id(10),
      epoch: 3,
      keyCommitment: _hash(20),
      entries: [
        (recipient: _id(4), sealed: Uint8List.fromList([4, 4])),
        (recipient: _id(2), sealed: Uint8List.fromList([2, 2])),
        (recipient: _id(3), sealed: Uint8List.fromList([3, 3])),
      ],
    );
    expect(sealSet.descriptor.recipientCount, 3);
    expect(sealSet.envelopes.map((entry) => entry.recipient), [
      _id(2),
      _id(3),
      _id(4),
    ]);
    for (final envelope in sealSet.envelopes) {
      expect(
        GroupEpochRecipientEnvelope.fromJson(envelope.toJson()),
        isNotNull,
      );
      expect(
        verifyGroupEpochEnvelope(
          descriptor: sealSet.descriptor,
          envelope: envelope,
        ),
        isTrue,
      );
    }

    final original = sealSet.envelopes[1];
    final tamperedSealed = GroupEpochRecipientEnvelope(
      groupId: original.groupId,
      epoch: original.epoch,
      keyCommitment: original.keyCommitment,
      recipient: original.recipient,
      index: original.index,
      recipientCount: original.recipientCount,
      sealed: Uint8List.fromList(original.sealed)..[0] ^= 1,
      proof: original.proof,
    );
    expect(
      verifyGroupEpochEnvelope(
        descriptor: sealSet.descriptor,
        envelope: tamperedSealed,
      ),
      isFalse,
    );
    final copiedRecipient = GroupEpochRecipientEnvelope(
      groupId: original.groupId,
      epoch: original.epoch,
      keyCommitment: original.keyCommitment,
      recipient: _id(9),
      index: original.index,
      recipientCount: original.recipientCount,
      sealed: original.sealed,
      proof: original.proof,
    );
    expect(
      verifyGroupEpochEnvelope(
        descriptor: sealSet.descriptor,
        envelope: copiedRecipient,
      ),
      isFalse,
    );

    final malformed = Map<String, dynamic>.from(original.toJson())
      ..['proof'] = <String>[];
    expect(GroupEpochRecipientEnvelope.fromJson(malformed), isNull);
  });

  test('mailbox-backed group envelope verifies issuer and inclusion', () async {
    final issuer = _id(1);
    final recipient = _id(2);
    final service = GroupEpochService(
      LoopbackMailboxCrypto(senderForOpen: issuer),
    );
    final key = Uint8List.fromList(List.generate(32, (index) => 255 - index));
    final sealSet = await service.sealEpoch(
      groupId: _id(10),
      epoch: 4,
      epochKey: key,
      recipients: [recipient, _id(3), recipient],
    );
    expect(sealSet.descriptor.recipientCount, 2);
    final opened = await service.openEpoch(
      descriptor: sealSet.descriptor,
      envelope: sealSet.envelopeFor(recipient)!,
      recipient: recipient,
      expectedIssuer: issuer,
      ourCertVersion: 0,
    );
    expect(opened.key, key);
    expect(opened.groupId, _id(10));
    expect(opened.epoch, 4);
    expect(key, isNot(everyElement(0)), reason: 'caller key stays owned');

    await expectLater(
      service.openEpoch(
        descriptor: sealSet.descriptor,
        envelope: sealSet.envelopeFor(recipient)!,
        recipient: recipient,
        expectedIssuer: _id(9),
        ourCertVersion: 0,
      ),
      throwsStateError,
    );
    await expectLater(
      service.openEpoch(
        descriptor: sealSet.descriptor,
        envelope: sealSet.envelopeFor(recipient)!,
        recipient: _id(8),
        expectedIssuer: issuer,
        ourCertVersion: 0,
      ),
      throwsStateError,
    );
  });

  test(
    'control log binds a valid epoch descriptor without changing legacy',
    () {
      final groupId = _id(10);
      final owner = _id(1);
      final member = _id(2);
      final add = ControlEntry(
        groupId: groupId,
        author: owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.addMember,
        target: member,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 1000,
        signature: Uint8List(64),
      );
      expect(utf8.decode(add.canonicalBytes()), isNot(contains('"ek"')));
      final descriptor = GroupEpochDescriptor(
        groupId: groupId,
        epoch: 1,
        keyCommitment: _hash(20),
        envelopeRoot: _hash(21),
        recipientCount: 2,
      );
      final rotate = ControlEntry(
        groupId: groupId,
        author: owner,
        seq: 1,
        prevHash: '',
        op: ControlOp.rotateEpoch,
        target: null,
        role: null,
        policyVersion: 0,
        createdAtMs: 2000,
        signature: Uint8List(64),
        epochDescriptor: descriptor,
      );
      final roundTrip = ControlEntry.fromJson(rotate.toJson());
      expect(roundTrip, isNotNull);
      expect(roundTrip!.canonicalBytes(), rotate.canonicalBytes());
      expect(roundTrip.epochDescriptor!.envelopeRoot, descriptor.envelopeRoot);

      final folded = foldControlLog(
        owner: owner,
        entries: [add, rotate],
        verify: (_) => true,
      );
      expect(folded.rejected, isEmpty);
      expect(folded.state.epoch, 1);
      expect(
        folded.state.epochDescriptor?.envelopeRoot,
        descriptor.envelopeRoot,
      );

      final wrongCount = ControlEntry(
        groupId: groupId,
        author: owner,
        seq: 1,
        prevHash: '',
        op: ControlOp.rotateEpoch,
        target: null,
        role: null,
        policyVersion: 0,
        createdAtMs: 2000,
        signature: Uint8List(64),
        epochDescriptor: GroupEpochDescriptor(
          groupId: groupId,
          epoch: 1,
          keyCommitment: _hash(20),
          envelopeRoot: _hash(21),
          recipientCount: 1,
        ),
      );
      final rejected = foldControlLog(
        owner: owner,
        entries: [add, wrongCount],
        verify: (_) => true,
      );
      expect(rejected.rejected, contains(wrongCount));
      expect(rejected.state.epoch, 0);
    },
  );

  test(
    'concurrent departures both apply and stale epoch proposal fails closed',
    () {
      final groupId = _id(10);
      final owner = _id(1);
      final admin = _id(2);
      final bob = _id(3);
      final carol = _id(4);
      ControlEntry entry({
        required NodeId author,
        required int seq,
        required int ts,
        required ControlOp op,
        NodeId? target,
        GroupRole? role,
        GroupEpochDescriptor? descriptor,
      }) => ControlEntry(
        groupId: groupId,
        author: author,
        seq: seq,
        prevHash: '',
        op: op,
        target: target,
        role: role,
        policyVersion: 0,
        createdAtMs: ts,
        signature: Uint8List(64),
        epochDescriptor: descriptor,
      );

      final setup = [
        entry(
          author: owner,
          seq: 0,
          ts: 100,
          op: ControlOp.addMember,
          target: admin,
          role: GroupRole.admin,
        ),
        entry(
          author: owner,
          seq: 1,
          ts: 101,
          op: ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        entry(
          author: owner,
          seq: 2,
          ts: 102,
          op: ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
      ];
      GroupEpochDescriptor descriptor(int root) => GroupEpochDescriptor(
        groupId: groupId,
        epoch: 1,
        keyCommitment: _hash(root),
        envelopeRoot: _hash(root + 1),
        recipientCount: 3,
      );
      final removeBob = entry(
        author: owner,
        seq: 3,
        ts: 200,
        op: ControlOp.removeMember,
        target: bob,
        descriptor: descriptor(20),
      );
      final removeCarol = entry(
        author: admin,
        seq: 0,
        ts: 201,
        op: ControlOp.removeMember,
        target: carol,
        descriptor: descriptor(30),
      );
      final folded = foldControlLog(
        owner: owner,
        entries: [...setup, removeBob, removeCarol],
        verify: (_) => true,
      );
      expect(folded.rejected, isNot(contains(removeBob)));
      expect(folded.rejected, isNot(contains(removeCarol)));
      expect(folded.state.isMember(bob), isFalse);
      expect(folded.state.isMember(carol), isFalse);
      expect(folded.state.epoch, 2);
      expect(folded.state.epochDescriptor, isNull);
    },
  );
}
