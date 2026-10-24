import 'dart:convert';
import 'dart:typed_data';

/// Public signed material still identifies contacts. Keep it in the identity's
/// encrypted container; never include it in logs or anonymized diagnostics.
class PeerAuthorizationEntry {
  PeerAuthorizationEntry(this.peer, Uint8List document)
    : document = Uint8List.fromList(document) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(peer) ||
        document.isEmpty ||
        document.length > maxDocumentBytes) {
      throw const CorruptPeerAuthorizationState();
    }
  }

  static const maxDocumentBytes = 16 * 1024;
  static const maxEntries = 512;
  final String peer;
  final Uint8List document;

  @override
  String toString() => 'PeerAuthorizationEntry(<protected>)';
}

class CorruptPeerAuthorizationState implements Exception {
  const CorruptPeerAuthorizationState();
  @override
  String toString() => 'Peer authorization state is corrupt';
}

class PeerAuthorizationSnapshot {
  PeerAuthorizationSnapshot(this.revision, List<PeerAuthorizationEntry> entries)
    : entries = List.unmodifiable(entries) {
    if (revision < 0 ||
        entries.length > PeerAuthorizationEntry.maxEntries ||
        entries.map((e) => e.peer).toSet().length != entries.length) {
      throw const CorruptPeerAuthorizationState();
    }
  }
  final int revision;
  final List<PeerAuthorizationEntry> entries;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 1,
        'entries': [
          for (final entry in entries)
            {'peer': entry.peer, 'document': base64Encode(entry.document)},
        ],
      }),
    ),
  );

  static PeerAuthorizationSnapshot decode(int revision, Uint8List bytes) {
    try {
      if (bytes.length > 12 * 1024 * 1024) {
        throw const CorruptPeerAuthorizationState();
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map ||
          value.length != 2 ||
          value['version'] != 1 ||
          value['entries'] is! List) {
        throw const CorruptPeerAuthorizationState();
      }
      final rows = value['entries'] as List;
      if (rows.length > PeerAuthorizationEntry.maxEntries) {
        throw const CorruptPeerAuthorizationState();
      }
      final entries = <PeerAuthorizationEntry>[];
      for (final row in rows) {
        if (row is! Map ||
            row.length != 2 ||
            row['peer'] is! String ||
            row['document'] is! String ||
            (row['document'] as String).length >
                ((PeerAuthorizationEntry.maxDocumentBytes + 2) ~/ 3) * 4) {
          throw const CorruptPeerAuthorizationState();
        }
        entries.add(
          PeerAuthorizationEntry(
            row['peer'] as String,
            base64Decode(row['document'] as String),
          ),
        );
      }
      return PeerAuthorizationSnapshot(revision, entries);
    } on Object {
      // A decoder's exception can quote attacker-controlled input. Keep the
      // failure useful without echoing document bytes or peer identifiers.
      throw const CorruptPeerAuthorizationState();
    }
  }
}

/// Optional sibling of the ratchet FFI handle; all operations are memory-only.
abstract interface class PeerAuthorizationStateHandle {
  int peerAuthorizationVersion();
  PeerAuthorizationSnapshot exportPeerAuthorization();
  void restorePeerAuthorization(PeerAuthorizationSnapshot snapshot);
  void acknowledgePeerAuthorization(int revision);
}

/// A current-document fence, not a way to establish ownership from a claim.
abstract interface class PeerDeviceAuthorizationHandle {
  bool peerDeviceProofAllowed(Uint8List identity, Uint8List device);
}
