import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';

const int maxGroupEpochSealedEnvelopeBytes = 64 * 1024;
const int maxGroupEpochRecipientCount = 0xffffffff;
const int maxGroupEpochProofDepth = 32;

final RegExp _groupEpochHash = RegExp(r'^[0-9a-f]{64}$');

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexBytes(String value) {
  if (!_groupEpochHash.hasMatch(value)) {
    throw const FormatException('not 32-byte hex');
  }
  final result = Uint8List(32);
  for (var index = 0; index < result.length; index++) {
    result[index] = int.parse(
      value.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
  }
  return result;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

Uint8List _u32(int value) {
  if (value < 0 || value > 0xffffffff) {
    throw ArgumentError.value(value, 'value', 'must fit u32');
  }
  return (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();
}

String groupEpochKeyCommitment({
  required NodeId groupId,
  required int epoch,
  required Uint8List key,
}) {
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key.length', 'must be 32');
  }
  return _hex(
    crypto.sha256.convert([
      ...utf8.encode('xveil.group-epoch-key.commitment.v1\u0000'),
      ...groupId.bytes,
      ..._u32(epoch),
      ...key,
    ]).bytes,
  );
}

/// The compact epoch material signed inside a control-log entry.
///
/// The root commits to one independently deliverable ML-KEM envelope per
/// recipient. Unlike a monolithic recipient bundle, this shape remains fixed
/// size as group membership grows.
class GroupEpochDescriptor {
  const GroupEpochDescriptor({
    required this.groupId,
    required this.epoch,
    required this.keyCommitment,
    required this.envelopeRoot,
    required this.recipientCount,
  });

  final NodeId groupId;
  final int epoch;
  final String keyCommitment;
  final String envelopeRoot;
  final int recipientCount;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'gid': groupId.hex,
    'epoch': epoch,
    'ekc': keyCommitment,
    'root': envelopeRoot,
    'count': recipientCount,
  };

  static GroupEpochDescriptor? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final groupId = value['gid'];
    final epoch = value['epoch'];
    final commitment = value['ekc'];
    final root = value['root'];
    final count = value['count'];
    if (groupId is! String ||
        epoch is! int ||
        epoch < 0 ||
        epoch > 0xffffffff ||
        commitment is! String ||
        !_groupEpochHash.hasMatch(commitment) ||
        root is! String ||
        !_groupEpochHash.hasMatch(root) ||
        count is! int ||
        count < 1 ||
        count > maxGroupEpochRecipientCount) {
      return null;
    }
    try {
      return GroupEpochDescriptor(
        groupId: NodeId.fromHex(groupId),
        epoch: epoch,
        keyCommitment: commitment,
        envelopeRoot: root,
        recipientCount: count,
      );
    } catch (_) {
      return null;
    }
  }
}

class GroupEpochRecipientEnvelope {
  GroupEpochRecipientEnvelope({
    required this.groupId,
    required this.epoch,
    required this.keyCommitment,
    required this.recipient,
    required this.index,
    required this.recipientCount,
    required this.sealed,
    required List<String> proof,
  }) : proof = List.unmodifiable(proof);

  final NodeId groupId;
  final int epoch;
  final String keyCommitment;
  final NodeId recipient;
  final int index;
  final int recipientCount;
  final Uint8List sealed;
  final List<String> proof;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'gid': groupId.hex,
    'epoch': epoch,
    'ekc': keyCommitment,
    'recipient': recipient.hex,
    'index': index,
    'count': recipientCount,
    'sealed': base64Encode(sealed),
    'proof': proof,
  };

  static GroupEpochRecipientEnvelope? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final groupId = value['gid'];
    final epoch = value['epoch'];
    final commitment = value['ekc'];
    final recipient = value['recipient'];
    final index = value['index'];
    final count = value['count'];
    final rawSealed = value['sealed'];
    final rawProof = value['proof'];
    if (groupId is! String ||
        epoch is! int ||
        epoch < 0 ||
        epoch > 0xffffffff ||
        commitment is! String ||
        !_groupEpochHash.hasMatch(commitment) ||
        recipient is! String ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > maxGroupEpochRecipientCount ||
        index < 0 ||
        index >= count ||
        rawSealed is! String ||
        rawProof is! List ||
        rawProof.length > maxGroupEpochProofDepth ||
        rawProof.any(
          (entry) => entry is! String || !_groupEpochHash.hasMatch(entry),
        )) {
      return null;
    }
    try {
      final sealed = Uint8List.fromList(base64Decode(rawSealed));
      if (sealed.isEmpty || sealed.length > maxGroupEpochSealedEnvelopeBytes) {
        return null;
      }
      final envelope = GroupEpochRecipientEnvelope(
        groupId: NodeId.fromHex(groupId),
        epoch: epoch,
        keyCommitment: commitment,
        recipient: NodeId.fromHex(recipient),
        index: index,
        recipientCount: count,
        sealed: sealed,
        proof: rawProof.cast<String>(),
      );
      return envelope.proof.length == _proofDepth(count) ? envelope : null;
    } catch (_) {
      return null;
    }
  }
}

