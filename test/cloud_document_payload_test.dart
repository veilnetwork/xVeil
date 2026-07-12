import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/domain/cloud_document_payload.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

CloudDocumentOperation _operation({int epoch = 2, int seq = 4}) =>
    CloudDocumentOperation(
      documentId: NodeId.fromHex(_hash(1)),
      membershipEpoch: epoch,
      author: NodeId.fromHex(_hash(2)),
      seq: seq,
      prevAuthorHash: _hash(3),
      operationId: _hash(4),
      parentOperationIds: [_hash(5)],
      opType: 'text.insert',
      payloadHash: _hash(0),
      createdAtMs: 1234,
      authorPubKey: Uint8List.fromList(List.filled(32, 2)),
      signature: Uint8List.fromList(List.filled(64, 2)),
    );

void main() {
  test(
    'payload AEAD round-trips and is bound to the signed operation',
    () async {
      final key = Uint8List.fromList(List.generate(32, (index) => index));
      final clear = Uint8List.fromList(
        utf8.encode('private collaborative text'),
      );
      final unsigned = _operation();
      final payload = await encryptCloudDocumentPayload(
        operation: unsigned,
        clearText: clear,
        epochKey: key,
        random: Random(7),
      );
      final operation = unsigned.withPayloadHash(payload.payloadHash);

      expect(
        await decryptCloudDocumentPayload(
          operation: operation,
          payload: payload,
          epochKey: key,
        ),
        clear,
      );
      expect(
        CloudDocumentEncryptedPayload.fromJson(payload.toJson())!.payloadHash,
        payload.payloadHash,
      );

      final moved = _operation(seq: 5).withPayloadHash(payload.payloadHash);
      await expectLater(
        decryptCloudDocumentPayload(
          operation: moved,
          payload: payload,
          epochKey: key,
        ),
        throwsFormatException,
      );
    },
  );

  test('tamper, wrong key, wrong epoch and oversize fail closed', () async {
    final key = Uint8List.fromList(List.filled(32, 8));
    final unsigned = _operation();
    final payload = await encryptCloudDocumentPayload(
      operation: unsigned,
      clearText: Uint8List.fromList([1, 2, 3]),
      epochKey: key,
      random: Random(8),
    );
    final operation = unsigned.withPayloadHash(payload.payloadHash);
    final tampered = CloudDocumentEncryptedPayload(
      documentId: payload.documentId,
      membershipEpoch: payload.membershipEpoch,
      operationId: payload.operationId,
      nonce: payload.nonce,
      cipherText: Uint8List.fromList(payload.cipherText)..[0] ^= 1,
      mac: payload.mac,
    );
    for (final attempt in <Future<Uint8List> Function()>[
      () => decryptCloudDocumentPayload(
        operation: operation,
        payload: tampered,
        epochKey: key,
      ),
      () => decryptCloudDocumentPayload(
        operation: operation,
        payload: payload,
        epochKey: Uint8List.fromList(List.filled(32, 9)),
      ),
      () => decryptCloudDocumentPayload(
        operation: _operation(epoch: 3).withPayloadHash(payload.payloadHash),
        payload: payload,
        epochKey: key,
      ),
    ]) {
      await expectLater(attempt(), throwsFormatException);
    }
    await expectLater(
      encryptCloudDocumentPayload(
        operation: unsigned,
        clearText: Uint8List(maxCloudDocumentPayloadBytes + 1),
        epochKey: key,
      ),
      throwsArgumentError,
    );
  });
}
