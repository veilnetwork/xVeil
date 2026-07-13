import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'cloud_document.dart';
import 'cloud_document_envelope.dart';
import 'cloud_document_payload.dart';

const int maxCloudDocumentFrameControls = 4096;
const int maxCloudDocumentFrameOperations = 100000;
const int maxCloudDocumentFrameEnvelopes = 1024;
const int maxCloudDocumentFramePayloads = 100000;
const int maxCloudDocumentFrameEncodedChars = 3800000;
const int maxCloudDocumentFramePayloadBytes = 2500000;

enum CloudDocumentFrameKind {
  invite,
  snapshot,
  delta,
  quiescence,
  quiescenceAck;

  static CloudDocumentFrameKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// A member-authored convergence proof for one exact signed document state.
///
/// It deliberately carries no presence/read information: only the document
/// owner asks for it, and an unauthorized or malformed proof is silently
/// discarded by the replication layer.
class CloudDocumentQuiescenceAck {
  CloudDocumentQuiescenceAck({
    required this.documentId,
    required this.rootHash,
    required this.generation,
    required this.stateHash,
    required this.roundId,
    required this.author,
    required this.issuedAtMs,
    required this.authorPubKey,
    required this.signature,
  });

  final NodeId documentId;
  final String rootHash;
  final int generation;
  final String stateHash;
  final String roundId;
  final NodeId author;
  final int issuedAtMs;
  final Uint8List authorPubKey;
  final Uint8List signature;

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'did': documentId.hex,
        'root': rootHash,
        'gen': generation,
        'state': stateHash,
        'round': roundId,
        'author': author.hex,
        'issuedAt': issuedAtMs,
      }),
    ),
  );

  CloudDocumentQuiescenceAck withSignature(Uint8List value, Uint8List pubKey) =>
      CloudDocumentQuiescenceAck(
        documentId: documentId,
        rootHash: rootHash,
        generation: generation,
        stateHash: stateHash,
        roundId: roundId,
        author: author,
        issuedAtMs: issuedAtMs,
        authorPubKey: Uint8List.fromList(pubKey),
        signature: Uint8List.fromList(value),
      );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'did': documentId.hex,
    'root': rootHash,
    'gen': generation,
    'state': stateHash,
    'round': roundId,
    'author': author.hex,
    'issuedAt': issuedAtMs,
    'pk': base64Encode(authorPubKey),
    'sig': base64Encode(signature),
  };

  static CloudDocumentQuiescenceAck? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final documentId = value['did'];
    final rootHash = value['root'];
    final generation = value['gen'];
    final stateHash = value['state'];
    final roundId = value['round'];
    final author = value['author'];
    final issuedAt = value['issuedAt'];
    final publicKey = value['pk'];
    final signature = value['sig'];
    if (documentId is! String ||
        rootHash is! String ||
        !_isHash32(rootHash) ||
        generation is! int ||
        generation < 0 ||
        stateHash is! String ||
        !_isHash32(stateHash) ||
        roundId is! String ||
        !_isHash32(roundId) ||
        author is! String ||
        issuedAt is! int ||
        issuedAt < 0 ||
        publicKey is! String ||
        signature is! String) {
      return null;
    }
    try {
      final parsedPublicKey = Uint8List.fromList(base64Decode(publicKey));
      final parsedSignature = Uint8List.fromList(base64Decode(signature));
      if (parsedPublicKey.length != 32 || parsedSignature.length != 64) {
        return null;
      }
      return CloudDocumentQuiescenceAck(
        documentId: NodeId.fromHex(documentId),
        rootHash: rootHash,
        generation: generation,
        stateHash: stateHash,
        roundId: roundId,
        author: NodeId.fromHex(author),
        issuedAtMs: issuedAt,
        authorPubKey: parsedPublicKey,
        signature: parsedSignature,
      );
    } catch (_) {
      return null;
    }
  }
}

