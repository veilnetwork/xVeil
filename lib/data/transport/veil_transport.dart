import 'dart:typed_data';

import '../../core/ids.dart';

/// A message received from a peer over the overlay network.
class InboundMessage {
  const InboundMessage({
    required this.src,
    required this.payload,
    this.replyId = 0,
  });
  final NodeId src;
  final Uint8List payload;

  /// Opaque, TTL-bounded handle to a one-time anonymous reply path the SENDER
  /// embedded with this message (non-zero only when they used [sendWithReply]).
  /// Answering via [VeilTransport.sendReply] routes back over the sender's
  /// already-built rendezvous circuit — no fresh resolve + circuit-build, no
  /// public ad either side — so a delivery ACK returns in ~half the round-trip.
  /// 0 = not repliable (fall back to a normal anonymous [VeilTransport.send]).
  final int replyId;
}

/// Session state of a peer, mapped from veil's wire bytes. [active] = a live
/// session right now; [connecting] = handshaking; [closed] = was connected and
/// has dropped; [unknown] = state byte not recognised.
enum PeerState { connecting, active, closed, unknown }

/// Which side opened the session.
enum PeerDirection { inbound, outbound, unknown }

/// One peer the node knows about — a point-in-time snapshot from the transport.
/// veil reports no timestamp, so [lastSeen] is stamped by the app the moment it
/// observed this peer (honest "last seen BY THIS DEVICE", not a node clock).
class PeerInfo {
  const PeerInfo({
    required this.nodeId,
    required this.state,
    required this.direction,
    required this.transport,
    this.lastSeen,
  });

  final NodeId nodeId;
  final PeerState state;
  final PeerDirection direction;

  /// Transport URI the session uses (e.g. `obfs4-tcp://…`, `tcp://…`). May be
  /// empty if the node didn't report one.
  final String transport;

  /// When this device last observed the peer active. Null until first seen.
  final DateTime? lastSeen;

  bool get isActive => state == PeerState.active;

  PeerInfo copyWith({PeerState? state, DateTime? lastSeen}) => PeerInfo(
        nodeId: nodeId,
        state: state ?? this.state,
        direction: direction,
        transport: transport,
        lastSeen: lastSeen ?? this.lastSeen,
      );
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

  /// Like an anonymous [send], but attach a one-time reply block so the
  /// recipient can answer over THIS sender's already-built rendezvous circuit
  /// (the answer surfaces as a non-zero [InboundMessage.replyId]). Use for
  /// messages that expect a fast confirmation (e.g. a delivery ACK) — it costs
  /// the sender one extra reply-circuit build but saves the responder a full
  /// resolve + circuit-build, halving the perceived round-trip. Same no-clearnet
  /// -fallback + fire-and-forget semantics as [send]. Anonymity is unchanged:
  /// the reply block is the SAME one-shot onion-return mechanism, not a reused
  /// circuit, so messages stay mutually unlinkable.
  Future<void> sendWithReply(NodeId dst, Uint8List payload);

  /// Answer a message that carried a non-zero [InboundMessage.replyId], routing
  /// back over the sender's embedded one-time reply circuit (no DHT resolve, no
  /// fresh circuit, no public ad either side). [replyId] is TTL-bounded by the
  /// node; an expired one fails like any undeliverable anonymous send.
  Future<void> sendReply(int replyId, Uint8List payload);

  /// Inbound application payloads addressed to us.
  Stream<InboundMessage> messages();

  /// Live count of the node's active overlay sessions (its connected peers) —
  /// emits the current value and every change. Surfaced as the real peer count
  /// in the network UI (never a fabricated number).
  Stream<int> sessionCount();

  /// Point-in-time snapshot of the node's peer sessions (node_id, state,
  /// direction, transport). Empty for transports that don't track peers (the
  /// loopback fake). No timestamps — callers stamp "last seen" themselves.
  Future<List<PeerInfo>> peers();

  Future<void> dispose();
}

/// A reliable, ordered, FLOW-CONTROLLED byte-stream to a peer — the transport's
/// windowed bulk channel (veil's SCTP-like stream: window-based flow control,
/// ordered delivery, retransmission). Unlike [VeilTransport.send] (fire-and-
/// forget datagrams with no congestion control), [write] back-pressures when the
/// peer's receive window is full, so a bulk file transfer rides the transport's
/// real congestion control instead of blasting + manual re-request. Mirrors
/// veil_flutter's `VeilStream`; an in-memory pipe implements it for tests.
abstract interface class ReliableStream {
  /// Write all of [data], resolving once the daemon has buffered it
  /// (flow-controlled). Throws if the stream is closed / the peer reset. The veil
  /// FFI caps one call at 16 MiB — callers chunk larger payloads.
  Future<void> write(Uint8List data);

  /// Read up to [maxBytes]. An EMPTY list means clean EOF (the peer closed its
  /// write half); further reads keep returning empty.
  Future<Uint8List> read({int maxBytes});

  /// Close + release the stream (idempotent).
  Future<void> close();
}

/// A [VeilTransport] that can also open/accept [ReliableStream]s — the bulk
/// file-transfer channel (any-size, flow-controlled). The production transport
/// implements it; simple datagram-only fakes need not, and the messaging layer
/// falls back to the datagram path when the transport is not a [StreamTransport].
abstract interface class StreamTransport {
  /// Open a reliable stream to [dst]'s chat endpoint (same routing/anonymity as
  /// a message), or null if one can't be opened.
  Future<ReliableStream?> openStream(NodeId dst);

  /// Accept the next inbound stream opened to our chat endpoint, or null on
  /// [timeout] (a server loop polls). The receive side of file streaming.
  Future<({ReliableStream stream, NodeId src})?> acceptStream(
      {Duration timeout});
}
