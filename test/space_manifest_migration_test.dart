import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Uint8List _signature(List<int> key, List<int> message) {
  final digest = sha256.convert([...key, ...message]).bytes;
  return Uint8List.fromList([...digest, ...digest]);
}

class _Signer implements GroupSigner {
  const _Signer(this.selfId);

  @override
  final NodeId selfId;

  @override
  Uint8List get selfPubKey => selfId.bytes;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) =>
      value.withSignature(_signature(selfPubKey, value.canonicalBytes()));

  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(Uint8List.fromList(value.genesisPubKey)) &&
      _sameBytes(
        value.signature,
        _signature(value.genesisPubKey, value.canonicalBytes()),
      );

  @override
  ControlEntry signControl(ControlEntry value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupMessage signMessage(GroupMessage value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupReaction signReaction(GroupReaction value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  SpacePost signPost(SpacePost value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupContentRequest signContentRequest(GroupContentRequest value) =>
      value.withSignature(Uint8List(64), value.requester.bytes);

  @override
  GroupCallSignal signCallSignal(GroupCallSignal value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  bool _valid(List<int> signature, List<int> publicKey) =>
      signature.length == 64 && publicKey.length == 32;

  @override
  bool verifyControl(ControlEntry value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyMessage(GroupMessage value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyReaction(GroupReaction value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyPost(SpacePost value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyContentRequest(GroupContentRequest value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyCallSignal(GroupCallSignal value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => false;
}

Future<void> _seedLegacy(Storage storage, SpaceManifest manifest) async {
  await storage.storeFile(
    'group:${manifest.groupId.hex}',
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'm': manifest.toJson(),
          'c': const <Object>[],
          'g': const <Object>[],
          'r': const <Object>[],
        }),
      ),
    ),
    name: 'group',
  );
  await storage.putSetting('groups.index', jsonEncode([manifest.groupId.hex]));
}

void main() {
  final owner = _id(1);
  final member = _id(2);

  test(
    'nested channel parser rejects malformed wire values without throwing',
    () {
      final valid = SpaceChannel(
        spaceId: owner,
        channelId: _id(8),
        kind: SpaceChannelKind.text,
        name: 'general',
        description: '',
        position: 0,
        isDefault: true,
        archived: false,
        history: SpaceChannelHistory.full,
        createdBy: owner,
        createdAtMs: 1,
      ).toJson();
      expect(SpaceChannel.fromJson(valid), isNotNull);
      expect(SpaceChannel.fromJson({...valid, 'kind': 7}), isNull);
      expect(SpaceChannel.fromJson({...valid, 'history': false}), isNull);
      expect(SpaceChannel.fromJson({...valid, 'category': 4}), isNull);
      expect(
        ControlEntry.fromJson({
          'gid': owner.hex,
          'author': owner.hex,
          'seq': 0,
          'prev': '',
          'op': 'createChannel',
          'channel': {...valid, 'kind': <Object>[]},
          'pv': 0,
          'ts': 1,
          'sig': base64Encode(Uint8List(64)),
        }),
        isNull,
      );
    },
  );

  test('new creation persists an owner-signed Space genesis', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(owner));

    final id = await service.createSpace(
      'Private circle',
      description: 'Distributed by members',
      visibility: SpaceVisibility.secret,
      discoverable: true,
    );
    final manifest = (await service.load(id))!.manifest;

    expect(manifest.isSpace, isTrue);
    expect(manifest.version, SpaceManifest.spaceVersion);
    expect(manifest.description, 'Distributed by members');
    expect(manifest.visibility, SpaceVisibility.secret);
    expect(manifest.discoverable, isFalse);
    expect(manifest.signature, hasLength(64));
    final channels = await service.channelsOf(id);
    expect(channels, hasLength(1));
    expect(channels.single.channelId, defaultSpaceChannelId(id));
    expect(channels.single.kind, SpaceChannelKind.text);
    expect(channels.single.isDefault, isTrue);
  });

  test(
    'channels are signed children with category, order and default rules',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(storage, _Signer(owner));
      final id = await ownerService.createSpace('Studio');
      final originalDefault = (await ownerService.channelsOf(id)).single;
      expect(
        await ownerService.setChannelArchived(
          id,
          originalDefault.channelId,
          true,
        ),
        isFalse,
        reason: 'the last active default text channel is protected',
      );

      final categoryId = await ownerService.createChannel(
        id,
        name: 'Projects',
        kind: SpaceChannelKind.category,
        position: 10,
      );
      expect(categoryId, isNotNull);
      final voiceId = await ownerService.createChannel(
        id,
        name: 'Stand-up',
        kind: SpaceChannelKind.voice,
        categoryId: categoryId,
      );
      expect(voiceId, isNotNull);
      expect(
        await ownerService.postMessage(id, 'not text', channelId: voiceId),
        isFalse,
      );
      final textId = await ownerService.createChannel(
        id,
        name: 'Roadmap',
        kind: SpaceChannelKind.text,
        categoryId: categoryId,
        position: 20,
        history: SpaceChannelHistory.full,
      );
      expect(textId, isNotNull);
      expect(await ownerService.setDefaultChannel(id, textId!), isTrue);
      expect(
        await ownerService.setChannelArchived(
          id,
          originalDefault.channelId,
          true,
        ),
        isTrue,
      );
      expect(
        await ownerService.createChannel(
          id,
          name: 'Orphan',
          kind: SpaceChannelKind.text,
          categoryId: _id(99),
        ),
        isNull,
      );

      expect(
        await ownerService.postMessage(id, 'in roadmap', channelId: textId),
        isTrue,
      );
      final message = (await ownerService.messagesOf(
        id,
        channelId: textId,
      )).single;
      expect(message.channelId, textId);
      expect(
        await ownerService.postMessage(
          id,
          'archived destination',
          channelId: originalDefault.channelId,
        ),
        isFalse,
      );

      final fromJoinId = await ownerService.createChannel(
        id,
        name: 'Newcomers',
        kind: SpaceChannelKind.text,
        history: SpaceChannelHistory.fromJoin,
      );
      expect(fromJoinId, isNotNull);
      expect(
        await ownerService.postMessage(
          id,
          'before membership',
          channelId: fromJoinId,
        ),
        isTrue,
      );

      expect(
        await ownerService.addControlOp(
          id,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final memberService = GroupService(storage, _Signer(member));
      expect(
        await memberService.messagesOf(id, channelId: fromJoinId),
        isEmpty,
        reason: 'fromJoin is enforced by the reading node, not only the UI',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(
        await ownerService.postMessage(
          id,
          'after membership',
          channelId: fromJoinId,
        ),
        isTrue,
      );
      expect(
        (await memberService.messagesOf(id, channelId: fromJoinId)).single.body,
        'after membership',
      );
      expect(
        await memberService.createChannel(
          id,
          name: 'Escalation',
          kind: SpaceChannelKind.voice,
        ),
        isNull,
      );

      final channels = await ownerService.channelsOf(id, includeArchived: true);
      expect(
        channels.where((channel) => channel.isDefault).single.channelId,
        textId,
      );
      expect(
        channels
            .singleWhere(
              (channel) => channel.channelId == originalDefault.channelId,
            )
            .archived,
        isTrue,
      );
      final ordered = orderSpaceChannelsForDisplay(channels);
      final categoryIndex = ordered.indexWhere(
        (channel) => channel.channelId == categoryId,
      );
      expect(categoryIndex, greaterThanOrEqualTo(0));
      expect(ordered[categoryIndex + 1].channelId, voiceId);
      expect(ordered[categoryIndex + 2].channelId, textId);
      expect(nextSpaceChannelPosition(channels, categoryId: categoryId), 120);

      expect(
        await ownerService.setChannelArchived(id, categoryId!, true),
        isFalse,
        reason: 'an active child must never be orphaned by category archival',
      );
      expect(await ownerService.setDefaultChannel(id, fromJoinId!), isTrue);
      expect(await ownerService.setChannelArchived(id, voiceId!, true), isTrue);
      expect(await ownerService.setChannelArchived(id, textId, true), isTrue);
      expect(
        await ownerService.setChannelArchived(id, categoryId, true),
        isTrue,
      );
    },
  );

  test('boot sync does not convert a group chat into a Space', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(owner));
    final groupId = await service.createGroup('Keep as chat');

    await service.nudgeGroupSyncAll();

    expect((await service.load(groupId))!.manifest.isSpace, isFalse);
    expect((await service.listGroups()).single.groupId, groupId);
    expect(await service.listSpaces(), isEmpty);
  });

  test(
    'explicit owner conversion preserves id, history and is idempotent',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final id = _id(41);
      final legacy = SpaceManifest(
        groupId: id,
        owner: owner,
        genesisPubKey: owner.bytes,
        name: 'Legacy circle',
        createdAtMs: 1234,
      );
      await _seedLegacy(storage, legacy);
      final service = GroupService(storage, _Signer(owner));
      expect(
        await service.postMessage(id, 'preserved', broadcast: false),
        isTrue,
      );

      final first = await service.migrateOwnedLegacyGroupsToSpaces();
      expect(first.upgraded, 1);
      expect(first.failed, 0);
      final upgraded = (await service.load(id))!;
      expect(upgraded.manifest.isSpace, isTrue);
      expect(upgraded.manifest.sameImmutableRoot(legacy), isTrue);
      expect((await service.messagesOf(id)).single.body, 'preserved');
      expect(
        (await service.channelsOf(id)).single.channelId,
        defaultSpaceChannelId(id),
      );

      final second = await service.migrateOwnedLegacyGroupsToSpaces();
      expect(second.upgraded, 0);
      expect(second.alreadyCurrent, 1);
      expect(second.failed, 0);
    },
  );

  test(
    'member cannot forge migration and adopts only matching owner root',
    () async {
      final id = _id(42);
      final legacy = SpaceManifest(
        groupId: id,
        owner: owner,
        genesisPubKey: owner.bytes,
        name: 'Shared legacy',
        createdAtMs: 5678,
      );
      final memberStorage = FakeHvContainer().storage();
      await memberStorage.open(password: 'pw', createIfMissing: true);
      await _seedLegacy(memberStorage, legacy);
      final memberService = GroupService(memberStorage, _Signer(member));
      expect(
        (await memberService.migrateOwnedLegacyGroupsToSpaces()).notOwner,
        1,
      );
      expect((await memberService.load(id))!.manifest.isLegacyGroup, isTrue);

      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await _seedLegacy(ownerStorage, legacy);
      final ownerService = GroupService(ownerStorage, _Signer(owner));
      expect(
        (await ownerService.migrateOwnedLegacyGroupsToSpaces()).upgraded,
        1,
      );
      final signed = (await ownerService.load(id))!;
      expect(
        await memberService.ingestSnapshot(ownerService.snapshotJson(signed)),
        isTrue,
      );
      expect((await memberService.load(id))!.manifest.isSpace, isTrue);

      final fork = _Signer(owner).signSpaceManifest(
        SpaceManifest.space(
          spaceId: id,
          owner: owner,
          genesisPubKey: owner.bytes,
          name: 'Changed genesis',
          createdAtMs: legacy.createdAtMs,
        ),
      );
      expect(
        await memberService.ingestSnapshot(
          jsonEncode({
            'm': fork.toJson(),
            'c': const <Object>[],
            'g': const <Object>[],
            'r': const <Object>[],
          }),
        ),
        isFalse,
      );
    },
  );
}