bool _isHash32(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// Public, signed replication material. Epoch keys are never carried here:
/// [envelopes] contain only recipient-bound ML-KEM ciphertexts.
class CloudDocumentFrame {
  CloudDocumentFrame({
    required this.kind,
    required this.root,
    required List<CloudDocumentControlEntry> controls,
    required List<CloudDocumentOperation> operations,
    required List<CloudDocumentEpochEnvelopeBundle> envelopes,
    List<CloudDocumentEncryptedPayload> payloads = const [],
    this.quiescenceAck,
    this.quiescenceId,
  }) : controls = List.unmodifiable(controls),
       operations = List.unmodifiable(operations),
       envelopes = List.unmodifiable(envelopes),
       payloads = List.unmodifiable(payloads);

  final CloudDocumentFrameKind kind;
  final CloudDocumentRoot root;
  final List<CloudDocumentControlEntry> controls;
  final List<CloudDocumentOperation> operations;
  final List<CloudDocumentEpochEnvelopeBundle> envelopes;
  final List<CloudDocumentEncryptedPayload> payloads;
  final CloudDocumentQuiescenceAck? quiescenceAck;
  final String? quiescenceId;

  Map<String, dynamic> toJson() => {
    'v':
        kind == CloudDocumentFrameKind.quiescence ||
            kind == CloudDocumentFrameKind.quiescenceAck
        ? 3
        : 2,
    'kind': kind.name,
    'root': root.toJson(),
    'controls': controls.map((entry) => entry.toJson()).toList(),
    'operations': operations.map((entry) => entry.toJson()).toList(),
    'envelopes': envelopes.map((entry) => entry.toJson()).toList(),
    'payloads': payloads.map((entry) => entry.toJson()).toList(),
    if (quiescenceAck != null) 'ack': quiescenceAck!.toJson(),
    if (quiescenceId != null) 'qid': quiescenceId,
  };

  String encode() => jsonEncode(toJson());

  static CloudDocumentFrame? decode(String encoded) {
    if (encoded.length > maxCloudDocumentFrameEncodedChars) return null;
    try {
      return fromJson(jsonDecode(encoded));
    } catch (_) {
      return null;
    }
  }

  static CloudDocumentFrame? fromJson(Object? value) {
    if (value is! Map ||
        (value['v'] != 1 && value['v'] != 2 && value['v'] != 3)) {
      return null;
    }
    final rawKind = value['kind'];
    final kind = CloudDocumentFrameKind.fromName(
      rawKind is String ? rawKind : null,
    );
    final version = value['v'] as int;
    final isQuiescenceKind =
        kind == CloudDocumentFrameKind.quiescence ||
        kind == CloudDocumentFrameKind.quiescenceAck;
    if ((version == 3) != isQuiescenceKind) return null;
    if (kind == CloudDocumentFrameKind.quiescence && value.containsKey('ack')) {
      return null;
    }
    final root = CloudDocumentRoot.fromJson(value['root']);
    final rawControls = value['controls'];
    final rawOperations = value['operations'];
    final rawEnvelopes = value['envelopes'];
    final rawPayloads = version == 1 ? const [] : value['payloads'];
    final ack = version == 3
        ? CloudDocumentQuiescenceAck.fromJson(value['ack'])
        : null;
    final quiescenceId = version == 3 ? value['qid'] : null;
    if (kind == null ||
        root == null ||
        rawControls is! List ||
        rawControls.length > maxCloudDocumentFrameControls ||
        rawOperations is! List ||
        rawOperations.length > maxCloudDocumentFrameOperations ||
        rawEnvelopes is! List ||
        rawEnvelopes.length > maxCloudDocumentFrameEnvelopes ||
        rawPayloads is! List ||
        rawPayloads.length > maxCloudDocumentFramePayloads) {
      return null;
    }
    final controls = rawControls
        .map(CloudDocumentControlEntry.fromJson)
        .whereType<CloudDocumentControlEntry>()
        .toList();
    final operations = rawOperations
        .map(CloudDocumentOperation.fromJson)
        .whereType<CloudDocumentOperation>()
        .toList();
    final envelopes = rawEnvelopes
        .map(CloudDocumentEpochEnvelopeBundle.fromJson)
        .whereType<CloudDocumentEpochEnvelopeBundle>()
        .toList();
    final payloads = rawPayloads
        .map(CloudDocumentEncryptedPayload.fromJson)
        .whereType<CloudDocumentEncryptedPayload>()
        .toList();
    if (controls.length != rawControls.length ||
        operations.length != rawOperations.length ||
        envelopes.length != rawEnvelopes.length ||
        payloads.length != rawPayloads.length ||
        controls.any((entry) => entry.documentId != root.documentId) ||
        operations.any((entry) => entry.documentId != root.documentId) ||
        envelopes.any((entry) => entry.documentId != root.documentId) ||
        payloads.any((entry) => entry.documentId != root.documentId)) {
      return null;
    }
    final isAck = kind == CloudDocumentFrameKind.quiescenceAck;
    if (isQuiescenceKind &&
        (quiescenceId is! String ||
            !_isHash32(quiescenceId) ||
            isAck != (ack != null) ||
            (kind == CloudDocumentFrameKind.quiescence && ack != null) ||
            (isAck &&
                (controls.isNotEmpty ||
                    operations.isNotEmpty ||
                    envelopes.isNotEmpty ||
                    payloads.isNotEmpty ||
                    ack!.documentId != root.documentId ||
                    ack.rootHash != root.recordHash ||
                    ack.generation != root.generation ||
                    ack.roundId != quiescenceId)))) {
      return null;
    }
    var payloadBytes = 0;
    for (final payload in payloads) {
      payloadBytes +=
          payload.nonce.length + payload.cipherText.length + payload.mac.length;
      if (payloadBytes > maxCloudDocumentFramePayloadBytes) return null;
    }
    return CloudDocumentFrame(
      kind: kind,
      root: root,
      controls: controls,
      operations: operations,
      envelopes: envelopes,
      payloads: payloads,
      quiescenceAck: ack,
      quiescenceId: quiescenceId,
    );
  }
}

class CloudDocumentPendingInvite {
  CloudDocumentPendingInvite({
    required this.sender,
    required this.receivedAtMs,
    required this.frame,
  });

  final NodeId sender;
  final int receivedAtMs;
  final CloudDocumentFrame frame;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'sender': sender.hex,
    'receivedAt': receivedAtMs,
    'frame': frame.toJson(),
  };

  static CloudDocumentPendingInvite? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final sender = value['sender'];
    final receivedAt = value['receivedAt'];
    final frame = CloudDocumentFrame.fromJson(value['frame']);
    if (sender is! String ||
        receivedAt is! int ||
        receivedAt < 0 ||
        frame == null ||
        frame.kind != CloudDocumentFrameKind.invite) {
      return null;
    }
    try {
      return CloudDocumentPendingInvite(
        sender: NodeId.fromHex(sender),
        receivedAtMs: receivedAt,
        frame: frame,
      );
    } catch (_) {
      return null;
    }
  }
}
