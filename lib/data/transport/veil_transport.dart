import 'dart:typed_data';

import '../../core/ids.dart';

/// A message received from a peer over the overlay network.
class InboundMessage {
  const InboundMessage({required this.src, required this.payload});
  final NodeId src;
  final Uint8List payload;
}

/// Port over the veil overlay network's messaging surface.
///
/// The real adapter wraps `veil_flutter`'s `VeilClient`/`AppHandle`
/// (`bindNamed` + `send`/`messages`, with mailbox fallback for offline
/// peers). A loopback fake implements the same contract so the messenger UI
/// and chat logic are built and tested without the native stack.
abstract interface class VeilTransport {
  /// 32-byte node id of the local identity, once the node is connected.
  Future<NodeId> nodeId();

  /// Send an opaque application payload to [dst]. Resolves when the node has
  /// accepted it for delivery (not when the peer has received it).
  ///
  /// When [anonymous] is true, the message is routed over an onion rendezvous
  /// circuit that hides the sender's network location (resolving [dst]'s
  /// rendezvous ad and sealing an introduce). This is FAIL-CLOSED: if the
  /// anonymous path cannot be built (e.g. [dst] publishes no rendezvous ad), the
  /// send throws rather than silently falling back to a clearnet send that would
  /// leak the sender's location — a leak that, for the threat model this app
  /// serves, must never happen behind the user's back.
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false});

  /// Inbound application payloads addressed to us.
  Stream<InboundMessage> messages();

  Future<void> dispose();
}
