import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/group_api_adapter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
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
  ControlEntry signControl(ControlEntry unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  GroupMessage signMessage(GroupMessage unsigned) =>
      unsigned.withSignature(Uint8List(64), selfPubKey);

  @override
  GroupReaction signReaction(GroupReaction unsigned) =>
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
  bool verifyContentRequest(GroupContentRequest request) =>
      request.signature.length == 64 && request.authorPubKey.length == 32;

  @override
  bool verifyCallSignal(GroupCallSignal signal) =>
      signal.signature.length == 64 && signal.authorPubKey.length == 32;

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
  test(
    'group file API posts a signed ref and scopes reads to its message',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(9);
      final service = GroupService(storage, _Signer(owner));
      final api = GroupApiAdapter(
        service,
        registerContent: (bytes, {required name}) async {
          const cid = 'c0ffee';
          await storage.storeFile(cid, bytes, name: name);
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

  test(
    'one adapter contract drives list/messages and full group administration',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final owner = _id(1);
      final bob = _id(2);
      final carol = _id(3);
      final ownerService = GroupService(storage, _Signer(owner));
      Future<String> register(Uint8List bytes, {required String name}) async {
        final cid = 'api-${bytes.length}-$name';
        await storage.storeFile(cid, bytes, name: name);
        return cid;
      }

      GroupApiAdapter apiFor(GroupService service) => GroupApiAdapter(
        service,
        registerContent: register,
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
}
