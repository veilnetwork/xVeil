import 'dart:convert';

import '../core/ids.dart';
import 'cloud_document.dart';
import 'cloud_document_envelope.dart';

const int maxCloudDocumentFrameControls = 4096;
const int maxCloudDocumentFrameOperations = 100000;
const int maxCloudDocumentFrameEnvelopes = 1024;

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
  }) : controls = List.unmodifiable(controls),
       operations = List.unmodifiable(operations),
       envelopes = List.unmodifiable(envelopes);

  final CloudDocumentFrameKind kind;
  final CloudDocumentRoot root;
  final List<CloudDocumentControlEntry> controls;
  final List<CloudDocumentOperation> operations;
  final List<CloudDocumentEpochEnvelopeBundle> envelopes;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': kind.name,
    'root': root.toJson(),
    'controls': controls.map((entry) => entry.toJson()).toList(),
    'operations': operations.map((entry) => entry.toJson()).toList(),
    'envelopes': envelopes.map((entry) => entry.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());

  static CloudDocumentFrame? decode(String encoded) {
    try {
      return fromJson(jsonDecode(encoded));
    } catch (_) {
      return null;
    }
  }

  static CloudDocumentFrame? fromJson(Object? value) {
    if (value is! Map || value['v'] != 1) return null;
    final rawKind = value['kind'];
    final kind = CloudDocumentFrameKind.fromName(
      rawKind is String ? rawKind : null,
    );
    final root = CloudDocumentRoot.fromJson(value['root']);
    final rawControls = value['controls'];
    final rawOperations = value['operations'];
    final rawEnvelopes = value['envelopes'];
    if (kind == null ||
        root == null ||
        rawControls is! List ||
        rawControls.length > maxCloudDocumentFrameControls ||
        rawOperations is! List ||
        rawOperations.length > maxCloudDocumentFrameOperations ||
        rawEnvelopes is! List ||
        rawEnvelopes.length > maxCloudDocumentFrameEnvelopes) {
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
    if (controls.length != rawControls.length ||
        operations.length != rawOperations.length ||
        envelopes.length != rawEnvelopes.length ||
        controls.any((entry) => entry.documentId != root.documentId) ||
        operations.any((entry) => entry.documentId != root.documentId) ||
        envelopes.any((entry) => entry.documentId != root.documentId)) {
      return null;
    }
    return CloudDocumentFrame(
      kind: kind,
      root: root,
      controls: controls,
      operations: operations,
      envelopes: envelopes,
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
