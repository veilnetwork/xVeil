import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/group_api_adapter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

final class _Signer implements GroupSigner {
  const _Signer(this.selfId);

  @override
  final NodeId selfId;

  @override
  Uint8List get selfPubKey => selfId.bytes;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) =>
      value.withSignature(Uint8List(64));

  @override
  ControlEntry signControl(ControlEntry unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  GroupMessage signMessage(GroupMessage unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  GroupReaction signReaction(GroupReaction unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  SpacePost signPost(SpacePost unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  GroupCallSignal signCallSignal(GroupCallSignal unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  bool verifyControl(ControlEntry entry) =>
      entry.signature.length == 64 && entry.authorPubKey.length == 32;

  @override
  bool verifyMessage(GroupMessage message) =>
      message.signature.length == 64 && message.authorPubKey.length == 32;

  @override
  bool verifyReaction(GroupReaction reaction) =>
      reaction.signature.length == 64 && reaction.authorPubKey.length == 32;

  @override
  bool verifyPost(SpacePost post) =>
      post.signature.length == 64 && post.authorPubKey.length == 32;

  @override
  bool verifyContentRequest(GroupContentRequest request) =>
      request.signature.length == 64 && request.authorPubKey.length == 32;

  @override
  bool verifyCallSignal(GroupCallSignal signal) =>
      signal.signature.length == 64 && signal.authorPubKey.length == 32;

  @override
  bool verifySpaceManifest(SpaceManifest value) => value.signature.length == 64;

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => false;
}

void main() {
  test('Space API creates and updates one signed profile model', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(3);
    final service = GroupService(storage, _Signer(owner));
    final api = GroupApiAdapter(
      service,
      registerContentSource:
          (name, size, read, {required close, sourcePath}) async {
            await close();
            return 'unused';
          },
      loadContent: storage.loadFile,
    );
    try {
      final space = await api.createSpace(
        'Field lab',
        'Initial summary',
        'secret',
      );
      expect(space, isNotNull);
      final listed = (await api.listSpaces()).single;
      expect(listed['description'], 'Initial summary');
      expect(listed['visibility'], 'secret');
      expect(listed['discoverable'], isFalse);

      final profile = (await api.profile(space!))!;
      expect(profile['description'], 'Initial summary');
      expect(profile['visibility'], 'secret');
      expect(await api.updateDescription(space, 'Updated summary'), isNull);
      expect((await api.profile(space))!['description'], 'Updated summary');
      expect((await api.lifecycle(space))!['state'], 'active');
      expect(await api.setLifecycle(space, 'archive'), isNull);
      final archived = (await api.lifecycle(space))!;
      expect(archived['state'], 'archived');
      expect(archived['canRestore'], isTrue);
      expect(await api.updateDescription(space, 'Blocked'), isNotNull);
      expect(await api.setLifecycle(space, 'restore'), isNull);
      expect((await api.lifecycle(space))!['state'], 'active');
      expect(await api.setLifecycle(space, 'invalid'), isNotNull);
      expect(await api.createSpace('Bad', '', 'unknown'), isNull);
    } finally {
      await service.dispose();
    }
  });

  test('Space API exposes rules history and signed acceptance state', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(31);
    final service = GroupService(storage, _Signer(owner));
    final api = GroupApiAdapter(
      service,
      registerContentSource:
          (name, size, read, {required close, sourcePath}) async {
            await close();
            return 'unused';
          },
      loadContent: storage.loadFile,
    );
    try {
      final space = (await api.createSpace('Rules', '', 'private'))!;
      expect((await api.rules(space))!['history'], isEmpty);
      expect(
        await api.publishRules(
          space,
          'Respect member privacy.',
          'Privacy first.',
          null,
        ),
        isNull,
      );
      var rules = (await api.rules(space))!;
      expect((rules['current'] as Map)['version'], 1);
      expect(rules['acceptanceRequired'], isTrue);
      expect(await api.acceptRules(space), isNull);
      rules = (await api.rules(space))!;
      expect(rules['acceptanceRequired'], isFalse);
      expect((rules['acceptance'] as Map)['rulesVersion'], 1);
      expect(await api.rules('invalid'), isNull);
    } finally {
      await service.dispose();
    }
  });

  test('Space API folds signed post revisions and tombstones', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(_id(33)));
    final api = GroupApiAdapter(
      service,
      registerContentSource:
          (name, size, read, {required close, sourcePath}) async {
            await close();
            return 'unused';
          },
      loadContent: storage.loadFile,
    );
    try {
      final space = (await api.createSpace('News', '', 'public'))!;
      final created = await api.publishPost(
        space,
        'Initial',
        'first body',
        'article',
      );
      expect(created.error, isNull);
      final postId = created.post!['postId'] as String;
      final cursor = created.post!['cursor'];
      final edited = await api.editPost(
        space,
        postId,
        'Corrected',
        'second body',
        'post',
      );
      expect(edited.error, isNull);
      expect(edited.post!['postId'], postId);
      expect(edited.post!['revisionId'], isNot(postId));
      expect(edited.post!['cursor'], cursor);
      expect(edited.post!['edited'], isTrue);
      expect(await api.reactToPost(space, postId, '🔥'), isNull);
      final listed = (await api.posts(space, 50, null))!['posts'] as List;
      expect(listed, hasLength(1));
      expect((listed.single['reactions'] as Map)['🔥'], [_id(33).hex]);
      expect(await api.editPost(space, '${_id(34).hex}:0', '', 'x', null), (
        error: 'post edit rejected',
        post: null,
      ));
      expect(await api.deletePost(space, postId), isNull);
      expect((await api.posts(space, 50, null))!['posts'], isEmpty);
      expect(await api.deletePost(space, postId), 'post deletion rejected');
    } finally {
      await service.dispose();
    }
  });

  test(
    'Space API invite proposes consent instead of adding immediately',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(4);
      final invitee = _id(5);
      await storage.upsertContact(
        Contact(nodeId: invitee, status: ContactStatus.accepted),
      );
      final sent = <String>[];
      final service = GroupService(
        storage,
        _Signer(owner),
        sendSpaceInvite: (peer, inviteId, json) async => sent.add(json),
      );
      final api = GroupApiAdapter(
        service,
        registerContentSource:
            (name, size, read, {required close, sourcePath}) async {
              await close();
              return 'unused';
            },
        loadContent: storage.loadFile,
      );
      try {
        final space = (await api.createSpace('Consent', '', 'private'))!;
        expect(
          await api.memberAction(space, 'invite', invitee.hex, 'member'),
          isNull,
        );
        expect(sent, hasLength(1));
        expect(
          (await service.stateOf(NodeId.fromHex(space)))!.isMember(invitee),
          isFalse,
        );
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'Space API transfers the effective owner through the signed log',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(6);
      final nextOwner = _id(7);
      final service = GroupService(storage, _Signer(owner));
      final api = GroupApiAdapter(
        service,
        registerContentSource:
            (name, size, read, {required close, sourcePath}) async {
              await close();
              return 'unused';
            },
        loadContent: storage.loadFile,
      );
      try {
        final space = (await api.createSpace('Ownership', '', 'private'))!;
        expect(
          await api.memberAction(space, 'add', nextOwner.hex, 'member'),
          isNull,
        );
        expect(
          await api.memberAction(space, 'transfer_owner', nextOwner.hex, null),
          isNull,
        );
        final roster = (await api.members(space))!;
        final byId = {
          for (final member in roster['members'] as List)
            (member as Map)['nodeId']: member['role'],
        };
        expect(byId[owner.hex], GroupRole.admin.name);
        expect(byId[nextOwner.hex], GroupRole.owner.name);
        expect(
          await api.memberAction(space, 'transfer_owner', owner.hex, null),
          'operation rejected by group policy',
        );
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'space API exposes signed nested channels and channel-scoped messages',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(7);
      final service = GroupService(storage, _Signer(owner));
      final api = GroupApiAdapter(
        service,
        registerContentSource:
            (name, size, read, {required close, sourcePath}) async {
              await close();
              return 'unused';
            },
        loadContent: storage.loadFile,
      );
      try {
        final space = (await api.createSpace('Veil builders', '', 'private'))!;
        final listed = (await api.listSpaces()).single;
        expect(listed['spaceId'], space);
        expect(listed['groupId'], space, reason: 'legacy API alias is stable');

        final initial = (await api.channels(space))!;
        expect(initial, hasLength(1));
        expect(initial.single['kind'], SpaceChannelKind.text.name);
        expect(initial.single['default'], isTrue);

        final created = await api.createChannel(
          space,
          'protocol',
          'text',
          null,
          10,
          'full',
          null,
          'space',
          const [],
        );
        expect(created.error, isNull);
        final channel = created.channelId!;
        expect(
          await api.sendChannelMessage(space, channel, 'signed note', null),
          isNull,
        );
        final messages = (await api.channelMessages(space, channel, 20))!;
        expect(messages.single['body'], 'signed note');
        expect(messages.single['channelId'], channel);

        expect(await api.channelAction(space, channel, 'default'), isNull);
        expect(
          await api.channelAction(space, channel, 'archive'),
          isNotNull,
          reason: 'the last active default channel cannot be archived',
        );
        expect(await api.channels('invalid'), isNull);
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'Space API keeps publications separate and pages the merged feed',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _Signer(_id(8)));
      final api = GroupApiAdapter(
        service,
        registerContentSource:
            (name, size, read, {required close, sourcePath}) async {
              await close();
              return 'unused';
            },
        loadContent: storage.loadFile,
      );
      try {
        final spaceId = await service.createSpace(
          'Public API',
          visibility: SpaceVisibility.public,
        );
        final result = await api.publishPost(
          spaceId.hex,
          'Headline',
          'Body',
          SpacePostType.article.name,
        );
        expect(result.error, isNull);
        expect(result.post?['title'], 'Headline');
        final posts = await api.posts(spaceId.hex, 10, null);
        expect((posts?['posts'] as List).single['body'], 'Body');
        final feed = await api.feed(10, null);
        expect((feed['posts'] as List).single['spaceName'], 'Public API');
        expect((await service.load(spaceId))!.messages, isEmpty);
        expect(await api.setFeedEnabled(spaceId.hex, false), isNull);
        expect((await api.feed(10, null))['posts'], isEmpty);
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'group file API posts a signed ref and scopes reads to its message',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(9);
      final service = GroupService(storage, _Signer(owner));
      final api = GroupApiAdapter(
        service,
        registerContentSource:
            (name, size, read, {required close, sourcePath}) async {
              const cid = 'c0ffee';
              try {
                await storage.storeFile(cid, await read(0, size), name: name);
              } finally {
                await close();
              }
              return cid;
            },
        loadContent: storage.loadFile,
      );
      final directory = await Directory.systemTemp.createTemp(
        'xveil-group-api-',
      );
      try {
        final group = (await api.create('Media'))!;
        final source = File('${directory.path}/clip.mp4');
        await source.writeAsBytes([9, 8, 7, 6]);
        final sent = await api.sendFile(
          group,
          source.path,
          null,
          'watch',
          null,
        );
        expect(sent.error, isNull);
        expect(sent.contentId, 'c0ffee');

        final message = (await service.messagesOf(
          NodeId.fromHex(group),
        )).single;
        expect(message.body, 'watch');
        expect(message.attachment?.kind, 'video');
        expect(message.attachment?.cid, 'c0ffee');
        expect(message.attachment?.name, 'clip.mp4');
        expect(message.attachment?.w, 4);

        final loaded = await api.loadFile(group, message.ref);
        expect(loaded.error, isNull);
        expect(loaded.bytes, [9, 8, 7, 6]);
        expect(
          await api.fetchFile(group, message.ref),
          isNull,
          reason: 'an already-held blob needs no network pull',
        );
        expect(
          (await api.loadFile(group, '${owner.hex}:999')).error,
          'group message attachment not found',
        );
        expect(
          (await api.sendFile(
            group,
            '${directory.path}/missing',
            null,
            '',
            null,
          )).error,
          'source not found',
        );
      } finally {
        await service.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('group file API passes an over-legacy-cap source through without an '
      'all-file read', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(19);
    final service = GroupService(storage, _Signer(owner));
    const size = 9 * 1024 * 1024 + 7;
    var maxRead = 0;
    var closed = false;
    String? durablePath;
    final api = GroupApiAdapter(
      service,
      registerContentSource:
          (name, declaredSize, read, {required close, sourcePath}) async {
            expect(declaredSize, size);
            durablePath = sourcePath;
            final first = await read(0, 4096);
            final last = await read(size - 7, 7);
            maxRead = [
              first.length,
              last.length,
            ].reduce((a, b) => a > b ? a : b);
            await close();
            closed = true;
            return 'large-cid';
          },
      loadContent: storage.loadFile,
    );
    final directory = await Directory.systemTemp.createTemp(
      'xveil-group-api-large-',
    );
    try {
      final group = (await api.create('Large'))!;
      final source = File('${directory.path}/archive.bin');
      final raf = await source.open(mode: FileMode.write);
      await raf.setPosition(size - 1);
      await raf.writeByte(23);
      await raf.close();

      final sent = await api.sendFile(group, source.path, null, '', null);
      expect(sent.error, isNull);
      expect(sent.contentId, 'large-cid');
      expect(closed, isTrue);
      expect(maxRead, 4096, reason: 'the adapter never materializes the file');
      expect(durablePath, source.absolute.path);
      final message = (await service.messagesOf(NodeId.fromHex(group))).single;
      expect(message.attachment?.w, size);
    } finally {
      await service.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'one adapter contract drives list/messages and full group administration',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(1);
      final bob = _id(2);
      final carol = _id(3);
      final ownerService = GroupService(storage, _Signer(owner));
      Future<String> register(
        String name,
        int size,
        Future<Uint8List> Function(int, int) read, {
        required Future<void> Function() close,
        String? sourcePath,
      }) async {
        final cid = 'api-$size-$name';
        try {
          await storage.storeFile(cid, await read(0, size), name: name);
        } finally {
          await close();
        }
        return cid;
      }

      GroupApiAdapter apiFor(GroupService service) => GroupApiAdapter(
        service,
        registerContentSource: register,
        loadContent: storage.loadFile,
      );

      final ownerApi = apiFor(ownerService);

      final group = await ownerApi.create('Bots');
      expect(group, isNotNull);
      expect((await ownerApi.list()).single['name'], 'Bots');
      expect(await ownerApi.sendMessage(group!, 'hello', null), isNull);
      expect((await ownerApi.messages(group, 10))!.single['body'], 'hello');

      var roster = await ownerApi.members(group);
      expect(roster!['selfRole'], 'owner');
      expect((roster['members'] as List).single['self'], isTrue);

      expect(
        await ownerApi.memberAction(group, 'add', bob.hex, 'member'),
        isNull,
      );
      expect(
        await ownerApi.memberAction(group, 'set_role', bob.hex, 'admin'),
        isNull,
      );
      expect(await ownerApi.memberAction(group, 'mute', bob.hex, null), isNull);
      roster = await ownerApi.members(group);
      final bobJson = (roster!['members'] as List<Map<String, dynamic>>)
          .singleWhere((member) => member['nodeId'] == bob.hex);
      expect(bobJson['role'], 'admin');
      expect(bobJson['muted'], isTrue);
      expect(
        await ownerApi.memberAction(group, 'unmute', bob.hex, null),
        isNull,
      );

      expect(
        await ownerApi.memberAction(group, 'add', carol.hex, 'member'),
        isNull,
      );
      final carolApi = apiFor(GroupService(storage, _Signer(carol)));
      expect(
        await carolApi.rename(group, 'Hijacked'),
        'operation rejected by group policy',
      );
      expect(
        await ownerApi.memberAction(group, 'remove', carol.hex, null),
        isNull,
      );
      expect((await ownerApi.members(group))!['members'], hasLength(2));

      expect(await ownerApi.rename(group, 'Automation'), isNull);
      expect((await ownerApi.members(group))!['name'], 'Automation');
      expect(
        await ownerApi.leave(group),
        'operation rejected by group policy',
        reason: 'the genesis owner cannot leave in group policy v1',
      );

      final bobApi = apiFor(GroupService(storage, _Signer(bob)));
      expect((await bobApi.members(group))!['selfRole'], 'admin');
      expect(await bobApi.leave(group), isNull);
      expect(await bobApi.members(group), isNull);
      expect((await ownerApi.members(group))!['members'], hasLength(1));

      expect(await ownerApi.members('not-a-group'), isNull);
      expect(
        await ownerApi.memberAction(group, 'unknown', bob.hex, null),
        'invalid member action',
      );
      await ownerService.dispose();
    },
  );

  test('moderation API is Space-only and keeps an immutable audit', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final owner = _id(41);
    final member = _id(42);
    final service = GroupService(storage, _Signer(owner));
    final api = GroupApiAdapter(
      service,
      registerContentSource:
          (name, size, read, {required close, sourcePath}) async {
            await close();
            return 'unused';
          },
      loadContent: storage.loadFile,
    );
    try {
      final group = (await api.create('Private group chat'))!;
      expect(
        (await api.moderate(
          group,
          SpaceModerationKind.warning.name,
          owner.hex,
          SpaceModerationScope.space.name,
          'not a community',
          null,
          null,
          null,
          null,
          null,
        )).error,
        'space not found',
      );
      expect(await api.moderationAudit(group), isNull);

      final space = (await api.createSpace('Community', '', 'public'))!;
      expect(
        await api.memberAction(space, 'add', member.hex, 'member'),
        isNull,
      );
      expect(
        await api.memberAction(space, 'mute', member.hex, null),
        contains('/v1/spaces/moderation'),
      );
      final created = await api.moderate(
        space,
        SpaceModerationKind.warning.name,
        member.hex,
        SpaceModerationScope.space.name,
        'signed warning',
        null,
        null,
        null,
        null,
        null,
      );
      expect(created.error, isNull);
      final audit = await api.moderationAudit(space);
      expect(audit, hasLength(1));
      expect(audit!.single['actionId'], created.actionId);
      expect(audit.single['reason'], 'signed warning');
      expect(
        await api.revokeModeration(space, created.actionId!, 'resolved'),
        isNull,
      );
      final revoked = (await api.moderationAudit(space))!.single;
      expect(revoked['active'], isFalse);
      expect(revoked['revocationReason'], 'resolved');
    } finally {
      await service.dispose();
    }
  });

  test(
    'retention API separates signed community and local device policy',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final signer = _Signer(_id(71));
      final service = GroupService(storage, signer);
      final api = GroupApiAdapter(
        service,
        registerContentSource:
            (name, size, read, {required close, sourcePath}) async {
              await close();
              return 'unused';
            },
        loadContent: storage.loadFile,
      );
      try {
        final group = (await api.create('Group chat'))!;
        expect(await api.retention(group), isNull);

        final space = (await api.createSpace('Community', '', 'private'))!;
        expect(await api.setRetention(space, 90, false), isNull);
        expect(await api.setRetention(space, 30, true), isNull);

        final spaceId = NodeId.fromHex(space);
        final bundle = (await service.load(spaceId))!;
        final oldMessage = signer.signMessage(
          GroupMessage(
            groupId: spaceId,
            author: signer.selfId,
            seq: 0,
            prevHash: '',
            body: 'old on this device',
            policyVersion: 0,
            createdAtMs:
                DateTime.now().millisecondsSinceEpoch -
                const Duration(days: 2).inMilliseconds,
            signature: Uint8List(0),
          ),
        );
        expect(
          await service.ingestSnapshot(
            service.snapshotJson(bundle.copyWith(messages: [oldMessage])),
          ),
          isTrue,
        );
        expect(await service.messagesOf(spaceId), hasLength(1));
        expect(await api.setRetention(space, 1, true), isNull);
        expect(await service.messagesOf(spaceId), isEmpty);
        expect(
          await service.messagesOf(spaceId, applyLocalRetention: false),
          hasLength(1),
          reason: 'device retention must not revoke community distribution',
        );

        final value = (await api.retention(space))!;
        expect(value['community']['mode'], 'deleteAfter');
        expect(
          value['community']['retentionMs'],
          const Duration(days: 90).inMilliseconds,
        );
        expect(value['localDevice']['retentionDays'], 1);
        expect(value['history'], hasLength(1));
        expect(
          (await service.stateOf(NodeId.fromHex(space)))!.policyVersion,
          0,
        );
      } finally {
        await service.dispose();
      }
    },
  );
}
