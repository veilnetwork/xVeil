import 'dart:typed_data';

import '../core/ids.dart';
import '../data/transport/veil_mailbox.dart';
import '../domain/cloud_document_envelope.dart';

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

class CloudDocumentEnvelopeService {
  CloudDocumentEnvelopeService(this._crypto);

  final VeilMailboxCrypto _crypto;

  Future<CloudDocumentEpochEnvelopeBundle> sealEpoch({
    required NodeId documentId,
    required int epoch,
    required Uint8List epochKey,
    required Iterable<NodeId> recipients,
  }) async {
    if (epochKey.length != 32) {
      throw ArgumentError.value(
        epochKey.length,
        'epochKey.length',
        'must be 32',
      );
    }
    final ordered = recipients.toSet().toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    if (ordered.isEmpty ||
        ordered.length > maxCloudDocumentEnvelopeRecipients) {
      throw ArgumentError.value(
        ordered.length,
        'recipients.length',
        'must be 1..$maxCloudDocumentEnvelopeRecipients',
      );
    }
    final payload = encodeCloudDocumentEpochKeyPayload(
      documentId: documentId,
      epoch: epoch,
      key: epochKey,
    );
    final envelopes = <CloudDocumentRecipientEnvelope>[];
    try {
      for (final recipient in ordered) {
        final copy = Uint8List.fromList(payload);
        try {
          final sealed = await _crypto.seal(
            recipient: recipient,
            appId: cloudDocumentEnvelopeAppId,
            endpointId: cloudDocumentEnvelopeEndpointId,
            data: copy,
          );
          if (sealed.isEmpty ||
              sealed.length > maxCloudDocumentSealedEnvelopeBytes) {
            throw StateError('document envelope rejected');
          }
          envelopes.add(
            CloudDocumentRecipientEnvelope(
              recipient: recipient,
              sealed: Uint8List.fromList(sealed),
            ),
          );
        } finally {
          copy.fillRange(0, copy.length, 0);
        }
      }
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
    return CloudDocumentEpochEnvelopeBundle(
      documentId: documentId,
      epoch: epoch,
      keyCommitment: cloudDocumentEpochKeyCommitment(
        documentId: documentId,
        epoch: epoch,
        key: epochKey,
      ),
      envelopes: envelopes,
    );
  }

  Future<CloudDocumentOpenedEpochKey> openEpoch({
    required CloudDocumentEpochEnvelopeBundle bundle,
    required String expectedBundleHash,
    required NodeId recipient,
    required NodeId expectedOwner,
    required int ourCertVersion,
  }) async {
    if (CloudDocumentEpochEnvelopeBundle.fromJson(bundle.toJson()) == null ||
        bundle.bundleHash != expectedBundleHash) {
      throw StateError('document envelope rejected');
    }
    final envelope = bundle.envelopeFor(recipient);
    if (envelope == null) throw StateError('document envelope rejected');
    OpenedMailboxMessage? opened;
    CloudDocumentOpenedEpochKey? key;
    try {
      opened = await _crypto.open(
        blob: envelope.sealed,
        ourCertVersion: ourCertVersion,
      );
      if (opened.verifiedSender != expectedOwner ||
          opened.endpointId != cloudDocumentEnvelopeEndpointId ||
          !_sameBytes(opened.appId, cloudDocumentEnvelopeAppId)) {
        throw StateError('document envelope rejected');
      }
      key = decodeCloudDocumentEpochKeyPayload(opened.data);
      if (key == null ||
          key.documentId != bundle.documentId ||
          key.epoch != bundle.epoch ||
          key.keyCommitment != bundle.keyCommitment) {
        key?.key.fillRange(0, key.key.length, 0);
        throw StateError('document envelope rejected');
      }
      return key;
    } catch (_) {
      key?.key.fillRange(0, key.key.length, 0);
      throw StateError('document envelope rejected');
    } finally {
      opened?.data.fillRange(0, opened.data.length, 0);
    }
  }
}
