import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/device_link.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_lifecycle.dart';
import 'package:xveil/domain/space_join_request.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_rules.dart';
import 'package:xveil/domain/space_recommendation.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/group_service_providers.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

NodeId _ordinalId(int value) {
  final bytes = Uint8List(32);
  bytes[0] = (value >> 8) & 0xff;
  bytes[1] = value & 0xff;
  return NodeId(bytes);
}

/// A fake signer: a deterministic "public key" per author (its node id bytes),
/// signatures are a fixed marker, verification accepts anything well-formed.
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
  bool verifyControl(ControlEntry e) =>
      e.signature.length == 64 && e.authorPubKey.length == 32;
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
  @override
  bool verifyCallSignal(GroupCallSignal s) =>
      s.signature.length == 64 && s.authorPubKey.length == 32;
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

class _NativeSovereignVerifier extends _FakeSigner {
  _NativeSovereignVerifier(super._self);

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => veil.verifySovereignSignature(
    algorithm: algorithm,
    nodeId: nodeId.bytes,
    publicKey: publicKey,
    message: message,
    signature: signature,
  );
}

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

class _FakeSovereign implements SovereignGroupSigner {
  _FakeSovereign(this.nodeId);
  @override
  final NodeId nodeId;
  bool _closed = false;
  @override
  String get algorithm => 'ed25519';
  @override
  Uint8List get publicKey => Uint8List.fromList(nodeId.bytes);
  @override
  Uint8List sign(Uint8List message) {
    if (_closed) throw StateError('closed');
    return _fakeSovereignSignature(publicKey, message);
  }

  @override
  void close() => _closed = true;
}

