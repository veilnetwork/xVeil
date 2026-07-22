import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_epoch.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_channel.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

NodeId _id(int byte) => NodeId.fromHex(_hash(byte));

void main() {
  test('legacy group message canonical bytes remain byte-identical', () {
    final message = GroupMessage(
      groupId: _id(10),
      author: _id(1),
      seq: 2,
      prevHash: 'prev',
      body: 'hello',
      policyVersion: 3,
      createdAtMs: 4000,
      signature: Uint8List(64),
    );
    expect(
      utf8.decode(message.canonicalBytes()),
      jsonEncode({
        'gid': _id(10).hex,
        'author': _id(1).hex,
        'seq': 2,
        'prev': 'prev',
        'body': 'hello',
        'pv': 3,
        'ts': 4000,
      }),
    );
    expect(message.toJson().containsKey('v'), isFalse);
    expect(
      GroupMessage.fromJson(message.toJson())!.canonicalBytes(),
      message.canonicalBytes(),
    );
  });

  test('legacy attachment keeps its signed wire shape byte-identical', () {
    final message = GroupMessage(
      groupId: _id(10),
      author: _id(1),
      seq: 3,
      prevHash: 'prev',
      body: '',
      policyVersion: 4,
      createdAtMs: 5000,
      signature: Uint8List(64),
      attachment: const MediaObject(
        kind: 'image',
        dataB64: 'QQ==',
        w: 2,
        h: 3,
        cid: 'legacy-content-id',
        name: 'photo.png',
      ),
    );
    final expected = jsonEncode({
      'gid': _id(10).hex,
      'author': _id(1).hex,
      'seq': 3,
      'prev': 'prev',
      'body': '',
      'pv': 4,
      'ts': 5000,
      'att': {
        'k': 'image',
        'd': 'QQ==',
        'w': 2,
        'h': 3,
        'cid': 'legacy-content-id',
        'n': 'photo.png',
      },
    });

    expect(utf8.decode(message.canonicalBytes()), expected);
    final parsed = GroupMessage.fromJson(message.toJson());
    expect(parsed?.canonicalBytes(), message.canonicalBytes());
    expect(parsed?.attachment, isA<MediaObject>());
  });

  test('Space post comment target is signed and cannot also be a channel', () {
    final postId = '${_id(4).hex}:7';
    final message = GroupMessage(
      groupId: _id(10),
      author: _id(1),
      seq: 2,
      prevHash: 'prev',
      body: 'discussion',
      spacePostId: postId,
      policyVersion: 3,
      createdAtMs: 4000,
      signature: Uint8List(64),
    );
    final json = message.toJson();
    expect(json['post'], postId);
    expect(utf8.decode(message.canonicalBytes()), contains('"post":"$postId"'));
    final parsed = GroupMessage.fromJson(json);
    expect(parsed?.spacePostId, postId);
    expect(parsed?.canonicalBytes(), message.canonicalBytes());

    expect(
      GroupMessage.fromJson({...json, 'post': 'not-a-post-reference'}),
      isNull,
    );
    expect(GroupMessage.fromJson({...json, 'channel': _id(9).hex}), isNull);
  });

  test('comment media cleartext uses strict reference wire v2', () {
    final cleartext = GroupMessageCleartext(
      body: '',
      attachment: MediaObject(
        contentId: 'a' * 64,
        kind: 'image',
        name: 'comment.png',
        mimeType: 'image/png',
        size: 42,
        width: 7,
        height: 6,
      ),
    );
    final encoded = cleartext.encode();
    final wire = jsonDecode(utf8.decode(encoded)) as Map;
    expect(wire['v'], 2);
    expect(wire.containsKey('att'), isFalse);
    expect((wire['media'] as Map)['cid'], 'a' * 64);

    final decoded = GroupMessageCleartext.decode(encoded);
    expect(decoded?.body, isEmpty);
    expect(decoded?.attachment?.name, 'comment.png');
    expect(decoded?.attachment?.mimeType, 'image/png');
    expect(decoded?.attachment?.size, 42);
    expect(decoded?.attachment?.width, 7);
    expect(decoded?.attachment?.height, 6);

    expect(
      GroupMessageCleartext.decode(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'v': 2,
              'body': '',
              'media': {'cid': 'legacy-id', 'kind': 'file'},
            }),
          ),
        ),
      ),
      isNull,
    );
  });

  test('comment edit cleartext is a strict metadata-only v3 revision', () {
    final target = '${_id(4).hex}:7';
    final encoded = GroupMessageCleartext(
      body: 'corrected',
      editOf: target,
    ).encode();
    final wire = jsonDecode(utf8.decode(encoded)) as Map;
    expect(wire, {'v': 3, 'body': 'corrected', 'edit': target});

    final decoded = GroupMessageCleartext.decode(encoded);
    expect(decoded?.body, 'corrected');
    expect(decoded?.editOf, target);
    expect(decoded?.attachment, isNull);
    expect(decoded?.replyTo, isNull);

    expect(
      GroupMessageCleartext.decode(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'v': 3,
              'body': 'forged',
              'edit': target,
              'rt': '${_id(3).hex}:1',
            }),
          ),
        ),
      ),
      isNull,
    );
  });

  test(
    'v2 stores only authenticated ciphertext and materializes in RAM',
    () async {
      final groupId = _id(10);
      final author = _id(1);
      final key = Uint8List.fromList(List.generate(32, (index) => index + 1));
      final cleartext = GroupMessageCleartext(
        body: 'secret body',
        attachment: const GroupAttachment(
          kind: 'image',
          dataB64: 'c2VjcmV0',
          w: 32,
          h: 24,
          cid: 'secret-cid',
        ),
        replyTo: '${_id(2).hex}:7',
      );
      final clearBytes = cleartext.encode();
      final encrypted = await encryptGroupPayload(
        groupId: groupId,
        membershipEpoch: 4,
        author: author,
        seq: 8,
        prevHash: 'head',
        policyVersion: 2,
        createdAtMs: 5000,
        clearText: clearBytes,
        epochKey: key,
        random: Random(7),
      );
      clearBytes.fillRange(0, clearBytes.length, 0);
      final message = GroupMessage(
        groupId: groupId,
        author: author,
        seq: 8,
        prevHash: 'head',
        body: '',
        version: 2,
        membershipEpoch: 4,
        encryptedPayload: encrypted,
        policyVersion: 2,
        createdAtMs: 5000,
        signature: Uint8List(64),
      );
      final json = message.toJson();
      expect(json.containsKey('body'), isFalse);
      expect(json.containsKey('att'), isFalse);
      expect(json.containsKey('rt'), isFalse);
      expect(jsonEncode(json), isNot(contains('secret body')));
      expect(jsonEncode(json), isNot(contains('secret-cid')));

      final parsed = GroupMessage.fromJson(json);
      expect(parsed, isNotNull);
      expect(parsed!.isEncrypted, isTrue);
      expect(parsed.canonicalBytes(), message.canonicalBytes());
      final opened = await decryptGroupPayload(
        groupId: parsed.groupId,
        membershipEpoch: parsed.membershipEpoch!,
        author: parsed.author,
        seq: parsed.seq,
        prevHash: parsed.prevHash,
        policyVersion: parsed.policyVersion,
        createdAtMs: parsed.createdAtMs,
        payload: parsed.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupMessageCleartext.decode(opened);
      opened.fillRange(0, opened.length, 0);
      expect(decoded?.body, 'secret body');
      expect(decoded?.attachment?.cid, 'secret-cid');
      expect(decoded?.replyTo, '${_id(2).hex}:7');
      final materialized = parsed.withDecryptedContent(decoded!);
      expect(materialized.body, 'secret body');
      expect(materialized.toJson().containsKey('body'), isFalse);
    },
  );

  test('v2 rejects ciphertext tamper and header replay', () async {
    final key = Uint8List(32);
    final payload = await encryptGroupPayload(
      groupId: _id(10),
      membershipEpoch: 1,
      author: _id(1),
      seq: 0,
      prevHash: '',
      policyVersion: 0,
      createdAtMs: 1000,
      clearText: Uint8List.fromList(utf8.encode('payload')),
      epochKey: key,
      random: Random(8),
    );
    final tampered = GroupEncryptedPayload(
      nonce: payload.nonce,
      cipherText: Uint8List.fromList(payload.cipherText)..[0] ^= 1,
      mac: payload.mac,
    );
    Future<Uint8List> open(GroupEncryptedPayload candidate, int epoch) =>
        decryptGroupPayload(
          groupId: _id(10),
          membershipEpoch: epoch,
          author: _id(1),
          seq: 0,
          prevHash: '',
          policyVersion: 0,
          createdAtMs: 1000,
          payload: candidate,
          epochKey: key,
        );
    await expectLater(open(tampered, 1), throwsFormatException);
    await expectLater(open(payload, 2), throwsFormatException);

    final mixed = GroupMessage(
      groupId: _id(10),
      author: _id(1),
      seq: 0,
      prevHash: '',
      body: '',
      version: 2,
      membershipEpoch: 1,
      encryptedPayload: payload,
      policyVersion: 0,
      createdAtMs: 1000,
      signature: Uint8List(64),
    ).toJson()..['body'] = 'cleartext injection';
    expect(GroupMessage.fromJson(mixed), isNull);
  });

  test(
    'reaction v2 is ciphertext-only and domain-separated from messages',
    () async {
      final key = Uint8List.fromList(List.generate(32, (index) => index));
      final clear = const GroupReactionCleartext(
        target: 'author:9',
        emoji: '🔥',
      ).encode();
      final payload = await encryptGroupReactionPayload(
        groupId: _id(10),
        membershipEpoch: 3,
        author: _id(1),
        seq: 4,
        createdAtMs: 5000,
        clearText: clear,
        epochKey: key,
        random: Random(12),
      );
      clear.fillRange(0, clear.length, 0);
      final reaction = GroupReaction(
        groupId: _id(10),
        author: _id(1),
        seq: 4,
        target: '',
        emoji: '',
        version: 2,
        membershipEpoch: 3,
        encryptedPayload: payload,
        createdAtMs: 5000,
        signature: Uint8List(64),
      );
      final encoded = jsonEncode(reaction.toJson());
      expect(encoded, isNot(contains('author:9')));
      expect(encoded, isNot(contains('🔥')));
      final parsed = GroupReaction.fromJson(reaction.toJson())!;
      final opened = await decryptGroupReactionPayload(
        groupId: parsed.groupId,
        membershipEpoch: parsed.membershipEpoch!,
        author: parsed.author,
        seq: parsed.seq,
        createdAtMs: parsed.createdAtMs,
        payload: parsed.encryptedPayload!,
        epochKey: key,
      );
      expect(GroupReactionCleartext.decode(opened)?.emoji, '🔥');
      opened.fillRange(0, opened.length, 0);
      await expectLater(
        decryptGroupPayload(
          groupId: parsed.groupId,
          membershipEpoch: parsed.membershipEpoch!,
          author: parsed.author,
          seq: parsed.seq,
          prevHash: '',
          policyVersion: 0,
          createdAtMs: parsed.createdAtMs,
          payload: parsed.encryptedPayload!,
          epochKey: key,
        ),
        throwsFormatException,
      );
      final mixed = Map<String, dynamic>.from(parsed.toJson())
        ..['emoji'] = 'clear';
      expect(GroupReaction.fromJson(mixed), isNull);
    },
  );

  test('typed reaction v4 binds the target namespace to ciphertext', () async {
    final key = Uint8List.fromList(List.generate(32, (index) => 31 - index));
    final clear = GroupReactionCleartext(
      target: '${_id(3).hex}:7',
      emoji: '👍',
      targetKind: ReactionTargetKind.spacePost,
      schemaVersion: 2,
    ).encode();
    final payload = await encryptGroupReactionPayload(
      groupId: _id(10),
      membershipEpoch: 5,
      author: _id(1),
      seq: 9,
      createdAtMs: 6000,
      clearText: clear,
      epochKey: key,
      reactionVersion: 4,
      random: Random(13),
    );
    clear.fillRange(0, clear.length, 0);
    final reaction = GroupReaction(
      groupId: _id(10),
      author: _id(1),
      seq: 9,
      target: '',
      emoji: '',
      version: 4,
      membershipEpoch: 5,
      encryptedPayload: payload,
      createdAtMs: 6000,
      signature: Uint8List(64),
    );
    final parsed = GroupReaction.fromJson(reaction.toJson())!;
    expect(parsed.version, 4);
    expect(parsed.isEncrypted, isTrue);
    final opened = await decryptGroupReactionPayload(
      groupId: parsed.groupId,
      membershipEpoch: parsed.membershipEpoch!,
      author: parsed.author,
      seq: parsed.seq,
      createdAtMs: parsed.createdAtMs,
      payload: parsed.encryptedPayload!,
      epochKey: key,
      reactionVersion: parsed.version,
    );
    final decoded = GroupReactionCleartext.decode(opened)!;
    expect(decoded.schemaVersion, 2);
    expect(decoded.targetKind, ReactionTargetKind.spacePost);
    opened.fillRange(0, opened.length, 0);
    await expectLater(
      decryptGroupReactionPayload(
        groupId: parsed.groupId,
        membershipEpoch: parsed.membershipEpoch!,
        author: parsed.author,
        seq: parsed.seq,
        createdAtMs: parsed.createdAtMs,
        payload: parsed.encryptedPayload!,
        epochKey: key,
      ),
      throwsFormatException,
    );

    final clearTyped = GroupReaction(
      groupId: _id(10),
      author: _id(1),
      seq: 10,
      target: '${_id(3).hex}:7',
      emoji: '👍',
      version: 3,
      targetKind: ReactionTargetKind.spacePost,
      createdAtMs: 6001,
      signature: Uint8List(64),
    );
    expect(
      GroupReaction.fromJson(clearTyped.toJson())!.targetKind,
      ReactionTargetKind.spacePost,
    );

    final lifecycle = 'ab' * 32;
    final lifecycleClear = GroupReactionCleartext(
      target: '${_id(3).hex}:7',
      emoji: '✅',
      targetKind: ReactionTargetKind.spacePost,
      schemaVersion: 2,
    ).encode();
    final lifecyclePayload = await encryptGroupReactionPayload(
      groupId: _id(10),
      membershipEpoch: 5,
      author: _id(1),
      seq: 11,
      createdAtMs: 6002,
      clearText: lifecycleClear,
      epochKey: key,
      reactionVersion: 6,
      lifecycleGeneration: lifecycle,
      random: Random(14),
    );
    lifecycleClear.fillRange(0, lifecycleClear.length, 0);
    final lifecycleReaction = GroupReaction(
      groupId: _id(10),
      author: _id(1),
      seq: 11,
      target: '',
      emoji: '',
      version: 6,
      membershipEpoch: 5,
      encryptedPayload: lifecyclePayload,
      lifecycleGeneration: lifecycle,
      createdAtMs: 6002,
      signature: Uint8List(64),
    );
    final lifecycleParsed = GroupReaction.fromJson(lifecycleReaction.toJson())!;
    expect(lifecycleParsed.lifecycleGeneration, lifecycle);
    final lifecycleOpened = await decryptGroupReactionPayload(
      groupId: lifecycleParsed.groupId,
      membershipEpoch: lifecycleParsed.membershipEpoch!,
      author: lifecycleParsed.author,
      seq: lifecycleParsed.seq,
      createdAtMs: lifecycleParsed.createdAtMs,
      payload: lifecycleParsed.encryptedPayload!,
      epochKey: key,
      reactionVersion: 6,
      lifecycleGeneration: lifecycle,
    );
    expect(GroupReactionCleartext.decode(lifecycleOpened)?.emoji, '✅');
    lifecycleOpened.fillRange(0, lifecycleOpened.length, 0);
    await expectLater(
      decryptGroupReactionPayload(
        groupId: lifecycleParsed.groupId,
        membershipEpoch: lifecycleParsed.membershipEpoch!,
        author: lifecycleParsed.author,
        seq: lifecycleParsed.seq,
        createdAtMs: lifecycleParsed.createdAtMs,
        payload: lifecycleParsed.encryptedPayload!,
        epochKey: key,
        reactionVersion: 6,
        lifecycleGeneration: 'cd' * 32,
      ),
      throwsFormatException,
    );

    final lifecyclePublic = GroupReaction(
      groupId: _id(10),
      author: _id(1),
      seq: 12,
      target: '${_id(3).hex}:7',
      emoji: '✅',
      version: 5,
      targetKind: ReactionTargetKind.spacePost,
      lifecycleGeneration: lifecycle,
      createdAtMs: 6003,
      signature: Uint8List(64),
    );
    expect(GroupReaction.fromJson(lifecyclePublic.toJson()), isNotNull);
    final missingLifecycle = Map<String, dynamic>.from(lifecyclePublic.toJson())
      ..remove('lifecycle');
    expect(GroupReaction.fromJson(missingLifecycle), isNull);
  });

  test(
    'restricted reaction v8 binds ciphertext to channel epoch and lifecycle',
    () async {
      final spaceId = _id(10);
      final channelId = _id(11);
      final author = _id(1);
      final key = Uint8List.fromList(
        List.generate(32, (index) => index ^ 0x5a),
      );
      final lifecycle = 'ef' * 32;
      final target = '${_id(3).hex}:7';
      final clear = GroupReactionCleartext(
        target: target,
        emoji: '🔐',
        schemaVersion: 2,
      ).encode();
      final payload = await encryptSpaceChannelReactionPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 4,
        author: author,
        seq: 12,
        createdAtMs: 7000,
        clearText: clear,
        channelKey: key,
        reactionVersion: 8,
        lifecycleGeneration: lifecycle,
        random: Random(15),
      );
      clear.fillRange(0, clear.length, 0);
      final reaction = GroupReaction(
        groupId: spaceId,
        author: author,
        seq: 12,
        target: '',
        emoji: '',
        version: 8,
        channelId: channelId,
        channelEpoch: 4,
        encryptedPayload: payload,
        lifecycleGeneration: lifecycle,
        createdAtMs: 7000,
        signature: Uint8List(64),
      );
      final wire = jsonEncode(reaction.toJson());
      expect(wire, isNot(contains(target)));
      expect(wire, isNot(contains('🔐')));
      final parsed = GroupReaction.fromJson(reaction.toJson())!;
      expect(parsed.isChannelEncrypted, isTrue);
      expect(parsed.isMembershipEncrypted, isFalse);
      expect(parsed.channelId, channelId);
      expect(parsed.channelEpoch, 4);
      final opened = await decryptSpaceChannelReactionPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 4,
        author: author,
        seq: 12,
        reactionVersion: 8,
        lifecycleGeneration: lifecycle,
        createdAtMs: 7000,
        payload: parsed.encryptedPayload!,
        channelKey: key,
      );
      final decoded = GroupReactionCleartext.decode(opened)!;
      expect(decoded.target, target);
      expect(decoded.emoji, '🔐');
      opened.fillRange(0, opened.length, 0);
      await expectLater(
        decryptSpaceChannelReactionPayload(
          spaceId: spaceId,
          channelId: _id(12),
          channelEpoch: 4,
          author: author,
          seq: 12,
          reactionVersion: 8,
          lifecycleGeneration: lifecycle,
          createdAtMs: 7000,
          payload: parsed.encryptedPayload!,
          channelKey: key,
        ),
        throwsFormatException,
      );
      final mixed = Map<String, dynamic>.from(parsed.toJson())..['epoch'] = 4;
      expect(GroupReaction.fromJson(mixed), isNull);
      final partial = Map<String, dynamic>.from(parsed.toJson())
        ..remove('cepoch');
      expect(GroupReaction.fromJson(partial), isNull);
    },
  );

  test(
    'channel control + message v3 bind the independent channel scope',
    () async {
      final spaceId = _id(10);
      final channelId = _id(11);
      final author = _id(1);
      final key = Uint8List.fromList(List.generate(32, (index) => 31 - index));
      final commitment = groupEpochKeyCommitment(
        groupId: channelId,
        epoch: 1,
        key: key,
      );
      final clear = SpaceChannelControlCleartext(
        channel: SpaceChannel(
          spaceId: spaceId,
          channelId: channelId,
          kind: SpaceChannelKind.text,
          name: 'hidden',
          description: 'metadata',
          position: 1,
          isDefault: false,
          archived: false,
          history: SpaceChannelHistory.fromJoin,
          createdBy: author,
          createdAtMs: 1000,
          access: SpaceChannelAccess.restricted,
        ),
        recipients: [author],
      ).encode();
      final encryptedControl = await encryptSpaceChannelControlPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        keyCommitment: commitment,
        author: author,
        policyVersion: 2,
        createdAtMs: 1001,
        clearText: clear,
        channelKey: key,
        random: Random(19),
      );
      clear.fillRange(0, clear.length, 0);
      final envelope = SpaceChannelControlEnvelope(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        keyDescriptor: GroupEpochDescriptor(
          groupId: channelId,
          epoch: 1,
          keyCommitment: commitment,
          envelopeRoot: _hash(7),
          recipientCount: 1,
        ),
        encryptedControl: encryptedControl,
      );
      expect(
        SpaceChannelControlEnvelope.fromJson(envelope.toJson()),
        isNotNull,
      );
      final openedControl = await decryptSpaceChannelControlPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        keyCommitment: commitment,
        author: author,
        policyVersion: 2,
        createdAtMs: 1001,
        payload: encryptedControl,
        channelKey: key,
      );
      expect(
        SpaceChannelControlCleartext.decode(openedControl)?.channel.name,
        'hidden',
      );
      openedControl.fillRange(0, openedControl.length, 0);
      await expectLater(
        decryptSpaceChannelControlPayload(
          spaceId: spaceId,
          channelId: _id(12),
          channelEpoch: 1,
          keyCommitment: commitment,
          author: author,
          policyVersion: 2,
          createdAtMs: 1001,
          payload: encryptedControl,
          channelKey: key,
        ),
        throwsFormatException,
      );

      final messageClear = const GroupMessageCleartext(body: 'scoped').encode();
      final encryptedMessage = await encryptSpaceChannelMessagePayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        author: author,
        seq: 3,
        prevHash: '',
        policyVersion: 2,
        createdAtMs: 1002,
        clearText: messageClear,
        channelKey: key,
        random: Random(20),
      );
      messageClear.fillRange(0, messageClear.length, 0);
      final message = GroupMessage(
        groupId: spaceId,
        channelId: channelId,
        author: author,
        seq: 3,
        prevHash: '',
        body: '',
        version: 3,
        channelEpoch: 1,
        encryptedPayload: encryptedMessage,
        policyVersion: 2,
        createdAtMs: 1002,
        signature: Uint8List(64),
      );
      final parsed = GroupMessage.fromJson(message.toJson())!;
      expect(parsed.isChannelEncrypted, isTrue);
      expect(jsonEncode(parsed.toJson()), isNot(contains('scoped')));
      final openedMessage = await decryptSpaceChannelMessagePayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: 1,
        author: author,
        seq: 3,
        prevHash: '',
        policyVersion: 2,
        createdAtMs: 1002,
        payload: parsed.encryptedPayload!,
        channelKey: key,
      );
      expect(GroupMessageCleartext.decode(openedMessage)?.body, 'scoped');
      openedMessage.fillRange(0, openedMessage.length, 0);
    },
  );
}
