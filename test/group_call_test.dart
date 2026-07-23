import 'dart:async';
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
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/group_service.dart';
import 'package:xveil/state/call_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

class _Signer implements GroupSigner {
  _Signer(this.selfId);

  @override
  final NodeId selfId;

  @override
  Uint8List get selfPubKey => Uint8List.fromList(selfId.bytes);

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) =>
      value.withSignature(Uint8List(64));

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
  SpacePost signPost(SpacePost unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.author.bytes);

  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.requester.bytes);

  @override
  GroupCallSignal signCallSignal(GroupCallSignal unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.author.bytes);
  @override
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal unsigned) =>
      unsigned.withSignature(Uint8List(64), unsigned.appellant.bytes);
  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision unsigned,
  ) => unsigned.withSignature(Uint8List(64), unsigned.reviewer.bytes);

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
  bool verifyPost(SpacePost post) => _valid(post.signature, post.authorPubKey);

  @override
  bool verifyContentRequest(GroupContentRequest request) =>
      _valid(request.signature, request.authorPubKey);

  @override
  bool verifyCallSignal(GroupCallSignal signal) =>
      _valid(signal.signature, signal.authorPubKey) &&
      signal.authorPubKey.every((byte) => byte == signal.author.bytes.first);
  @override
  bool verifyModerationAppeal(SpaceModerationAppeal appeal) =>
      _valid(appeal.signature, appeal.authorPubKey);
  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision decision) =>
      _valid(decision.signature, decision.authorPubKey);

  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(Uint8List.fromList(value.genesisPubKey)) &&
      value.signature.length == 64;

  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(
    Uint8List message,
  ) => (signature: Uint8List(64), publicKey: selfPubKey);

  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      signer == NodeId(Uint8List.fromList(publicKey)) &&
      _valid(signature, publicKey);

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
  String? selectedScreenId;
  final StreamController<void> screenStops = StreamController.broadcast();
  final List<CallMediaDevice> screens = const [
    CallMediaDevice(
      id: 'display-1',
      label: 'Studio display',
      kind: CallMediaDeviceKind.screen,
      selected: true,
    ),
    CallMediaDevice(
      id: 'display-2',
      label: 'Projector',
      kind: CallMediaDeviceKind.screen,
    ),
  ];

  @override
  Stream<void> get screenShareStopped => screenStops.stream;

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

  @override
  Future<List<CallMediaDevice>> listScreens() async => screens;

  @override
  Future<bool> selectScreen(String id) async {
    if (!screens.any((screen) => screen.id == id)) return false;
    selectedScreenId = id;
    return true;
  }
}

