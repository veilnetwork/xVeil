import 'dart:convert';

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
  delta;

  static CloudDocumentFrameKind? fromName(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

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

  Map<String, dynamic> toJson() => {
    'v': 2,
    'kind': kind.name,
    'root': root.toJson(),
    'controls': controls.map((entry) => entry.toJson()).toList(),
    'operations': operations.map((entry) => entry.toJson()).toList(),
    'envelopes': envelopes.map((entry) => entry.toJson()).toList(),
    'payloads': payloads.map((entry) => entry.toJson()).toList(),
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
    if (value is! Map || (value['v'] != 1 && value['v'] != 2)) return null;
    final rawKind = value['kind'];
    final kind = CloudDocumentFrameKind.fromName(
      rawKind is String ? rawKind : null,
    );
    final root = CloudDocumentRoot.fromJson(value['root']);
    final rawControls = value['controls'];
    final rawOperations = value['operations'];
    final rawEnvelopes = value['envelopes'];
    final rawPayloads = value['v'] == 2 ? value['payloads'] : const [];
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
