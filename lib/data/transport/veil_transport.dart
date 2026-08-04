import 'dart:typed_data';

import '../../core/ids.dart';

/// How much this device actually KNOWS about an [InboundMessage.src], as
/// opposed to what the frame merely claimed.
///
/// Mirrors veil's `SenderProvenance`, which since veil `2e5471cc` travels to
/// the app as the trailing byte of `AppDeliverPayload`. Before that, every
/// delivery path put the same untyped 32 bytes in front of the app, so a
/// contact's message and a stranger's frame that merely NAMED that contact were
/// indistinguishable — audit X/V-01. Any node on the network could hand this
/// device a frame carrying an accepted contact's node id, and it arrived AS
/// that contact.
///
/// The levels are a hierarchy of evidence, not of importance. Only [claimed]
/// means "nothing at all stands behind this name".
enum SenderProvenance {
  /// Nothing corroborates the claim. NEVER a basis for an authorization
  /// decision — and not a synonym for "hostile": this is the normal, correct
  /// level for the anonymous meta-E2E path and for anything relayed. ML-KEM
  /// seals to a PUBLISHED key, so it buys confidentiality and never origin;
  /// anyone can name anyone. An anonymous message from a stranger is a
  /// supported thing. A stranger wearing a contact's name is not.
  claimed,

  /// The message never left this device; `src` is our own node id.
  localIpc,

  /// `src` is the authenticated session peer that handed us the frame — the
  /// sender speaking for itself, not a name carried through it.
  sessionPeer,

  /// `src` is proven by a signature over this very message, checked against the
  /// sender's identity document.
  signed;

  /// Parse veil's wire byte. Anything unrecognised reads as [claimed] — the
  /// fail-closed direction, and the only safe one: a reader that does not
  /// understand some future level must treat the identity as unverified, never
  /// as proven.
  static SenderProvenance fromWire(int byte) => switch (byte) {
    1 => localIpc,
    2 => sessionPeer,
    3 => signed,
    _ => claimed,
  };

  /// Whether something the sender could not choose backs `src` up, so a
  /// decision may rest on it. False for [claimed] alone.
  bool get isAuthenticated => this != SenderProvenance.claimed;
}

/// A message received from a peer over the overlay network.
class InboundMessage {
  const InboundMessage({
    required this.src,
    required this.payload,
    this.replyId = 0,
    this.provenance = SenderProvenance.claimed,
  });
  final NodeId src;
  final Uint8List payload;

  /// What this device knows about [src] (audit X/V-01). Defaults to
  /// [SenderProvenance.claimed] on purpose: a construction site that says
  /// nothing has, by definition, verified nothing, and the default must be the
  /// one that cannot be mistaken for proof.
  final SenderProvenance provenance;

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

/// Optional latency-critical datagram egress over an already-active direct
/// peer session at realtime priority.
///
/// Call signaling uses this surface so an answer/end frame cannot enter route
/// discovery or sit behind bulk, mailbox and media control work. Failure when
/// no direct session exists is expected: the caller keeps a durable fallback.
/// [anonymous] has exactly the same no-clearnet-fallback contract as
/// [VeilTransport.send]: an anonymous identity still sends only through the
/// onion rendezvous path.
abstract interface class RealtimeTransport {
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  });
}

/// Optional non-anonymous low-latency egress through an already-connected
/// overlay relay. Unlike [RealtimeTransport], this does not require a direct
/// session to the destination and is suitable for cold call setup.
abstract interface class RelayRealtimeTransport {
  Future<void> sendRelayRealtime(NodeId dst, Uint8List payload);
}

/// Optional latency-critical inbound control surface.
///
/// Production binds call control to a dedicated app endpoint. Keep that stream
/// separate from the ordinary inbox all the way into [MessagingService]: an
/// answer/end frame must not depend on an adapter-side merge controller or sit
/// behind chat/bulk delivery. Implementations without a dedicated endpoint do
/// not need to implement this interface.
abstract interface class RealtimeInboundTransport {
  Stream<InboundMessage> realtimeMessages();
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

  /// Abort + release the stream (idempotent). Use when cancelling a timed-out
  /// transfer attempt so a blocked native read wakes promptly. A simple in-memory
  /// transport may implement this as [close].
  Future<void> abort();
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
  Future<({ReliableStream stream, NodeId src})?> acceptStream({
    Duration timeout,
  });

  /// Pre-warm the transport's outbound path toward [dst] so the next
  /// [openStream] / serve to that peer skips the cold-start (circuit-pool
  /// open) latency. Best-effort fire-and-forget; a no-op where the transport
  /// has no warmable state (in-memory test pipes).
  Future<void> warmStreamPeer(NodeId dst);
}

/// Optional direct P2P bulk stream surface.
///
/// Implementations expose this only when the native node can bridge AppOpen /
/// AppData directly over an active peer session. Callers must gate usage with
/// user P2P policy and anonymity posture; anonymous identities must never call
/// this surface.
abstract interface class P2PStreamTransport {
  Future<ReliableStream?> openP2PStream(NodeId dst);

  Future<({ReliableStream stream, NodeId src})?> acceptP2PStream({
    Duration timeout,
  });
}
