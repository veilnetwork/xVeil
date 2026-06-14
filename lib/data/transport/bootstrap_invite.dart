import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../crypto/blake3.dart';

/// A veil bootstrap invite — the `veil:bootstrap?pk=…&t=…&a=…&nc=…` URI a node
/// emits (`veil-cli bootstrap invite`) and a peer redeems (`bootstrap join`).
/// This is the messenger's "add contact" token: each device shows its invite
/// (as a QR) and scans the other's, which establishes the bidirectional
/// session veil's directional dedup needs. Carries only public data
/// (public_key, transport, PoW nonce) — safe to share.
class BootstrapInvite {
  BootstrapInvite({
    required this.publicKey,
    required this.transport,
    required this.nonce,
    this.algo = 'ed25519',
  });

  /// Signing public key (32 bytes for ed25519).
  final Uint8List publicKey;

  /// Transport URI to reach the node, e.g. `tcp://1.2.3.4:9000`.
  final String transport;

  /// Proof-of-work nonce bytes.
  final Uint8List nonce;

  final String algo;

  /// The peer's node id = BLAKE3(public_key) — see veil sovereign_flow.rs
  /// (`node_id == BLAKE3(device_pubkey)`), verified against live nodes.
  NodeId get nodeId => NodeId(blake3Hash(publicKey));

  static const _scheme = 'veil:bootstrap?';

  /// Parse a scanned/pasted invite. veil emits the base64 fields RAW (not
  /// percent-encoded), so split manually to preserve `+ / =` and the `://`
  /// inside the transport URI.
  static BootstrapInvite parse(String uri) {
    final trimmed = uri.trim();
    if (!trimmed.startsWith(_scheme)) {
      throw const FormatException('not a veil bootstrap invite');
    }
    final params = <String, String>{};
    for (final part in trimmed.substring(_scheme.length).split('&')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      params[part.substring(0, i)] = part.substring(i + 1);
    }
    final pk = params['pk'];
    final t = params['t'];
    final nc = params['nc'];
    if (pk == null || t == null || nc == null) {
      throw const FormatException('invite missing pk/t/nc');
    }
    return BootstrapInvite(
      publicKey: base64.decode(pk),
      transport: t,
      nonce: base64.decode(nc),
      algo: params['a'] ?? 'ed25519',
    );
  }

  String toUri() => '$_scheme'
      'pk=${base64.encode(publicKey)}'
      '&t=$transport'
      '&a=$algo'
      '&nc=${base64.encode(nonce)}';
}
