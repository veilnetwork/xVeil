import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/cloud_document_envelope.dart';
import 'package:xveil/state/cloud_document_envelope_service.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

NodeId _id(int byte) => NodeId.fromHex(_hash(byte));

void main() {
  test('binary epoch-key payload binds document, epoch and commitment', () {
    final key = Uint8List.fromList(List.generate(32, (index) => index));
    final payload = encodeCloudDocumentEpochKeyPayload(
      documentId: _id(10),
      epoch: 7,
      key: key,
    );
    expect(payload.length, 101);
    final opened = decodeCloudDocumentEpochKeyPayload(payload);
    expect(opened, isNotNull);
    expect(opened!.documentId, _id(10));
    expect(opened.epoch, 7);
    expect(opened.key, key);
    expect(
      opened.keyCommitment,
      cloudDocumentEpochKeyCommitment(documentId: _id(10), epoch: 7, key: key),
    );

    final tampered = Uint8List.fromList(payload)..[50] ^= 1;
    expect(decodeCloudDocumentEpochKeyPayload(tampered), isNull);
  });

  test(
    'bundle codec is canonical, sorted, bounded and recipient-addressed',
    () {
      final bundle = CloudDocumentEpochEnvelopeBundle(
        documentId: _id(10),
        epoch: 1,
        keyCommitment: _hash(20),
        envelopes: [
          CloudDocumentRecipientEnvelope(
            recipient: _id(2),
            sealed: Uint8List.fromList([2]),
          ),
          CloudDocumentRecipientEnvelope(
            recipient: _id(3),
            sealed: Uint8List.fromList([3]),
          ),
        ],
      );
      final parsed = CloudDocumentEpochEnvelopeBundle.fromJson(bundle.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.canonicalBytes(), bundle.canonicalBytes());
      expect(parsed.bundleHash, bundle.bundleHash);
      expect(parsed.envelopeFor(_id(3))!.sealed, [3]);
      expect(parsed.envelopeFor(_id(4)), isNull);

      final reversed = Map<String, dynamic>.from(bundle.toJson())
        ..['entries'] = (bundle.toJson()['entries'] as List).reversed.toList();
      expect(CloudDocumentEpochEnvelopeBundle.fromJson(reversed), isNull);
    },
  );

  test(
    'mailbox-backed envelope roundtrip verifies owner and bundle hash',
    () async {
      final owner = _id(1);
      final recipient = _id(2);
      final service = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final key = Uint8List.fromList(List.generate(32, (index) => 255 - index));
      final bundle = await service.sealEpoch(
        documentId: _id(10),
        epoch: 4,
        epochKey: key,
        recipients: [recipient, _id(3), recipient],
      );
      expect(bundle.envelopes.map((entry) => entry.recipient), [
        recipient,
        _id(3),
      ]);
      expect(
        bundle.keyCommitment,
        cloudDocumentEpochKeyCommitment(
          documentId: _id(10),
          epoch: 4,
          key: key,
        ),
      );

      final opened = await service.openEpoch(
        bundle: bundle,
        expectedBundleHash: bundle.bundleHash,
        recipient: recipient,
        expectedOwner: owner,
        ourCertVersion: 0,
      );
      expect(opened.key, key);
      expect(opened.documentId, _id(10));
      expect(opened.epoch, 4);
      expect(
        key,
        isNot(everyElement(0)),
        reason: 'caller-owned key is not wiped',
      );

      await expectLater(
        service.openEpoch(
          bundle: bundle,
          expectedBundleHash: _hash(99),
          recipient: recipient,
          expectedOwner: owner,
          ourCertVersion: 0,
        ),
        throwsStateError,
      );
      await expectLater(
        service.openEpoch(
          bundle: bundle,
          expectedBundleHash: bundle.bundleHash,
          recipient: recipient,
          expectedOwner: _id(9),
          ourCertVersion: 0,
        ),
        throwsStateError,
      );
      await expectLater(
        service.openEpoch(
          bundle: bundle,
          expectedBundleHash: bundle.bundleHash,
          recipient: _id(8),
          expectedOwner: owner,
          ourCertVersion: 0,
        ),
        throwsStateError,
      );

      final originalEnvelope = bundle.envelopeFor(recipient)!;
      final tamperedSealed = Uint8List.fromList(originalEnvelope.sealed)
        ..[originalEnvelope.sealed.length - 1] ^= 1;
      final tamperedBundle = CloudDocumentEpochEnvelopeBundle(
        documentId: bundle.documentId,
        epoch: bundle.epoch,
        keyCommitment: bundle.keyCommitment,
        envelopes: [
          CloudDocumentRecipientEnvelope(
            recipient: recipient,
            sealed: tamperedSealed,
          ),
          bundle.envelopeFor(_id(3))!,
        ],
      );
      await expectLater(
        service.openEpoch(
          bundle: tamperedBundle,
          expectedBundleHash: tamperedBundle.bundleHash,
          recipient: recipient,
          expectedOwner: owner,
          ourCertVersion: 0,
        ),
        throwsStateError,
      );

      final duplicateRecipientBundle = CloudDocumentEpochEnvelopeBundle(
        documentId: bundle.documentId,
        epoch: bundle.epoch,
        keyCommitment: bundle.keyCommitment,
        envelopes: [originalEnvelope, originalEnvelope],
      );
      await expectLater(
        service.openEpoch(
          bundle: duplicateRecipientBundle,
          expectedBundleHash: duplicateRecipientBundle.bundleHash,
          recipient: recipient,
          expectedOwner: owner,
          ourCertVersion: 0,
        ),
        throwsStateError,
      );
    },
  );
}
