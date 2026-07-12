import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../core/ids.dart';
import 'cloud_document.dart';

const int maxCloudDocumentPayloadBytes = 1024 * 1024;

final Chacha20 _cloudDocumentAead = Chacha20.poly1305Aead();

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var diff = 0;
  for (var index = 0; index < left.length; index++) {
    diff |= left[index] ^ right[index];
  }
  return diff == 0;
}

/// AEAD ciphertext carried next to a signed document operation. The signed
/// operation binds [payloadHash], while the AEAD associated data binds every
/// field that determines where the plaintext is allowed to be interpreted.
class CloudDocumentEncryptedPayload {
  CloudDocumentEncryptedPayload({
    required this.documentId,
    required this.membershipEpoch,
    required this.operationId,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final NodeId documentId;
  final int membershipEpoch;
  final String operationId;
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  String get payloadHash {
    final digest = crypto.sha256.convert([
      ...utf8.encode('xveil.cloud-document.payload.v1\u0000'),
      ...documentId.bytes,
      ..._u64(membershipEpoch),
      ..._hexBytes(operationId),
      ...nonce,
      ...cipherText,
      ...mac,
    ]);
    return _hex(digest.bytes);
  }

  bool get isStructurallyValid =>
      membershipEpoch >= 0 &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(operationId) &&
      nonce.length == 12 &&
      mac.length == 16 &&
      cipherText.length <= maxCloudDocumentPayloadBytes;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'did': documentId.hex,
    'epoch': membershipEpoch,
    'id': operationId,
    'nonce': base64Encode(nonce),
    'ct': base64Encode(cipherText),
    'mac': base64Encode(mac),
  };

  static CloudDocumentEncryptedPayload? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final did = value['did'];
    final epoch = value['epoch'];
    final id = value['id'];
    final rawNonce = value['nonce'];
    final rawCipherText = value['ct'];
    final rawMac = value['mac'];
    if (did is! String ||
        epoch is! int ||
        epoch < 0 ||
        id is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
        rawNonce is! String ||
        rawCipherText is! String ||
        rawMac is! String) {
      return null;
    }
    try {
      final payload = CloudDocumentEncryptedPayload(
        documentId: NodeId.fromHex(did),
        membershipEpoch: epoch,
        operationId: id,
        nonce: Uint8List.fromList(base64Decode(rawNonce)),
        cipherText: Uint8List.fromList(base64Decode(rawCipherText)),
        mac: Uint8List.fromList(base64Decode(rawMac)),
      );
      return payload.isStructurallyValid ? payload : null;
    } catch (_) {
      return null;
    }
  }
}

Future<CloudDocumentEncryptedPayload> encryptCloudDocumentPayload({
  required CloudDocumentOperation operation,
  required Uint8List clearText,
  required Uint8List epochKey,
  Random? random,
}) async {
  if (epochKey.length != 32 ||
      clearText.length > maxCloudDocumentPayloadBytes ||
      CloudDocumentOperation.fromJson(operation.toJson()) == null) {
    throw ArgumentError('invalid cloud document payload input');
  }
  final nonce = Uint8List(12);
  final rng = random ?? Random.secure();
  for (var index = 0; index < nonce.length; index++) {
    nonce[index] = rng.nextInt(256);
  }
  final box = await _cloudDocumentAead.encrypt(
    clearText,
    secretKey: SecretKey(epochKey),
    nonce: nonce,
    aad: _payloadAad(operation),
  );
  return CloudDocumentEncryptedPayload(
    documentId: operation.documentId,
    membershipEpoch: operation.membershipEpoch,
    operationId: operation.operationId,
    nonce: nonce,
    cipherText: Uint8List.fromList(box.cipherText),
    mac: Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> decryptCloudDocumentPayload({
  required CloudDocumentOperation operation,
  required CloudDocumentEncryptedPayload payload,
  required Uint8List epochKey,
}) async {
  if (epochKey.length != 32 ||
      !payload.isStructurallyValid ||
      payload.documentId != operation.documentId ||
      payload.membershipEpoch != operation.membershipEpoch ||
      payload.operationId != operation.operationId ||
      !_sameBytes(
        _hexBytes(payload.payloadHash),
        _hexBytes(operation.payloadHash),
      )) {
    throw const FormatException('cloud document payload rejected');
  }
  try {
    final clear = await _cloudDocumentAead.decrypt(
      SecretBox(
        payload.cipherText,
        nonce: payload.nonce,
        mac: Mac(payload.mac),
      ),
      secretKey: SecretKey(epochKey),
      aad: _payloadAad(operation),
    );
    if (clear.length > maxCloudDocumentPayloadBytes) {
      throw const FormatException('cloud document payload is too large');
    }
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const FormatException('cloud document payload rejected');
  }
}

Uint8List _payloadAad(CloudDocumentOperation operation) => Uint8List.fromList([
  ...utf8.encode('xveil.cloud-document.payload-aad.v1\u0000'),
  ...utf8.encode(
    jsonEncode({
      'did': operation.documentId.hex,
      'epoch': operation.membershipEpoch,
      'author': operation.author.hex,
      'seq': operation.seq,
      'prev': operation.prevAuthorHash,
      'id': operation.operationId,
      'parents': operation.parentOperationIds,
      'op': operation.opType,
      'ts': operation.createdAtMs,
    }),
  ),
]);

Uint8List _u64(int value) {
  if (value < 0) throw ArgumentError.value(value);
  final out = Uint8List(8);
  for (var index = 7; index >= 0; index--) {
    out[index] = value & 0xff;
    value >>= 8;
  }
  return out;
}

Uint8List _hexBytes(String value) {
  if (value.length.isOdd) throw const FormatException('invalid hex');
  final out = Uint8List(value.length ~/ 2);
  for (var index = 0; index < out.length; index++) {
    final byte = int.tryParse(
      value.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
    if (byte == null) throw const FormatException('invalid hex');
    out[index] = byte;
  }
  return out;
}
