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

/// Encrypt one restricted/secret channel metadata + ACL revision. The
/// descriptor commitment is authenticated independently from the signed outer
/// control entry so a ciphertext cannot be paired with another recipient set.
Future<GroupEncryptedPayload> encryptSpaceChannelControlPayload({
  required NodeId spaceId,
  required NodeId channelId,
  required int channelEpoch,
  required String keyCommitment,
  required NodeId author,
  required int policyVersion,
  required int createdAtMs,
  required Uint8List clearText,
  required Uint8List channelKey,
  Random? random,
}) async {
  if (channelEpoch <= 0 ||
      channelEpoch > 0xffffffff ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(keyCommitment) ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      clearText.length > maxGroupEncryptedPayloadBytes ||
      channelKey.length != 32) {
    throw ArgumentError('invalid Space channel control payload input');
  }
  final nonce = Uint8List(12);
  final rng = random ?? Random.secure();
  for (var index = 0; index < nonce.length; index++) {
    nonce[index] = rng.nextInt(256);
  }
  final box = await _groupAead.encrypt(
    clearText,
    secretKey: SecretKey(channelKey),
    nonce: nonce,
    aad: spaceChannelControlPayloadAad(
      spaceId: spaceId,
      channelId: channelId,
      channelEpoch: channelEpoch,
      keyCommitment: keyCommitment,
      author: author,
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

Future<Uint8List> decryptSpaceChannelControlPayload({
  required NodeId spaceId,
  required NodeId channelId,
  required int channelEpoch,
  required String keyCommitment,
  required NodeId author,
  required int policyVersion,
  required int createdAtMs,
  required GroupEncryptedPayload payload,
  required Uint8List channelKey,
}) async {
  if (channelEpoch <= 0 ||
      channelEpoch > 0xffffffff ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(keyCommitment) ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      !payload.isStructurallyValid ||
      channelKey.length != 32) {
    throw const FormatException('Space channel control payload rejected');
  }
  try {
    final clear = await _groupAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(channelKey),
      aad: spaceChannelControlPayloadAad(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: channelEpoch,
        keyCommitment: keyCommitment,
        author: author,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
      ),
    );
    if (clear.length > maxGroupEncryptedPayloadBytes) {
      throw const FormatException('Space channel control payload rejected');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('Space channel control payload rejected');
  }
}

/// Encrypt one message under a channel epoch instead of the Space membership
/// epoch. The channel id is part of AEAD AAD, so even a validly signed outer
/// row cannot transplant ciphertext between channels.
Future<GroupEncryptedPayload> encryptSpaceChannelMessagePayload({
  required NodeId spaceId,
  required NodeId channelId,
  required int channelEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required int policyVersion,
  required int createdAtMs,
  required Uint8List clearText,
  required Uint8List channelKey,
  Random? random,
}) async {
  if (channelEpoch <= 0 ||
      channelEpoch > 0xffffffff ||
      seq < 0 ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      clearText.length > maxGroupEncryptedPayloadBytes ||
      channelKey.length != 32) {
    throw ArgumentError('invalid Space channel message payload input');
  }
  final nonce = Uint8List(12);
  final rng = random ?? Random.secure();
  for (var index = 0; index < nonce.length; index++) {
    nonce[index] = rng.nextInt(256);
  }
  final box = await _groupAead.encrypt(
    clearText,
    secretKey: SecretKey(channelKey),
    nonce: nonce,
    aad: spaceChannelMessagePayloadAad(
      spaceId: spaceId,
      channelId: channelId,
      channelEpoch: channelEpoch,
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

Future<Uint8List> decryptSpaceChannelMessagePayload({
  required NodeId spaceId,
  required NodeId channelId,
  required int channelEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required int policyVersion,
  required int createdAtMs,
  required GroupEncryptedPayload payload,
  required Uint8List channelKey,
}) async {
  if (channelEpoch <= 0 ||
      channelEpoch > 0xffffffff ||
      seq < 0 ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      !payload.isStructurallyValid ||
      channelKey.length != 32) {
    throw const FormatException('Space channel message payload rejected');
  }
  try {
    final clear = await _groupAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(channelKey),
      aad: spaceChannelMessagePayloadAad(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: channelEpoch,
        author: author,
        seq: seq,
        prevHash: prevHash,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
      ),
    );
    if (clear.length > maxGroupEncryptedPayloadBytes) {
      throw const FormatException('Space channel message payload rejected');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('Space channel message payload rejected');
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
  int reactionVersion = 2,
  String lifecycleGeneration = '',
  Random? random,
}) async {
  if (membershipEpoch < 0 ||
      seq < 0 ||
      createdAtMs < 0 ||
      (reactionVersion == 6) !=
          RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycleGeneration) ||
      (reactionVersion != 6 && lifecycleGeneration.isNotEmpty) ||
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
      reactionVersion: reactionVersion,
      lifecycleGeneration: lifecycleGeneration,
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
  int reactionVersion = 2,
  String lifecycleGeneration = '',
}) async {
  if (membershipEpoch < 0 ||
      seq < 0 ||
      createdAtMs < 0 ||
      (reactionVersion == 6) !=
          RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycleGeneration) ||
      (reactionVersion != 6 && lifecycleGeneration.isNotEmpty) ||
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
        reactionVersion: reactionVersion,
        lifecycleGeneration: lifecycleGeneration,
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

Future<GroupEncryptedPayload> encryptSpacePostPayload({
  required NodeId spaceId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required String postType,
  required String visibility,
  required int policyVersion,
  required int createdAtMs,
  required int publishedAtMs,
  List<Map<String, dynamic>> controlFrontier = const [],
  String controlCheckpointHash = '',
  String postOperation = '',
  int? targetSeq,
  String lifecycleGeneration = '',
  required Uint8List clearText,
  required Uint8List epochKey,
  Random? random,
}) async {
  if (membershipEpoch <= 0 ||
      seq < 0 ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      publishedAtMs < createdAtMs ||
      clearText.length > maxGroupEncryptedPayloadBytes ||
      epochKey.length != 32 ||
      (controlFrontier.isNotEmpty && controlCheckpointHash.isNotEmpty) ||
      (controlCheckpointHash.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(controlCheckpointHash)) ||
      (lifecycleGeneration.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycleGeneration)) ||
      (postOperation.isEmpty
          ? targetSeq != null
          : !const {'publish', 'edit', 'delete'}.contains(postOperation) ||
                (postOperation == 'publish'
                    ? targetSeq != null
                    : targetSeq == null ||
                          targetSeq < 0 ||
                          targetSeq >= seq))) {
    throw ArgumentError('invalid Space post payload input');
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
    aad: spacePostPayloadAad(
      spaceId: spaceId,
      membershipEpoch: membershipEpoch,
      author: author,
      seq: seq,
      prevHash: prevHash,
      postType: postType,
      visibility: visibility,
      policyVersion: policyVersion,
      createdAtMs: createdAtMs,
      publishedAtMs: publishedAtMs,
      controlFrontier: controlFrontier,
      controlCheckpointHash: controlCheckpointHash,
      postOperation: postOperation,
      targetSeq: targetSeq,
      lifecycleGeneration: lifecycleGeneration,
    ),
  );
  return GroupEncryptedPayload(
    nonce: nonce,
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptSpacePostPayload({
  required NodeId spaceId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required String postType,
  required String visibility,
  required int policyVersion,
  required int createdAtMs,
  required int publishedAtMs,
  List<Map<String, dynamic>> controlFrontier = const [],
  String controlCheckpointHash = '',
  String postOperation = '',
  int? targetSeq,
  String lifecycleGeneration = '',
  required GroupEncryptedPayload payload,
  required Uint8List epochKey,
}) async {
  if (membershipEpoch <= 0 ||
      seq < 0 ||
      policyVersion < 0 ||
      createdAtMs < 0 ||
      publishedAtMs < createdAtMs ||
      !payload.isStructurallyValid ||
      epochKey.length != 32 ||
      (controlFrontier.isNotEmpty && controlCheckpointHash.isNotEmpty) ||
      (controlCheckpointHash.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(controlCheckpointHash)) ||
      (lifecycleGeneration.isNotEmpty &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(lifecycleGeneration)) ||
      (postOperation.isEmpty
          ? targetSeq != null
          : !const {'publish', 'edit', 'delete'}.contains(postOperation) ||
                (postOperation == 'publish'
                    ? targetSeq != null
                    : targetSeq == null ||
                          targetSeq < 0 ||
                          targetSeq >= seq))) {
    throw const FormatException('Space post payload rejected');
  }
  try {
    final clear = await _groupAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(epochKey),
      aad: spacePostPayloadAad(
        spaceId: spaceId,
        membershipEpoch: membershipEpoch,
        author: author,
        seq: seq,
        prevHash: prevHash,
        postType: postType,
        visibility: visibility,
        policyVersion: policyVersion,
        createdAtMs: createdAtMs,
        publishedAtMs: publishedAtMs,
        controlFrontier: controlFrontier,
        controlCheckpointHash: controlCheckpointHash,
        postOperation: postOperation,
        targetSeq: targetSeq,
        lifecycleGeneration: lifecycleGeneration,
      ),
    );
    if (clear.length > maxGroupEncryptedPayloadBytes) {
      throw const FormatException('Space post payload rejected');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('Space post payload rejected');
  }
}

Future<GroupEncryptedPayload> encryptGroupCallPayload({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required Uint8List clearText,
  required Uint8List epochKey,
  Random? random,
}) async {
  if (membershipEpoch <= 0 ||
      clearText.length > maxGroupEncryptedPayloadBytes ||
      epochKey.length != 32) {
    throw ArgumentError('invalid group call payload input');
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
    aad: groupCallPayloadAad(
      groupId: groupId,
      membershipEpoch: membershipEpoch,
      author: author,
    ),
  );
  return GroupEncryptedPayload(
    nonce: nonce,
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptGroupCallPayload({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
  required GroupEncryptedPayload payload,
  required Uint8List epochKey,
}) async {
  if (membershipEpoch <= 0 ||
      !payload.isStructurallyValid ||
      epochKey.length != 32) {
    throw const FormatException('group call payload rejected');
  }
  try {
    final clear = await _groupAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(epochKey),
      aad: groupCallPayloadAad(
        groupId: groupId,
        membershipEpoch: membershipEpoch,
        author: author,
      ),
    );
    if (clear.length > maxGroupEncryptedPayloadBytes) {
      throw const FormatException('group call payload rejected');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('group call payload rejected');
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

Uint8List spaceChannelControlPayloadAad({
  required NodeId spaceId,
  required NodeId channelId,
  required int channelEpoch,
  required String keyCommitment,
  required NodeId author,
  required int policyVersion,
  required int createdAtMs,
}) => Uint8List.fromList([
  ...utf8.encode('xveil.space-channel.control-aad.v1\u0000'),
  ...utf8.encode(
    jsonEncode({
      'sid': spaceId.hex,
      'cid': channelId.hex,
      'epoch': channelEpoch,
      'ekc': keyCommitment,
      'author': author.hex,
      'pv': policyVersion,
      'ts': createdAtMs,
    }),
  ),
]);

Uint8List spaceChannelMessagePayloadAad({
  required NodeId spaceId,
  required NodeId channelId,
  required int channelEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required int policyVersion,
  required int createdAtMs,
}) => Uint8List.fromList([
  ...utf8.encode('xveil.space-channel.message-aad.v1\u0000'),
  ...utf8.encode(
    jsonEncode({
      'sid': spaceId.hex,
      'cid': channelId.hex,
      'epoch': channelEpoch,
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
  int reactionVersion = 2,
  String lifecycleGeneration = '',
}) => Uint8List.fromList([
  ...utf8.encode(
    reactionVersion == 2
        ? 'xveil.group-reaction.payload-aad.v1\u0000'
        : reactionVersion == 6
        ? 'xveil.group-reaction.payload-aad.v3\u0000'
        : 'xveil.group-reaction.payload-aad.v2\u0000',
  ),
  ...utf8.encode(
    jsonEncode({
      if (reactionVersion != 2) 'rv': reactionVersion,
      if (reactionVersion == 6) 'lifecycle': lifecycleGeneration,
      'gid': groupId.hex,
      'epoch': membershipEpoch,
      'author': author.hex,
      'seq': seq,
      'ts': createdAtMs,
    }),
  ),
]);

Uint8List spacePostPayloadAad({
  required NodeId spaceId,
  required int membershipEpoch,
  required NodeId author,
  required int seq,
  required String prevHash,
  required String postType,
  required String visibility,
  required int policyVersion,
  required int createdAtMs,
  required int publishedAtMs,
  List<Map<String, dynamic>> controlFrontier = const [],
  String controlCheckpointHash = '',
  String postOperation = '',
  int? targetSeq,
  String lifecycleGeneration = '',
}) => Uint8List.fromList([
  ...utf8.encode(
    lifecycleGeneration.isNotEmpty
        ? 'xveil.space-post.payload-aad.v5\u0000'
        : postOperation.isNotEmpty
        ? 'xveil.space-post.payload-aad.v4\u0000'
        : controlCheckpointHash.isNotEmpty
        ? 'xveil.space-post.payload-aad.v3\u0000'
        : controlFrontier.isEmpty
        ? 'xveil.space-post.payload-aad.v1\u0000'
        : 'xveil.space-post.payload-aad.v2\u0000',
  ),
  ...utf8.encode(
    jsonEncode({
      'sid': spaceId.hex,
      'epoch': membershipEpoch,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'type': postType,
      'visibility': visibility,
      'pv': policyVersion,
      'created': createdAtMs,
      'published': publishedAtMs,
      if (controlFrontier.isNotEmpty) 'frontier': controlFrontier,
      if (controlCheckpointHash.isNotEmpty) 'checkpoint': controlCheckpointHash,
      if (postOperation.isNotEmpty) 'op': postOperation,
      'target': ?targetSeq,
      if (lifecycleGeneration.isNotEmpty) 'lifecycle': lifecycleGeneration,
    }),
  ),
]);

Uint8List groupCallPayloadAad({
  required NodeId groupId,
  required int membershipEpoch,
  required NodeId author,
}) => Uint8List.fromList([
  ...utf8.encode('xveil.group-call.payload-aad.v1\u0000'),
  ...utf8.encode(
    jsonEncode({
      'gid': groupId.hex,
      'epoch': membershipEpoch,
      'author': author.hex,
    }),
  ),
]);