void main() {
  final owner = _id(1);
  final bob = _id(2);
  final carol = _id(3);
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

  test('Space voice-session v2 binds the signed channel id', () {
    final channelId = _id(7);
    final unsigned = GroupCallSignal(
      groupId: _id(8),
      channelId: channelId,
      callId: 'voice-session-1',
      author: owner,
      membershipEpoch: 2,
      type: GroupCallSignalType.announce,
      media: const CallMedia(audio: true),
      sentAtMs: 123456,
      nonce: '00112233445566778899aabb',
      protocolVersion: kSpaceVoiceSessionProtocolVersion,
      signature: Uint8List(0),
      authorPubKey: Uint8List(0),
    );
    final signed = _Signer(owner).signCallSignal(unsigned);
    final decoded = GroupCallSignal.tryDecode(signed.encode());
    expect(decoded?.channelId, channelId);
    expect(decoded?.protocolVersion, kSpaceVoiceSessionProtocolVersion);
    expect(decoded?.canonicalBytes(), signed.canonicalBytes());

    expect(
      GroupCallSignal(
        groupId: _id(8),
        callId: 'missing-channel',
        author: owner,
        membershipEpoch: 2,
        type: GroupCallSignalType.announce,
        media: const CallMedia(audio: true),
        sentAtMs: 123456,
        nonce: '00112233445566778899aabb',
        protocolVersion: kSpaceVoiceSessionProtocolVersion,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      ).isStructurallyValid,
      isFalse,
    );
  });

  test(
    'restricted voice-session v3 binds channel epoch and uses channel AEAD',
    () async {
      final spaceId = _id(8);
      final channelId = _id(7);
      final channelKey = Uint8List.fromList(
        List<int>.generate(32, (index) => index),
      );
      final unsigned = GroupCallSignal(
        groupId: spaceId,
        channelId: channelId,
        channelEpoch: 4,
        callId: 'protected-voice-session',
        author: owner,
        membershipEpoch: 9,
        type: GroupCallSignalType.announce,
        media: const CallMedia(audio: true),
        sentAtMs: 123456,
        nonce: '00112233445566778899aabb',
        protocolVersion: kProtectedSpaceVoiceSessionProtocolVersion,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      final signed = _Signer(owner).signCallSignal(unsigned);
      final decoded = GroupCallSignal.tryDecode(signed.encode());
      expect(decoded?.channelId, channelId);
      expect(decoded?.channelEpoch, 4);
      expect(decoded?.canonicalBytes(), signed.canonicalBytes());

      final clear = Uint8List.fromList(utf8.encode(signed.encode()));
      final payload = await encryptSpaceChannelCallPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 4,
        author: owner,
        clearText: clear,
        channelKey: channelKey,
        random: Random(11),
      );
      final frame = GroupCallWireFrame(
        groupId: spaceId,
        channelId: channelId,
        channelEpoch: 4,
        payload: payload,
      );
      final frameJson = frame.encode();
      expect(frameJson, isNot(contains('protected-voice-session')));
      expect(frameJson, isNot(contains('announce')));
      final decodedFrame = GroupCallWireFrame.tryDecode(frameJson);
      expect(decodedFrame?.isChannelEncrypted, isTrue);
      expect(decodedFrame?.membershipEpoch, isNull);
      expect(decodedFrame?.channelId, channelId);
      expect(decodedFrame?.channelEpoch, 4);
      final opened = await decryptSpaceChannelCallPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 4,
        author: owner,
        payload: payload,
        channelKey: channelKey,
      );
      expect(
        GroupCallSignal.tryDecode(utf8.decode(opened))?.callId,
        'protected-voice-session',
      );
      opened.fillRange(0, opened.length, 0);
      clear.fillRange(0, clear.length, 0);

      await expectLater(
        decryptSpaceChannelCallPayload(
          spaceId: spaceId,
          channelId: _id(6),
          channelEpoch: 4,
          author: owner,
          payload: payload,
          channelKey: channelKey,
        ),
        throwsFormatException,
      );
      final mixedFrame = jsonDecode(frameJson) as Map<String, dynamic>
        ..['e'] = 9;
      expect(GroupCallWireFrame.tryDecode(jsonEncode(mixedFrame)), isNull);
      expect(
        GroupCallSignal(
          groupId: spaceId,
          channelId: channelId,
          callId: 'missing-channel-epoch',
          author: owner,
          membershipEpoch: 9,
          type: GroupCallSignalType.announce,
          media: const CallMedia(audio: true),
          sentAtMs: 123456,
          nonce: '00112233445566778899aabb',
          protocolVersion: kProtectedSpaceVoiceSessionProtocolVersion,
          signature: Uint8List(0),
          authorPubKey: Uint8List(0),
        ).isStructurallyValid,
        isFalse,
      );
    },
  );

  test('Space voice session starts only in an active voice channel', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final groups = GroupService(
      storage,
      _Signer(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
      sendGroupCallFrame: (_, _, _) async {},
    );
    final spaceId = await groups.createSpace('Voice Space');
    final textChannel = (await groups.channelsOf(spaceId)).single.channelId;
    final voiceChannel = await groups.createChannel(
      spaceId,
      name: 'Town hall',
      kind: SpaceChannelKind.voice,
    );
    expect(voiceChannel, isNotNull);

    final calls = GroupCallService(groups)..start();
    addTearDown(calls.dispose);
    expect(
      await calls.startCall(
        spaceId,
        const CallMedia(audio: true),
        channelId: textChannel,
      ),
      isFalse,
    );
    expect(
      await calls.startCall(
        spaceId,
        const CallMedia(audio: true),
        channelId: _id(99),
      ),
      isFalse,
    );
    expect(
      await calls.startCall(
        spaceId,
        const CallMedia(audio: true),
        channelId: voiceChannel,
      ),
      isTrue,
    );
    expect(calls.current?.channelId, voiceChannel);
    await calls.leave();

    expect(
      await groups.setChannelArchived(spaceId, voiceChannel!, true),
      isTrue,
    );
    expect(
      await calls.startCall(
        spaceId,
        const CallMedia(audio: true),
        channelId: voiceChannel,
      ),
      isFalse,
    );
  });

  test(
    'restricted voice uses channel fanout and ACL rotation tears media down',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      final carolStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      await carolStorage.open(password: 'pw', createIfMissing: true);
      late GroupService ownerGroups;
      late GroupService bobGroups;
      late GroupService carolGroups;
      final ownerFrames =
          <({NodeId peer, GroupCallSignal signal, String json})>[];
      final bobFrames =
          <({NodeId peer, GroupCallSignal signal, String json})>[];
      final ownerAccepted = <bool>[];
      ownerGroups = GroupService(
        ownerStorage,
        _Signer(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (peer, signal, json) async {
          ownerFrames.add((peer: peer, signal: signal, json: json));
          if (peer == bob) {
            await bobGroups.ingestGroupCallFrame(owner, json);
          } else if (peer == carol) {
            await carolGroups.ingestGroupCallFrame(owner, json);
          }
        },
      );
      final spaceId = await ownerGroups.createSpace('Protected voice');
      expect(
        await ownerGroups.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerGroups.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final voiceChannel = await ownerGroups.createChannel(
        spaceId,
        name: 'Core voice',
        kind: SpaceChannelKind.voice,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(voiceChannel, isNotNull);

      bobGroups = GroupService(
        bobStorage,
        _Signer(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (peer, signal, json) async {
          bobFrames.add((peer: peer, signal: signal, json: json));
          if (peer == owner) {
            ownerAccepted.add(
              await ownerGroups.ingestGroupCallFrame(bob, json),
            );
          }
        },
      );
      carolGroups = GroupService(
        carolStorage,
        _Signer(carol),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendGroupCallFrame: (_, _, _) async {},
      );
      expect(
        await bobGroups.ingestSnapshot(
          ownerGroups.snapshotJson(
            (await ownerGroups.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await carolGroups.ingestSnapshot(
          ownerGroups.snapshotJson(
            (await ownerGroups.load(spaceId))!,
            recipient: carol,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobGroups.channelsOf(spaceId)).map((entry) => entry.channelId),
        contains(voiceChannel),
      );
      expect(
        (await carolGroups.channelsOf(spaceId)).map((entry) => entry.channelId),
        isNot(contains(voiceChannel)),
      );

      final ownerMedia = _Media();
      final bobMedia = _Media();
      final carolMedia = _Media();
      final ownerCalls = GroupCallService(
        ownerGroups,
        media: ownerMedia,
        channelEpochReannounceDelays: const [Duration(milliseconds: 300)],
      )..start();
      final bobCalls = GroupCallService(bobGroups, media: bobMedia)..start();
      final carolCalls = GroupCallService(carolGroups, media: carolMedia)
        ..start();
      addTearDown(ownerCalls.dispose);
      addTearDown(bobCalls.dispose);
      addTearDown(carolCalls.dispose);
      addTearDown(ownerGroups.dispose);
      addTearDown(bobGroups.dispose);
      addTearDown(carolGroups.dispose);

      expect(
        await ownerCalls.startCall(
          spaceId,
          const CallMedia(audio: true),
          channelId: voiceChannel,
        ),
        isTrue,
      );
      await pumpEventQueue();
      expect(ownerFrames.map((entry) => entry.peer), [bob]);
      expect(bobCalls.current?.status, GroupCallStatus.ringing);
      expect(carolCalls.current, isNull);
      final firstFrame = GroupCallWireFrame.tryDecode(ownerFrames.single.json);
      expect(firstFrame?.isChannelEncrypted, isTrue);
      expect(firstFrame?.channelId, voiceChannel);
      expect(firstFrame?.channelEpoch, 1);
      expect(
        ownerFrames.single.json,
        isNot(contains(ownerCalls.current!.callId)),
      );
      expect(
        ownerFrames.single.signal.protocolVersion,
        kProtectedSpaceVoiceSessionProtocolVersion,
      );
      expect(ownerFrames.single.signal.channelEpoch, 1);

      expect(await bobCalls.join(), isTrue);
      await pumpEventQueue();
      expect(ownerAccepted.last, isTrue);
      expect(ownerCalls.current?.participants.keys, contains(bob.hex));
      expect(ownerCalls.current?.channelEpoch, 1);

      expect(
        await ownerGroups.setChannelMembers(spaceId, voiceChannel!, [carol]),
        isTrue,
      );
      await pumpEventQueue();
      expect(ownerCalls.current?.channelEpoch, 2);
      expect(ownerCalls.current?.participants.keys, [owner.hex]);
      expect(ownerMedia.latest?.participants.keys, [owner.hex]);
      expect(ownerFrames.last.peer, carol);
      expect(ownerFrames.last.signal.channelEpoch, 2);

      // Bob has not seen the rotation yet and can still mint an epoch-1 frame;
      // the authoritative owner rejects it before it reaches the call FSM.
      expect(
        await bobGroups.broadcastGroupCallSignal(
          spaceId,
          channelId: voiceChannel,
          callId: bobCalls.current!.callId,
          type: GroupCallSignalType.heartbeat,
          media: const CallMedia(audio: true),
        ),
        isNotNull,
      );
      expect(ownerAccepted.last, isFalse);
      expect(bobFrames.last.signal.channelEpoch, 1);

      final rotated = (await ownerGroups.load(spaceId))!;
      expect(
        await bobGroups.ingestSnapshot(
          ownerGroups.snapshotJson(rotated, recipient: bob),
        ),
        isTrue,
      );
      expect(
        await carolGroups.ingestSnapshot(
          ownerGroups.snapshotJson(rotated, recipient: carol),
        ),
        isTrue,
      );
      await pumpEventQueue();
      expect(bobCalls.current?.status, GroupCallStatus.ended);
      expect(bobMedia.stops, greaterThanOrEqualTo(1));
      expect(
        (await bobGroups.channelsOf(spaceId)).map((entry) => entry.channelId),
        isNot(contains(voiceChannel)),
      );
      expect(
        (await carolGroups.channelsOf(spaceId)).map((entry) => entry.channelId),
        contains(voiceChannel),
      );

      final before = ownerFrames.length;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await pumpEventQueue();
      expect(ownerFrames.skip(before).map((entry) => entry.peer), [carol]);
      expect(carolCalls.current?.status, GroupCallStatus.ringing);
      expect(carolCalls.current?.channelEpoch, 2);
    },
  );

  test('signed Space voice restriction prevents starting a session', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final ownerGroups = GroupService(
      storage,
      _Signer(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
      sendGroupCallFrame: (_, _, _) async {},
    );
    final spaceId = await ownerGroups.createSpace('Quiet room');
    final voiceChannel = await ownerGroups.createChannel(
      spaceId,
      name: 'Town hall',
      kind: SpaceChannelKind.voice,
    );
    expect(voiceChannel, isNotNull);
    expect(
      await ownerGroups.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(
      await ownerGroups.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.restrictVoice,
        target: bob,
        scope: SpaceModerationScope.voice,
        reason: 'voice cool-down',
      ),
      isNotNull,
    );

    final bobGroups = GroupService(
      storage,
      _Signer(bob),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
      sendGroupCallFrame: (_, _, _) async {},
    );
    final bobCalls = GroupCallService(bobGroups)..start();
    addTearDown(bobCalls.dispose);
    addTearDown(ownerGroups.dispose);
    addTearDown(bobGroups.dispose);
    expect(
      await bobCalls.startCall(
        spaceId,
        const CallMedia(audio: true),
        channelId: voiceChannel,
      ),
      isFalse,
    );
  });

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
      expect(ownerCalls.current?.micOn, isTrue);
      expect(ownerCalls.current?.cameraOn, isFalse);
      expect(ownerCalls.current?.screenOn, isFalse);
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

      await ownerCalls.leave();
      expect(
        await ownerCalls.startCall(
          groupId,
          const CallMedia(audio: true, video: true, screen: true),
        ),
        isTrue,
      );
      await pumpEventQueue();
      expect(ownerCalls.current?.micOn, isTrue);
      expect(ownerCalls.current?.cameraOn, isFalse);
      expect(ownerCalls.current?.screenOn, isTrue);
      expect(await ownerCalls.listScreens(), ownerMedia.screens);
      expect(await ownerCalls.selectScreen('display-2'), isTrue);
      expect(ownerMedia.selectedScreenId, 'display-2');
      expect(await ownerCalls.selectScreen('missing'), isFalse);

      ownerMedia.screenStops.add(null);
      await pumpEventQueue();
      expect(
        ownerCalls.current?.screenOn,
        isFalse,
        reason: 'an OS-revoked projection is folded into room state',
      );
    },
  );
}
