import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../crypto/blake3.dart';

/// The well-known messenger endpoint every xVeil node binds. A peer's app_id is
/// derived from its node id + this (namespace, name), so a contact is fully
/// addressable from its node id alone.
const veilChatNamespace = 'xveil';
const veilChatName = 'inbox';
const veilChatEndpointId = 0;

const _appIdContext = 'veil.app_id.v1';
const _maxFieldLen = 256;

Uint8List _be32(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.big);
  return b;
}

/// Derives the stable veil `app_id` for a named endpoint on [nodeId], matching
/// veil-app/src/address.rs:
///
///   app_id = BLAKE3-derive_key(
///     "veil.app_id.v1",
///     node_id ‖ ns_len_be32 ‖ ns ‖ name_len_be32 ‖ name)
///
/// Length-prefixes are mandatory (they prevent ("fo","obar") vs ("foo","bar")
/// collisions); fields are truncated to 256 bytes like the Rust side.
Uint8List deriveAppId(NodeId nodeId, String namespace, String name) {
  final ns = utf8.encode(namespace);
  final nm = utf8.encode(name);
  final nsB = ns.length > _maxFieldLen ? ns.sublist(0, _maxFieldLen) : ns;
  final nmB = nm.length > _maxFieldLen ? nm.sublist(0, _maxFieldLen) : nm;

  final ikm = BytesBuilder()
    ..add(nodeId.bytes)
    ..add(_be32(nsB.length))
    ..add(nsB)
    ..add(_be32(nmB.length))
    ..add(nmB);

  return blake3DeriveKey(_appIdContext, ikm.toBytes());
}

/// The app_id a peer exposes on the shared chat endpoint — the routing target
/// for [VeilTransport.send].
Uint8List chatAppIdFor(NodeId peer) =>
    deriveAppId(peer, veilChatNamespace, veilChatName);
