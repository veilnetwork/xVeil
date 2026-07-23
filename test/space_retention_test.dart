import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_epoch.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_retention.dart';

NodeId _id(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

ControlEntry _retentionEntry({
  required int seq,
  required int atMs,
  required SpaceRetentionPolicy policy,
  String prevHash = '',
}) => ControlEntry(
  version: 9,
  groupId: _id(9),
  author: _id(1),
  seq: seq,
  prevHash: prevHash,
  op: ControlOp.setRetention,
  target: null,
  role: null,
  retentionPolicy: policy,
  policyVersion: 0,
  createdAtMs: atMs,
  signature: Uint8List(64),
  authorPubKey: Uint8List(32),
);

GroupEncryptedPayload _opaquePayload() => GroupEncryptedPayload(
  nonce: Uint8List(12),
  cipherText: Uint8List.fromList([1, 2, 3]),
  mac: Uint8List(16),
);

void main() {
  test('typed retention policy validates and round-trips in signed V9 row', () {
    final policy = SpaceRetentionPolicy(
      mode: SpaceRetentionMode.deleteAfter,
      retentionMs: const Duration(days: 90).inMilliseconds,
    );
    final entry = _retentionEntry(seq: 0, atMs: 1000, policy: policy);

    expect(entry.isStructurallyValid, isTrue);
    final decoded = ControlEntry.fromJson(entry.toJson());
    expect(decoded?.retentionPolicy?.retentionMs, policy.retentionMs);
    expect(decoded?.op, ControlOp.setRetention);
  });

  test('retention is owner-only and is not available to legacy group rows', () {
    final owner = _id(1);
    final member = _id(2);
    final policy = SpaceRetentionPolicy(
      mode: SpaceRetentionMode.deleteAfter,
      retentionMs: const Duration(days: 7).inMilliseconds,
    );
    final add = ControlEntry(
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: member,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(0),
    );
    final rejected = ControlEntry(
      version: 9,
      groupId: _id(9),
      author: member,
      seq: 0,
      prevHash: '',
      op: ControlOp.setRetention,
      target: null,
      role: null,
      retentionPolicy: policy,
      policyVersion: 0,
      createdAtMs: 2,
      signature: Uint8List(0),
    );
    final result = foldControlLog(
      owner: owner,
      entries: [add, rejected],
      verify: (_) => true,
    );

    expect(result.state.retentionHistory, isEmpty);
    expect(result.rejected, contains(rejected));
  });

  test(
    'V15 restricted retention is opaque and bound to current channel epoch',
    () {
      final owner = _id(1);
      final space = _id(9);
      final channel = _id(4);
      final channelControl = ControlEntry(
        version: 5,
        groupId: space,
        author: owner,
        seq: 0,
        prevHash: '',
        op: ControlOp.createChannel,
        target: null,
        role: null,
        channelControl: SpaceChannelControlEnvelope(
          spaceId: space,
          channelId: channel,
          channelEpoch: 1,
          keyDescriptor: GroupEpochDescriptor(
            groupId: channel,
            epoch: 1,
            keyCommitment: 'a' * 64,
            envelopeRoot: 'b' * 64,
            recipientCount: 1,
          ),
          encryptedControl: _opaquePayload(),
        ),
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(0),
      );
      ControlEntry protectedRetention(int epoch) => ControlEntry(
        version: 15,
        groupId: space,
        author: owner,
        seq: 1,
        prevHash: controlEntryHash(channelControl),
        op: ControlOp.setRetention,
        target: null,
        role: null,
        channelRetention: SpaceChannelRetentionEnvelope(
          spaceId: space,
          channelId: channel,
          channelEpoch: epoch,
          encryptedPolicy: _opaquePayload(),
        ),
        policyVersion: 0,
        createdAtMs: 2,
        signature: Uint8List(0),
      );

      final current = protectedRetention(1);
      expect(current.isStructurallyValid, isTrue);
      expect(ControlEntry.fromJson(current.toJson())?.version, 15);
      expect(current.retentionPolicy, isNull);
      expect(
        foldControlLog(
          owner: owner,
          entries: [channelControl, current],
          verify: (_) => true,
        ).state.protectedRetention,
        contains('${owner.hex}:1'),
      );

      final stale = protectedRetention(2);
      final staleFold = foldControlLog(
        owner: owner,
        entries: [channelControl, stale],
        verify: (_) => true,
      );
      expect(staleFold.state.protectedRetention, isEmpty);
      expect(staleFold.rejected, contains(stale));
    },
  );

  test('relaxing policy never resurrects already retired content', () {
    final week = const Duration(days: 7).inMilliseconds;
    final destructive = SpaceRetentionRevision(
      policy: SpaceRetentionPolicy(
        mode: SpaceRetentionMode.deleteAfter,
        retentionMs: week,
      ),
      activatedAtMs: 20 * week,
      author: _id(1),
      authorSeq: 0,
    );
    final relaxed = SpaceRetentionRevision(
      policy: const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever),
      activatedAtMs: 21 * week,
      author: _id(1),
      authorSeq: 1,
    );

    expect(
      spaceRetentionRemoves(
        revisions: [destructive, relaxed],
        createdAtMs: 10 * week,
        atMs: 40 * week,
      ),
      isTrue,
    );
    expect(
      spaceRetentionRemoves(
        revisions: [destructive, relaxed],
        createdAtMs: 20 * week + const Duration(days: 1).inMilliseconds,
        atMs: 40 * week,
      ),
      isFalse,
    );
  });

  test('channel override can keep history while Space policy expires it', () {
    final channel = _id(4);
    final day = const Duration(days: 1).inMilliseconds;
    final revisions = [
      SpaceRetentionRevision(
        policy: SpaceRetentionPolicy(
          mode: SpaceRetentionMode.keepForever,
          channelId: channel,
        ),
        activatedAtMs: 10 * day,
        author: _id(1),
        authorSeq: 0,
      ),
      SpaceRetentionRevision(
        policy: SpaceRetentionPolicy(
          mode: SpaceRetentionMode.deleteAfter,
          retentionMs: 7 * day,
        ),
        activatedAtMs: 10 * day,
        author: _id(1),
        authorSeq: 1,
      ),
    ];

    expect(
      spaceRetentionRemoves(
        revisions: revisions,
        createdAtMs: day,
        atMs: 20 * day,
        channelId: channel,
      ),
      isFalse,
    );
    expect(
      spaceRetentionRemoves(
        revisions: revisions,
        createdAtMs: day,
        atMs: 20 * day,
        channelId: _id(5),
      ),
      isTrue,
    );
  });
}
