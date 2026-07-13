import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/ids.dart';

const int maxGroupEncryptedPayloadBytes = 1024 * 1024;

final Chacha20 _groupAead = Chacha20.poly1305Aead();

class GroupEncryptedPayload {
  GroupEncryptedPayload({
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  bool get isStructurallyValid =>
      nonce.length == 12 &&
      mac.length == 16 &&
      cipherText.length <= maxGroupEncryptedPayloadBytes;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'nonce': base64Encode(nonce),
    'ct': base64Encode(cipherText),
    'mac': base64Encode(mac),
  };

  static GroupEncryptedPayload? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final nonce = value['nonce'];
    final cipherText = value['ct'];
    final mac = value['mac'];
    if (nonce is! String || cipherText is! String || mac is! String) {
      return null;
    }
    try {
      final payload = GroupEncryptedPayload(
        nonce: Uint8List.fromList(base64Decode(nonce)),
        cipherText: Uint8List.fromList(base64Decode(cipherText)),
        mac: Uint8List.fromList(base64Decode(mac)),
      );
      return payload.isStructurallyValid ? payload : null;
    } catch (_) {
      return null;
    }
  }
}

Future<GroupEncryptedPayload> encryptGroupPayload({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required int policyVersion,
  required int createdAtMs,
  required Uint8List clearText,
  required Uint8List epochKey,
  Random? random,
}) async {
  if (membershipEpoch < 0 ||
      seq < 0 ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      clearText.length > maxGroupEncryptedPayloadBytes ||
      epochKey.length != 32) {
    throw ArgumentError('invalid group payload input');
  }
  final nonce = Uint8List(12);
  final rng = random ?? Random.secure();
  for (var index = 0; index < nonce.length; index++) {
    nonce[index] = rng.nextInt(256);
  }
  final box = await _groupAead.encrypt(
    clearText,
    secretKey: SecretKey(epochKey),
    nonce: nonce,
    aad: groupPayloadAad(
      groupId: groupId,
      membershipEpoch: membershipEpoch,
      author: author,
      seq: seq,
      prevHash: prevHash,
      policyVersion: policyVersion,
      createdAtMs: createdAtMs,
    ),
  );
  return GroupEncryptedPayload(
    nonce: nonce,
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptGroupPayload({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required int policyVersion,
  required int createdAtMs,
  required GroupEncryptedPayload payload,
  required Uint8List epochKey,
}) async {
  if (membershipEpoch < 0 ||
      seq < 0 ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      !payload.isStructurallyValid ||
      epochKey.length != 32) {
    throw const FormatException('group payload rejected');
  }
  try {
    final clear = await _groupAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(epochKey),
      aad: groupPayloadAad(
        groupId: groupId,
        membershipEpoch: membershipEpoch,
        author: author,
        seq: seq,
        prevHash: prevHash,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
      ),
    );
    if (clear.length > maxGroupEncryptedPayloadBytes) {
      throw const FormatException('group payload rejected');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('group payload rejected');
  }
}

Future<GroupEncryptedPayload> encryptGroupReactionPayload({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required int createdAtMs,
  required Uint8List clearText,
  required Uint8List epochKey,
  Random? random,
}) async {
  if (membershipEpoch < 0 ||
      seq < 0 ||
      createdAtMs < 0 ||
      clearText.length > maxGroupEncryptedPayloadBytes ||
      epochKey.length != 32) {
    throw ArgumentError('invalid group reaction payload input');
  }
  final nonce = Uint8List(12);
  final rng = random ?? Random.secure();
  for (var index = 0; index < nonce.length; index++) {
    nonce[index] = rng.nextInt(256);
  }
  final box = await _groupAead.encrypt(
    clearText,
    secretKey: SecretKey(epochKey),
    nonce: nonce,
    aad: groupReactionPayloadAad(
      groupId: groupId,
      membershipEpoch: membershipEpoch,
      author: author,
      seq: seq,
      createdAtMs: createdAtMs,
    ),
  );
  return GroupEncryptedPayload(
    nonce: nonce,
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptGroupReactionPayload({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required int createdAtMs,
  required GroupEncryptedPayload payload,
  required Uint8List epochKey,
}) async {
  if (membershipEpoch < 0 ||
      seq < 0 ||
      createdAtMs < 0 ||
      !payload.isStructurallyValid ||
      epochKey.length != 32) {
    throw const FormatException('group reaction payload rejected');
  }
  try {
    final clear = await _groupAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(epochKey),
      aad: groupReactionPayloadAad(
        groupId: groupId,
        membershipEpoch: membershipEpoch,
        author: author,
        seq: seq,
        createdAtMs: createdAtMs,
      ),
    );
    if (clear.length > maxGroupEncryptedPayloadBytes) {
      throw const FormatException('group reaction payload rejected');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('group reaction payload rejected');
  }
}

Uint8List groupPayloadAad({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required int policyVersion,
  required int createdAtMs,
}) => Uint8List.fromList([
  ...utf8.encode('xveil.group-message.payload-aad.v1\u0000'),
  ...utf8.encode(
    jsonEncode({
      'gid': groupId.hex,
      'epoch': membershipEpoch,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'pv': policyVersion,
      'ts': createdAtMs,
    }),
  ),
]);

Uint8List groupReactionPayloadAad({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required int createdAtMs,
}) => Uint8List.fromList([
  ...utf8.encode('xveil.group-reaction.payload-aad.v1\u0000'),
  ...utf8.encode(
    jsonEncode({
      'gid': groupId.hex,
      'epoch': membershipEpoch,
      'author': author.hex,
      'seq': seq,
      'ts': createdAtMs,
    }),
  ),
]);
