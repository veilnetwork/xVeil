import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';

final RegExp _hex32 = RegExp(r'^[0-9a-f]{64}$');

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexBytes(String value) {
  if (!_hex32.hasMatch(value)) throw const FormatException('not 32-byte hex');
  final result = Uint8List(32);
  for (var index = 0; index < 32; index++) {
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

final Uint8List cloudDocumentEnvelopeAppId = Uint8List.fromList(
  crypto.sha256.convert(utf8.encode('xveil.cloud-document-key.app.v1')).bytes,
);

const int cloudDocumentEnvelopeEndpointId = 62;
const int maxCloudDocumentEnvelopeRecipients = 256;
const int maxCloudDocumentSealedEnvelopeBytes = 64 * 1024;

/// Domain-separated commitment to one 32-byte epoch key. The key itself never
/// appears in the signed root/control log; only this digest and the hash of the
/// recipient-envelope bundle do.
String cloudDocumentEpochKeyCommitment({
  required NodeId documentId,
  required int epoch,
  required Uint8List key,
}) {
  if (epoch < 0 || epoch > 0xffffffff) {
    throw ArgumentError.value(epoch, 'epoch', 'must fit u32');
  }
  if (key.length != 32) {
    throw ArgumentError.value(key.length, 'key.length', 'must be 32');
  }
  final epochBytes = ByteData(4)..setUint32(0, epoch, Endian.big);
  return _hex(
    crypto.sha256.convert([
      ...utf8.encode('xveil.cloud-document-key.commitment.v1\u0000'),
      ...documentId.bytes,
      ...epochBytes.buffer.asUint8List(),
      ...key,
    ]).bytes,
  );
}

class CloudDocumentRecipientEnvelope {
  CloudDocumentRecipientEnvelope({
    required this.recipient,
    required this.sealed,
  });

  final NodeId recipient;
  final Uint8List sealed;

  Map<String, dynamic> toJson() => {
    'recipient': recipient.hex,
    'sealed': base64Encode(sealed),
  };

  static CloudDocumentRecipientEnvelope? fromJson(Object? value) {
    if (value is! Map) return null;
    final recipient = value['recipient'];
    final sealed = value['sealed'];
    if (recipient is! String || sealed is! String) return null;
    try {
      final bytes = Uint8List.fromList(base64Decode(sealed));
      if (bytes.isEmpty || bytes.length > maxCloudDocumentSealedEnvelopeBytes) {
        return null;
      }
      return CloudDocumentRecipientEnvelope(
        recipient: NodeId.fromHex(recipient),
        sealed: bytes,
      );
    } catch (_) {
      return null;
    }
  }
}

class CloudDocumentEpochEnvelopeBundle {
  CloudDocumentEpochEnvelopeBundle({
    required this.documentId,
    required this.epoch,
    required this.keyCommitment,
    required List<CloudDocumentRecipientEnvelope> envelopes,
  }) : envelopes = List.unmodifiable(envelopes);

  final NodeId documentId;
  final int epoch;
  final String keyCommitment;
  final List<CloudDocumentRecipientEnvelope> envelopes;

  Uint8List canonicalBytes() {
    final ordered = [
      ...envelopes,
    ]..sort((left, right) => left.recipient.hex.compareTo(right.recipient.hex));
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'did': documentId.hex,
          'epoch': epoch,
          'ekc': keyCommitment,
          'entries': ordered.map((entry) => entry.toJson()).toList(),
        }),
      ),
    );
  }

  String get bundleHash => _hex(crypto.sha256.convert(canonicalBytes()).bytes);

  CloudDocumentRecipientEnvelope? envelopeFor(NodeId recipient) {
    for (final envelope in envelopes) {
      if (envelope.recipient == recipient) return envelope;
    }
    return null;
  }

  Map<String, dynamic> toJson() => jsonDecode(utf8.decode(canonicalBytes()));

  static CloudDocumentEpochEnvelopeBundle? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final did = value['did'];
    final epoch = value['epoch'];
    final commitment = value['ekc'];
    final entries = value['entries'];
    if (did is! String ||
        epoch is! int ||
        epoch < 0 ||
        epoch > 0xffffffff ||
        commitment is! String ||
        !_hex32.hasMatch(commitment) ||
        entries is! List ||
        entries.isEmpty ||
        entries.length > maxCloudDocumentEnvelopeRecipients) {
      return null;
    }
    final parsed = entries
        .map(CloudDocumentRecipientEnvelope.fromJson)
        .whereType<CloudDocumentRecipientEnvelope>()
        .toList();
    if (parsed.length != entries.length) return null;
    final recipients = parsed.map((entry) => entry.recipient.hex).toList();
    if (recipients.toSet().length != recipients.length) return null;
    final sorted = [...recipients]..sort();
    for (var index = 0; index < sorted.length; index++) {
      if (sorted[index] != recipients[index]) return null;
    }
    try {
      return CloudDocumentEpochEnvelopeBundle(
        documentId: NodeId.fromHex(did),
        epoch: epoch,
        keyCommitment: commitment,
        envelopes: parsed,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Fixed binary plaintext sealed inside the existing ML-KEM mailbox envelope:
/// version || document id || epoch(u32 BE) || key || key commitment. Keeping it
/// binary avoids immutable base64 cleartext copies of the epoch key in Dart.
Uint8List encodeCloudDocumentEpochKeyPayload({
  required NodeId documentId,
  required int epoch,
  required Uint8List key,
}) {
  final commitment = cloudDocumentEpochKeyCommitment(
    documentId: documentId,
    epoch: epoch,
    key: key,
  );
  final result = Uint8List(1 + 32 + 4 + 32 + 32);
  result[0] = 1;
  result.setRange(1, 33, documentId.bytes);
  ByteData.sublistView(result, 33, 37).setUint32(0, epoch, Endian.big);
  result.setRange(37, 69, key);
  result.setRange(69, 101, _hexBytes(commitment));
  return result;
}

class CloudDocumentOpenedEpochKey {
  CloudDocumentOpenedEpochKey({
    required this.documentId,
    required this.epoch,
    required this.key,
    required this.keyCommitment,
  });

  final NodeId documentId;
  final int epoch;
  final Uint8List key;
  final String keyCommitment;
}

CloudDocumentOpenedEpochKey? decodeCloudDocumentEpochKeyPayload(
  Uint8List payload,
) {
  if (payload.length != 101 || payload[0] != 1) return null;
  try {
    final documentId = NodeId(Uint8List.fromList(payload.sublist(1, 33)));
    final epoch = ByteData.sublistView(
      payload,
      33,
      37,
    ).getUint32(0, Endian.big);
    final key = Uint8List.fromList(payload.sublist(37, 69));
    final carriedCommitment = payload.sublist(69, 101);
    final expected = cloudDocumentEpochKeyCommitment(
      documentId: documentId,
      epoch: epoch,
      key: key,
    );
    if (!_sameBytes(carriedCommitment, _hexBytes(expected))) {
      key.fillRange(0, key.length, 0);
      return null;
    }
    return CloudDocumentOpenedEpochKey(
      documentId: documentId,
      epoch: epoch,
      key: key,
      keyCommitment: expected,
    );
  } catch (_) {
    return null;
  }
}
