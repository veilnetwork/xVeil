import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/state/committed_device_events.dart';

GroupMessage row(
  int seq, {
  String body = 'content',
  int author = 2,
  int signature = 3,
  int group = 1,
}) => GroupMessage(
  groupId: NodeId(Uint8List(32)..fillRange(0, 32, group)),
  author: NodeId(Uint8List(32)..fillRange(0, 32, author)),
  seq: seq,
  prevHash: '0' * 64,
  body: body,
  policyVersion: 1,
  createdAtMs: 1700000000000,
  signature: Uint8List(64)..fillRange(0, 64, signature),
);

void main() {
  test('25 new events do not serialize the unrelated durable history', () {
    final fresh = [for (var i = 1000; i < 1025; i++) row(i)];
    final committed = [for (var i = 0; i < 1025; i++) row(i)];
    var hashed = 0;
    final hashes = committedDeviceEventHashes(
      committed,
      fresh,
      hashMessage: (message) {
        hashed++;
        return groupMessageHash(message);
      },
    );
    for (final event in fresh) {
      expect(hashes, contains(groupMessageHash(event)));
    }
    expect(hashed, 25, reason: 'only candidate rows need full commitments');
  });

  test('a signed-slot collision still requires the exact full commitment', () {
    final committed = row(1);
    for (final fresh in [row(1, body: 'different'), row(1, group: 7)]) {
      final hashes = committedDeviceEventHashes(
        [committed],
        [fresh],
        hashMessage: groupMessageHash,
      );
      expect(hashes, isNot(contains(groupMessageHash(fresh))));
    }
  });

  test('different signatures or authors do not match a stored event', () {
    final committed = row(1);
    for (final fresh in [row(1, signature: 4), row(1, author: 5)]) {
      final hashes = committedDeviceEventHashes(
        [committed],
        [fresh],
        hashMessage: groupMessageHash,
      );
      expect(hashes, isNot(contains(groupMessageHash(fresh))));
    }
  });

  test('each invocation rechecks mutable IDs and signature bytes', () {
    final committed = row(1), fresh = row(1);
    Set<String> index() => committedDeviceEventHashes(
      [committed],
      [fresh],
      hashMessage: groupMessageHash,
    );
    final wanted = groupMessageHash(fresh);
    expect(index(), contains(wanted));
    committed.groupId.bytes[0] ^= 1;
    expect(index(), isNot(contains(wanted)));
    committed.groupId.bytes[0] ^= 1;
    committed.signature[0] ^= 1;
    expect(index(), isNot(contains(wanted)));
    committed.signature[0] ^= 1;
    committed.author.bytes[0] ^= 1;
    expect(index(), isNot(contains(wanted)));
    committed.author.bytes[0] ^= 1;
    expect(index(), contains(wanted));
  });

  test('all competing rows in a candidate slot remain distinguishable', () {
    final committed = [for (var i = 0; i < 20; i++) row(1, body: 'branch-$i')];
    final fresh = [row(1, body: 'branch-7'), row(1, body: 'not-committed')];
    final hashes = committedDeviceEventHashes(
      committed,
      fresh,
      hashMessage: groupMessageHash,
    );
    expect(hashes, contains(groupMessageHash(fresh[0])));
    expect(hashes, isNot(contains(groupMessageHash(fresh[1]))));
  });

  test('encrypted bytes are compared by full hash on every invocation', () {
    GroupMessage encrypted() {
      final value = row(1);
      return GroupMessage(
        groupId: value.groupId,
        author: value.author,
        seq: value.seq,
        prevHash: value.prevHash,
        body: '',
        version: 2,
        membershipEpoch: 1,
        encryptedPayload: GroupEncryptedPayload(
          nonce: Uint8List(12),
          cipherText: Uint8List.fromList([1, 2, 3]),
          mac: Uint8List(16),
        ),
        policyVersion: value.policyVersion,
        createdAtMs: value.createdAtMs,
        signature: value.signature,
      );
    }

    final committed = encrypted(), fresh = encrypted();
    Set<String> index() => committedDeviceEventHashes(
      [committed],
      [fresh],
      hashMessage: groupMessageHash,
    );
    final wanted = groupMessageHash(fresh);
    expect(index(), contains(wanted));
    final payload = committed.encryptedPayload!;
    for (final bytes in [payload.nonce, payload.cipherText, payload.mac]) {
      bytes[0] ^= 1;
      expect(index(), isNot(contains(wanted)));
      bytes[0] ^= 1;
      expect(index(), contains(wanted));
    }
  });

  test('duplicate candidates do not repeat durable hashing', () {
    final fresh = row(1);
    var hashed = 0;
    final hashes = committedDeviceEventHashes(
      [row(1)],
      [fresh, fresh],
      hashMessage: (message) {
        hashed++;
        return groupMessageHash(message);
      },
    );
    expect(hashes, contains(groupMessageHash(fresh)));
    expect(hashed, 1);
  });

  test('empty ingress needs no durable payload serialization', () {
    var hashed = 0;
    committedDeviceEventHashes(
      [for (var i = 0; i < 100; i++) row(i)],
      const [],
      hashMessage: (message) {
        hashed++;
        return groupMessageHash(message);
      },
    );
    expect(hashed, 0);
  });
}
