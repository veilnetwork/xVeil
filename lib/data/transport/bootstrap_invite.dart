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
    this.transport,
    required this.nonce,
    this.algo = 'ed25519',
  });

  /// Signing public key (32 bytes for ed25519).
  final Uint8List publicKey;

  /// Direct-dial transport URI to reach the node, e.g. `tcp://1.2.3.4:9000`.
  /// NULL for an IDENTITY-ONLY invite: a node that isn't directly reachable
  /// (e.g. a phone behind NAT, whose only listener is loopback) shares just its
  /// identity (public_key/nonce → node_id) and is reached over the rendezvous
  /// network by node_id — NOT by dialing an address. Including a loopback `t=`
  /// here would be worse than useless (the redeemer would try to dial
  /// `127.0.0.1` on THEIR device).
  final String? transport;

  /// Proof-of-work nonce bytes.
  final Uint8List nonce;

  final String algo;

  /// The peer's node id = BLAKE3(public_key) — see veil sovereign_flow.rs
  /// (`node_id == BLAKE3(device_pubkey)`), verified against live nodes.
  NodeId get nodeId => NodeId(blake3Hash(publicKey));

  /// The prefix every invite URI carries.
  ///
  /// Public because the question "is this string an invite at all" is asked at
  /// boundaries that hold no invite yet — the API's contact-request target, for
  /// one — and a second literal copy of the prefix out there is a second thing
  /// to keep in step with [parse].
  static const scheme = 'veil:bootstrap?';

  /// A scanned/pasted invite is normally a few hundred chars (one key + nonce +
  /// a transport URI). Cap the input so a hostile QR/paste cannot hand us a
  /// multi-megabyte string to base64-decode into a huge allocation.
  static const _maxUriChars = 4 * 1024;

  /// Parse a scanned/pasted invite. veil emits the base64 fields RAW (not
  /// percent-encoded), so split manually to preserve `+ / =` and the `://`
  /// inside the transport URI.
  static BootstrapInvite parse(String uri) {
    final trimmed = uri.trim();
    if (!trimmed.startsWith(scheme)) {
      throw const FormatException('not a veil bootstrap invite');
    }
    if (trimmed.length > _maxUriChars) {
      throw const FormatException('bootstrap invite too large');
    }
    final params = <String, String>{};
    for (final part in trimmed.substring(scheme.length).split('&')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      params[part.substring(0, i)] = part.substring(i + 1);
    }
    final pk = params['pk'];
    final t = params['t']; // optional — absent ⇒ identity-only invite
    final nc = params['nc'];
    if (pk == null || nc == null) {
      throw const FormatException('invite missing pk/nc');
    }
    return BootstrapInvite(
      publicKey: base64.decode(pk),
      transport: (t != null && t.isNotEmpty) ? t : null,
      nonce: base64.decode(nc),
      algo: params['a'] ?? 'ed25519',
    );
  }

  String toUri() => '$scheme'
      'pk=${base64.encode(publicKey)}'
      '${(transport != null && transport!.isNotEmpty) ? '&t=$transport' : ''}'
      '&a=$algo'
      '&nc=${base64.encode(nonce)}';
}

/// Why a contact request aimed at [target] cannot be turned into something the
/// node can deliver — or null when the target carries what it needs.
///
/// The fact behind it is one line up: a node id is `BLAKE3(public_key)` (see
/// [BootstrapInvite.nodeId]). It is a hash. Handed one, nothing in this process
/// or in the node can recover the key a first contact has to be sealed to, and
/// there is no second channel that would supply it — the invite IS that
/// channel.
///
/// The API's `POST /v1/contacts` took a bare hex node id and answered
/// `200 {"ok":true}`. Measured against a live peer: eighty seconds, nothing at
/// the other end, and a `pendingOutgoing` contact left on the sender's side
/// whose retry failed with the node's own `PeerUnresolved`. The same call with
/// the peer's invite URI was delivered in eight seconds.
///
/// Note what a refusal here must NOT be gated on: whether a contact record for
/// that node id already exists. `sendRequest` writes one BEFORE anything is
/// delivered, so the second attempt would be admitted on the strength of the
/// first attempt's own leftovers — the failing call authorising itself. There
/// is nothing to consult; the target either carries the key or it does not.
///
/// English, deliberately: this is an HTTP error body for a program, alongside
/// `unknown identity` and `node unavailable`, not a string a person is shown.
String? contactRequestRefusal(String target) {
  if (target.trim().startsWith(BootstrapInvite.scheme)) return null;
  return 'a bare node id cannot be used to request contact: a node id is '
      'BLAKE3 of the peer public key, so nothing here can recover the key the '
      'request has to be sealed to. Pass the peer bootstrap invite '
      '("${BootstrapInvite.scheme}pk=...&nc=...") as `target` instead.';
}