class GroupEpochSealSet {
  const GroupEpochSealSet({required this.descriptor, required this.envelopes});

  final GroupEpochDescriptor descriptor;
  final List<GroupEpochRecipientEnvelope> envelopes;

  GroupEpochRecipientEnvelope? envelopeFor(NodeId recipient) {
    for (final envelope in envelopes) {
      if (envelope.recipient == recipient) return envelope;
    }
    return null;
  }
}

GroupEpochSealSet buildGroupEpochSealSet({
  required NodeId groupId,
  required int epoch,
  required String keyCommitment,
  required Iterable<({NodeId recipient, Uint8List sealed})> entries,
}) {
  if (epoch < 0 ||
      epoch > 0xffffffff ||
      !_groupEpochHash.hasMatch(keyCommitment)) {
    throw ArgumentError('invalid group epoch seal set');
  }
  final ordered = [...entries]
    ..sort((left, right) => left.recipient.hex.compareTo(right.recipient.hex));
  if (ordered.isEmpty || ordered.length > maxGroupEpochRecipientCount) {
    throw ArgumentError.value(ordered.length, 'entries.length');
  }
  final recipients = ordered.map((entry) => entry.recipient.hex).toList();
  if (recipients.toSet().length != recipients.length ||
      ordered.any(
        (entry) =>
            entry.sealed.isEmpty ||
            entry.sealed.length > maxGroupEpochSealedEnvelopeBytes,
      )) {
    throw ArgumentError('invalid group epoch recipient envelope');
  }
  final levels = <List<Uint8List>>[
    [
      for (var index = 0; index < ordered.length; index++)
        _leafHash(
          groupId: groupId,
          epoch: epoch,
          keyCommitment: keyCommitment,
          recipient: ordered[index].recipient,
          index: index,
          recipientCount: ordered.length,
          sealed: ordered[index].sealed,
        ),
    ],
  ];
  while (levels.last.length > 1) {
    final current = levels.last;
    final next = <Uint8List>[];
    for (var index = 0; index < current.length; index += 2) {
      final left = current[index];
      final right = index + 1 < current.length ? current[index + 1] : left;
      next.add(_nodeHash(left, right));
    }
    levels.add(next);
  }
  final root = _hex(levels.last.single);
  final envelopes = <GroupEpochRecipientEnvelope>[];
  for (var leafIndex = 0; leafIndex < ordered.length; leafIndex++) {
    var index = leafIndex;
    final proof = <String>[];
    for (var levelIndex = 0; levelIndex < levels.length - 1; levelIndex++) {
      final level = levels[levelIndex];
      final siblingIndex = index.isEven ? index + 1 : index - 1;
      proof.add(
        _hex(siblingIndex < level.length ? level[siblingIndex] : level[index]),
      );
      index ~/= 2;
    }
    envelopes.add(
      GroupEpochRecipientEnvelope(
        groupId: groupId,
        epoch: epoch,
        keyCommitment: keyCommitment,
        recipient: ordered[leafIndex].recipient,
        index: leafIndex,
        recipientCount: ordered.length,
        sealed: Uint8List.fromList(ordered[leafIndex].sealed),
        proof: proof,
      ),
    );
  }
  return GroupEpochSealSet(
    descriptor: GroupEpochDescriptor(
      groupId: groupId,
      epoch: epoch,
      keyCommitment: keyCommitment,
      envelopeRoot: root,
      recipientCount: ordered.length,
    ),
    envelopes: List.unmodifiable(envelopes),
  );
}

