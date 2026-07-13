import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import '../data/transport/veil_mailbox.dart';
import '../domain/group_epoch.dart';

final Uint8List groupEpochEnvelopeAppId = Uint8List.fromList(
  crypto.sha256.convert(utf8.encode('xveil.group-epoch-key.app.v1')).bytes,
);

const int groupEpochEnvelopeEndpointId = 63;

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

class GroupEpochService {
  GroupEpochService(this._crypto);

  final VeilMailboxCrypto _crypto;

  Future<GroupEpochSealSet> sealEpoch({
    required NodeId groupId,
    required int epoch,
    required Uint8List epochKey,
    required Iterable<NodeId> recipients,
  }) async {
    if (epochKey.length != 32 || epoch < 0 || epoch > 0xffffffff) {
      throw ArgumentError('invalid group epoch key');
    }
    final ordered = recipients.toSet().toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    if (ordered.isEmpty || ordered.length > maxGroupEpochRecipientCount) {
      throw ArgumentError.value(ordered.length, 'recipients.length');
    }
    final commitment = groupEpochKeyCommitment(
      groupId: groupId,
      epoch: epoch,
      key: epochKey,
    );
    final payload = encodeGroupEpochKeyPayload(
      groupId: groupId,
      epoch: epoch,
      key: epochKey,
    );
    final sealedEntries = <({NodeId recipient, Uint8List sealed})>[];
    try {
      for (final recipient in ordered) {
        final clearCopy = Uint8List.fromList(payload);
        try {
          final sealed = await _crypto.seal(
            recipient: recipient,
            appId: groupEpochEnvelopeAppId,
            endpointId: groupEpochEnvelopeEndpointId,
            data: clearCopy,
          );
          if (sealed.isEmpty ||
              sealed.length > maxGroupEpochSealedEnvelopeBytes) {
            throw StateError('group epoch envelope rejected');
          }
          sealedEntries.add((
            recipient: recipient,
            sealed: Uint8List.fromList(sealed),
          ));
        } finally {
          clearCopy.fillRange(0, clearCopy.length, 0);
        }
      }
      return buildGroupEpochSealSet(
        groupId: groupId,
        epoch: epoch,
        keyCommitment: commitment,
        entries: sealedEntries,
      );
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  Future<GroupOpenedEpochKey> openEpoch({
    required GroupEpochDescriptor descriptor,
    required GroupEpochRecipientEnvelope envelope,
    required NodeId recipient,
    required NodeId expectedIssuer,
    required int ourCertVersion,
  }) async {
    if (envelope.recipient != recipient ||
        !verifyGroupEpochEnvelope(descriptor: descriptor, envelope: envelope)) {
      throw StateError('group epoch envelope rejected');
    }
    OpenedMailboxMessage? opened;
    GroupOpenedEpochKey? key;
    try {
      opened = await _crypto.open(
        blob: envelope.sealed,
        ourCertVersion: ourCertVersion,
      );
      if (opened.verifiedSender != expectedIssuer ||
          opened.endpointId != groupEpochEnvelopeEndpointId ||
          !_sameBytes(opened.appId, groupEpochEnvelopeAppId)) {
        throw StateError('group epoch envelope rejected');
      }
      key = decodeGroupEpochKeyPayload(opened.data);
      if (key == null ||
          key.groupId != descriptor.groupId ||
          key.epoch != descriptor.epoch ||
          key.keyCommitment != descriptor.keyCommitment) {
        key?.key.fillRange(0, key.key.length, 0);
        throw StateError('group epoch envelope rejected');
      }
      return key;
    } catch (_) {
      key?.key.fillRange(0, key.key.length, 0);
      throw StateError('group epoch envelope rejected');
    } finally {
      opened?.data.fillRange(0, opened.data.length, 0);
    }
  }
}
