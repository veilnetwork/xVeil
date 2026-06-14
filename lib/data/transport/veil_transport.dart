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
  Future<void> send(NodeId dst, Uint8List payload);

  /// Inbound application payloads addressed to us.
  Stream<InboundMessage> messages();

  Future<void> dispose();
}
