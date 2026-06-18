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
  /// rendezvous ad and sealing an introduce).
  ///
  /// The safety guarantee is NO CLEARNET FALLBACK: an anonymous send is *only*
  /// ever attempted over the onion path — it never quietly degrades to a
  /// location-revealing clearnet send, a leak that for this threat model must
  /// never happen behind the user's back. It is NOT synchronously fail-fast:
  /// the call resolves once the node has accepted the command (the IPC send is
  /// fire-and-forget), so an onion delivery that can't complete yet (e.g. [dst]
  /// publishes no ad, or no relay circuit is available) does not throw here —
  /// the message simply stays undelivered (un-acked) and the outbox retries it
  /// until a circuit can be built. Failures surface as "not delivered", never
  /// as a silent clearnet leak.
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false});

  /// Inbound application payloads addressed to us.
  Stream<InboundMessage> messages();

  /// Live count of the node's active overlay sessions (its connected peers) —
  /// emits the current value and every change. Surfaced as the real peer count
  /// in the network UI (never a fabricated number).
  Stream<int> sessionCount();

  Future<void> dispose();
}