bool verifyGroupEpochEnvelope({
  required GroupEpochDescriptor descriptor,
  required GroupEpochRecipientEnvelope envelope,
}) {
  if (envelope.groupId != descriptor.groupId ||
      envelope.epoch != descriptor.epoch ||
      envelope.keyCommitment != descriptor.keyCommitment ||
      envelope.recipientCount != descriptor.recipientCount ||
      envelope.index < 0 ||
      envelope.index >= envelope.recipientCount ||
      envelope.proof.length != _proofDepth(envelope.recipientCount) ||
      envelope.sealed.isEmpty ||
      envelope.sealed.length > maxGroupEpochSealedEnvelopeBytes) {
    return false;
  }
  var current = _leafHash(
    groupId: envelope.groupId,
    epoch: envelope.epoch,
    keyCommitment: envelope.keyCommitment,
    recipient: envelope.recipient,
    index: envelope.index,
    recipientCount: envelope.recipientCount,
    sealed: envelope.sealed,
  );
  var index = envelope.index;
  try {
    for (final siblingHex in envelope.proof) {
      final sibling = _hexBytes(siblingHex);
      current = index.isEven
          ? _nodeHash(current, sibling)
          : _nodeHash(sibling, current);
      index ~/= 2;
    }
    return _sameBytes(current, _hexBytes(descriptor.envelopeRoot));
  } catch (_) {
    return false;
  }
}

Uint8List encodeGroupEpochKeyPayload({
  required NodeId groupId,
  required int epoch,
  required Uint8List key,
}) {
  final commitment = groupEpochKeyCommitment(
    groupId: groupId,
    epoch: epoch,
    key: key,
  );
  final result = Uint8List(1 + 32 + 4 + 32 + 32);
  result[0] = 1;
  result.setRange(1, 33, groupId.bytes);
  result.setRange(33, 37, _u32(epoch));
  result.setRange(37, 69, key);
  result.setRange(69, 101, _hexBytes(commitment));
  return result;
}

class GroupOpenedEpochKey {
  GroupOpenedEpochKey({
    required this.groupId,
    required this.epoch,
    required this.key,
    required this.keyCommitment,
  });

  final NodeId groupId;
  final int epoch;
  final Uint8List key;
  final String keyCommitment;
}

GroupOpenedEpochKey? decodeGroupEpochKeyPayload(Uint8List payload) {
  if (payload.length != 101 || payload[0] != 1) return null;
  try {
    final groupId = NodeId(Uint8List.fromList(payload.sublist(1, 33)));
    final epoch = ByteData.sublistView(
      payload,
      33,
      37,
    ).getUint32(0, Endian.big);
    final key = Uint8List.fromList(payload.sublist(37, 69));
    final commitment = groupEpochKeyCommitment(
      groupId: groupId,
      epoch: epoch,
      key: key,
    );
    if (!_sameBytes(payload.sublist(69, 101), _hexBytes(commitment))) {
      key.fillRange(0, key.length, 0);
      return null;
    }
    return GroupOpenedEpochKey(
      groupId: groupId,
      epoch: epoch,
      key: key,
      keyCommitment: commitment,
    );
  } catch (_) {
    return null;
  }
}

int _proofDepth(int count) {
  var width = count;
  var depth = 0;
  while (width > 1) {
    width = (width + 1) ~/ 2;
    depth++;
  }
  return depth;
}

Uint8List _leafHash({
  required NodeId groupId,
  required int epoch,
  required String keyCommitment,
  required NodeId recipient,
  required int index,
  required int recipientCount,
  required Uint8List sealed,
}) => Uint8List.fromList(
  crypto.sha256.convert([
    ...utf8.encode('xveil.group-epoch-envelope.leaf.v1\u0000'),
    ...groupId.bytes,
    ..._u32(epoch),
    ..._hexBytes(keyCommitment),
    ...recipient.bytes,
    ..._u32(index),
    ..._u32(recipientCount),
    ...crypto.sha256.convert(sealed).bytes,
  ]).bytes,
);

Uint8List _nodeHash(Uint8List left, Uint8List right) => Uint8List.fromList(
  crypto.sha256.convert([
    ...utf8.encode('xveil.group-epoch-envelope.node.v1\u0000'),
    ...left,
    ...right,
  ]).bytes,
);
