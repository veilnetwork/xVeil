import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_reaction.dart';

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
}
