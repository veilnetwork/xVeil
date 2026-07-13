import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

class _Signer implements GroupSigner {
  _Signer(this.selfId);

  @override
  final NodeId selfId;

  @override
  Uint8List get selfPubKey => Uint8List.fromList(selfId.bytes);

  @override
  ControlEntry signControl(ControlEntry unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.author.bytes);

  @override
  GroupMessage signMessage(GroupMessage unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.author.bytes);

  @override
  GroupReaction signReaction(GroupReaction unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.author.bytes);

  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.requester.bytes);

  @override
  GroupCallSignal signCallSignal(GroupCallSignal unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.author.bytes);

  bool _valid(List<int> signature, List<int> publicKey) =>
      signature.length == 64 && publicKey.length == 32;

  @override
  bool verifyControl(ControlEntry entry) =>
      _valid(entry.signature, entry.authorPubKey);

  @override
  bool verifyMessage(GroupMessage message) =>
      _valid(message.signature, message.authorPubKey);

  @override
  bool verifyReaction(GroupReaction reaction) =>
      _valid(reaction.signature, reaction.authorPubKey);

  @override
  bool verifyContentRequest(GroupContentRequest request) =>
      _valid(request.signature, request.authorPubKey);

  @override
  bool verifyCallSignal(GroupCallSignal signal) =>
      _valid(signal.signature, signal.authorPubKey) &&
      signal.authorPubKey.every((byte) => byte == signal.author.bytes.first);

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => false;
}

class _Media extends GroupCallMediaController {
  int starts = 0;
  int updates = 0;
  int stops = 0;
  GroupCall? latest;

  @override
  Future<bool> start(GroupCall call) async {
    starts++;
    latest = call;
    return true;
  }