void main() {
  final hasVeilFfi = (Platform.environment['VEIL_FFI_DYLIB'] ?? '').isNotEmpty;
  final owner = _id(1);
  final bob = _id(3);
  final carol = _id(4);
  final stranger = _id(7);
  final sovereign = _FakeSovereign(_id(9));

  /// Fresh storage + an owner-perspective service; extra services over the SAME
  /// storage model other members on their own devices.
  Future<(GroupService, dynamic Function(NodeId))> setup() async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    GroupService member(NodeId self) =>
        GroupService(storage, _FakeSigner(self));
    return (member(owner), member);
  }

  test('create -> owner is sole member, group persists + lists', () async {
    final (svc, _) = await setup();
    final ticks = <int>[];
    void recordTick() => ticks.add(svc.changes.value);
    svc.changes.addListener(recordTick);
    addTearDown(() => svc.changes.removeListener(recordTick));
    final gid = await svc.createGroup('Family');
    final state = (await svc.stateOf(gid))!;
    final manifest = (await svc.load(gid))!.manifest;
    expect(state.roleOf(owner), GroupRole.owner);
    expect(state.members.length, 1);
    final groups = await svc.listGroups();
    expect(groups.single.name, 'Family');
    expect(groups.single.groupId, gid);
    expect(
      groups.single.lastTs,
      manifest.createdAtMs,
      reason:
          'an empty new group must sort by creation time instead of falling '
          'to the bottom of Chats with timestamp zero',
    );
    expect(ticks, [
      1,
    ], reason: 'a mounted Chats list must refresh after the durable create');
  });

  test('mounted group list provider emits a newly created group', () async {
    final (service, _) = await setup();
    final container = ProviderContainer(
      overrides: [groupServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final values = <List<GroupListEntry>>[];
    final subscription = container.listen(
      groupListProvider,
      (_, next) => next.whenData(values.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    expect(await container.read(groupListProvider.future), isEmpty);
    final groupId = await service.createGroup('Visible immediately');
    for (var attempt = 0; attempt < 20; attempt++) {
      if (values.any(
        (value) => value.any((entry) => entry.groupId == groupId),
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(
      values.expand((value) => value).map((entry) => entry.groupId),
      contains(groupId),
      reason: 'Chats must update without restarting or another group mutation',
    );
  });

  test(
    'group chats and Spaces have disjoint creation and list semantics',
    () async {
      final (service, _) = await setup();
      final before = service.changes.value;
      final groupId = await service.createGroup('Family chat');
      final spaceId = await service.createSpace('Builders');

      final group = (await service.load(groupId))!;
      final space = (await service.load(spaceId))!;
      expect(group.manifest.isSpace, isFalse);
      expect(await service.channelsOf(groupId), isEmpty);
      expect(space.manifest.isSpace, isTrue);
      expect(await service.channelsOf(spaceId), hasLength(1));

      expect((await service.listGroups()).single.groupId, groupId);
      expect((await service.listSpaces()).single.groupId, spaceId);
      expect(
        service.changes.value,
        before + 2,
        reason: 'Group and Space creation each invalidate their own list',
      );
    },
  );

  test(
    'Space rules are signed, versioned and require explicit re-acceptance',
    () async {
      final (service, member) = await setup();
      final groupId = await service.createGroup('Family chat');
      final spaceId = await service.createSpace('Builders');

      expect(
        await service.publishSpaceRules(
          groupId,
          fullText: 'Rules must never attach to a group chat.',
          summary: 'Wrong entity',
        ),
        isFalse,
      );
      expect(
        await service.publishSpaceRules(
          spaceId,
          fullText: 'Be kind. Verify information before redistributing it.',
          summary: 'Be kind and verify.',
        ),
        isTrue,
      );
      var state = (await service.stateOf(spaceId))!;
      expect(state.currentRules?.version, 1);
      expect(state.rulesHistory, hasLength(1));
      expect(state.requiresRulesAcceptance(owner), isTrue);
      expect(await service.acceptSpaceRules(spaceId), isTrue);
      state = (await service.stateOf(spaceId))!;
      expect(state.requiresRulesAcceptance(owner), isFalse);
      expect(state.rulesAcceptanceOf(owner)?.rulesVersion, 1);

      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );
      expect(
        await member(bob).publishSpaceRules(
          spaceId,
          fullText: 'An admin must not replace owner-approved rules.',
          summary: 'Forged',
        ),
        isFalse,
      );

      expect(
        await service.publishSpaceRules(
          spaceId,
          fullText: 'Be kind. Verify sources. Do not expose private data.',
          summary: 'Privacy requirement added.',
        ),
        isTrue,
      );
      state = (await service.stateOf(spaceId))!;
      expect(state.currentRules?.version, 2);
      expect(state.currentRules?.previousVersion, 1);
      expect(state.rulesHistory, hasLength(2));
      expect(state.requiresRulesAcceptance(owner), isTrue);
      expect(state.requiresRulesAcceptance(bob), isTrue);
      expect(
        SpaceRulesVersion.fromJson(state.currentRules!.toJson())?.fullText,
        state.currentRules!.fullText,
      );
    },
  );

  test(
    'epoch E2EE persists and wires only ciphertext for messages + reactions',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('Encrypted');
      expect((await ownerSvc.stateOf(gid))!.epoch, 1);
      expect(
        await ownerSvc.addControlOp(
          gid,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final afterJoin = (await ownerSvc.stateOf(gid))!;
      expect(afterJoin.epoch, 2);
      expect(afterJoin.epochDescriptor?.recipientCount, 2);

      const attachment = GroupAttachment(
        kind: 'image',
        dataB64: 'c2VjcmV0LWltYWdl',
        w: 32,
        h: 24,
        cid: 'private-content-id',
      );
      const customEmoji = InlineCustomEmoji(offset: 6, dataB64: 'AQID');
      expect(
        await ownerSvc.postMessage(
          gid,
          'owner ☺ secret',
          attachment: attachment,
          customEmoji: const [customEmoji],
          broadcast: false,
        ),
        isTrue,
      );
      final ownerBundle = (await ownerSvc.load(gid))!;
      expect(ownerBundle.messages.single.isEncrypted, isTrue);
      expect(ownerBundle.messages.single.body, isEmpty);
      final bobWire = ownerSvc.snapshotJson(ownerBundle, recipient: bob);
      expect(bobWire, isNot(contains('owner ☺ secret')));
      expect(bobWire, isNot(contains('AQID')));
      expect(bobWire, isNot(contains('private-content-id')));
      expect((jsonDecode(bobWire) as Map)['kk'], isNull);
      expect(((jsonDecode(bobWire) as Map)['ke'] as List).length, 1);

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(await bobSvc.ingestSnapshot(bobWire), isTrue);
      final bobMessages = await bobSvc.messagesOf(gid);
      expect(bobMessages.single.body, 'owner ☺ secret');
      expect(bobMessages.single.customEmoji.single.offset, 6);
      expect(bobMessages.single.customEmoji.single.dataB64, 'AQID');
      expect(bobMessages.single.attachment?.cid, 'private-content-id');
      final persisted = utf8.decode(
        (await bobStorage.loadFile('group:${gid.hex}'))!,
      );
      expect(persisted, isNot(contains('owner ☺ secret')));
      expect(persisted, isNot(contains('AQID')));
      expect(persisted, isNot(contains('private-content-id')));

      expect(
        await bobSvc.postMessage(gid, 'bob secret', broadcast: false),
        isTrue,
      );
      expect(
        await bobSvc.react(gid, bobMessages.single.ref, '🔥', broadcast: false),
        isTrue,
      );
      final bobBundle = (await bobSvc.load(gid))!;
      expect(bobBundle.messages.last.isEncrypted, isTrue);
      expect(bobBundle.reactions.single.isEncrypted, isTrue);
      final ownerWire = bobSvc.snapshotJson(bobBundle, recipient: owner);
      expect(ownerWire, isNot(contains('bob secret')));
      expect(ownerWire, isNot(contains('🔥')));
      final concurrentLocal = ownerSvc.postMessage(
        gid,
        'concurrent owner secret',
        broadcast: false,
      );
      final concurrentIngest = ownerSvc.ingestSnapshot(ownerWire);
      expect(await concurrentLocal, isTrue);
      expect(await concurrentIngest, isTrue);
      expect(
        (await ownerSvc.messagesOf(gid)).map((message) => message.body),
        containsAll([
          'owner ☺ secret',
          'bob secret',
          'concurrent owner secret',
        ]),
      );
      expect((await ownerSvc.reactionsOf(gid))[bobMessages.single.ref]?['🔥'], [
        bob,
      ]);
    },
  );

  test(
    'new members get only the post-join epoch and removed members get no new key',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('Forward secure');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'before carol', broadcast: false);
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'after carol', broadcast: false);
      final bundle = (await ownerSvc.load(gid))!;
      expect((await ownerSvc.stateOf(gid))!.epoch, 3);
      expect(
        bundle.messages.last.prevHash,
        isEmpty,
        reason: 'a membership epoch is a new visibility/chain scope',
      );
      final carolWire = ownerSvc.snapshotJson(bundle, recipient: carol);
      expect(carolWire, isNot(contains('before carol')));

      final carolStorage = FakeHvContainer().storage();
      await carolStorage.open(password: 'pw', createIfMissing: true);
      final carolSvc = GroupService(
        carolStorage,
        _FakeSigner(carol),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(await carolSvc.ingestSnapshot(carolWire), isTrue);
      expect((await carolSvc.messagesOf(gid)).map((message) => message.body), [
        'after carol',
      ]);

      expect(
        await ownerSvc.addControlOp(gid, ControlOp.removeMember, target: bob),
        isTrue,
      );
      expect((await ownerSvc.stateOf(gid))!.epoch, 4);
      await ownerSvc.postMessage(gid, 'after bob removal', broadcast: false);
      final removedWire = ownerSvc.snapshotJson(
        (await ownerSvc.load(gid))!,
        recipient: bob,
      );
      final removedJson = jsonDecode(removedWire) as Map;
      final bobEpochs = (removedJson['ke'] as List? ?? const [])
          .map((entry) => (entry as Map)['epoch'])
          .toList();
      expect(bobEpochs, isNot(contains(4)));
      expect(removedWire, isNot(contains('after bob removal')));
    },
  );

  test(
    'missing/wrong epoch envelope fails closed and clear v1 downgrade drops',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('No downgrade');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'cipher only', broadcast: false);
      final validWire =
          jsonDecode(
                ownerSvc.snapshotJson(
                  (await ownerSvc.load(gid))!,
                  recipient: bob,
                ),
              )
              as Map<String, dynamic>;

      Future<GroupService> receiver(NodeId reportedIssuer) async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        return GroupService(
          storage,
          _FakeSigner(bob),
          epochService: GroupEpochService(
            LoopbackMailboxCrypto(senderForOpen: reportedIssuer),
          ),
        );
      }

      final withoutEnvelope = Map<String, dynamic>.from(validWire)
        ..remove('ke');
      final missing = await receiver(owner);
      expect(await missing.ingestSnapshot(jsonEncode(withoutEnvelope)), isTrue);
      expect(await missing.messagesOf(gid), isEmpty);
      expect(await missing.postMessage(gid, 'must not fall back'), isFalse);

      final wrongIssuer = await receiver(stranger);
      expect(await wrongIssuer.ingestSnapshot(jsonEncode(validWire)), isTrue);
      expect(await wrongIssuer.messagesOf(gid), isEmpty);
      expect(await wrongIssuer.postMessage(gid, 'must stay closed'), isFalse);

      final downgrade = _FakeSigner(bob).signMessage(
        GroupMessage(
          groupId: gid,
          author: bob,
          seq: 0,
          prevHash: '',
          body: 'clear downgrade',
          policyVersion: 0,
          createdAtMs: 9000,
          signature: Uint8List(0),
        ),
      );
      final injected = Map<String, dynamic>.from(validWire)
        ..['g'] = [downgrade.toJson()];
      final before = (await ownerSvc.load(gid))!.messages.length;
      expect(await ownerSvc.ingestSnapshot(jsonEncode(injected)), isTrue);
      expect((await ownerSvc.load(gid))!.messages.length, before);
    },
  );

  test(
    'owner boot migration upgrades a legacy group without re-sending clear history',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final legacy = GroupService(storage, _FakeSigner(owner));
      final gid = await legacy.createGroup('Legacy');
      await legacy.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await legacy.postMessage(gid, 'legacy local history', broadcast: false);
      expect((await legacy.stateOf(gid))!.epochDescriptor, isNull);

      final upgraded = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      await upgraded.nudgeGroupSyncAll();
      final state = (await upgraded.stateOf(gid))!;
      expect(state.epochDescriptor, isNotNull);
      expect(state.epoch, 1);
      await upgraded.postMessage(gid, 'encrypted future', broadcast: false);
      final bundle = (await upgraded.load(gid))!;
      expect(bundle.messages.first.isEncrypted, isFalse);
      expect(bundle.messages.last.isEncrypted, isTrue);
      final bobWire = upgraded.snapshotJson(bundle, recipient: bob);
      expect(bobWire, isNot(contains('legacy local history')));
      expect(bobWire, isNot(contains('encrypted future')));
      expect((jsonDecode(bobWire) as Map)['ke'], isNotNull);
    },
  );

  test(
    'member leave clears the key and owner automatically establishes a fresh epoch',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('Leave rekey');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      String? leaveDelta;
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        send: (peer, group, json) async {
          if (peer == owner && group == gid) leaveDelta = json;
        },
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson((await ownerSvc.load(gid))!, recipient: bob),
        ),
        isTrue,
      );
      expect(await bobSvc.leaveGroup(gid), isTrue);
      expect(leaveDelta, isNotNull);
      expect(await ownerSvc.ingestSnapshot(leaveDelta!), isTrue);
      GroupState? state;
      for (var attempt = 0; attempt < 20; attempt++) {
        state = await ownerSvc.stateOf(gid);
        if (state?.epochDescriptor != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(state?.isMember(bob), isFalse);
      expect(state?.epoch, 4);
      expect(state?.epochDescriptor?.recipientCount, 1);
      expect(
        await ownerSvc.postMessage(gid, 'after leave', broadcast: false),
        isTrue,
      );
      expect((await ownerSvc.load(gid))!.messages.single.isEncrypted, isTrue);
    },
  );

  test('owner adds a member; a plain member cannot add', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    expect(
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);

    expect(
      await member(bob).addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      ),
      isFalse,
    );
    expect((await svc.stateOf(gid))!.isMember(carol), isFalse);
  });

  test('post + read: a member posts, a stranger cannot', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );

    expect(await svc.postMessage(gid, 'hi from owner'), isTrue);
    expect(await member(bob).postMessage(gid, 'hi from bob'), isTrue);
    expect(await member(stranger).postMessage(gid, 'spam'), isFalse);

    final msgs = await svc.messagesOf(gid);
    expect(
      msgs.map((m) => m.body),
      containsAll(['hi from owner', 'hi from bob']),
    );
    expect(msgs.length, 2, reason: 'stranger message was never stored');
  });

  test('a muted member cannot post; unmute restores', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await svc.addControlOp(gid, ControlOp.mute, target: bob);

    expect(await member(bob).postMessage(gid, 'muted'), isFalse);
    await svc.addControlOp(gid, ControlOp.unmute, target: bob);
    expect(await member(bob).postMessage(gid, 'back'), isTrue);
    expect((await svc.messagesOf(gid)).single.body, 'back');
  });

  test('snapshot -> ingest materializes the group on a fresh device', () async {
    // Owner's device.
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final owned = GroupService(s1, _FakeSigner(owner));
    final gid = await owned.createGroup('Shared');
    await owned.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await owned.postMessage(gid, 'welcome');
    final snap = owned.snapshotJson((await owned.load(gid))!);

    // Bob's fresh device: never saw the group before.
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobDev = GroupService(s2, _FakeSigner(bob));
    expect(await bobDev.stateOf(gid), isNull);
    expect(await bobDev.ingestSnapshot(snap), isTrue);

    final st = (await bobDev.stateOf(gid))!;
    expect(st.roleOf(owner), GroupRole.owner);
    expect(st.isMember(bob), isTrue);
    expect((await bobDev.listGroups()).single.name, 'Shared');
    expect((await bobDev.messagesOf(gid)).single.body, 'welcome');
    // Re-ingest is idempotent (no dupes).
    await bobDev.ingestSnapshot(snap);
    final b = await bobDev.load(gid);
    expect(
      b!.control.where((entry) => entry.op == ControlOp.addMember).length,
      1,
    );
    expect(b.messages.length, 1);
  });

  test('new control entries are group-bound while legacy canonical bytes stay '
      'compatible', () {
    ControlEntry entry({NodeId? gid}) => ControlEntry(
      groupId: gid,
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(0),
    );

    final legacy = String.fromCharCodes(entry().canonicalBytes());
    final bound = String.fromCharCodes(entry(gid: _id(8)).canonicalBytes());
    expect(legacy.contains('"gid"'), isFalse);
    expect(bound.contains('"gid":"${_id(8).hex}"'), isTrue);
    expect(ControlEntry.fromJson(entry(gid: _id(8)).toJson())!.groupId, _id(8));
  });

  test(
    'ingest rejects cross-group replay and invalid-signature seq poisoning',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      final groupA = await svc.createGroup('A');
      final groupB = await svc.createGroup('B');
      await svc.addControlOp(
        groupA,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      final aBundle = (await svc.load(groupA))!;
      final bBundle = (await svc.load(groupB))!;

      final replay = jsonEncode({
        'm': bBundle.manifest.toJson(),
        'c': [
          aBundle.control
              .singleWhere((entry) => entry.op == ControlOp.addMember)
              .toJson(),
        ],
        'g': const [],
        'r': const [],
      });
      expect(await svc.ingestSnapshot(replay), isTrue);
      expect((await svc.stateOf(groupB))!.isMember(bob), isFalse);
      expect(
        (await svc.load(
          groupB,
        ))!.control.where((entry) => entry.op == ControlOp.addMember),
        isEmpty,
      );

      GroupMessage message(Uint8List signature, String body) => GroupMessage(
        groupId: groupB,
        author: owner,
        seq: 0,
        prevHash: '',
        body: body,
        policyVersion: 0,
        createdAtMs: 2,
        signature: signature,
        authorPubKey: owner.bytes,
      );
      String snap(GroupMessage m) => jsonEncode({
        'm': bBundle.manifest.toJson(),
        'c': const [],
        'g': [m.toJson()],
        'r': const [],
      });

      await svc.ingestSnapshot(snap(message(Uint8List(0), 'poison')));
      expect((await svc.load(groupB))!.messages, isEmpty);
      await svc.ingestSnapshot(snap(message(Uint8List(64), 'valid')));
      expect((await svc.messagesOf(groupB)).single.body, 'valid');
    },
  );

  test(
    'cross-group messages/reactions and non-member reactions are ignored',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      final gid = await svc.createGroup('target');
      final other = _id(9);
      final bundle = (await svc.load(gid))!;
      final wrongMessage = GroupMessage(
        groupId: other,
        author: owner,
        seq: 0,
        prevHash: '',
        body: 'wrong-group',
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(64),
        authorPubKey: owner.bytes,
      );
      GroupReaction reaction(NodeId group, NodeId author, int seq) =>
          GroupReaction(
            groupId: group,
            author: author,
            seq: seq,
            target: '${owner.hex}:0',
            emoji: '🔥',
            createdAtMs: 2,
            signature: Uint8List(64),
            authorPubKey: author.bytes,
          );
      final payload = jsonEncode({
        'm': bundle.manifest.toJson(),
        'c': const [],
        'g': [wrongMessage.toJson()],
        'r': [
          reaction(other, owner, 0).toJson(),
          reaction(gid, stranger, 0).toJson(),
        ],
      });
      expect(await svc.ingestSnapshot(payload), isTrue);
      final stored = (await svc.load(gid))!;
      expect(stored.messages, isEmpty);
      expect(stored.reactions, isEmpty);
      expect(await svc.reactionsOf(gid), isEmpty);
    },
  );

  test('broadcast ships the snapshot to every other member', () async {
    final sent = <(NodeId, NodeId)>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(
      storage,
      _FakeSigner(owner),
      send: (peer, gid, json) async => sent.add((peer, gid)),
    );
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: carol,
      role: GroupRole.member,
    );
    final n = await svc.broadcast(gid);
    expect(n, 2, reason: 'both members, not self');
    expect(sent.map((e) => e.$1).toSet(), {bob, carol});
    expect(sent.every((e) => e.$2 == gid), isTrue);
  });

  test('XOR neighbour selection is deterministic, unique, and capped at k', () {
    final self = _id(1);
    final peers = [_id(7), _id(2), self, _id(5), _id(3), _id(0), _id(3)];

    expect(
      nearestGroupNodesByXor(self, peers, k: 3),
      [_id(0), _id(3), _id(2)],
      reason: 'distance is numeric XOR, not membership/insertion order',
    );
    expect(nearestGroupNodesByXor(self, peers.reversed, k: 3), [
      _id(0),
      _id(3),
      _id(2),
    ]);
    expect(nearestGroupNodesByXor(self, peers, k: 0), isEmpty);
  });

  test(
    'chat deltas use five XOR neighbours and relay once transitively',
    () async {
      final sent = <(NodeId, String)>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add((peer, json)),
      );
      final gid = await svc.createGroup('overlay');
      final members = [_id(0), _id(2), _id(3), _id(4), _id(5), _id(7)];
      for (final member in members) {
        await svc.addControlOp(
          gid,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        );
      }
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      sent.clear();

      await svc.postMessage(gid, 'sparse');
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(sent.map((entry) => entry.$1).toSet(), {
        _id(0),
        _id(3),
        _id(2),
        _id(5),
        _id(4),
      });
      expect(sent, hasLength(GroupService.kGroupSyncNeighbors));
      final delta = sent.first.$2;
      final wire = jsonDecode(delta) as Map;
      expect(
        wire['ov'],
        isA<String>(),
        reason: 'the stable overlay id breaks relay cycles',
      );

      final relayStorage = FakeHvContainer().storage();
      await relayStorage.open(password: 'pw', createIfMissing: true);
      final relayed = <NodeId>[];
      final relay = GroupService(
        relayStorage,
        _FakeSigner(_id(3)),
        send: (peer, gid, json) async => relayed.add(peer),
      );
      final ownerBundle = (await svc.load(gid))!;
      // Materialize membership without the new message, then deliver its delta
      // through real ingress so the sparse overlay forwards it.
      final beforeMessage = ownerBundle.copyWith(messages: const []);
      expect(
        await relay.ingestSnapshot(
          svc.snapshotJson(beforeMessage, recipient: _id(3)),
        ),
        isTrue,
      );
      expect(await relay.ingestGroupEntry(owner, delta), isTrue);
      expect(relayed, isNotEmpty);
      final once = relayed.length;
      expect(await relay.ingestGroupEntry(owner, delta), isTrue);
      expect(relayed, hasLength(once), reason: 'a duplicate is not relayed');
    },
  );

  test(
    'boot gap-fill contacts the same deterministic XOR neighbours',
    () async {
      final sent = <(NodeId, String)>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add((peer, json)),
      );
      final gid = await svc.createGroup('boot-overlay');
      for (final member in [_id(0), _id(2), _id(3), _id(4), _id(5), _id(7)]) {
        await svc.addControlOp(
          gid,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        );
      }
      await svc.setGroupSyncNeighborCount(gid, 2);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      sent.clear();

      await svc.nudgeGroupSyncAll();

      expect(sent.map((entry) => entry.$1).toSet(), {_id(0), _id(3)});
      expect(sent, hasLength(2));
      expect(
        sent.every((entry) => (jsonDecode(entry.$2) as Map)['sreq'] == 1),
        isTrue,
      );
    },
  );

  test('per-chat XOR neighbour count persists and defaults to five', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    final gid = await svc.createGroup('configurable-overlay');

    expect(await svc.groupSyncNeighborCount(gid), 5);
    await svc.setGroupSyncNeighborCount(gid, 8);
    expect(await svc.groupSyncNeighborCount(gid), 8);
    expect(
      await GroupService(
        storage,
        _FakeSigner(owner),
      ).groupSyncNeighborCount(gid),
      8,
    );
    expect(svc.setGroupSyncNeighborCount(gid, 0), throwsA(isA<RangeError>()));
    expect(svc.setGroupSyncNeighborCount(gid, 21), throwsA(isA<RangeError>()));
  });

  test(
    'inline image attachment persists + survives snapshot round-trip',
    () async {
      // A realistic-size payload (~40 KB) so the bundle overflows the single
      // ~4 KB setting cap and is chunked across the file-store — the exact case
      // that threw PayloadTooLarge when the bundle lived in one setting.
      final big = 'Q' * 40000;
      final att = GroupAttachment(kind: 'image', dataB64: big, w: 40, h: 30);
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final owned = GroupService(s1, _FakeSigner(owner));
      final gid = await owned.createGroup('Pics');
      await owned.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      expect(await owned.postMessage(gid, 'look', attachment: att), isTrue);

      final mine = (await owned.messagesOf(gid)).single;
      expect(mine.body, 'look');
      expect(mine.attachment, isNotNull);
      expect(mine.attachment!.w, 40);
      expect(mine.attachment!.h, 30);
      expect(mine.attachment!.dataB64, big);

      // Fresh member device materializes the group AND the image via snapshot.
      final snap = owned.snapshotJson((await owned.load(gid))!);
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobDev = GroupService(s2, _FakeSigner(bob));
      expect(await bobDev.ingestSnapshot(snap), isTrue);
      final got = (await bobDev.messagesOf(gid)).single;
      expect(got.attachment?.dataB64, big);
      expect(got.attachment?.w, 40);
    },
  );

  test('attachment is signed: canonicalBytes differ, text-only unchanged', () {
    GroupMessage base({GroupAttachment? att}) => GroupMessage(
      groupId: _id(2),
      author: owner,
      seq: 0,
      prevHash: '',
      body: 'hi',
      policyVersion: 0,
      createdAtMs: 5,
      signature: Uint8List(0),
      attachment: att,
    );
    final textOnly = base().canonicalBytes();
    final withImg = base(
      att: const GroupAttachment(kind: 'image', dataB64: 'QQ', w: 1, h: 1),
    ).canonicalBytes();
    // The attachment is inside the signed bytes (tamper-evident)...
    expect(withImg, isNot(equals(textOnly)));
    // ...and a text-only message signs byte-identically to before the field
    // existed (the 'att' key is omitted, not null).
    expect(String.fromCharCodes(textOnly).contains('att'), isFalse);
    // JSON round-trip preserves the attachment.
    final rt = GroupMessage.fromJson(
      base(
        att: const GroupAttachment(
          kind: 'image',
          dataB64: 'QQ',
          w: 2,
          h: 3,
          name: 'photo.png',
        ),
      ).toJson(),
    )!;
    expect(rt.attachment?.w, 2);
    expect(rt.attachment?.h, 3);
    expect(rt.attachment?.dataB64, 'QQ');
    expect(rt.attachment?.name, 'photo.png');
  });

  test(
    'voice attachment: durationMs rides in w, round-trips, signs stably',
    () {
      GroupMessage voiceMsg() => GroupMessage(
        groupId: _id(2),
        author: owner,
        seq: 0,
        prevHash: '',
        body: '',
        policyVersion: 0,
        createdAtMs: 5,
        signature: Uint8List(0),
        attachment: const GroupAttachment(
          kind: 'voice',
          dataB64: 'Vk9QMQ',
          w: 4200,
          h: 1,
        ),
      );
      final rt = GroupMessage.fromJson(voiceMsg().toJson())!;
      expect(rt.attachment?.kind, 'voice');
      expect(rt.attachment?.w, 4200, reason: 'durationMs travels in w');
      expect(rt.attachment?.h, 1);
      // The parsed message re-canonicalizes byte-identically — a signature a
      // voice-aware build minted verifies on any build (zero schema change).
      expect(rt.canonicalBytes(), voiceMsg().canonicalBytes());
    },
  );

  test(
    'content path: member request → grant; stranger/replay/unknown → drop',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final grants = <(NodeId, String)>[];
      final sentReq = <String>[];
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        grantContentServe: (peer, cid) => grants.add((peer, cid)),
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await svc.postMessage(
        gid,
        '',
        attachment: const GroupAttachment(
          kind: 'image',
          dataB64: 'QQ',
          w: 1,
          h: 1,
          cid: 'c0ffee',
        ),
      );
      expect(await svc.referencedContentIds(gid), {'c0ffee'});

      // Bob (member, own service+store) mints a signed request…
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentReq.add(json),
      );
      expect(await bobSvc.requestGroupContent(gid, 'c0ffee', owner), isTrue);
      // …and the holder authorizes: a grant for exactly (bob, cid).
      expect(await svc.handleContentRequest(sentReq.last), isTrue);
      expect(grants.single.$1, bob);
      expect(grants.single.$2, 'c0ffee');

      // A replay of the same request is refused (nonce cache).
      expect(await svc.handleContentRequest(sentReq.last), isFalse);

      // A stranger's request never grants.
      final evieSvc = GroupService(
        bobStorage,
        _FakeSigner(_id(7)),
        sendContentRequest: (holder, json) async => sentReq.add(json),
      );
      expect(await evieSvc.requestGroupContent(gid, 'c0ffee', owner), isTrue);
      expect(await svc.handleContentRequest(sentReq.last), isFalse);

      // A cid the group never referenced never grants either.
      expect(await bobSvc.requestGroupContent(gid, 'beef', owner), isTrue);
      expect(await svc.handleContentRequest(sentReq.last), isFalse);
      expect(grants, hasLength(1));
    },
  );

  test(
    'fetchGroupContent authorizes every current member and pulls from any',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sentTo = <NodeId>[];
      final pulls = <(List<NodeId>, String)>[];
      final svc = GroupService(
        storage,
        _FakeSigner(bob),
        sendContentRequest: (holder, json) async {
          sentTo.add(holder);
          if (holder == carol) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        startContentPullFromAny: (holders, cid) async =>
            pulls.add((holders, cid)),
        contentRequestFanoutTimeout: const Duration(milliseconds: 5),
        contentGrantDelay: Duration.zero,
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: owner,
        role: GroupRole.member,
      );
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      );
      await svc.postMessage(
        gid,
        '',
        attachment: const GroupAttachment(
          kind: 'file',
          dataB64: 'QQ==',
          w: 10,
          h: 1,
          cid: 'c0ffee',
        ),
      );

      expect(await svc.fetchGroupContent(gid, 'c0ffee', owner), isTrue);
      expect(sentTo.toSet(), {owner, carol});
      expect(pulls.single.$1, [owner, carol], reason: 'author stays preferred');
      expect(pulls.single.$2, 'c0ffee');
      expect(
        await svc.fetchGroupContent(gid, 'not-referenced', owner),
        isFalse,
        reason: 'membership must not become an arbitrary cid probe',
      );
      expect(sentTo, hasLength(2));

      // Without a pull sink the flow reports not-started (nothing to drive).
      final noPull = GroupService(
        storage,
        _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentTo.add(holder),
        contentGrantDelay: Duration.zero,
      );
      expect(await noPull.fetchGroupContent(gid, 'c0ffee', owner), isFalse);
    },
  );

  test(
    'stranger sync: member delta merges into a held group; others drop',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final sent = <String>[];
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        s1,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      final gid = await ownerSvc.createGroup('G');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await drain();
      final full =
          sent.last; // the join snapshot bob's device materializes from

      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        s2,
        _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j),
      );
      expect(await bobSvc.ingestSnapshot(full), isTrue);
      sent.clear();
      await bobSvc.postMessage(gid, 'from-bob');
      await drain();
      final delta = sent.last;

      // Bob needs NO contact relationship: he is a member per the owner's fold.
      expect(await ownerSvc.allowStrangerGroupSync(bob, gid.hex), isTrue);
      expect(await ownerSvc.ingestSnapshotFromStranger(bob, delta), isTrue);
      expect(
        (await ownerSvc.messagesOf(gid)).map((m) => m.body),
        contains('from-bob'),
      );

      // A non-member stranger is refused even with a well-formed bundle…
      expect(await ownerSvc.ingestSnapshotFromStranger(_id(7), delta), isFalse);
      // …and a group we don't hold NEVER materializes from a stranger.
      expect(await ownerSvc.allowStrangerGroupSync(bob, 'ff' * 32), isFalse);
      expect(
        await ownerSvc.ingestSnapshotFromStranger(
          bob,
          '{"m":{"gid":"${'ff' * 32}"}}',
        ),
        isFalse,
      );
    },
  );

  test(
    'unread + incoming: ingest feeds the stream, watermark clears the count',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final sent = <String>[];
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        s1,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      final gid = await ownerSvc.createGroup('G');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await drain();
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        s2,
        _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j),
      );
      await bobSvc.ingestSnapshot(sent.last);
      sent.clear();
      await bobSvc.postMessage(gid, 'ping-1');
      await bobSvc.postMessage(gid, 'ping-2');
      await drain();

      // Owner ingests bob's deltas: the incoming stream fires per NEW message…
      final got = <String>[];
      final sub = ownerSvc.incoming.listen((n) => got.add(n.message.body));
      for (final delta in sent) {
        await ownerSvc.ingestSnapshot(delta);
      }
      await drain();
      expect(got, ['ping-1', 'ping-2']);
      // …a re-ingest is silent (dedup)…
      await ownerSvc.ingestSnapshot(sent.last);
      await drain();
      expect(got, hasLength(2));
      // …and our OWN messages never feed the stream.
      await ownerSvc.postMessage(gid, 'mine');
      await drain();
      expect(got, hasLength(2));
      await sub.cancel();

      // Unread counts bob's two messages, ignores ours, and clears on seen.
      expect(await ownerSvc.unreadOf(gid), 2);
      final listed = await ownerSvc.listGroups();
      expect(listed.single.unread, 2);
      // The list carries the last-message preview + its timestamp too.
      expect(listed.single.preview, 'mine');
      expect(listed.single.lastTs, greaterThan(0));
      await ownerSvc.markGroupSeen(gid);
      expect(await ownerSvc.unreadOf(gid), 0);

      // The local notification mute persists and rides the list record.
      expect(listed.single.muted, isFalse);
      await ownerSvc.setGroupMuted(gid, true);
      expect(await ownerSvc.isGroupMuted(gid), isTrue);
      expect((await ownerSvc.listGroups()).single.muted, isTrue);
      await ownerSvc.setGroupMuted(gid, false);
      expect(await ownerSvc.isGroupMuted(gid), isFalse);
    },
  );

  test(
    'mirror loop: msgMirror events fold + apply, deduped, deniability-safe',
    () async {
      // Pure fold/codec check of the mirror event vocabulary against the store's
      // dedup contract — the wiring (onMessageStored → postDeviceEvent →
      // deviceIncoming → applyMirroredMessage) is exercised on-device; here we
      // pin the fold that carries it.
      final a = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm1',
        tsMs: 10,
        payload: const {'peer': 'aa', 'dir': 'incoming', 'body': 'hi'},
      );
      final dup = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm1',
        tsMs: 10,
        payload: const {'peer': 'aa', 'dir': 'incoming', 'body': 'hi'},
      );
      final b = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm2',
        tsMs: 20,
        payload: const {'peer': 'aa', 'dir': 'outgoing', 'body': 'yo'},
      );
      final folded = foldDeviceSync([a, dup, b]);
      // One entry per msgId (the mirror key IS the message id → idempotent apply).
      expect(folded.length, 2);
      expect(folded[(DeviceSyncKind.msgMirror, 'm1')]!.payload['body'], 'hi');
      expect(
        folded[(DeviceSyncKind.msgMirror, 'm2')]!.payload['dir'],
        'outgoing',
      );
      // Body codec preserves the mirror payload across the wire.
      expect(DeviceSyncEvent.fromBody(a.toBody())!.payload, a.payload);
    },
  );

  test('device group: link/adopt/revoke lifecycle, hidden + silent', () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final sent = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final primary = GroupService(
      s1,
      _FakeSigner(owner),
      send: (p, g, j) async => sent.add(j),
    );

    // First link creates the device group; the second reuses it (a different
    // device — bob is _id(3), so link _id(4) as the second phone).
    expect(await primary.deviceGroupIdHex(), isNull);
    expect(await primary.linkDevice(bob, sovereign: sovereign), isTrue);
    final gidHex = (await primary.deviceGroupIdHex())!;
    expect(await primary.linkDevice(_id(4), sovereign: sovereign), isTrue);
    expect(await primary.deviceGroupIdHex(), gidHex);
    await drain();

    // Hidden from the user-facing group list despite being a real group…
    expect(
      (await primary.listGroups()).where((g) => g.groupId.hex == gidHex),
      isEmpty,
    );
    // …and linked devices are members; only the sovereign is owner.
    final st = (await primary.stateOf(NodeId.fromHex(gidHex)))!;
    expect(st.roleOf(bob), GroupRole.member);
    expect(st.roleOf(sovereign.nodeId), GroupRole.owner);

    // The NEW device adopts via the handshake id, then sees the same group.
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final secondary = GroupService(s2, _FakeSigner(bob));
    expect(await secondary.ingestSnapshot(sent.first), isTrue);
    expect(await secondary.adoptDeviceGroup(NodeId.fromHex(gidHex)), isTrue);
    expect(await secondary.deviceGroupIdHex(), gidHex);

    // Sync events round-trip through the device log and fold newest-wins…
    final chat = <String>[];
    final sub = primary.incoming.listen((n) => chat.add(n.message.body));
    expect(
      await secondary.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: 'theme',
          tsMs: 111,
          payload: const {'v': 'dark'},
        ),
      ),
      isTrue,
    );
    final deltas = <String>[];
    final secondary2 = GroupService(
      s2,
      _FakeSigner(bob),
      send: (p, g, j) async => deltas.add(j),
    );
    await secondary2.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'theme',
        tsMs: 222,
        payload: const {'v': 'light'},
      ),
    );
    await drain();
    for (final d in deltas) {
      await primary.ingestSnapshot(d);
    }
    await drain();
    final folded = await primary.deviceSyncState();
    expect(folded[(DeviceSyncKind.settingSet, 'theme')]!.payload['v'], 'light');
    // …and device-group traffic NEVER feeds the chat notification stream.
    expect(chat, isEmpty);
    await sub.cancel();

    // Revoke removes the device and rotates the epoch.
    final epochBefore = (await primary.stateOf(NodeId.fromHex(gidHex)))!.epoch;
    expect(await primary.revokeDevice(bob, sovereign: sovereign), isTrue);
    final after = (await primary.stateOf(NodeId.fromHex(gidHex)))!;
    expect(after.isMember(bob), isFalse);
    expect(after.epoch, greaterThan(epochBefore));
  });

  test(
    'sovereign genesis tampering is rejected before materialization',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(
        storage,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      expect(await primary.linkDevice(bob, sovereign: sovereign), isTrue);

      final wire = jsonDecode(sent.first) as Map<String, dynamic>;
      final manifest = wire['m'] as Map<String, dynamic>;
      expect(manifest['v'], GroupManifest.sovereignDeviceVersion);
      expect(manifest['kind'], GroupManifest.sovereignDeviceKind);
      expect(manifest['alg'], 'ed25519');
      expect(manifest['msig'], isNotEmpty);
      manifest['name'] = ' xveil.devices.tampered';

      final freshStorage = FakeHvContainer().storage();
      await freshStorage.open(password: 'pw', createIfMissing: true);
      final fresh = GroupService(freshStorage, _FakeSigner(bob));
      expect(await fresh.ingestSnapshot(jsonEncode(wire)), isFalse);
      expect(await fresh.listGroups(), isEmpty);
    },
  );

  test(
    'hybrid bundle hash gates snapshot and adopt persists encrypted copy',
    () async {
      final phrase = veil.generateMasterPhrase();
      final encrypted = veil.createHybrid512SovereignBundle(phrase);
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      await sourceStorage.putSetting(
        GroupService.kSovereignBundleSetting,
        base64Encode(encrypted),
      );
      final source = GroupService(
        sourceStorage,
        _NativeSovereignVerifier(owner),
      );
      final signer = NativeSovereignGroupSigner.openBundle(encrypted, phrase);
      expect(await source.linkDevice(bob, sovereign: signer), isTrue);
      signer.close();

      final gid = NodeId.fromHex((await source.deviceGroupIdHex())!);
      final local = (await source.load(gid))!;
      expect(local.manifest.signatureAlgorithm, 'ed25519+falcon512');
      expect(local.manifest.sovereignBundleHash, hasLength(32));
      expect(local.sovereignBundle, encrypted);
      final snapshot = source.snapshotJson(local);

      final tampered = jsonDecode(snapshot) as Map<String, dynamic>;
      final wireBundle = base64Decode(tampered['s'] as String)..last ^= 1;
      tampered['s'] = base64Encode(wireBundle);
      final targetStorage = FakeHvContainer().storage();
      await targetStorage.open(password: 'pw', createIfMissing: true);
      final target = GroupService(targetStorage, _NativeSovereignVerifier(bob));
      expect(await target.ingestSnapshot(jsonEncode(tampered)), isFalse);
      expect(await target.ingestSnapshot(snapshot), isTrue);
      expect(
        await target.localSovereignBundle(),
        isNull,
        reason: 'a planted snapshot stays inert before explicit adopt',
      );
      expect(await target.adoptDeviceGroup(gid), isTrue);
      expect(await target.localSovereignBundle(), encrypted);

      await expectLater(
        target.openLocalSovereign(veil.generateMasterPhrase()),
        throwsA(anything),
      );
      final reopened = await target.openLocalSovereign(phrase);
      expect(reopened.algorithm, 'ed25519+falcon512');
      expect(reopened.nodeId, local.manifest.owner);
      reopened.close();

      final corruptStorage = FakeHvContainer().storage();
      await corruptStorage.open(password: 'pw', createIfMissing: true);
      await corruptStorage.putSetting(
        GroupService.kSovereignBundleSetting,
        'not-base64%%%',
      );
      final corrupt = GroupService(
        corruptStorage,
        _NativeSovereignVerifier(owner),
      );
      await expectLater(corrupt.openLocalSovereign(phrase), throwsStateError);
      expect(
        await corruptStorage.getSetting(GroupService.kSovereignBundleSetting),
        'not-base64%%%',
        reason: 'corruption must fail closed, never rotate sovereign identity',
      );
    },
    skip: hasVeilFfi ? false : 'set VEIL_FFI_DYLIB to test hybrid XVSB',
  );

  test(
    'XVRC disaster recovery preserves sovereign node id and mints fresh gid',
    () async {
      final phrase = veil.generateMasterPhrase();
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      final source = GroupService(
        sourceStorage,
        _NativeSovereignVerifier(owner),
      );

      final exported = await source.exportRecoveryCertificate(phrase);
      expect(
        exported,
        isNotNull,
        reason: 'pre-issuing a certificate provisions XVSB before first link',
      );
      expect(await source.sovereignCredentialKind(), 'phrase');
      expect(
        await source.deviceGroupIdHex(),
        isNull,
        reason: 'pre-issuing a certificate does not create device membership',
      );
      expect(ascii.decode(exported!.certificate.sublist(0, 4)), 'XVRC');

      final recoveredStorage = FakeHvContainer().storage();
      await recoveredStorage.open(password: 'pw', createIfMissing: true);
      final recovered = GroupService(
        recoveredStorage,
        _NativeSovereignVerifier(bob),
      );
      final gid = await recovered.recoverDeviceGroupFromCertificate(
        exported.certificate,
        exported.code,
      );
      expect(gid, isNotNull);
      final bundle = (await recovered.load(gid!))!;
      expect(bundle.manifest.owner, exported.nodeId);
      expect(bundle.manifest.sovereignBundleHash, hasLength(32));
      expect(bundle.sovereignBundle, exported.certificate);
      expect((await recovered.stateOf(gid))!.isMember(bob), isTrue);
      expect(await recovered.sovereignCredentialKind(), 'certificate');

      final reopened = await recovered.openLocalSovereign(exported.code);
      expect(reopened.nodeId, exported.nodeId);
      reopened.close();
      await expectLater(
        recovered.openLocalSovereign(veil.generateSovereignRecoveryCode()),
        throwsA(anything),
      );

      final rotated = await recovered.exportRecoveryCertificate(exported.code);
      expect(rotated, isNotNull);
      expect(rotated!.nodeId, exported.nodeId);
      final rotatedSigner = NativeSovereignGroupSigner.openRecoveryCertificate(
        rotated.certificate,
        rotated.code,
      );
      expect(rotatedSigner.nodeId, exported.nodeId);
      rotatedSigner.close();

      final wrongStorage = FakeHvContainer().storage();
      await wrongStorage.open(password: 'pw', createIfMissing: true);
      final wrong = GroupService(wrongStorage, _NativeSovereignVerifier(bob));
      await expectLater(
        wrong.recoverDeviceGroupFromCertificate(
          exported.certificate,
          veil.generateSovereignRecoveryCode(),
        ),
        throwsA(anything),
      );
      expect(
        await wrong.localSovereignBundle(),
        isNull,
        reason: 'wrong code must fail before persisting any credential',
      );
      expect(await wrong.deviceGroupIdHex(), isNull);

      final rejectedStorage = FakeHvContainer().storage();
      await rejectedStorage.open(password: 'pw', createIfMissing: true);
      final rejected = GroupService(rejectedStorage, _FakeSigner(bob));
      expect(
        await rejected.recoverDeviceGroupFromCertificate(
          exported.certificate,
          exported.code,
        ),
        isNull,
      );
      expect(
        await rejected.localSovereignBundle(),
        isNull,
        reason: 'failed manifest verification rolls back the staged XVRC',
      );
    },
    skip: hasVeilFfi ? false : 'set VEIL_FFI_DYLIB to test XVRC recovery',
  );

  test(
    'guided adoption admits one pinned stranger snapshot then auto-adopts',
    () async {
      final sourceInvite = BootstrapInvite(
        publicKey: Uint8List.fromList(List.filled(32, 21)),
        nonce: Uint8List.fromList([1, 2, 3, 4]),
      );
      final targetInvite = BootstrapInvite(
        publicKey: Uint8List.fromList(List.filled(32, 22)),
        nonce: Uint8List.fromList([4, 3, 2, 1]),
      );
      final sent = <({NodeId peer, String json})>[];
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      final source = GroupService(
        sourceStorage,
        _FakeSigner(sourceInvite.nodeId),
        send: (peer, _, json) async => sent.add((peer: peer, json: json)),
      );
      final sourceSovereign = _FakeSovereign(_id(9));
      expect(
        await source.linkDevice(
          targetInvite.nodeId,
          sovereign: sourceSovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      expect(
        sent,
        isEmpty,
        reason: 'target has not explicitly admitted it yet',
      );
      final token = await source.createDeviceLinkToken(sourceInvite);
      expect(token, isNotNull);
      final gid = token!.groupId;
      final bundle = (await source.load(gid))!;
      final snapshot = source.snapshotJson(bundle);

      final targetStorage = FakeHvContainer().storage();
      await targetStorage.open(password: 'pw', createIfMissing: true);
      final target = GroupService(
        targetStorage,
        _FakeSigner(targetInvite.nodeId),
      );
      expect(
        await target.ingestSnapshotFromStranger(sourceInvite.nodeId, snapshot),
        isFalse,
        reason: 'a new marker group is inert without scanned consent',
      );
      expect(
        await target.prepareDeviceAdoption(
          DeviceLinkToken(
            groupId: token.groupId,
            source: token.source,
            manifestHash: Uint8List(32),
            sourceInvite: token.sourceInvite,
            expiresAtMs: token.expiresAtMs,
          ),
        ),
        isTrue,
      );
      expect(
        await target.ingestGroupEntry(sourceInvite.nodeId, snapshot),
        isFalse,
        reason: 'the QR pins the exact sovereign-signed manifest',
      );
      expect(await target.prepareDeviceAdoption(token), isTrue);
      expect(
        await target.ingestSnapshotFromStranger(_id(77), snapshot),
        isFalse,
        reason: 'the token pins the source device',
      );

      expect(await source.broadcastDeviceGroup(), 1);
      expect(sent.single.peer, targetInvite.nodeId);
      expect(
        await target.ingestGroupEntry(sourceInvite.nodeId, sent.single.json),
        isTrue,
      );
      expect(await target.deviceGroupIdHex(), gid.hex);
      expect(await target.pendingDeviceAdoption(), isNull);
      expect(
        (await target.stateOf(gid))!.isMember(targetInvite.nodeId),
        isTrue,
      );
    },
  );

  test(
    'device keys and a wrong sovereign cannot mutate the registry',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(storage, _FakeSigner(owner));
      expect(await primary.linkDevice(bob, sovereign: sovereign), isTrue);
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);
      final wrong = _FakeSovereign(_id(8));

      expect(await primary.linkDevice(carol, sovereign: wrong), isFalse);
      expect(await primary.revokeDevice(bob, sovereign: wrong), isFalse);
      expect(
        await primary.addControlOp(
          gid,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isFalse,
      );
      final beforeRows = (await primary.load(gid))!.control.length;
      final forged = ControlEntry(
        groupId: gid,
        author: owner,
        seq: 99,
        prevHash: '',
        op: ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 9999,
        signature: Uint8List(0),
      );
      await primary.ingestControl(gid, _FakeSigner(owner).signControl(forged));
      expect((await primary.load(gid))!.control, hasLength(beforeRows));
      final state = (await primary.stateOf(gid))!;
      expect(state.isMember(bob), isTrue);
      expect(state.isMember(carol), isFalse);
    },
  );

  test(
    'legacy device group remints gid and carries compact sync state',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final legacyGid = _id(43);
      final legacyManifest = GroupManifest(
        groupId: legacyGid,
        owner: owner,
        genesisPubKey: owner.bytes,
        name: 'Legacy devices',
        createdAtMs: 1000,
      );
      await storage.storeFile(
        'group:${legacyGid.hex}',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'm': legacyManifest.toJson(),
              'c': const <Object>[],
              'g': const <Object>[],
              'r': const <Object>[],
            }),
          ),
        ),
        name: 'group',
      );
      await storage.putSetting(
        'groups.index',
        jsonEncode(<String>[legacyGid.hex]),
      );
      final builder = GroupService(storage, _FakeSigner(owner));
      expect(
        await builder.addControlOp(
          legacyGid,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final raw = await storage.loadFile('group:${legacyGid.hex}');
      final legacyJson = jsonDecode(utf8.decode(raw!)) as Map<String, dynamic>;
      (legacyJson['m'] as Map<String, dynamic>)['name'] =
          GroupService.kDeviceGroupName;
      await storage.storeFile(
        'group:${legacyGid.hex}',
        Uint8List.fromList(utf8.encode(jsonEncode(legacyJson))),
        name: 'group',
      );
      await storage.putSetting('devices.gid', legacyGid.hex);
      final legacy = GroupService(storage, _FakeSigner(owner));
      expect(
        await legacy.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.settingSet,
            key: 'locale',
            tsMs: 4242,
            payload: const {'v': 'ru'},
          ),
        ),
        isTrue,
      );

      final migrating = GroupService(
        storage,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      expect(
        await migrating.addControlOp(
          legacyGid,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isFalse,
        reason: 'legacy registry is read-only',
      );
      expect(await migrating.linkDevice(carol, sovereign: sovereign), isTrue);
      final newGid = NodeId.fromHex((await migrating.deviceGroupIdHex())!);
      expect(newGid, isNot(legacyGid));

      final oldBundle = (await migrating.load(legacyGid))!;
      final newBundle = (await migrating.load(newGid))!;
      expect(oldBundle.manifest.version, 1);
      expect(oldBundle.control, hasLength(1));
      expect(newBundle.manifest.isSovereignDevice, isTrue);
      expect(newBundle.manifest.owner, sovereign.nodeId);
      expect(
        (await migrating.deviceSyncState())[(
              DeviceSyncKind.settingSet,
              'locale',
            )]!
            .payload['v'],
        'ru',
      );
      final state = (await migrating.stateOf(newGid))!;
      expect(state.isMember(owner), isTrue);
      expect(state.isMember(bob), isTrue);
      expect(state.isMember(carol), isTrue);
      expect(state.roleOf(bob), GroupRole.member);
      expect(sent, isNotEmpty);

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobDevice = GroupService(bobStorage, _FakeSigner(bob));
      final applied = <String>[];
      final sub = bobDevice.deviceIncoming.listen((m) => applied.add(m.body));
      expect(await bobDevice.ingestSnapshot(sent.first), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        applied,
        isEmpty,
        reason: 'snapshot is inert before explicit local adoption',
      );
      expect(await bobDevice.adoptDeviceGroup(newGid), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        applied
            .map(DeviceSyncEvent.fromBody)
            .whereType<DeviceSyncEvent>()
            .any((e) => e.key == 'locale'),
        isTrue,
      );
      await sub.cancel();
    },
  );

  test('postDeviceEvent: concurrent fire-and-forget emits ALL land '
      '(regression: two unawaited posts raced the group log read-modify-write '
      'and the later save dropped the earlier append — caught in the brick-4 '
      'device verify)', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    await svc.linkDevice(bob, sovereign: sovereign);

    // Fire a burst WITHOUT awaiting each — exactly what the sync taps do.
    final posts = [
      for (var i = 0; i < 5; i++)
        svc.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.contactUp,
            key: 'peer$i',
            tsMs: 1000 + i,
            payload: {'pin': i.isEven},
          ),
        ),
    ];
    expect(await Future.wait(posts), everyElement(isTrue));
    final folded = await svc.deviceSyncState();
    for (var i = 0; i < 5; i++) {
      expect(
        folded[(DeviceSyncKind.contactUp, 'peer$i')],
        isNotNull,
        reason: 'emit $i must survive the concurrent burst',
      );
    }
  });

  test('gap-fill (brick G1): a member behind by one LOST delta converges from '
      'the sync-vector exchange; the reply carries ONLY the missing entry and '
      'a non-member vector is dropped silently', () async {
    // Owner + member over separate stores, cross-wired sends.
    final sOwner = FakeHvContainer().storage();
    await sOwner.open(password: 'pw', createIfMissing: true);
    final sBob = FakeHvContainer().storage();
    await sBob.open(password: 'pw', createIfMissing: true);
    final toBob = <String>[], toOwner = <String>[];
    final ownerSvc = GroupService(
      sOwner,
      _FakeSigner(owner),
      send: (p, g, j) async => (p == bob ? toBob : toOwner).add(j),
    );
    final bobSvc = GroupService(
      sBob,
      _FakeSigner(bob),
      send: (p, g, j) async => toOwner.add(j),
    );

    final gid = await ownerSvc.createGroup('g1');
    await ownerSvc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Bob joins from the full snapshot.
    for (final j in toBob) {
      await bobSvc.ingestSnapshot(j);
    }
    expect((await bobSvc.messagesOf(gid)).length, 0);

    // A visible post AND a silently-lost one (the outage-class delta).
    await ownerSvc.postMessage(gid, 'delivered');
    await ownerSvc.postMessage(gid, 'lost-in-outage', broadcast: false);
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    toBob.removeRange(0, toBob.length - 1); // keep only the delivered delta
    for (final j in toBob) {
      await bobSvc.ingestSnapshot(j);
    }
    expect(
      (await bobSvc.messagesOf(gid)).length,
      1,
      reason: 'precondition: bob is missing the lost delta',
    );

    // Bob's boot vector reaches the owner → reply carries ONLY the gap.
    toBob.clear();
    final req = (await bobSvc.buildGroupSyncRequest(gid))!;
    expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req)), isTrue);
    expect(toBob, hasLength(1), reason: 'one targeted reply');
    final reply = jsonDecode(toBob.single) as Map;
    expect(
      (reply['g'] as List).length,
      1,
      reason: 'only the missing message ships, not the whole log',
    );
    expect(
      reply['ov'],
      isA<String>(),
      reason: 'a repaired content gap continues through the XOR overlay',
    );
    await bobSvc.ingestSnapshot(toBob.single);
    final bodies = (await bobSvc.messagesOf(gid)).map((m) => m.body).toList();
    expect(bodies, containsAll(['delivered', 'lost-in-outage']));

    // In-sync vector → nothing to send. Non-member vector → silent drop.
    toBob.clear();
    final req2 = (await bobSvc.buildGroupSyncRequest(gid))!;
    expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req2)), isFalse);
    expect(toBob, isEmpty);
    expect(
      await ownerSvc.ingestGroupEntry(_id(9), jsonEncode(req2)),
      isFalse,
      reason: 'no membership oracle — a stranger gets nothing',
    );
  });

  test(
    'new message rows chain to the exact predecessor inside each visible scope',
    () async {
      final (service, _) = await setup();
      final groupId = await service.createGroup('chained chat');
      expect(await service.postMessage(groupId, 'one'), isTrue);
      expect(await service.postMessage(groupId, 'two'), isTrue);
      final chatRows = (await service.load(groupId))!.messages;
      expect(chatRows, hasLength(2));
      expect(chatRows.first.prevHash, isEmpty);
      expect(chatRows.last.prevHash, groupMessageHash(chatRows.first));

      final spaceId = await service.createSpace('scoped chains');
      final defaultChannel = (await service.channelsOf(
        spaceId,
      )).single.channelId;
      final secondChannel = await service.createChannel(
        spaceId,
        name: 'second',
        kind: SpaceChannelKind.text,
      );
      expect(secondChannel, isNotNull);
      expect(
        await service.postMessage(
          spaceId,
          'default-0',
          channelId: defaultChannel,
        ),
        isTrue,
      );
      expect(
        await service.postMessage(
          spaceId,
          'second-0',
          channelId: secondChannel,
        ),
        isTrue,
      );
      expect(
        await service.postMessage(
          spaceId,
          'default-1',
          channelId: defaultChannel,
        ),
        isTrue,
      );
      final spaceRows = (await service.load(spaceId))!.messages;
      expect(spaceRows.map((message) => message.seq), [0, 1, 2]);
      expect(spaceRows[0].prevHash, isEmpty);
      expect(
        spaceRows[1].prevHash,
        isEmpty,
        reason: 'another channel is an independent visibility scope',
      );
      expect(spaceRows[2].prevHash, groupMessageHash(spaceRows[0]));

      final vector = (await service.buildGroupSyncRequest(spaceId))!;
      expect((vector['mg'] as Map), contains('${defaultChannel.hex}|clear'));
      expect((vector['mg'] as Map), contains('${secondChannel!.hex}|clear'));
    },
  );

  test(
    'out-of-order chained suffix stays hidden until gap-fill supplies predecessor',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final groupId = await ownerService.createGroup('ordered chain');
      expect(
        await ownerService.addControlOp(
          groupId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final base = (await ownerService.load(groupId))!;
      expect(
        await ownerService.postMessage(groupId, 'zero', broadcast: false),
        isTrue,
      );
      expect(
        await ownerService.postMessage(groupId, 'one', broadcast: false),
        isTrue,
      );
      final rows = (await ownerService.load(groupId))!.messages;
      expect(rows[1].prevHash, groupMessageHash(rows[0]));

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(base, recipient: bob),
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            base.copyWith(messages: [rows[1]]),
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(await bobService.messagesOf(groupId), isEmpty);
      expect((await bobService.load(groupId))!.messages, hasLength(1));

      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            base.copyWith(messages: [rows[0]]),
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobService.messagesOf(groupId)).map((message) => message.body),
        ['zero', 'one'],
      );
    },
  );

  test(
    'same-seq message fork quarantines the scoped suffix and converges by sync',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final groupId = await ownerService.createGroup('fork evidence');
      expect(
        await ownerService.addControlOp(
          groupId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      for (final body in ['zero', 'one', 'two']) {
        expect(
          await ownerService.postMessage(groupId, body, broadcast: false),
          isTrue,
        );
      }
      final cleanBundle = (await ownerService.load(groupId))!;
      final original = cleanBundle.messages[1];
      final alternate = _FakeSigner(owner).signMessage(
        GroupMessage(
          groupId: groupId,
          author: owner,
          seq: original.seq,
          prevHash: original.prevHash,
          body: 'fork',
          policyVersion: original.policyVersion,
          createdAtMs: original.createdAtMs + 1,
          signature: Uint8List(0),
        ),
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(cleanBundle, recipient: bob),
        ),
        isTrue,
      );
      expect((await bobService.messagesOf(groupId)), hasLength(3));

      expect(
        await ownerService.ingestSnapshot(
          ownerService.snapshotJson(
            cleanBundle.copyWith(
              messages: [...cleanBundle.messages, alternate],
            ),
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerService.messagesOf(groupId)).map((message) => message.body),
        ['zero'],
      );
      expect(
        await ownerService.postMessage(groupId, 'must not extend the fork'),
        isFalse,
      );

      final replies = <String>[];
      final responder = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, gid, wire) async => replies.add(wire),
      );
      final cleanRequest = (await bobService.buildGroupSyncRequest(groupId))!;
      expect(
        await responder.ingestGroupEntry(bob, jsonEncode(cleanRequest)),
        isTrue,
      );
      final evidence = jsonDecode(replies.single) as Map;
      expect(evidence['g'] as List, hasLength(2));
      await bobService.ingestSnapshot(replies.single);
      expect(
        (await bobService.messagesOf(groupId)).map((message) => message.body),
        ['zero'],
      );

      final forkedRequest = (await bobService.buildGroupSyncRequest(groupId))!;
      final fork =
          (((forkedRequest['ms'] as Map)['group|clear'] as Map)[owner.hex]
                  as Map)['f']
              as Map;
      expect(fork['s'], 1);
      expect((fork['h'] as List).toSet(), {
        groupMessageHash(original),
        groupMessageHash(alternate),
      });
      replies.clear();
      expect(
        await responder.ingestGroupEntry(bob, jsonEncode(forkedRequest)),
        isFalse,
        reason: 'known fork evidence must not be re-sent forever',
      );
      expect(replies, isEmpty);
    },
  );

  test(
    'gap-fill G1 remainder: a LOST reaction converges from the sync-vector '
    'exchange; a legacy vector without the r-key over-ships but dedups',
    () async {
      final sOwner = FakeHvContainer().storage();
      await sOwner.open(password: 'pw', createIfMissing: true);
      final sBob = FakeHvContainer().storage();
      await sBob.open(password: 'pw', createIfMissing: true);
      final toBob = <String>[], toOwner = <String>[];
      final ownerSvc = GroupService(
        sOwner,
        _FakeSigner(owner),
        send: (p, g, j) async => (p == bob ? toBob : toOwner).add(j),
      );
      final bobSvc = GroupService(
        sBob,
        _FakeSigner(bob),
        send: (p, g, j) async => toOwner.add(j),
      );

      final gid = await ownerSvc.createGroup('g1rx');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'react-target');
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final j in toBob) {
        await bobSvc.ingestSnapshot(j);
      }
      expect((await bobSvc.messagesOf(gid)).length, 1);

      // The owner's reaction is stored but its delta is LOST (broadcast off).
      final ref = (await ownerSvc.messagesOf(gid)).last.ref;
      expect(await ownerSvc.react(gid, ref, '🔥', broadcast: false), isTrue);
      expect(
        await bobSvc.reactionsOf(gid),
        isEmpty,
        reason: 'precondition: bob never saw the reaction delta',
      );

      // Bob's boot vector → the reply carries ONLY the missing reaction.
      toBob.clear();
      final req = (await bobSvc.buildGroupSyncRequest(gid))!;
      expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req)), isTrue);
      expect(toBob, hasLength(1));
      final reply = jsonDecode(toBob.single) as Map;
      expect(reply['g'] as List, isEmpty, reason: 'messages are in sync');
      expect(reply['c'] as List, isEmpty, reason: 'control is in sync');
      expect(reply['r'] as List, hasLength(1));
      await bobSvc.ingestSnapshot(toBob.single);
      final agg = await bobSvc.reactionsOf(gid);
      expect(agg[ref]?['🔥']?.map((n) => n.hex), contains(owner.hex));

      // Converged → the same exchange now stays silent.
      toBob.clear();
      final req2 = (await bobSvc.buildGroupSyncRequest(gid))!;
      expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req2)), isFalse);
      expect(toBob, isEmpty);

      // A LEGACY requester (no 'r' key) gets every reaction re-shipped; the
      // (author, seq) ingest dedup keeps the fold at exactly one reactor.
      final legacy = Map<String, dynamic>.of(req2)..remove('r');
      expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(legacy)), isTrue);
      expect(toBob, hasLength(1));
      await bobSvc.ingestSnapshot(toBob.single);
      expect(
        (await bobSvc.reactionsOf(gid))[ref]?['🔥']?.length,
        1,
        reason: 'over-shipped reaction dedups by (author, seq)',
      );
    },
  );

  test(
    'gap-fill heals a lost FIRST entry (seq 0) of an author — with the old '
    '0-floor vector semantics it was unrecoverable (latent G1 bug)',
    () async {
      final sOwner = FakeHvContainer().storage();
      await sOwner.open(password: 'pw', createIfMissing: true);
      final sBob = FakeHvContainer().storage();
      await sBob.open(password: 'pw', createIfMissing: true);
      final toBob = <String>[], toOwner = <String>[];
      final ownerSvc = GroupService(
        sOwner,
        _FakeSigner(owner),
        send: (p, g, j) async => (p == bob ? toBob : toOwner).add(j),
      );
      final bobSvc = GroupService(
        sBob,
        _FakeSigner(bob),
        send: (p, g, j) async => toOwner.add(j),
      );

      final gid = await ownerSvc.createGroup('g1seq0');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final j in toBob) {
        await bobSvc.ingestSnapshot(j);
      }

      // Bob's very FIRST message (his seq 0) is lost in an outage.
      await bobSvc.postMessage(gid, 'first-and-lost', broadcast: false);
      expect((await ownerSvc.messagesOf(gid)), isEmpty);

      // The owner's boot vector has never seen bob as a message author — bob's
      // reply must include the seq-0 message (old floor 0 dropped it forever).
      toOwner.clear();
      final req = (await ownerSvc.buildGroupSyncRequest(gid))!;
      expect(
        await bobSvc.ingestGroupEntry(owner, jsonEncode(req)),
        isTrue,
        reason: 'the seq-0 entry IS missing and must ship',
      );
      expect(toOwner, hasLength(1));
      await ownerSvc.ingestSnapshot(toOwner.single);
      expect(
        (await ownerSvc.messagesOf(gid)).map((m) => m.body),
        contains('first-and-lost'),
      );
    },
  );

  test('state-log compaction collapses reaction history, preserves fold and '
      'per-author high-water', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    final gid = await svc.createGroup('compact-rx');
    await svc.postMessage(gid, 'target');
    final ref = (await svc.messagesOf(gid)).single.ref;
    await svc.react(gid, ref, '🔥');
    await svc.react(gid, ref, '🎯');
    await svc.react(gid, ref, '🎯'); // clear
    await svc.react(gid, ref, '❤️');
    final beforeFold = await svc.reactionsOf(gid);
    final beforeVector = (await svc.buildGroupSyncRequest(gid))!['r'] as Map;
    expect((await svc.load(gid))!.reactions, hasLength(4));

    final compacted = (await svc.compactStateLogs(gid))!;
    expect(compacted.reactionsBefore, 4);
    expect(compacted.reactionsAfter, 1);
    expect(await svc.reactionsOf(gid), beforeFold);
    expect(
      (await svc.buildGroupSyncRequest(gid))!['r'],
      beforeVector,
      reason: 'author head keeps the gap-fill high-water at seq 3',
    );

    final freshStorage = FakeHvContainer().storage();
    await freshStorage.open(password: 'pw', createIfMissing: true);
    final fresh = GroupService(freshStorage, _FakeSigner(owner));
    await fresh.ingestSnapshot(svc.snapshotJson((await svc.load(gid))!));
    expect(
      await fresh.reactionsOf(gid),
      beforeFold,
      reason: 'a wiped/fresh device reconstructs the same state',
    );
    expect((await fresh.buildGroupSyncRequest(gid))!['r'], beforeVector);

    await svc.react(gid, ref, '❤️'); // clear after compaction
    expect(
      (await svc.load(gid))!.reactions.last.seq,
      4,
      reason: 'next seq must not rewind after old rows are removed',
    );
  });

  test('device-group compaction keeps LWW winners, unknown future events and '
      'author heads; ordinary chat messages are untouched', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    await svc.linkDevice(bob, sovereign: sovereign);
    final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);
    for (var i = 0; i < 3; i++) {
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: 'theme',
          tsMs: i + 1,
          payload: {'v': 'theme-$i'},
        ),
      );
    }
    await svc.postMessage(deviceGid, '{"v":2,"k":"futureKind"}');
    final vectorBefore =
        (await svc.buildGroupSyncRequest(deviceGid))!['g'] as Map;
    expect((await svc.load(deviceGid))!.messages, hasLength(4));

    final compacted = (await svc.compactStateLogs(deviceGid))!;
    expect(compacted.messagesBefore, 4);
    expect(
      compacted.messagesAfter,
      2,
      reason: 'theme winner + unknown forward-compatible row',
    );
    expect(
      (await svc.deviceSyncState())[(DeviceSyncKind.settingSet, 'theme')]!
          .payload['v'],
      'theme-2',
    );
    expect((await svc.buildGroupSyncRequest(deviceGid))!['g'], vectorBefore);

    final chatGid = await svc.createGroup('history');
    await svc.postMessage(chatGid, 'one');
    await svc.postMessage(chatGid, 'two');
    final chatResult = (await svc.compactStateLogs(chatGid))!;
    expect(chatResult.messagesBefore, 2);
    expect(
      chatResult.messagesAfter,
      2,
      reason: 'ordinary group history is not state and must not compact',
    );
  });

  test('nudgeDeviceSync (brick 4e): ships the FULL device-group snapshot to '
      'every other device — the boot catch-up for deltas lost during a total '
      'outage; no-op on a solo install', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final sent = <String>[];
    final svc = GroupService(
      s,
      _FakeSigner(owner),
      send: (p, g, j) async => sent.add(j),
    );
    expect(await svc.nudgeDeviceSync(), 0, reason: 'no device group yet');

    await svc.linkDevice(bob, sovereign: sovereign);
    await svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'theme',
        tsMs: 1,
        payload: const {'v': 'dark'},
      ),
    );
    // Let the fire-and-forget link/post broadcasts land before isolating the
    // nudge's own send.
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sent.clear();
    expect(await svc.nudgeDeviceSync(), 1, reason: 'one other device');
    // The nudge is a FULL snapshot (manifest + control + messages), so a
    // sibling that missed any delta converges from it alone.
    final snap = jsonDecode(sent.single) as Map;
    expect(snap['m'], isNotNull);
    expect((snap['c'] as List), isNotEmpty);
    expect((snap['g'] as List).length, 1, reason: 'carries the missed event');
  });

  test('isMyDevice: true only for current device-group members, and the '
      'cache invalidates on revoke (brick 4c mirror exclusion)', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    expect(await svc.isMyDevice(bob), isFalse, reason: 'no device group yet');
    await svc.linkDevice(bob, sovereign: sovereign);
    expect(await svc.isMyDevice(bob), isTrue);
    expect(await svc.isMyDevice(_id(9)), isFalse);
    await svc.revokeDevice(bob, sovereign: sovereign);
    expect(
      await svc.isMyDevice(bob),
      isFalse,
      reason: 'revoke must invalidate the cached member set',
    );

    // Group seen mirror: apply is monotonic and never fires the local tap.
    final taps = <(String, int)>[];
    svc.onGroupSeen = (g, ts) => taps.add((g, ts));
    expect(await svc.applyMirroredGroupSeen('aa', 500), isTrue);
    expect(await svc.applyMirroredGroupSeen('aa', 400), isFalse);
    expect(taps, isEmpty, reason: 'apply must not echo into the tap');
  });

  test(
    'isMyDevice cache invalidates when a sibling revoke is ingested',
    () async {
      final primaryStorage = FakeHvContainer().storage();
      await primaryStorage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(primaryStorage, _FakeSigner(owner));
      expect(
        await primary.linkDevice(
          bob,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      expect(
        await primary.linkDevice(
          carol,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);

      final siblingStorage = FakeHvContainer().storage();
      await siblingStorage.open(password: 'pw', createIfMissing: true);
      final sibling = GroupService(siblingStorage, _FakeSigner(carol));
      final initial = primary.snapshotJson(
        (await primary.load(gid))!,
        recipient: carol,
      );
      expect(await sibling.ingestSnapshot(initial), isTrue);
      expect(await sibling.adoptDeviceGroup(gid), isTrue);
      expect(await sibling.isMyDevice(bob), isTrue);

      expect(await primary.revokeDevice(bob, sovereign: sovereign), isTrue);
      final revoked = primary.snapshotJson(
        (await primary.load(gid))!,
        recipient: carol,
      );
      expect(await sibling.ingestSnapshot(revoked), isTrue);
      expect(
        await sibling.isMyDevice(bob),
        isFalse,
        reason: 'an ingested device-control update must invalidate the cache',
      );
    },
  );

  test(
    'postDeviceEvent with an attachment ref authorizes the membership pull '
    '(brick 4b: the cid lands in referencedContentIds of the device group)',
    () async {
      final s = FakeHvContainer().storage();
      await s.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(s, _FakeSigner(owner));
      await svc.linkDevice(bob, sovereign: sovereign);
      final gid = NodeId.fromHex((await svc.deviceGroupIdHex())!);

      expect(
        await svc.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.msgMirror,
            key: 'f1',
            tsMs: 5,
            payload: const {
              'peer': 'aa',
              'dir': 'outgoing',
              'body': '📎 report.pdf',
              'cid': 'cafe01',
              'fname': 'report.pdf',
              'fsize': 12345,
            },
          ),
          attachment: const GroupAttachment(
            kind: 'file',
            dataB64: 'AA==',
            w: 1,
            h: 1,
            cid: 'cafe01',
          ),
        ),
        isTrue,
      );
      expect(
        await svc.referencedContentIds(gid),
        contains('cafe01'),
        reason: 'the ref is what lets my other device fetch the bytes',
      );
      // The event still parses as a normal msgMirror with the file payload.
      final msgs = await svc.messagesOf(gid);
      final e = DeviceSyncEvent.fromBody(msgs.last.body)!;
      expect(e.payload['cid'], 'cafe01');
      expect(msgs.last.attachment?.cid, 'cafe01');
    },
  );

  // Auto-broadcast is unawaited (fire-and-forget) — let it drain.
  Future<void> pump() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'postMessage ships a DELTA (only the new message), not the whole log',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json),
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await svc.postMessage(gid, 'first');
      await svc.postMessage(gid, 'second');
      await pump();
      // The last send is the delta for 'second' — ONLY that message, no control.
      final last = jsonDecode(sent.last) as Map;
      final bodies = (last['g'] as List)
          .map((m) => (m as Map)['body'])
          .toList();
      expect(bodies, ['second'], reason: 'delta carries only the new message');
      expect(last['c'] as List, isEmpty);
      expect(
        last['m'],
        isNotNull,
        reason: 'manifest rides along for a racing join',
      );
    },
  );

  test(
    'addMember ships a FULL snapshot so a joining member gets history',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json),
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await svc.postMessage(gid, 'history');
      await pump();
      sent.clear();
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      );
      await pump();
      final snap = jsonDecode(sent.last) as Map;
      final bodies = (snap['g'] as List)
          .map((m) => (m as Map)['body'])
          .toList();
      expect(
        bodies,
        contains('history'),
        reason: 'the full snapshot on join carries the prior log',
      );
    },
  );

  test(
    'Space invite requires explicit consent before membership materializes',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      await bobStorage.upsertContact(
        Contact(nodeId: owner, status: ContactStatus.accepted),
      );
      late GroupService ownerService;
      late GroupService bobService;
      String? proposalJson;
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceInvite: (peer, inviteId, json) async {
          expect(peer, bob);
          proposalJson = json;
          expect(await bobService.receiveSpaceInvite(owner, json), isTrue);
        },
        send: (peer, spaceId, json) async {
          if (peer == bob) {
            expect(await bobService.ingestGroupEntry(owner, json), isTrue);
          }
        },
      );
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendSpaceInviteDecision: (peer, inviteId, json) async {
          expect(peer, owner);
          expect(
            await ownerService.receiveSpaceInviteDecision(bob, json),
            isTrue,
          );
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final spaceId = await ownerService.createSpace('Consent lab');
      final unsolicited = ownerService.snapshotJson(
        (await ownerService.load(spaceId))!,
      );
      expect(
        await bobService.ingestGroupEntry(owner, unsolicited),
        isFalse,
        reason: 'an accepted contact cannot plant a new Space snapshot',
      );
      expect(await bobService.load(spaceId), isNull);

      expect(await ownerService.inviteToSpace(spaceId, bob), isTrue);
      final proposal = jsonDecode(proposalJson!) as Map;
      expect(proposal['space'], spaceId.hex);
      for (final privateField in const ['m', 'c', 'g', 'ke']) {
        expect(proposal, isNot(contains(privateField)));
      }
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
      expect(await bobService.load(spaceId), isNull);
      final pending = await bobService.pendingSpaceInvites();
      expect(pending, hasLength(1));
      expect(pending.single.accepted, isFalse);

      expect(
        await bobService.decideSpaceInvite(
          pending.single.invite.inviteId,
          accept: true,
        ),
        isTrue,
      );
      await pump();
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(
        (await bobService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(await bobService.pendingSpaceInvites(), isEmpty);
    },
  );

  test(
    'public Space join link admits a non-contact only after signed approval',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late GroupService ownerService;
      late GroupService requesterService;
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceJoinDecision: (peer, requestId, json) async {
          expect(peer, bob);
          if (!await requesterService.receiveSpaceJoinDecision(owner, json)) {
            throw StateError('requester rejected a valid decision');
          }
        },
        send: (peer, spaceId, json) async {
          if (peer == bob &&
              !await requesterService.ingestGroupEntryFromStranger(
                owner,
                json,
              )) {
            throw StateError('requester rejected approved Space snapshot');
          }
        },
      );
      requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(peer, owner);
          if (!await ownerService.receiveSpaceJoinRequest(bob, json)) {
            throw StateError('approver rejected a valid join request');
          }
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final groupChat = await ownerService.createGroup('Team chat');
      expect(
        await ownerService.createSpaceJoinCode(groupChat),
        isNull,
        reason: 'group chats remain chats and never become public Spaces',
      );
      final privateSpace = await ownerService.createSpace('Private lab');
      expect(await ownerService.createSpaceJoinCode(privateSpace), isNull);
      final spaceId = await ownerService.createSpace(
        'Public lab',
        visibility: SpaceVisibility.public,
      );
      final code = await ownerService.createSpaceJoinCode(spaceId);
      expect(code, startsWith('xveil://space/v1#'));
      expect(
        (await ownerService.currentSpaceJoinCode(spaceId)),
        code,
        reason: 'copying the same active link must not rotate its capability',
      );

      final unsolicited = ownerService.snapshotJson(
        (await ownerService.load(spaceId))!,
        recipient: bob,
      );
      expect(
        await requesterService.ingestGroupEntryFromStranger(owner, unsolicited),
        isFalse,
      );
      expect(await requesterService.load(spaceId), isNull);

      expect(await requesterService.requestToJoinSpace(code!), isTrue);
      expect(
        await ownerService.pendingSpaceJoinRequests(spaceId),
        hasLength(1),
      );
      final outgoing = await requesterService.outgoingSpaceJoinRequests();
      expect(outgoing, hasLength(1));
      expect(outgoing.single.ticket.spaceName, 'Public lab');
      expect(
        outgoing.single.request.ticketHash,
        spaceJoinTicketHash(outgoing.single.ticket),
      );

      // A second request for the same Space reuses the durable id instead of
      // creating a spam row or a second membership ceremony.
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      expect(
        await ownerService.pendingSpaceJoinRequests(spaceId),
        hasLength(1),
      );

      final requestId = outgoing.single.request.requestId;
      expect(
        await ownerService.decideSpaceJoinRequest(requestId, accept: true),
        isTrue,
      );
      await pump();
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(
        (await requesterService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(await requesterService.outgoingSpaceJoinRequests(), isEmpty);
      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
    },
  );

  test(
    'public Space recommendation campaign is signed and revocable',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      final sent = <({NodeId peer, String campaign})>[];
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        sendSpaceRecommendation: (peer, card) async {
          sent.add((peer: peer, campaign: card.campaignId));
          return true;
        },
      );
      addTearDown(service.dispose);

      final groupId = await service.createGroup('Chat');
      final privateSpace = await service.createSpace('Private');
      final publicSpace = await service.createSpace(
        'Public',
        description: 'Open community',
        visibility: SpaceVisibility.public,
      );
      expect(
        await service.createSpaceRecommendationCampaign(groupId, 'Share it'),
        isNull,
      );
      expect(
        await service.createSpaceRecommendationCampaign(
          privateSpace,
          'Share it',
        ),
        isNull,
      );

      final campaign = await service.createSpaceRecommendationCampaign(
        publicSpace,
        '  Расскажите друзьям  ',
      );
      expect(campaign, isNotNull);
      expect(campaign!.text, 'Расскажите друзьям');
      expect(campaign.joinCode, startsWith('xveil://space/v1#'));
      final listed = await service.spaceRecommendationCampaigns(publicSpace);
      expect(listed, hasLength(1));
      expect(listed.single.campaignId, campaign.campaignId);
      final bundle = (await service.load(publicSpace))!;
      final control = bundle.control.last;
      expect(control.version, 13);
      expect(control.op, ControlOp.setRecommendationCampaign);
      expect(control.recommendationCampaign?.campaignId, campaign.campaignId);

      await storage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          bob,
        ),
        SpaceRecommendationShareResult.sent,
      );
      expect(sent.single.peer, bob);
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          bob,
        ),
        SpaceRecommendationShareResult.duplicate,
      );
      final shareAudit = await service.spaceRecommendationShareAudit();
      expect(shareAudit, hasLength(1));
      expect(shareAudit.single.recipient, bob);

      for (var seed = 30; seed < 34; seed++) {
        final peer = _id(seed);
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        expect(
          await service.shareSpaceRecommendation(
            publicSpace,
            campaign.campaignId,
            peer,
          ),
          SpaceRecommendationShareResult.sent,
        );
      }
      final overLimit = _id(34);
      await storage.upsertContact(
        Contact(nodeId: overLimit, status: ContactStatus.accepted),
      );
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          overLimit,
        ),
        SpaceRecommendationShareResult.rateLimited,
      );
      expect(sent, hasLength(5));

      expect(
        await service.revokeSpaceRecommendationCampaign(
          publicSpace,
          campaign.campaignId,
        ),
        isTrue,
      );
      expect(await service.spaceRecommendationCampaigns(publicSpace), isEmpty);
      final campaignAudit = await service.spaceRecommendationCampaigns(
        publicSpace,
        includeRevoked: true,
      );
      expect(campaignAudit.single.active, isFalse);
      expect(campaignAudit.single.joinCode, isEmpty);
    },
  );

  test(
    'revoked public Space join link receives no durable acceptance',
    () async {
      final storage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late GroupService ownerService;
      ownerService = GroupService(storage, _FakeSigner(owner));
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          if (!await ownerService.receiveSpaceJoinRequest(bob, json)) {
            throw StateError('revoked ticket rejected');
          }
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);
      final spaceId = await ownerService.createSpace(
        'Revocation lab',
        visibility: SpaceVisibility.public,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      final ticket = SpaceJoinCode.parse(code);
      final tampered = SpaceJoinRequest(
        requestId: 'ef' * 32,
        ticketId: ticket.ticketId,
        ticketHash: '00' * 32,
        spaceId: spaceId,
        requester: bob,
        approver: owner,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(
        await ownerService.receiveSpaceJoinRequest(
          bob,
          jsonEncode(tampered.toJson()),
        ),
        isFalse,
        reason: 'the request must be bound to the exact bearer ticket',
      );
      expect(await ownerService.revokeSpaceJoinCode(spaceId), isTrue);
      expect(await requesterService.requestToJoinSpace(code), isFalse);
      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
    },
  );

  test('a mute op ships a control DELTA (no messages re-sent)', () async {
    final sent = <String>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(
      storage,
      _FakeSigner(owner),
      send: (peer, gid, json) async => sent.add(json),
    );
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await svc.postMessage(gid, 'msg');
    await pump();
    sent.clear();
    await svc.addControlOp(gid, ControlOp.mute, target: bob);
    await pump();
    final delta = jsonDecode(sent.last) as Map;
    expect(delta['g'] as List, isEmpty, reason: 'a mute re-sends no messages');
    expect((delta['c'] as List).length, 1, reason: 'just the mute entry');
  });

  test(
    'a member leaves: removed from state + hidden from their list; owner cannot',
    () async {
      final (svc, member) = await setup();
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      expect((await svc.stateOf(gid))!.isMember(bob), isTrue);

      final bobDev = member(bob);
      expect(await bobDev.leaveGroup(gid), isTrue);
      expect(
        (await svc.stateOf(gid))!.isMember(bob),
        isFalse,
        reason: 'the leave op removes the author',
      );
      expect(
        (await bobDev.listGroups()).where((g) => g.groupId == gid),
        isEmpty,
        reason: 'a left group is hidden from the leaver',
      );
      expect(
        (await svc.listGroups()).where((g) => g.groupId == gid),
        isNotEmpty,
        reason: 'the owner still sees it',
      );

      // The owner is the genesis and cannot leave.
      expect(await svc.leaveGroup(gid), isFalse);
      expect((await svc.stateOf(gid))!.isMember(owner), isTrue);
    },
  );

  test(
    'Space owner transfers atomically, then the previous owner may leave',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(storage, _FakeSigner(owner));
      final bobService = GroupService(storage, _FakeSigner(bob));
      final spaceId = await ownerService.createSpace('Transferable');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      expect(await ownerService.transferSpaceOwnership(spaceId, bob), isTrue);
      final transferred = (await ownerService.load(spaceId))!;
      expect(
        transferred.manifest.owner,
        owner,
        reason: 'genesis root is immutable',
      );
      expect(transferred.control.last.version, 6);
      expect(transferred.control.last.op, ControlOp.transferOwnership);
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(owner),
        GroupRole.admin,
      );
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.owner,
      );
      expect(
        await ownerService.transferSpaceOwnership(spaceId, owner),
        isFalse,
        reason: 'the previous owner lost owner-only authority atomically',
      );

      expect(await ownerService.leaveGroup(spaceId), isTrue);
      final finalState = (await bobService.stateOf(spaceId))!;
      expect(finalState.isMember(owner), isFalse);
      expect(finalState.roleOf(bob), GroupRole.owner);
      expect(await bobService.leaveGroup(spaceId), isFalse);
    },
  );

  test(
    'ownership transfer rekeys protected channel control for the new owner',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace('Protected transfer');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final channelId = await service.createChannel(
        spaceId,
        name: 'owners only',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      expect(await service.channelMembersOf(spaceId, channelId!), [owner]);

      expect(await service.transferSpaceOwnership(spaceId, bob), isTrue);
      expect(
        await service.channelMembersOf(spaceId, channelId),
        containsAllInOrder([owner, bob]),
        reason: 'the effective owner must never inherit a stranded ACL subtree',
      );
      final controls = (await service.load(spaceId))!.control;
      expect(
        controls.any(
          (entry) =>
              entry.version == 6 && entry.op == ControlOp.transferOwnership,
        ),
        isTrue,
      );
      expect(
        controls.last.channelControl?.channelEpoch,
        2,
        reason: 'role transfer rotates opaque channel control immediately',
      );
    },
  );

  test(
    'reactions: toggle on/off, aggregate, and survive snapshot round-trip',
    () async {
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final owned = GroupService(s1, _FakeSigner(owner));
      final gid = await owned.createGroup('G');
      await owned.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await owned.postMessage(gid, 'react to me');
      final msg = (await owned.messagesOf(gid)).single;
      final ref = msg.ref;

      // Owner reacts 👍.
      expect(await owned.react(gid, ref, '👍'), isTrue);
      var agg = await owned.reactionsOf(gid);
      expect(agg[ref]!['👍'], contains(owner));

      // Bob (same store) reacts ❤ on the same message → both counted.
      final bobDev = GroupService(s1, _FakeSigner(bob));
      await bobDev.react(gid, ref, '❤');
      agg = await owned.reactionsOf(gid);
      expect(agg[ref]!['👍'], contains(owner));
      expect(agg[ref]!['❤'], contains(bob));

      // Owner taps 👍 again → toggles OFF (latest-per-author-target wins).
      await owned.react(gid, ref, '👍');
      agg = await owned.reactionsOf(gid);
      expect(agg[ref]?['👍'] ?? const [], isNot(contains(owner)));
      expect(agg[ref]!['❤'], contains(bob), reason: 'bob still reacts');

      // A fresh device materializes the reactions via the full snapshot.
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final carolDev = GroupService(s2, _FakeSigner(carol));
      await carolDev.ingestSnapshot(
        owned.snapshotJson((await owned.load(gid))!),
      );
      final got = await carolDev.reactionsOf(gid);
      expect(got[ref]!['❤'], contains(bob));
    },
  );

  test('replyTo is signed + round-trips; a plain message omits it', () {
    GroupMessage base({String? rt}) => GroupMessage(
      groupId: _id(2),
      author: owner,
      seq: 1,
      prevHash: '',
      body: 'reply body',
      policyVersion: 0,
      createdAtMs: 9,
      signature: Uint8List(0),
      replyTo: rt,
    );
    final withReply = base(rt: '${bob.hex}:3').canonicalBytes();
    final plain = base().canonicalBytes();
    expect(
      withReply,
      isNot(equals(plain)),
      reason: 'the reply ref is inside the signed bytes (tamper-evident)',
    );
    expect(
      String.fromCharCodes(plain).contains('"rt"'),
      isFalse,
      reason: 'a non-reply message signs as before the field existed',
    );
    final rt = GroupMessage.fromJson(base(rt: '${bob.hex}:3').toJson())!;
    expect(rt.replyTo, '${bob.hex}:3');
    // The ref of a message resolves to its (author, seq) identity.
    expect(base().ref, '${owner.hex}:1');
  });

  test('a delta merges on a peer that already has the group', () async {
    // Owner device.
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    String? lastDelta;
    final owned = GroupService(
      s1,
      _FakeSigner(owner),
      send: (peer, gid, json) async => lastDelta = json,
    );
    final gid = await owned.createGroup('Shared');
    await owned.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );

    // Bob materializes from the FULL snapshot (the addMember broadcast).
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobDev = GroupService(s2, _FakeSigner(bob));
    await bobDev.ingestSnapshot(owned.snapshotJson((await owned.load(gid))!));
    expect(await bobDev.messagesOf(gid), isEmpty);

    // Owner posts → only the delta is sent; Bob ingests it and sees the message.
    await owned.postMessage(gid, 'hi bob');
    await pump();
    expect(lastDelta, isNotNull);
    await bobDev.ingestSnapshot(lastDelta!);
    expect((await bobDev.messagesOf(gid)).single.body, 'hi bob');
  });

  test('ingestControl dedups on (author, seq)', () async {
    final (svc, _) = await setup();
    final gid = await svc.createGroup('G');
    final initial = await svc.load(gid);
    final authored = initial!.control
        .where((entry) => entry.author == owner)
        .toList();
    final head = authored.isEmpty
        ? null
        : authored.reduce((left, right) => left.seq > right.seq ? left : right);
    final e = _FakeSigner(owner).signControl(
      ControlEntry(
        version: 2,
        groupId: gid,
        author: owner,
        seq: head == null ? 0 : head.seq + 1,
        prevHash: head == null ? '' : controlEntryHash(head),
        op: ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(0),
      ),
    );
    await svc.ingestControl(gid, e);
    await svc.ingestControl(gid, e); // duplicate
    final b = await svc.load(gid);
    expect(
      b!.control.where((entry) => entry.op == ControlOp.addMember).length,
      1,
    );
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);
  });

  test('new control rows form a contiguous signed v2/v3 chain', () async {
    final (svc, _) = await setup();
    final gid = await svc.createGroup('Control chain');
    expect(
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(await svc.addControlOp(gid, ControlOp.mute, target: bob), isTrue);

    final authored =
        (await svc.load(
            gid,
          ))!.control.where((entry) => entry.author == owner).toList()
          ..sort((left, right) => left.seq.compareTo(right.seq));
    expect(authored, isNotEmpty);
    for (var index = 0; index < authored.length; index++) {
      final entry = authored[index];
      expect(entry.version, 2);
      expect(entry.seq, index);
      expect(
        entry.prevHash,
        index == 0 ? isEmpty : controlEntryHash(authored[index - 1]),
      );
      final roundTrip = ControlEntry.fromJson(entry.toJson());
      expect(roundTrip, isNotNull);
      expect(controlEntryHash(roundTrip!), controlEntryHash(entry));
    }
  });

  test(
    'control fork evidence converges through same-seq head-hash sync',
    () async {
      final baseStorage = FakeHvContainer().storage();
      await baseStorage.open(password: 'pw', createIfMissing: true);
      final base = GroupService(baseStorage, _FakeSigner(owner));
      final gid = await base.createGroup('Fork convergence');
      final initial = (await base.load(gid))!;
      final head = initial.control.isEmpty ? null : initial.control.single;

      ControlEntry fork(NodeId target, int timestamp) =>
          _FakeSigner(owner).signControl(
            ControlEntry(
              version: 2,
              groupId: gid,
              author: owner,
              seq: head == null ? 0 : head.seq + 1,
              prevHash: head == null ? '' : controlEntryHash(head),
              op: ControlOp.addMember,
              target: target,
              role: GroupRole.member,
              policyVersion: 0,
              createdAtMs: timestamp,
              signature: Uint8List(0),
            ),
          );

      final leftOut = <String>[];
      final rightOut = <String>[];
      final leftStorage = FakeHvContainer().storage();
      final rightStorage = FakeHvContainer().storage();
      await leftStorage.open(password: 'pw', createIfMissing: true);
      await rightStorage.open(password: 'pw', createIfMissing: true);
      final left = GroupService(
        leftStorage,
        _FakeSigner(owner),
        send: (_, _, payload) async => leftOut.add(payload),
      );
      final right = GroupService(
        rightStorage,
        _FakeSigner(owner),
        send: (_, _, payload) async => rightOut.add(payload),
      );
      final genesis = base.snapshotJson(initial, recipient: owner);
      expect(await left.ingestSnapshot(genesis), isTrue);
      expect(await right.ingestSnapshot(genesis), isTrue);
      await left.ingestControl(gid, fork(bob, 2000));
      await right.ingestControl(gid, fork(carol, 2001));
      expect((await left.stateOf(gid))!.isMember(bob), isTrue);
      expect((await right.stateOf(gid))!.isMember(carol), isTrue);

      final leftVector = (await left.buildGroupSyncRequest(gid))!;
      final rightVector = (await right.buildGroupSyncRequest(gid))!;
      expect(
        ((leftVector['c'] as Map)[owner.hex] as Map)['s'],
        head == null ? 0 : head.seq + 1,
      );
      expect(
        ((leftVector['c'] as Map)[owner.hex] as Map)['h'],
        isNot(((rightVector['c'] as Map)[owner.hex] as Map)['h']),
      );

      expect(await left.handleGroupSyncRequest(owner, rightVector), isTrue);
      expect(await right.handleGroupSyncRequest(owner, leftVector), isTrue);
      expect(leftOut, hasLength(1));
      expect(rightOut, hasLength(1));
      await left.ingestSnapshot(rightOut.single);
      await right.ingestSnapshot(leftOut.single);

      final leftState = (await left.stateOf(gid))!;
      final rightState = (await right.stateOf(gid))!;
      expect(leftState.isMember(bob), isFalse);
      expect(leftState.isMember(carol), isFalse);
      expect(rightState.isMember(bob), isFalse);
      expect(rightState.isMember(carol), isFalse);
      expect((await left.load(gid))!.control, hasLength(2));
      expect((await right.load(gid))!.control, hasLength(2));
      expect(
        await left.renameGroup(gid, 'must not build on a fork'),
        isFalse,
        reason: 'local writers fail closed until equivocation is resolved',
      );
      expect((await left.stateOf(gid))!.name, 'Fork convergence');
    },
  );

  test(
    'rename: owner renames, name folds + lists; a plain member cannot',
    () async {
      // Owner device, capturing what gets broadcast so we can confirm it's a
      // DELTA (a setName control op ships without re-sending the whole log).
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      String? lastDelta;
      final owned = GroupService(
        s1,
        _FakeSigner(owner),
        send: (peer, gid, json) async => lastDelta = json,
      );
      final gid = await owned.createGroup('Old name');
      await owned.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );

      // Owner renames → state folds the new name and the list reflects it.
      expect(await owned.renameGroup(gid, 'New name'), isTrue);
      expect((await owned.stateOf(gid))!.name, 'New name');
      expect((await owned.listGroups()).single.name, 'New name');
      expect(lastDelta, isNotNull); // a delta, not a full snapshot

      // Bob materializes from the owner's snapshot: he inherits the new name.
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobDev = GroupService(s2, _FakeSigner(bob));
      await bobDev.ingestSnapshot(owned.snapshotJson((await owned.load(gid))!));
      expect((await bobDev.stateOf(gid))!.name, 'New name');

      // A plain member cannot rename: the op is rejected, the name is unchanged
      // on the owner's authoritative view.
      expect(await bobDev.renameGroup(gid, 'Hijacked'), isFalse);
      expect((await bobDev.stateOf(gid))!.name, 'New name');
    },
  );

  test(
    'Space profile keeps genesis visibility and replicates signed description edits',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      String? lastDelta;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (_, _, payload) async => lastDelta = payload,
      );
      final spaceId = await ownerService.createSpace(
        'Field lab',
        description: 'Initial field notes',
        visibility: SpaceVisibility.secret,
      );
      await ownerService.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );

      final initial = (await ownerService.listSpaces()).single;
      expect(initial.description, 'Initial field notes');
      expect(initial.visibility, SpaceVisibility.secret);
      expect(initial.discoverable, isFalse);

      expect(
        await ownerService.setSpaceDescription(
          spaceId,
          'Verified protocols and meetups',
        ),
        isTrue,
      );
      expect(
        (await ownerService.stateOf(spaceId))!.description,
        'Verified protocols and meetups',
      );
      expect(lastDelta, isNotNull);

      final memberStorage = FakeHvContainer().storage();
      await memberStorage.open(password: 'pw', createIfMissing: true);
      final memberService = GroupService(memberStorage, _FakeSigner(bob));
      expect(
        await memberService.ingestSnapshot(
          ownerService.snapshotJson((await ownerService.load(spaceId))!),
        ),
        isTrue,
      );
      expect(
        (await memberService.stateOf(spaceId))!.description,
        'Verified protocols and meetups',
      );
      expect(
        await memberService.setSpaceDescription(spaceId, 'forged'),
        isFalse,
      );
      expect(
        await ownerService.setSpaceDescription(spaceId, 'x' * 4097),
        isFalse,
      );
    },
  );

  test(
    'Space rules and member acceptance converge through P2P deltas',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      late GroupService ownerService;
      late GroupService bobService;
      var bobMaterialized = false;
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, spaceId, payload) async {
          if (peer == bob && bobMaterialized) {
            expect(await bobService.ingestGroupEntry(owner, payload), isTrue);
          }
        },
      );
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        send: (peer, spaceId, payload) async {
          if (peer == owner) {
            expect(await ownerService.ingestGroupEntry(bob, payload), isTrue);
          }
        },
      );

      final spaceId = await ownerService.createSpace('Rules replication');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      await pump();
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      bobMaterialized = true;
      expect((await bobService.stateOf(spaceId))!.isMember(bob), isTrue);

      expect(
        await ownerService.publishSpaceRules(
          spaceId,
          fullText: 'Distribute only data that your current ACL permits.',
          summary: 'Respect ACL while redistributing.',
        ),
        isTrue,
      );
      await pump();
      expect((await bobService.stateOf(spaceId))!.currentRules?.version, 1);
      expect(
        (await bobService.stateOf(spaceId))!.requiresRulesAcceptance(bob),
        isTrue,
      );

      expect(await bobService.acceptSpaceRules(spaceId), isTrue);
      await pump();
      final ownerView = (await ownerService.stateOf(spaceId))!;
      expect(ownerView.rulesAcceptanceOf(bob)?.rulesVersion, 1);
      expect(ownerView.requiresRulesAcceptance(bob), isFalse);
    },
  );

  test(
    'Space post drafts persist locally, support large bodies and never enter P2P logs',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final spaceId = await service.createSpace(
        'Draft lab',
        visibility: SpaceVisibility.public,
      );
      final largeBody = List.filled(6000, 'draft').join();
      final draftMedia = MediaObjectRef(
        contentId: 'd' * 64,
        kind: 'video',
        name: 'draft.mp4',
        size: 512,
      );

      expect(
        await service.saveSpacePostDraft(
          spaceId,
          title: 'Work in progress',
          body: largeBody,
          type: SpacePostType.shortVideo,
          media: [draftMedia],
        ),
        isTrue,
      );
      final stored = await storage.loadFile(
        'space.post-draft.v1:${spaceId.hex}',
      );
      expect(stored, isNotNull);
      final storedJson = jsonDecode(utf8.decode(stored!)) as Map;
      // Keep this assertion close to persistence: the local draft must not be
      // confused with opaque content bytes or a signed post row.
      expect(storedJson['v'], 2);
      expect(storedJson['sid'], spaceId.hex);
      expect(storedJson['type'], SpacePostType.shortVideo.name);
      expect(storedJson['title'], 'Work in progress');
      expect((storedJson['body'] as String).length, largeBody.length);
      expect(storedJson['updatedAt'], isA<int>());
      expect((storedJson['media'] as List).single['cid'], 'd' * 64);
      final draft = await service.spacePostDraft(spaceId);
      expect(draft?.title, 'Work in progress');
      expect(draft?.body, largeBody);
      expect(draft?.type, SpacePostType.shortVideo);
      expect(draft?.media.single.name, 'draft.mp4');
      expect((await service.load(spaceId))!.posts, isEmpty);

      final reopened = GroupService(storage, _FakeSigner(owner));
      expect((await reopened.spacePostDraft(spaceId))?.body, largeBody);

      await Future.wait([
        service.saveSpacePostDraft(
          spaceId,
          title: 'First queued value',
          body: '',
          type: SpacePostType.post,
        ),
        service.saveSpacePostDraft(
          spaceId,
          title: 'Last queued value',
          body: '',
          type: SpacePostType.article,
        ),
      ]);
      expect(
        (await service.spacePostDraft(spaceId))?.title,
        'Last queued value',
      );

      expect(await service.clearSpacePostDraft(spaceId), isTrue);
      expect(await service.spacePostDraft(spaceId), isNull);
      expect(
        await service.saveSpacePostDraft(
          await service.createGroup('Not a community'),
          title: 'Must stay unavailable',
          body: '',
          type: SpacePostType.post,
        ),
        isFalse,
      );
    },
  );

  test(
    'public Space posts are a separate signed log with stable feed paging',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Public updates',
        visibility: SpaceVisibility.public,
      );
      final first = await svc.publishSpacePost(
        spaceId,
        title: 'One',
        body: 'first publication',
        type: SpacePostType.article,
        media: [MediaObjectRef(contentId: 'a' * 64, kind: 'image')],
        broadcast: false,
      );
      final second = await svc.publishSpacePost(
        spaceId,
        body: 'second publication',
        broadcast: false,
      );
      expect(first, isNotNull);
      expect(second, isNotNull);
      final raw = (await svc.load(spaceId))!;
      expect(raw.messages, isEmpty);
      expect(raw.posts, hasLength(2));
      expect(raw.posts.every((post) => !post.isEncrypted), isTrue);
      expect(raw.posts.every((post) => post.version == 5), isTrue);
      expect(
        raw.posts.every(
          (post) =>
              post.controlFrontier == null &&
              post.controlCheckpointHash != null,
        ),
        isTrue,
      );
      expect(
        raw.posts.map((post) => post.controlCheckpointHash).toSet(),
        hasLength(1),
        reason: 'unchanged ACL state reuses one checkpoint',
      );
      expect(
        raw.posts.every(
          (post) => post.visibility == SpacePostVisibility.public,
        ),
        isTrue,
      );
      expect(await svc.referencedContentIds(spaceId), {'a' * 64});

      expect(
        await svc.reactToSpacePost(
          spaceId,
          first!.postId,
          '🔥',
          broadcast: false,
        ),
        isTrue,
      );
      expect(await svc.postMessage(spaceId, 'same-id message'), isTrue);
      final message = (await svc.messagesOf(spaceId)).single;
      expect(message.ref, first.postId);
      expect(
        await svc.react(spaceId, message.ref, '👍', broadcast: false),
        isTrue,
      );
      final postReactions = await svc.spacePostReactionsOf(spaceId);
      expect(postReactions[first.postId]?['🔥'], [owner]);
      expect((await svc.reactionsOf(spaceId))[message.ref]?['👍'], [owner]);
      expect(
        (await svc.reactionsOf(spaceId))[message.ref],
        isNot(contains('🔥')),
      );
      final reactionRows = (await svc.load(spaceId))!.reactions;
      expect(reactionRows, hasLength(2));
      expect(reactionRows.every((row) => row.version == 3), isTrue);
      expect(reactionRows.map((row) => row.targetKind).toSet(), {
        ReactionTargetKind.message,
        ReactionTargetKind.spacePost,
      });

      final page1 = await svc.spaceFeed(limit: 1);
      expect(page1.single.post.body, 'second publication');
      final page2 = await svc.spaceFeed(
        before: SpaceFeedCursor.fromView(page1.single.post),
        limit: 1,
      );
      expect(page2.single.post.body, 'first publication');
      expect(page2.single.spaceName, 'Public updates');
      expect(page2.single.reactions['🔥'], [owner]);

      await svc.updateSpaceSubscription(
        spaceId,
        feedEnabled: true,
        notificationsEnabled: true,
        hiddenFromRecommendations: false,
      );
      await Future.wait([
        svc.setSpaceFeedEnabled(spaceId, false),
        svc.setSpaceNotificationsEnabled(spaceId, false),
        svc.setSpaceCommentNotifications(
          spaceId,
          SpaceCommentNotificationMode.all,
        ),
        svc.setSpaceHiddenFromRecommendations(spaceId, true),
      ]);
      expect(await svc.spaceFeed(), isEmpty);
      expect((await svc.stateOf(spaceId))!.isMember(owner), isTrue);
      final preferences = await svc.spaceSubscription(spaceId);
      expect(preferences.feedEnabled, isFalse);
      expect(preferences.notificationsEnabled, isFalse);
      expect(
        preferences.commentNotifications,
        SpaceCommentNotificationMode.all,
      );
      expect(preferences.hiddenFromRecommendations, isTrue);
      await svc.setSpaceFeedEnabled(spaceId, true);
      expect(await svc.spaceFeed(), hasLength(2));
      expect(
        await svc.unreadSpacePosts(spaceId),
        0,
        reason: 'own posts are read-neutral',
      );
    },
  );

  test(
    'Space post comments are encrypted, scoped to their root and absent from Chats',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace(
        'Discussion lab',
        visibility: SpaceVisibility.public,
      );
      final otherSpace = await service.createSpace(
        'Other discussion',
        visibility: SpaceVisibility.public,
      );
      final groupId = await service.createGroup('Ordinary group chat');
      final first = (await service.publishSpacePost(
        spaceId,
        body: 'First root',
        broadcast: false,
      ))!;
      final second = (await service.publishSpacePost(
        spaceId,
        body: 'Second root',
        broadcast: false,
      ))!;
      await service.publishSpacePost(
        otherSpace,
        body: 'Foreign root',
        broadcast: false,
      );
      final commentMedia = MediaObject(
        contentId: 'c' * 64,
        kind: 'file',
        name: 'review.pdf',
        mimeType: 'application/pdf',
        size: 128,
      );

      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          '  First comment  ',
          broadcast: false,
        ),
        isTrue,
      );
      final firstComment = (await service.spacePostCommentsOf(
        spaceId,
        first.postId,
      )).single;
      expect(firstComment.body, 'First comment');
      expect(
        await service.editSpacePostComment(
          spaceId,
          first.postId,
          firstComment.ref,
          'Corrected first comment',
          broadcast: false,
        ),
        isTrue,
      );
      final editedFirst = (await service.spacePostCommentsOf(
        spaceId,
        first.postId,
      )).single;
      expect(editedFirst.ref, firstComment.ref);
      expect(editedFirst.body, 'Corrected first comment');
      expect(editedFirst.edited, isTrue);
      expect(editedFirst.editedAtMs, isNotNull);
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          'Reply',
          replyTo: firstComment.ref,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          '',
          media: commentMedia,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          second.postId,
          'Second-root comment',
          broadcast: false,
        ),
        isTrue,
      );

      final firstThread = await service.spacePostCommentsOf(
        spaceId,
        first.postId,
      );
      expect(firstThread.map((comment) => comment.body), [
        'Corrected first comment',
        'Reply',
        '',
      ]);
      expect(firstThread[1].replyTo, firstThread.first.ref);
      expect(firstThread.last.attachment?.toReferenceJson(), {
        'cid': 'c' * 64,
        'kind': 'file',
        'name': 'review.pdf',
        'mime': 'application/pdf',
        'size': 128,
      });
      expect(await service.referencedContentIds(spaceId), contains('c' * 64));
      expect(
        (await service.spacePostCommentsOf(spaceId, second.postId)).single.body,
        'Second-root comment',
      );
      expect(await service.messagesOf(spaceId), isEmpty);
      expect(
        await service.messagesOf(
          spaceId,
          channelId: defaultSpaceChannelId(spaceId),
        ),
        isEmpty,
      );
      expect((await service.listGroups()).single.groupId, groupId);
      expect(
        (await service.listSpaces()).map((entry) => entry.groupId),
        containsAll([spaceId, otherSpace]),
      );

      final wire = (await service.load(spaceId))!.messages;
      expect(wire, hasLength(5));
      expect(wire.every((comment) => comment.isEncrypted), isTrue);
      expect(wire.every((comment) => comment.body.isEmpty), isTrue);
      expect(wire.every((comment) => comment.channelId == null), isTrue);
      expect(wire.map((comment) => comment.spacePostId), [
        first.postId,
        first.postId,
        first.postId,
        first.postId,
        second.postId,
      ]);

      expect(
        await service.commentOnSpacePost(
          groupId,
          first.postId,
          'Must not turn a group chat into a Space',
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          '',
          media: const MediaObject(contentId: 'not-a-sha256-cid', kind: 'file'),
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          '${bob.hex}:99',
          'Cross-Space target',
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          second.postId,
          'Cross-thread reply',
          replyTo: firstComment.ref,
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          List.filled(kSpacePostCommentMaxBytes + 1, 'x').join(),
        ),
        isFalse,
      );
      expect(
        await service.editSpacePostComment(
          spaceId,
          first.postId,
          '${bob.hex}:99',
          'Cannot edit a missing or foreign comment',
        ),
        isFalse,
      );

      expect(
        await service.deleteSpacePost(spaceId, first.postId, broadcast: false),
        isTrue,
      );
      expect(await service.spacePostCommentsOf(spaceId, first.postId), isEmpty);
      expect(
        await service.referencedContentIds(spaceId),
        isNot(contains('c' * 64)),
      );
      expect((await service.load(spaceId))!.messages, hasLength(5));
    },
  );

  test(
    'Space post comments converge member-to-member without chat notifications',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerService.createSpace(
        'Distributed discussion',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      final chatNotices = <GroupMessage>[];
      final commentNotices = <GroupMessage>[];
      final ownerCommentNotices = <GroupMessage>[];
      final chatSub = bobService.incoming.listen(
        (notice) => chatNotices.add(notice.message),
      );
      final commentSub = bobService.incomingComments.listen(
        (notice) => commentNotices.add(notice.message),
      );
      final ownerCommentSub = ownerService.incomingComments.listen(
        (notice) => ownerCommentNotices.add(notice.message),
      );
      addTearDown(chatSub.cancel);
      addTearDown(commentSub.cancel);
      addTearDown(ownerCommentSub.cancel);

      final root = (await ownerService.publishSpacePost(
        spaceId,
        body: 'Root distributed with its discussion',
        broadcast: false,
      ))!;
      final commentMedia = MediaObject(
        contentId: 'd' * 64,
        kind: 'audio',
        name: 'answer.opus',
        mimeType: 'audio/opus',
        size: 512,
        durationMs: 2400,
      );
      expect(
        await ownerService.commentOnSpacePost(
          spaceId,
          root.postId,
          'Owner comment',
          media: commentMedia,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      await pump();
      expect(chatNotices, isEmpty);
      expect(commentNotices.map((comment) => comment.body), ['Owner comment']);
      expect(
        (await bobService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).single.body,
        'Owner comment',
      );
      expect(
        (await bobService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).single.attachment?.toReferenceJson(),
        commentMedia.toReferenceJson(),
      );
      final ownerComment = (await bobService.spacePostCommentsOf(
        spaceId,
        root.postId,
      )).single;
      expect(
        await bobService.editSpacePostComment(
          spaceId,
          root.postId,
          ownerComment.ref,
          'Member cannot impersonate the owner',
          broadcast: false,
        ),
        isFalse,
      );
      expect(
        await bobService.referencedContentIds(spaceId),
        contains('d' * 64),
      );

      expect(
        await bobService.commentOnSpacePost(
          spaceId,
          root.postId,
          'Member redistribution',
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).map((comment) => comment.body),
        ['Owner comment', 'Member redistribution'],
      );
      final memberComment = (await ownerService.spacePostCommentsOf(
        spaceId,
        root.postId,
      )).last;
      expect(
        await bobService.editSpacePostComment(
          spaceId,
          root.postId,
          memberComment.ref,
          'Member revision',
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      await pump();
      expect(
        (await ownerService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).last.body,
        'Member revision',
      );
      expect(
        commentNotices.map((comment) => comment.body),
        ['Owner comment'],
        reason: 'an edit refreshes state but is not a new-comment notice',
      );
      expect(
        ownerCommentNotices.map((comment) => comment.body),
        ['Member redistribution'],
        reason: 'a remote edit is not emitted as another comment',
      );

      final bobBundle = (await bobService.load(spaceId))!;
      final bobState = (await bobService.stateOf(spaceId))!;
      final bobHead = bobBundle.messages
          .where((message) => message.author == bob)
          .reduce((left, right) => left.seq > right.seq ? left : right);
      final clearWithAttachment = const GroupMessageCleartext(
        body: 'attachment smuggling',
        attachment: GroupAttachment(
          kind: 'file',
          dataB64: 'AQID',
          w: 1,
          h: 1,
          cid: 'must-not-be-referenced',
        ),
      ).encode();
      final createdAt = bobHead.createdAtMs + 1;
      final encryptedWithAttachment = await encryptGroupPayload(
        groupId: spaceId,
        membershipEpoch: bobState.epoch,
        author: bob,
        seq: bobHead.seq + 1,
        prevHash: groupMessageHash(bobHead),
        policyVersion: bobState.policyVersion,
        createdAtMs: createdAt,
        clearText: clearWithAttachment,
        epochKey: bobBundle.localEpochKeys[bobState.epoch]!,
      );
      clearWithAttachment.fillRange(0, clearWithAttachment.length, 0);
      final smuggled = _FakeSigner(bob).signMessage(
        GroupMessage(
          groupId: spaceId,
          author: bob,
          seq: bobHead.seq + 1,
          prevHash: groupMessageHash(bobHead),
          body: '',
          spacePostId: root.postId,
          version: 2,
          membershipEpoch: bobState.epoch,
          encryptedPayload: encryptedWithAttachment,
          policyVersion: bobState.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        ),
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            bobBundle.copyWith(messages: [...bobBundle.messages, smuggled]),
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerService.load(spaceId))!.messages,
        hasLength(3),
        reason: 'legacy inline comment media is rejected after AEAD open',
      );
      expect(
        await ownerService.referencedContentIds(spaceId),
        isNot(contains('must-not-be-referenced')),
      );
    },
  );

  test(
    'Space post revisions preserve root cursor and tombstones revoke feed media',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Editable updates',
        visibility: SpaceVisibility.public,
      );
      final root = (await svc.publishSpacePost(
        spaceId,
        title: 'Original',
        body: 'first body',
        type: SpacePostType.article,
        media: [MediaObjectRef(contentId: 'a' * 64, kind: 'image')],
        broadcast: false,
      ))!;
      await svc.publishSpacePost(
        spaceId,
        body: 'second root',
        broadcast: false,
      );
      final rootCursor = SpaceFeedCursor.fromPost(root);

      final edited = await svc.editSpacePost(
        spaceId,
        root.postId,
        title: 'Corrected',
        body: 'revised body',
        type: SpacePostType.post,
        media: [MediaObjectRef(contentId: 'b' * 64, kind: 'image')],
        broadcast: false,
      );
      expect(edited, isNotNull);
      expect(edited!.postId, root.postId);
      expect(edited.revisionId, isNot(root.postId));
      expect(edited.edited, isTrue);
      expect(edited.title, 'Corrected');
      expect(edited.body, 'revised body');
      expect(edited.type, SpacePostType.post);
      expect(SpaceFeedCursor.fromView(edited).compareTo(rootCursor), 0);
      expect(await svc.postsOf(spaceId), hasLength(2));
      expect(await svc.referencedContentIds(spaceId), {'b' * 64});
      final afterEdit = (await svc.load(spaceId))!;
      expect(afterEdit.posts, hasLength(3));
      expect(afterEdit.posts.last.version, 7);
      expect(afterEdit.posts.last.operation, SpacePostOperation.edit);
      expect(afterEdit.posts.last.targetSeq, root.seq);

      expect(
        await svc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isTrue,
      );
      expect(await svc.spacePostReactionsOf(spaceId), isEmpty);
      expect(await svc.reactToSpacePost(spaceId, root.postId, '👍'), isFalse);
      final remaining = await svc.postsOf(spaceId);
      expect(remaining, hasLength(1));
      expect(remaining.single.body, 'second root');
      expect(await svc.referencedContentIds(spaceId), isEmpty);
      final afterDelete = (await svc.load(spaceId))!;
      expect(afterDelete.posts.last.operation, SpacePostOperation.delete);
      expect(afterDelete.posts.last.title, isEmpty);
      expect(afterDelete.posts.last.body, isEmpty);
      expect(
        await svc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isFalse,
      );
      expect(
        await svc.editSpacePost(
          spaceId,
          root.postId,
          title: 'resurrect',
          body: 'must fail',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await svc.editSpacePost(
          spaceId,
          '${bob.hex}:0',
          title: 'forged',
          body: 'other author',
          broadcast: false,
        ),
        isNull,
      );
    },
  );

  test(
    'private Space post revisions stay ciphertext-only and converge by snapshot',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerSvc.createSpace('Private revisions');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final root = (await ownerSvc.publishSpacePost(
        spaceId,
        body: 'private original',
        broadcast: false,
      ))!;
      final edit = await ownerSvc.editSpacePost(
        spaceId,
        root.postId,
        title: '',
        body: 'private revision',
        broadcast: false,
      );
      expect(edit, isNotNull);
      final ownerBundle = (await ownerSvc.load(spaceId))!;
      final wireEdit = ownerBundle.posts.last;
      expect(wireEdit.version, 8);
      expect(wireEdit.operation, SpacePostOperation.edit);
      expect(wireEdit.isEncrypted, isTrue);
      expect(wireEdit.title, isEmpty);
      expect(wireEdit.body, isEmpty);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(ownerBundle, recipient: bob),
        ),
        isTrue,
      );
      final bobView = (await bobSvc.postsOf(spaceId)).single;
      expect(bobView.postId, root.postId);
      expect(bobView.body, 'private revision');
      expect(bobView.edited, isTrue);
      expect(
        await bobSvc.reactToSpacePost(
          spaceId,
          root.postId,
          '❤',
          broadcast: false,
        ),
        isTrue,
      );
      final bobReactionBundle = (await bobSvc.load(spaceId))!;
      final wireReaction = bobReactionBundle.reactions.single;
      expect(wireReaction.version, 4);
      expect(wireReaction.isEncrypted, isTrue);
      expect(wireReaction.target, isEmpty);
      expect(wireReaction.emoji, isEmpty);
      expect(jsonEncode(wireReaction.toJson()), isNot(contains(root.postId)));
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson(bobReactionBundle, recipient: owner),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.spacePostReactionsOf(spaceId))[root.postId]?['❤'],
        [bob],
      );

      expect(
        await ownerSvc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isTrue,
      );
      final deletedBundle = (await ownerSvc.load(spaceId))!;
      expect(deletedBundle.posts.last.version, 8);
      expect(deletedBundle.posts.last.encryptedPayload, isNotNull);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(deletedBundle, recipient: bob),
        ),
        isTrue,
      );
      expect(await bobSvc.postsOf(spaceId), isEmpty);
    },
  );

  test(
    'invalid edit-of-edit suffix is retained as evidence but never extended',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Revision topology',
        visibility: SpaceVisibility.public,
      );
      final root = (await svc.publishSpacePost(
        spaceId,
        body: 'root',
        broadcast: false,
      ))!;
      expect(
        await svc.editSpacePost(
          spaceId,
          root.postId,
          title: '',
          body: 'valid edit',
          broadcast: false,
        ),
        isNotNull,
      );
      final before = (await svc.load(spaceId))!;
      final previous = before.posts.last;
      final bad = _FakeSigner(owner).signPost(
        SpacePost(
          spaceId: spaceId,
          author: owner,
          seq: previous.seq + 1,
          prevHash: sha256.convert([
            ...previous.canonicalBytes(),
            ...previous.signature,
          ]).toString(),
          type: SpacePostType.post,
          visibility: SpacePostVisibility.public,
          title: '',
          body: 'must not apply',
          policyVersion: previous.policyVersion,
          createdAtMs: previous.createdAtMs + 1,
          publishedAtMs: previous.publishedAtMs + 1,
          version: 7,
          controlCheckpointHash: previous.controlCheckpointHash,
          operation: SpacePostOperation.edit,
          targetSeq: previous.seq,
          signature: Uint8List(0),
        ),
      );
      expect(bad.isStructurallyValid, isTrue);
      expect(
        await svc.ingestSnapshot(
          jsonEncode({
            'm': before.manifest.toJson(),
            'c': const [],
            'g': const [],
            'r': const [],
            'p': [bad.toJson()],
          }),
        ),
        isTrue,
      );
      expect((await svc.load(spaceId))!.posts, hasLength(3));
      expect((await svc.postsOf(spaceId)).single.body, 'valid edit');
      expect(
        await svc.publishSpacePost(
          spaceId,
          body: 'must not extend invalid topology',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await svc.editSpacePost(
          spaceId,
          root.postId,
          title: '',
          body: 'also blocked',
          broadcast: false,
        ),
        isNull,
      );
    },
  );

  test(
    'Space post edit and tombstone deltas converge through member P2P relay',
    () async {
      final toBob = <String>[];
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async {
          if (peer == bob) toBob.add(json);
        },
      );
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      final incomingPosts = <SpacePostView>[];
      final incomingPostSub = bobSvc.incomingPosts.listen(
        (notice) => incomingPosts.add(notice.post),
      );
      addTearDown(incomingPostSub.cancel);
      final spaceId = await ownerSvc.createSpace(
        'Relayed revisions',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      toBob.clear();
      final root = (await ownerSvc.publishSpacePost(
        spaceId,
        body: 'relayed original',
      ))!;
      await pump();
      expect(toBob, isNotEmpty);
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect((await bobSvc.postsOf(spaceId)).single.body, 'relayed original');
      expect(incomingPosts.map((post) => post.body), ['relayed original']);

      toBob.clear();
      expect(
        await ownerSvc.editSpacePost(
          spaceId,
          root.postId,
          title: '',
          body: 'relayed correction',
        ),
        isNotNull,
      );
      await pump();
      final editDelta = jsonDecode(toBob.last) as Map;
      expect(editDelta['p'], hasLength(1));
      expect((editDelta['p'] as List).single['op'], 'edit');
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect((await bobSvc.postsOf(spaceId)).single.body, 'relayed correction');
      expect(incomingPosts, hasLength(1), reason: 'edits do not alert again');

      toBob.clear();
      expect(await ownerSvc.deleteSpacePost(spaceId, root.postId), isTrue);
      await pump();
      final deleteDelta = jsonDecode(toBob.last) as Map;
      expect(deleteDelta['p'], hasLength(1));
      expect((deleteDelta['p'] as List).single['op'], 'delete');
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      expect(incomingPosts, hasLength(1), reason: 'deletions never alert');
    },
  );

  test(
    'feed dismissals stay local, survive edits/reopen and serialize across Spaces',
    () async {
      final (service, reopen) = await setup();
      final firstSpace = await service.createSpace(
        'One',
        visibility: SpaceVisibility.public,
      );
      final secondSpace = await service.createSpace(
        'Two',
        visibility: SpaceVisibility.public,
      );
      final first = (await service.publishSpacePost(
        firstSpace,
        body: 'first',
        broadcast: false,
      ))!;
      final second = (await service.publishSpacePost(
        secondSpace,
        body: 'second',
        broadcast: false,
      ))!;

      await Future.wait([
        service.setSpaceFeedPostHidden(firstSpace, first.postId, true),
        service.setSpaceFeedPostHidden(secondSpace, second.postId, true),
      ]);
      expect(await service.spaceFeed(), isEmpty);
      expect(await service.postsOf(firstSpace), hasLength(1));
      expect(await service.postsOf(secondSpace), hasLength(1));

      final edited = await service.editSpacePost(
        firstSpace,
        first.postId,
        title: '',
        body: 'edited while hidden',
        broadcast: false,
      );
      expect(edited?.postId, first.postId);
      expect(await service.spaceFeed(), isEmpty);

      final reopened = reopen(owner) as GroupService;
      expect(
        await reopened.isSpaceFeedPostHidden(firstSpace, first.postId),
        isTrue,
      );
      expect(await reopened.spaceFeed(), isEmpty);
      await Future.wait([
        reopened.setSpaceFeedPostHidden(firstSpace, first.postId, false),
        reopened.setSpaceFeedPostHidden(secondSpace, second.postId, false),
      ]);
      final restored = await reopened.spaceFeed();
      expect(restored, hasLength(2));
      expect(
        restored.singleWhere((item) => item.spaceId == firstSpace).post.body,
        'edited while hidden',
      );
    },
  );

  test(
    'feed type filter is identity-local, survives reopen and keeps Space posts',
    () async {
      final (service, reopen) = await setup();
      final spaceId = await service.createSpace(
        'Mixed media',
        visibility: SpaceVisibility.public,
      );
      await service.publishSpacePost(
        spaceId,
        body: 'plain update',
        broadcast: false,
      );
      await service.publishSpacePost(
        spaceId,
        body: 'long read',
        type: SpacePostType.article,
        broadcast: false,
      );

      expect(await service.spaceFeed(), hasLength(2));
      await service.setSpaceFeedTypeFilter({SpacePostType.article});
      expect(await service.spaceFeedTypeFilter(), {SpacePostType.article});
      expect((await service.spaceFeed()).single.post.body, 'long read');
      expect(await service.postsOf(spaceId), hasLength(2));

      final reopened = reopen(owner) as GroupService;
      expect(await reopened.spaceFeedTypeFilter(), {SpacePostType.article});
      expect(
        (await reopened.spaceFeed()).single.post.type,
        SpacePostType.article,
      );
      expect(
        await reopened.spaceFeed(types: {SpacePostType.post}),
        hasLength(1),
        reason: 'an explicit service-level filter remains an override',
      );

      await reopened.setSpaceFeedTypeFilter({});
      expect(
        await reopened.spaceFeedTypeFilter(),
        SpacePostType.values.toSet(),
      );
      expect(await reopened.spaceFeed(), hasLength(2));
    },
  );

  test(
    'hidden feed registry crosses the single-setting limit safely',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final spaceId = await service.createSpace(
        'Busy feed',
        visibility: SpaceVisibility.public,
      );
      final postIds = <String>[];
      for (var index = 0; index < 40; index++) {
        final post = await service.publishSpacePost(
          spaceId,
          body: 'publication $index',
          broadcast: false,
        );
        postIds.add(post!.postId);
      }

      await Future.wait([
        for (final postId in postIds)
          service.setSpaceFeedPostHidden(spaceId, postId, true),
      ]);
      final persisted = await storage.loadFile('space.feed.hidden.v1');
      expect(persisted, isNotNull);
      expect(
        persisted!.length,
        greaterThan(4096),
        reason: 'the registry must use chunked file storage, not putSetting',
      );
      expect(await service.spaceFeed(), isEmpty);
      expect(await service.postsOf(spaceId), hasLength(40));
    },
  );

  test(
    'checkpointed posts scale past 256 state-mutating control authors',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Large causal space',
        visibility: SpaceVisibility.public,
      );
      final base = (await svc.load(spaceId))!;
      final control = [...base.control];
      final accepted = foldControlLog(
        owner: base.manifest.owner,
        entries: control,
        verify: (_) => true,
        initialName: base.manifest.name,
      ).accepted;
      var ownerHead = accepted.where((entry) => entry.author == owner).last;
      var timestamp =
          control
              .map((entry) => entry.createdAtMs)
              .fold<int>(0, (left, right) => left > right ? left : right) +
          1;
      final admins = [
        for (var index = 0; index < kSpaceControlFrontierMax + 1; index++)
          _ordinalId(100 + index),
      ];
      for (final admin in admins) {
        final entry = _FakeSigner(owner).signControl(
          ControlEntry(
            version: 2,
            groupId: spaceId,
            author: owner,
            seq: ownerHead.seq + 1,
            prevHash: controlEntryHash(ownerHead),
            op: ControlOp.addMember,
            target: admin,
            role: GroupRole.admin,
            policyVersion: 0,
            createdAtMs: timestamp++,
            signature: Uint8List(0),
          ),
        );
        control.add(entry);
        ownerHead = entry;
      }
      for (var index = 0; index < admins.length; index++) {
        control.add(
          _FakeSigner(admins[index]).signControl(
            ControlEntry(
              version: 2,
              groupId: spaceId,
              author: admins[index],
              seq: 0,
              prevHash: '',
              op: ControlOp.addMember,
              target: _ordinalId(1000 + index),
              role: GroupRole.member,
              policyVersion: 0,
              createdAtMs: timestamp++,
              signature: Uint8List(0),
            ),
          ),
        );
      }
      expect(
        await svc.ingestSnapshot(
          jsonEncode({
            'm': base.manifest.toJson(),
            'c': [for (final entry in control) entry.toJson()],
            'g': const [],
            'r': const [],
          }),
        ),
        isTrue,
      );

      final post = await svc.publishSpacePost(
        spaceId,
        body: 'constant-size publication frontier',
        broadcast: false,
      );
      expect(post, isNotNull);
      expect(post!.version, 5);
      expect(post.controlCheckpointHash, hasLength(64));
      expect(post.canonicalBytes().length, lessThan(2048));
      final stored = (await svc.load(spaceId))!;
      final checkpoint = stored.control.lastWhere(
        (entry) =>
            entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == post.controlCheckpointHash,
      );
      expect(
        checkpoint.controlCheckpoint!.heads.length,
        greaterThan(kSpaceControlFrontierMax),
      );
      expect(
        (await svc.postsOf(spaceId)).single.body,
        contains('constant-size'),
      );
    },
  );

  test(
    'checkpoint control fork quarantines dependent posts fail-closed',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Checkpoint fork',
        visibility: SpaceVisibility.public,
      );
      final post = await svc.publishSpacePost(
        spaceId,
        body: 'must disappear with forked authority',
        broadcast: false,
      );
      expect(post, isNotNull);
      final before = (await svc.load(spaceId))!;
      final checkpoint = before.control.singleWhere(
        (entry) => controlEntryHash(entry) == post!.controlCheckpointHash,
      );
      final fork = _FakeSigner(owner).signControl(
        ControlEntry(
          version: 4,
          groupId: spaceId,
          author: checkpoint.author,
          seq: checkpoint.seq,
          prevHash: checkpoint.prevHash,
          op: ControlOp.checkpoint,
          target: null,
          role: null,
          controlCheckpoint: SpaceControlCheckpoint(const []),
          policyVersion: checkpoint.policyVersion,
          createdAtMs: checkpoint.createdAtMs + 1,
          signature: Uint8List(0),
        ),
      );
      expect(
        await svc.ingestSnapshot(
          jsonEncode({
            'm': before.manifest.toJson(),
            'c': [fork.toJson()],
            'g': const [],
            'r': const [],
          }),
        ),
        isTrue,
      );
      expect((await svc.load(spaceId))!.posts, hasLength(1));
      expect(await svc.postsOf(spaceId), isEmpty);
      expect(
        await svc.publishSpacePost(
          spaceId,
          body: 'cannot extend forked control history',
          broadcast: false,
        ),
        isNull,
      );
      await svc.compactStateLogs(spaceId);
      final retained = (await svc.load(spaceId))!.control.where(
        (entry) =>
            entry.author == checkpoint.author && entry.seq == checkpoint.seq,
      );
      expect(retained, hasLength(2));
    },
  );

  test('private Space posts stay epoch-encrypted on disk and wire', () async {
    final ownerStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    final spaceId = await ownerSvc.createSpace('Private updates');
    expect(
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(
      await ownerSvc.publishSpacePost(
        spaceId,
        title: 'Members',
        body: 'ciphertext on the wire',
        broadcast: false,
      ),
      isNotNull,
    );
    final ownerBundle = (await ownerSvc.load(spaceId))!;
    final stored = ownerBundle.posts.single;
    expect(stored.isEncrypted, isTrue);
    expect(stored.version, 6);
    expect(stored.controlFrontier, isNull);
    expect(stored.controlCheckpointHash, isNotNull);
    expect(stored.title, isEmpty);
    expect(stored.body, isEmpty);
    final wire = ownerSvc.snapshotJson(ownerBundle, recipient: bob);
    expect(wire, isNot(contains('ciphertext on the wire')));
    expect(wire, isNot(contains('Members')));
    expect((jsonDecode(wire) as Map)['p'], hasLength(1));

    final bobStorage = FakeHvContainer().storage();
    await bobStorage.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    expect(await bobSvc.ingestSnapshot(wire), isTrue);
    expect((await bobSvc.load(spaceId))!.posts, hasLength(1));
    final visible = await bobSvc.postsOf(spaceId);
    expect(visible.single.title, 'Members');
    expect(visible.single.body, 'ciphertext on the wire');
    expect(await bobSvc.unreadSpacePosts(spaceId), 1);
    await bobSvc.setSpaceFeedEnabled(spaceId, false);
    expect(await bobSvc.spaceFeed(), isEmpty);
    expect(
      await bobSvc.unreadSpacePosts(spaceId),
      1,
      reason: 'combined Feed and per-Space unread are independent',
    );
    await bobSvc.setSpaceFeedPostHidden(spaceId, visible.single.postId, true);
    expect(await bobSvc.unreadSpacePosts(spaceId), 0);
    expect(await bobSvc.postsOf(spaceId), hasLength(1));
    await bobSvc.setSpaceFeedPostHidden(spaceId, visible.single.postId, false);
    expect(await bobSvc.unreadSpacePosts(spaceId), 1);
    await bobSvc.markSpaceFeedSeen(spaceId);
    expect(await bobSvc.unreadSpacePosts(spaceId), 0);
  });

  test(
    'Space post gap-fill uses the contiguous chain and heals a lost prefix',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final toBob = <String>[];
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async {
          if (peer == bob) toBob.add(json);
        },
      );
      final spaceId = await ownerSvc.createSpace(
        'Public replication',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      toBob.clear();
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'lost seq zero',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.publishSpacePost(spaceId, body: 'received seq one'),
        isNotNull,
      );
      await pump();
      final delta = jsonDecode(toBob.last) as Map;
      expect(delta['p'], hasLength(1));
      expect((delta['p'] as List).single['seq'], 1);
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect((await bobSvc.load(spaceId))!.posts, isEmpty);
      expect(
        await bobSvc.postsOf(spaceId),
        isEmpty,
        reason: 'a post without its signed checkpoint is not admitted',
      );

      final request = (await bobSvc.buildGroupSyncRequest(spaceId))!;
      expect(request['p'], isEmpty);
      toBob.clear();
      expect(await ownerSvc.handleGroupSyncRequest(bob, request), isTrue);
      final repair = jsonDecode(toBob.single) as Map;
      expect(repair['c'], hasLength(1));
      expect(repair['p'], hasLength(2));
      expect(await bobSvc.ingestSnapshot(toBob.single), isTrue);
      expect((await bobSvc.postsOf(spaceId)).map((post) => post.body), [
        'lost seq zero',
        'received seq one',
      ]);
    },
  );

  test(
    'same-seq Space post equivocation quarantines both branches independent of arrival order',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerSvc.createSpace(
        'Fork convergence',
        visibility: SpaceVisibility.public,
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
      final base = (await ownerSvc.load(spaceId))!;
      final original = (await ownerSvc.publishSpacePost(
        spaceId,
        body: 'branch A',
        broadcast: false,
      ))!;
      final fork = _FakeSigner(owner).signPost(
        SpacePost(
          spaceId: original.spaceId,
          author: original.author,
          seq: original.seq,
          prevHash: original.prevHash,
          type: original.type,
          visibility: original.visibility,
          title: original.title,
          body: 'branch B',
          policyVersion: original.policyVersion,
          createdAtMs: original.createdAtMs,
          publishedAtMs: original.publishedAtMs,
          version: original.version,
          controlFrontier: original.controlFrontier,
          controlCheckpointHash: original.controlCheckpointHash,
          signature: Uint8List(0),
        ),
      );
      final checkpoint = (await ownerSvc.load(spaceId))!.control.lastWhere(
        (entry) =>
            entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == original.controlCheckpointHash,
      );
      String delta(SpacePost post) => jsonEncode({
        'm': base.manifest.toJson(),
        'c': [checkpoint.toJson()],
        'g': const [],
        'r': const [],
        'p': [post.toJson()],
      });

      Future<GroupService> replica(NodeId self) async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final service = GroupService(storage, _FakeSigner(self));
        expect(
          await service.ingestSnapshot(
            ownerSvc.snapshotJson(base, recipient: self),
          ),
          isTrue,
        );
        return service;
      }

      final bobSvc = await replica(bob);
      final carolSvc = await replica(carol);
      expect(await bobSvc.ingestSnapshot(delta(original)), isTrue);
      expect(await bobSvc.ingestSnapshot(delta(fork)), isTrue);
      expect(await carolSvc.ingestSnapshot(delta(fork)), isTrue);
      expect(await carolSvc.ingestSnapshot(delta(original)), isTrue);
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      expect(await carolSvc.postsOf(spaceId), isEmpty);
      expect((await bobSvc.load(spaceId))!.posts, hasLength(2));
      expect((await carolSvc.load(spaceId))!.posts, hasLength(2));
      await bobSvc.compactStateLogs(spaceId);
      expect((await bobSvc.load(spaceId))!.posts, hasLength(2));
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      expect((await bobSvc.buildGroupSyncRequest(spaceId))!['p'], isEmpty);
      expect((await carolSvc.buildGroupSyncRequest(spaceId))!['p'], isEmpty);
    },
  );

  test(
    'causal Space posts survive mute boundary and resume after a new grant',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerSvc.createSpace(
        'Causal publications',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final before = await bobSvc.publishSpacePost(
        spaceId,
        body: 'published before mute',
        broadcast: false,
      );
      expect(before, isNotNull);
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );

      expect(
        await ownerSvc.addControlOp(spaceId, ControlOp.mute, target: bob),
        isTrue,
      );
      final mutedBundle = (await ownerSvc.load(spaceId))!;
      final mute = mutedBundle.control.lastWhere(
        (entry) => entry.op == ControlOp.mute && entry.target == bob,
      );
      expect(mute.postBoundary?.seq, 0);
      expect(mute.postBoundary?.hash, isNotEmpty);
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'published before mute',
      ]);

      expect(
        await ownerSvc.addControlOp(spaceId, ControlOp.unmute, target: bob),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final after = await bobSvc.publishSpacePost(
        spaceId,
        body: 'published after unmute',
        broadcast: false,
      );
      expect(after, isNotNull);
      final afterPost = after!;
      final beforePost = before!;
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'published before mute',
        'published after unmute',
      ]);

      // This row is chained after the new publication but deliberately carries
      // the pre-mute authorization frontier. It may be retained for evidence,
      // but the signed seq-0 boundary keeps it out of every reader/feed.
      final lateOldGrant = _FakeSigner(bob).signPost(
        SpacePost(
          spaceId: spaceId,
          author: bob,
          seq: 2,
          prevHash: sha256.convert([
            ...afterPost.canonicalBytes(),
            ...afterPost.signature,
          ]).toString(),
          type: SpacePostType.post,
          visibility: SpacePostVisibility.public,
          title: '',
          body: 'stale authority',
          policyVersion: beforePost.policyVersion,
          createdAtMs: afterPost.createdAtMs + 1,
          publishedAtMs: afterPost.publishedAtMs + 1,
          version: beforePost.version,
          controlFrontier: beforePost.controlFrontier,
          controlCheckpointHash: beforePost.controlCheckpointHash,
          signature: Uint8List(0),
        ),
      );
      final current = (await ownerSvc.load(spaceId))!;
      expect(
        await ownerSvc.ingestSnapshot(
          jsonEncode({
            'm': current.manifest.toJson(),
            'c': const [],
            'g': const [],
            'r': const [],
            'p': [lateOldGrant.toJson()],
          }),
        ),
        isTrue,
      );
      expect((await ownerSvc.load(spaceId))!.posts, hasLength(3));
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'published before mute',
        'published after unmute',
      ]);
    },
  );

  test(
    'legacy revocation without a boundary hides causal history fail-closed',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerSvc.createSpace(
        'Legacy revoke migration',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
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
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'cannot be proven across a legacy revoke',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      final beforeMute = (await ownerSvc.load(spaceId))!;
      expect(
        await ownerSvc.addControlOp(spaceId, ControlOp.mute, target: bob),
        isTrue,
      );
      final v3Mute = (await ownerSvc.load(spaceId))!.control.last;
      final legacyMute = _FakeSigner(owner).signControl(
        ControlEntry(
          version: 2,
          groupId: spaceId,
          author: v3Mute.author,
          seq: v3Mute.seq,
          prevHash: v3Mute.prevHash,
          op: v3Mute.op,
          target: v3Mute.target,
          role: v3Mute.role,
          policyVersion: v3Mute.policyVersion,
          createdAtMs: v3Mute.createdAtMs,
          signature: Uint8List(0),
        ),
      );

      final replicaStorage = FakeHvContainer().storage();
      await replicaStorage.open(password: 'pw', createIfMissing: true);
      final replica = GroupService(replicaStorage, _FakeSigner(owner));
      expect(
        await replica.ingestSnapshot(
          ownerSvc.snapshotJson(beforeMute, recipient: owner),
        ),
        isTrue,
      );
      expect(
        await replica.ingestSnapshot(
          jsonEncode({
            'm': beforeMute.manifest.toJson(),
            'c': [legacyMute.toJson()],
            'g': const [],
            'r': const [],
            'p': const [],
          }),
        ),
        isTrue,
      );
      expect((await replica.stateOf(spaceId))!.memberOf(bob)?.muted, isTrue);
      expect(await replica.postsOf(spaceId), isEmpty);
    },
  );

  test(
    'protected text channel hides metadata, distributes through holders and revokes by epoch',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerSvc.createSpace('Scoped');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.createChannel(
          spaceId,
          name: 'not-yet-indistinguishable',
          kind: SpaceChannelKind.text,
          access: SpaceChannelAccess.secret,
          members: [bob],
        ),
        isNull,
        reason: 'secret stays fail-closed while opaque update cadence leaks',
      );
      final channelId = await ownerSvc.createChannel(
        spaceId,
        name: 'incident-room-plaintext-must-never-leak',
        description: 'sensitive metadata',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(channelId, isNotNull);
      final ownerBundle = (await ownerSvc.load(spaceId))!;
      final outer = jsonEncode(ownerBundle.control.last.toJson());
      expect(outer, isNot(contains('incident-room-plaintext-must-never-leak')));
      expect(outer, isNot(contains('sensitive metadata')));
      expect(outer, isNot(contains(bob.hex)));
      expect(ownerBundle.control.last.version, 5);
      expect(ownerBundle.control.last.channel, isNull);

      final bobWire = ownerSvc.snapshotJson(ownerBundle, recipient: bob);
      final bobWireJson = jsonDecode(bobWire) as Map;
      expect((bobWireJson['cke'] as List), hasLength(2));
      final outsiderWire =
          jsonDecode(ownerSvc.snapshotJson(ownerBundle, recipient: carol))
              as Map;
      expect(outsiderWire['cke'], isNull);
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(await bobSvc.ingestSnapshot(bobWire), isTrue);
      expect(
        (await bobSvc.channelsOf(
          spaceId,
        )).singleWhere((channel) => channel.channelId == channelId).access,
        SpaceChannelAccess.restricted,
      );
      expect(
        (await bobSvc.load(spaceId))!.channelEpochEnvelopes,
        hasLength(2),
        reason: 'an authorized holder retains every sealed recipient record',
      );
      expect(
        await bobSvc.postMessage(
          spaceId,
          'channel-key ciphertext',
          channelId: channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.postMessage(
          spaceId,
          'media stays closed',
          channelId: channelId,
          attachment: const GroupAttachment(
            kind: 'file',
            dataB64: 'QQ==',
            w: 1,
            h: 1,
            cid: 'must-not-serve',
          ),
          broadcast: false,
        ),
        isFalse,
      );
      final bobBundle = (await bobSvc.load(spaceId))!;
      final storedMessage = bobBundle.messages.single;
      expect(storedMessage.version, 3);
      expect(storedMessage.isChannelEncrypted, isTrue);
      expect(
        jsonEncode(storedMessage.toJson()),
        isNot(contains('channel-key ciphertext')),
      );
      final syncVector = (await bobSvc.buildGroupSyncRequest(spaceId))!;
      expect((syncVector['g'] as Map)[bob.hex], isNull);
      final protectedHead =
          ((syncVector['cg'] as Map)['${channelId!.hex}|channelEpoch:1']
                  as Map)[bob.hex]
              as Map;
      expect(protectedHead['s'], 0);
      expect(protectedHead['h'], groupMessageHash(storedMessage));
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson(bobBundle, recipient: owner),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.messagesOf(spaceId, channelId: channelId)).single.body,
        'channel-key ciphertext',
      );
      expect(
        await ownerSvc.setChannelMembers(spaceId, channelId, const []),
        isTrue,
      );
      expect(
        (await ownerSvc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        2,
      );
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
        (await bobSvc.channelsOf(
          spaceId,
        )).where((channel) => channel.channelId == channelId),
        isEmpty,
      );
      expect(
        await bobSvc.postMessage(
          spaceId,
          'stale key write',
          channelId: channelId,
          broadcast: false,
        ),
        isFalse,
      );
    },
  );

  test(
    'Space moderation is signed and reversible without changing group chats',
    () async {
      final (ownerSvc, member) = await setup();
      final bobSvc = member(bob);
      final groupId = await ownerSvc.createGroup('Friends chat');

      expect(
        await ownerSvc.moderateSpace(
          groupId,
          kind: SpaceModerationKind.warning,
          target: owner,
          scope: SpaceModerationScope.space,
          reason: 'must remain a group chat',
        ),
        isNull,
      );
      expect((await ownerSvc.load(groupId))!.manifest.isSpace, isFalse);
      expect(
        (await ownerSvc.listGroups()).map((entry) => entry.groupId),
        contains(groupId),
      );
      expect(
        (await ownerSvc.listSpaces()).map((entry) => entry.groupId),
        isNot(contains(groupId)),
      );

      final spaceId = await ownerSvc.createSpace(
        'Builders',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(await bobSvc.postMessage(spaceId, 'before restriction'), isTrue);

      final actionId = await ownerSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.restrictMessages,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'cool-down',
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
      );
      expect(actionId, isNotNull);
      expect(await bobSvc.postMessage(spaceId, 'blocked'), isFalse);
      final audit = await ownerSvc.spaceModerationAudit(spaceId);
      expect(audit, hasLength(1));
      expect(audit.single.actionId, actionId);
      expect(audit.single.action.reason, 'cool-down');

      expect(
        await ownerSvc.revokeSpaceModeration(
          spaceId,
          actionId!,
          reason: 'review complete',
        ),
        isTrue,
      );
      expect(await bobSvc.postMessage(spaceId, 'after review'), isTrue);
      final revoked = (await ownerSvc.spaceModerationAudit(spaceId)).single;
      expect(revoked.revokedBy, owner);
      expect(revoked.revocationReason, 'review complete');
      expect(
        (await ownerSvc.listSpaces()).map((entry) => entry.groupId),
        contains(spaceId),
      );
      expect(
        (await ownerSvc.listGroups()).map((entry) => entry.groupId),
        isNot(contains(spaceId)),
      );
    },
  );

  test(
    'owner-signed Space lifecycle preserves history and starts a fresh content generation',
    () async {
      final (ownerSvc, member) = await setup();
      final bobSvc = member(bob);
      final groupId = await ownerSvc.createGroup('Friends remain a group chat');
      expect(await ownerSvc.setSpaceArchived(groupId, true), isFalse);
      expect(await ownerSvc.deleteSpace(groupId), isFalse);

      final spaceId = await ownerSvc.createSpace(
        'Archive lab',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final defaultChannel = (await ownerSvc.channelsOf(spaceId)).single;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'before archive',
          channelId: defaultChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'publication before archive',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.react(spaceId, '${owner.hex}:0', '👍', broadcast: false),
        isTrue,
      );

      expect(await bobSvc.setSpaceArchived(spaceId, true), isFalse);
      expect(await ownerSvc.setSpaceArchived(spaceId, true), isTrue);
      var state = (await ownerSvc.stateOf(spaceId))!;
      expect(state.lifecycleState, SpaceLifecycleState.archived);
      expect(state.lifecycleTransitionHash, hasLength(64));
      expect(state.lifecycleTransition!.messageHeads, hasLength(1));
      expect(state.lifecycleTransition!.postHeads, hasLength(1));
      expect(state.lifecycleTransition!.reactionHeads, hasLength(1));
      expect(
        jsonEncode(state.lifecycleTransition!.toJson()),
        isNot(contains(defaultChannel.channelId.hex)),
        reason: 'the global lifecycle record exposes only hashed scopes',
      );
      expect(
        (await ownerSvc.messagesOf(spaceId)).map((message) => message.body),
        ['before archive'],
      );
      expect((await ownerSvc.postsOf(spaceId)).single.body, contains('before'));
      expect((await ownerSvc.reactionsOf(spaceId))['${owner.hex}:0']?['👍'], [
        owner,
      ]);

      expect(
        await ownerSvc.postMessage(
          spaceId,
          'blocked',
          channelId: defaultChannel.channelId,
          broadcast: false,
        ),
        isFalse,
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'blocked',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await ownerSvc.react(spaceId, '${owner.hex}:0', '👍', broadcast: false),
        isFalse,
      );
      expect(
        await ownerSvc.createChannel(
          spaceId,
          name: 'blocked',
          kind: SpaceChannelKind.text,
        ),
        isNull,
      );
      expect(await ownerSvc.setSpaceDescription(spaceId, 'blocked'), isFalse);

      expect(await bobSvc.setSpaceArchived(spaceId, false), isFalse);
      expect(await ownerSvc.setSpaceArchived(spaceId, false), isTrue);
      state = (await ownerSvc.stateOf(spaceId))!;
      expect(state.lifecycleState, SpaceLifecycleState.active);
      final generation = state.lifecycleTransitionHash;
      expect(generation, hasLength(64));
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'after restore',
          channelId: defaultChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'publication after restore',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.react(spaceId, '${owner.hex}:0', '❤️', broadcast: false),
        isTrue,
      );
      final bundle = (await ownerSvc.load(spaceId))!;
      expect(bundle.messages.last.lifecycleGeneration, generation);
      expect(bundle.posts.last.lifecycleGeneration, generation);
      expect(bundle.reactions.last.lifecycleGeneration, generation);
      expect((await ownerSvc.messagesOf(spaceId)).map((m) => m.body), [
        'before archive',
        'after restore',
      ]);
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'publication before archive',
        'publication after restore',
      ]);
    },
  );

  test(
    'recoverable Space deletion hides content, purges idempotently, and resists stale snapshots',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final recoveryStorage = FakeHvContainer().storage();
      await recoveryStorage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final recoveryService = GroupService(recoveryStorage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(recoveryService.dispose);

      final spaceId = await service.createSpace(
        'Recoverable deletion',
        visibility: SpaceVisibility.public,
      );
      final channel = (await service.channelsOf(spaceId)).single;
      expect(
        await service.postMessage(
          spaceId,
          'retained until purge',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.publishSpacePost(
          spaceId,
          body: 'recoverable publication',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await recoveryService.ingestSnapshot(
          service.snapshotJson(
            (await service.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );

      expect(
        await service.deleteSpace(
          spaceId,
          recoveryPeriod: const Duration(minutes: 1),
        ),
        isTrue,
      );
      final deletedBundle = (await service.load(spaceId))!;
      final deletedState = (await service.stateOf(spaceId))!;
      final deadline = deletedState.lifecycleTransition!.recoveryDeadlineMs!;
      expect(deletedState.lifecycleState, SpaceLifecycleState.deleted);
      expect(deletedBundle.control.last.version, 11);
      expect(deletedBundle.control.last.op, ControlOp.deleteSpace);
      expect(await service.channelsOf(spaceId), isEmpty);
      expect(await service.messagesOf(spaceId), isEmpty);
      expect(await service.postsOf(spaceId), isEmpty);
      expect(await service.reactionsOf(spaceId), isEmpty);
      expect(
        (await service.listSpaces()).single.lifecycleState,
        SpaceLifecycleState.deleted,
      );
      expect(
        await service.postMessage(
          spaceId,
          'blocked while deleted',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isFalse,
      );

      final deletedSnapshot = service.snapshotJson(
        deletedBundle,
        recipient: owner,
      );
      final deletedWire = jsonDecode(deletedSnapshot) as Map<String, dynamic>;
      expect(deletedWire['g'], isEmpty);
      expect(deletedWire['p'], isEmpty);
      expect(deletedWire['r'], isEmpty);
      expect(deletedWire, isNot(contains('ke')));
      expect(await recoveryService.ingestSnapshot(deletedSnapshot), isTrue);
      expect(await recoveryService.restoreSpace(spaceId), isTrue);
      final restoredSnapshot = recoveryService.snapshotJson(
        (await recoveryService.load(spaceId))!,
        recipient: owner,
      );
      expect(
        (await recoveryService.stateOf(
          spaceId,
        ))!.lifecycleTransition!.changedAtMs,
        lessThanOrEqualTo(deadline),
      );

      final sweep = await service.purgeDeletedSpaces(nowMs: deadline);
      expect(sweep.scanned, 1);
      expect(sweep.purged, 1);
      expect(sweep.failed, 0);
      expect(await service.load(spaceId), isNull);
      expect(await service.listSpaces(), isEmpty);
      expect(await storage.loadFile('group:${spaceId.hex}'), isNull);
      final tombstone = await service.deletedSpaceTombstone(spaceId);
      expect(
        tombstone?.deleteTransitionHash,
        deletedState.lifecycleTransitionHash,
      );
      expect((await service.purgeDeletedSpaces(nowMs: deadline)).purged, 0);

      // The expired delete snapshot is acknowledged but cannot recreate its
      // heavy bundle or index entry.
      expect(await service.ingestSnapshot(deletedSnapshot), isTrue);
      expect(await service.load(spaceId), isNull);
      expect(await service.deletedSpaceTombstone(spaceId), isNotNull);

      // A complete restore signed before the deadline may arrive late. It
      // includes the exact purged delete row and therefore clears the compact
      // anti-resurrection marker without losing history.
      expect(await service.ingestSnapshot(restoredSnapshot), isTrue);
      expect(await service.deletedSpaceTombstone(spaceId), isNull);
      expect((await service.stateOf(spaceId))!.isActive, isTrue);
      expect(
        (await service.messagesOf(spaceId)).single.body,
        'retained until purge',
      );
      expect(
        (await service.postsOf(spaceId)).single.body,
        'recoverable publication',
      );
    },
  );

  test(
    'offline pre-archive suffix cannot rejoin after archive and restore arrive',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));

      final spaceId = await ownerSvc.createSpace(
        'Offline boundary',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final ownerChannel = (await ownerSvc.channelsOf(spaceId)).single;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'archive boundary message',
          channelId: ownerChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final channel = (await bobSvc.channelsOf(spaceId)).single;
      expect(
        await bobSvc.postMessage(
          spaceId,
          'offline stale message',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'offline stale publication',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await bobSvc.react(spaceId, '${owner.hex}:0', '⚠️', broadcast: false),
        isTrue,
      );

      expect(await ownerSvc.setSpaceArchived(spaceId, true), isTrue);
      expect(await ownerSvc.setSpaceArchived(spaceId, false), isTrue);
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      final mergedLifecycle = (await ownerSvc.stateOf(spaceId))!;
      expect(mergedLifecycle.lifecycleTransitionHash, isNotNull);
      expect(mergedLifecycle.lifecycleTransitionHash, isNotEmpty);
      expect(mergedLifecycle.lifecycleTransition!.messageHeads, hasLength(1));
      expect(mergedLifecycle.lifecycleTransition!.reactionHeads, isEmpty);
      final mergedRows = (await ownerSvc.load(spaceId))!.messages;
      expect(mergedRows.map((message) => message.body), [
        'archive boundary message',
      ]);
      expect(
        (await ownerSvc.messagesOf(spaceId)).map((message) => message.body),
        ['archive boundary message'],
      );
      expect(await ownerSvc.postsOf(spaceId), isEmpty);
      expect(await ownerSvc.reactionsOf(spaceId), isEmpty);
      final retained = (await ownerSvc.load(spaceId))!;
      expect(retained.messages, hasLength(1));
      expect(retained.posts, isEmpty);
      expect(retained.reactions, isEmpty);

      final restored = (await ownerSvc.stateOf(spaceId))!;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'fresh message',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.load(spaceId))!.messages.last.lifecycleGeneration,
        restored.lifecycleTransitionHash,
      );
    },
  );
}