  @override
  Future<void> update(GroupCall call) async {
    updates++;
    latest = call;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  final owner = _id(1);
  final bob = _id(2);
  final stranger = _id(9);

  test(
    'signed signal round-trips canonically and rejects mixed clear shape',
    () {
      final unsigned = GroupCallSignal(
        groupId: _id(8),
        callId: 'call-1',
        author: owner,
        membershipEpoch: 4,
        type: GroupCallSignalType.announce,
        media: const CallMedia(audio: true, video: true),
        sentAtMs: 123456,
        nonce: '00112233445566778899aabb',
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      final signed = _Signer(owner).signCallSignal(unsigned);
      final decoded = GroupCallSignal.tryDecode(signed.encode());
      expect(decoded, isNotNull);
      expect(decoded!.canonicalBytes(), signed.canonicalBytes());
      expect(decoded.callId, 'call-1');
      expect(decoded.media?.video, isTrue);

      final malformed = signed.toJson()..['n'] = 'short';
      expect(GroupCallSignal.tryDecode(malformed), isNull);
      final unknown = signed.toJson()..['k'] = 999;
      expect(GroupCallSignal.tryDecode(unknown), isNull);
    },
  );

  test(
    'group-call AEAD binds gid, epoch and authenticated transport author',
    () async {
      final key = Uint8List.fromList(List.generate(32, (index) => index));
      final clear = Uint8List.fromList(utf8.encode('signed signal'));
      final payload = await encryptGroupCallPayload(
        groupId: _id(8),
        membershipEpoch: 3,
        author: owner,
        clearText: clear,
        epochKey: key,
        random: Random(7),
      );
      final opened = await decryptGroupCallPayload(
        groupId: _id(8),
        membershipEpoch: 3,
        author: owner,
        payload: payload,
        epochKey: key,
      );
      expect(utf8.decode(opened), 'signed signal');
      opened.fillRange(0, opened.length, 0);
      await expectLater(
        decryptGroupCallPayload(
          groupId: _id(8),
          membershipEpoch: 3,
          author: stranger,
          payload: payload,
          epochKey: key,
        ),
        throwsFormatException,
      );
      await expectLater(
        decryptGroupCallPayload(
          groupId: _id(8),
          membershipEpoch: 4,
          author: owner,
          payload: payload,
          epochKey: key,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'ephemeral signal is ciphertext-only, replay-safe and current-member gated',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerFrames =
          <({NodeId peer, GroupCallSignal signal, String json})>[];
      final ownerService = GroupService(
        ownerStorage,
        _Signer(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (peer, signal, json) async {
          ownerFrames.add((peer: peer, signal: signal, json: json));
        },
      );
      final groupId = await ownerService.createGroup('Calls');
      expect(
        await ownerService.addControlOp(
          groupId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobFrames =
          <({NodeId peer, GroupCallSignal signal, String json})>[];
      final bobService = GroupService(
        bobStorage,
        _Signer(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (peer, signal, json) async {
          bobFrames.add((peer: peer, signal: signal, json: json));
        },
      );
      final ownerBundle = (await ownerService.load(groupId))!;
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(ownerBundle, recipient: bob),
        ),
        isTrue,
      );

      final incoming = bobService.groupCallIncoming.first;
      final sent = await ownerService.broadcastGroupCallSignal(
        groupId,
        callId: 'private-call-id',
        type: GroupCallSignalType.announce,
        media: const CallMedia(audio: true, video: true),
      );
      expect(sent, isNotNull);
      expect(ownerFrames, hasLength(1));
      expect(ownerFrames.single.peer, bob);
      expect(ownerFrames.single.json, isNot(contains('private-call-id')));
      expect(ownerFrames.single.json, isNot(contains('announce')));
      expect(
        await bobService.ingestGroupCallFrame(owner, ownerFrames.single.json),
        isTrue,
      );
      expect((await incoming).callId, 'private-call-id');
      expect(
        await bobService.ingestGroupCallFrame(owner, ownerFrames.single.json),
        isFalse,
      );
      expect(
        await bobService.ingestGroupCallFrame(
          stranger,
          ownerFrames.single.json,
        ),
        isFalse,
      );

      expect(
        await bobService.broadcastGroupCallSignal(
          groupId,
          callId: 'private-call-id',
          type: GroupCallSignalType.join,
          media: const CallMedia(audio: true, video: true),
        ),
        isNotNull,
      );
      expect(bobFrames, hasLength(1));
      final ownerIncoming = ownerService.groupCallIncoming.first;
      expect(
        await ownerService.ingestGroupCallFrame(bob, bobFrames.single.json),
        isTrue,
      );
      expect((await ownerIncoming).type, GroupCallSignalType.join);

      expect(
        await ownerService.addControlOp(
          groupId,
          ControlOp.removeMember,
          target: bob,
        ),
        isTrue,
      );
      // Bob's stale local view can still mint epoch-2 ciphertext, but the
      // authoritative current fold rejects it silently after removal.
      expect(
        await bobService.broadcastGroupCallSignal(
          groupId,
          callId: 'private-call-id',
          type: GroupCallSignalType.heartbeat,
        ),
        isNotNull,
      );
      expect(bobFrames, hasLength(2));
      expect(
        await ownerService.ingestGroupCallFrame(bob, bobFrames.last.json),
        isFalse,
      );
      final before = ownerFrames.length;
      expect(
        await ownerService.broadcastGroupCallSignal(
          groupId,
          callId: 'owner-only',
          type: GroupCallSignalType.announce,
          media: const CallMedia(audio: true),
        ),
        isNotNull,
      );
      expect(ownerFrames, hasLength(before));

      final persisted = utf8.decode(
        (await ownerStorage.loadFile('group:${groupId.hex}'))!,
      );
      expect(persisted, isNot(contains('private-call-id')));
    },
  );

  test(
    'N-party FSM rings, joins, syncs media and honors admin end + revoke',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      late GroupService ownerGroups;
      late GroupService bobGroups;
      final bobSignals = <GroupCallSignal>[];
      ownerGroups = GroupService(
        ownerStorage,
        _Signer(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (peer, signal, json) async {
          if (peer == bob) await bobGroups.ingestGroupCallFrame(owner, json);
        },
      );
      final groupId = await ownerGroups.createGroup('Live room');
      await ownerGroups.addControlOp(
        groupId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      bobGroups = GroupService(
        bobStorage,
        _Signer(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (peer, signal, json) async {
          bobSignals.add(signal);
          if (peer == owner) await ownerGroups.ingestGroupCallFrame(bob, json);
        },
      );
      expect(
        await bobGroups.ingestSnapshot(
          ownerGroups.snapshotJson(
            (await ownerGroups.load(groupId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      final ownerMedia = _Media();
      final bobMedia = _Media();
      final ownerCalls = GroupCallService(ownerGroups, media: ownerMedia)
        ..start();
      final bobCalls = GroupCallService(
        bobGroups,
        media: bobMedia,
        heartbeatInterval: const Duration(milliseconds: 10),
        reannounceInterval: const Duration(milliseconds: 25),
      )..start();
      addTearDown(ownerCalls.dispose);
      addTearDown(bobCalls.dispose);

      expect(
        await ownerCalls.startCall(
          groupId,
          const CallMedia(audio: true, video: true),
        ),
        isTrue,
      );
      await pumpEventQueue();
      expect(ownerCalls.current?.status, GroupCallStatus.active);
      expect(ownerMedia.starts, 1);
      expect(bobCalls.current?.status, GroupCallStatus.ringing);
      expect(bobCalls.current?.initiator, owner);

      expect(await bobCalls.join(), isTrue);
      await pumpEventQueue();
      expect(bobCalls.current?.status, GroupCallStatus.active);
      expect(
        ownerCalls.current?.participants.keys,
        containsAll([owner.hex, bob.hex]),
      );
      expect(ownerMedia.updates, greaterThanOrEqualTo(1));

      await bobCalls.setMicEnabled(false);
      await bobCalls.setCameraEnabled(false);
      await pumpEventQueue();
      expect(bobCalls.current?.micOn, isFalse);
      expect(bobCalls.current?.participants[bob.hex]?.media.audio, isFalse);
      expect(bobCalls.current?.participants[bob.hex]?.media.video, isFalse);
      expect(ownerCalls.current?.participants[bob.hex]?.media.audio, isFalse);
      expect(ownerCalls.current?.participants[bob.hex]?.media.video, isFalse);

      // Renegotiate is live-only and can be lost. Periodic heartbeat and
      // reannounce must repeat the CURRENT posture, not restore the room's
      // original audio+video capabilities. Short injected intervals make this
      // a fast deterministic regression for the physical-iPhone failure.
      final afterToggle = bobSignals.length;
      await Future<void>.delayed(const Duration(milliseconds: 45));
      await pumpEventQueue();
      final recoverySignals = bobSignals
          .skip(afterToggle)
          .where(
            (signal) =>
                signal.type == GroupCallSignalType.heartbeat ||
                signal.type == GroupCallSignalType.announce,
          );
      expect(recoverySignals, isNotEmpty);
      final recoveryHeartbeats = recoverySignals.where(
        (signal) => signal.type == GroupCallSignalType.heartbeat,
      );
      final recoveryAnnounces = recoverySignals.where(
        (signal) => signal.type == GroupCallSignalType.announce,
      );
      expect(recoveryHeartbeats, isNotEmpty);
      expect(
        recoveryHeartbeats.every(
          (signal) =>
              signal.media?.audio == false && signal.media?.video == false,
        ),
        isTrue,
      );
      expect(recoveryAnnounces, isNotEmpty);
      expect(
        recoveryAnnounces.every(
          (signal) =>
              signal.media?.audio == true && signal.media?.video == true,
        ),
        isTrue,
      );
      expect(ownerCalls.current?.participants[bob.hex]?.media.audio, isFalse);
      expect(ownerCalls.current?.participants[bob.hex]?.media.video, isFalse);

      // A plain member cannot terminate the room for everyone.
      expect(await bobCalls.endForEveryone(), isFalse);
      final endedCallId = ownerCalls.current!.callId;
      expect(await ownerCalls.endForEveryone(), isTrue);
      await pumpEventQueue();
      expect(ownerCalls.current?.status, GroupCallStatus.ended);
      expect(bobCalls.current?.status, GroupCallStatus.ended);
      expect(ownerMedia.stops, greaterThanOrEqualTo(1));
      expect(bobMedia.stops, greaterThanOrEqualTo(1));

      // A delayed durable periodic announce must not ring a room again after
      // its admin end. This happened on the four-device physical-iPhone run.
      expect(
        await ownerGroups.broadcastGroupCallSignal(
          groupId,
          callId: endedCallId,
          type: GroupCallSignalType.announce,
          media: const CallMedia(audio: true, video: true),
        ),
        isNotNull,
      );
      await pumpEventQueue();
      expect(bobCalls.current?.callId, endedCallId);
      expect(bobCalls.current?.status, GroupCallStatus.ended);

      // The same protection must work when durable end arrives before the
      // first announce for a room (different relay/outbox ordering).
      const reorderedCallId = 'end-before-announce';
      expect(
        await ownerGroups.broadcastGroupCallSignal(
          groupId,
          callId: reorderedCallId,
          type: GroupCallSignalType.end,
          reason: CallEndReason.hangup,
        ),
        isNotNull,
      );
      expect(
        await ownerGroups.broadcastGroupCallSignal(
          groupId,
          callId: reorderedCallId,
          type: GroupCallSignalType.announce,
          media: const CallMedia(audio: true),
        ),
        isNotNull,
      );
      await pumpEventQueue();
      expect(bobCalls.current?.callId, endedCallId);
      expect(bobCalls.current?.status, GroupCallStatus.ended);

      // A fresh room drops a participant from the authoritative projection as
      // soon as the group control fold revokes them; no call signal is required.
      expect(
        await ownerCalls.startCall(groupId, const CallMedia(audio: true)),
        isTrue,
      );
      await pumpEventQueue();
      expect(await bobCalls.join(), isTrue);
      await pumpEventQueue();
      expect(ownerCalls.current?.participants, hasLength(2));
      expect(
        await ownerGroups.addControlOp(
          groupId,
          ControlOp.removeMember,
          target: bob,
        ),
        isTrue,
      );
      await pumpEventQueue();
      expect(ownerCalls.current?.participants.keys, [owner.hex]);
      expect(ownerMedia.latest?.participants.keys, [owner.hex]);
    },
  );
}
