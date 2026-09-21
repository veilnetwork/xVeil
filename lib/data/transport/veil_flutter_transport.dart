import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

// `SenderProvenance` now exists on BOTH sides of this boundary: veil_flutter's
// (the SDK's decode of veil's wire byte) and this app's port type. They are the
// same four levels with the same bytes, but the app must speak its own
// vocabulary, so the SDK's name is hidden here and its value crosses as a
// `wireByte` — the one representation both sides agree on by construction.
import 'package:veil_flutter/veil_ffi.dart' hide SenderProvenance;

import '../../core/ids.dart';
import '../../core/log.dart';
import '../../state/mailbox_orchestrator.dart';
import '../../state/mailbox_service.dart';
import 'relay_key_cache.dart';
import 'veil_addressing.dart';
import 'veil_mailbox.dart';
import 'veil_mailbox_network.dart';
import 'veil_transport.dart';

/// Which path a live send may take.
enum SendRoute {
  /// None. The destination is our own identity, and no live path can reach a
  /// sibling device — the mailbox deposit the caller makes IS the delivery.
  deviceSync,

  /// Onion rendezvous circuit; the sender's location stays hidden.
  onion,

  /// Ordinary addressed send.
  direct,
}

/// Decide the path BEFORE anonymity does.
///
/// The ordering is the whole point, and getting it wrong is what a comment
/// cannot catch. Anonymity is on by default, and the anonymous branch used to
/// return first — so a send addressed at our own identity went out over a path
/// that cannot deliver it, and no check further down was ever reached.
///
/// Why no live path works: every device of an identity registers as a
/// rendezvous publisher under the SAME address, so resolving it picks one
/// device, and for the sender that device is itself. Measured on a two-device
/// stand as seven `INBOUND from=<our own id>` at the source and `recovered=0`
/// at the sibling, for a snapshot the source reported sent. The non-anonymous
/// path is no better: the node short-circuits a self-addressed send into a
/// local delivery.
///
/// The mailbox is the only path that knows an identity has several devices — it
/// seals one envelope per instance from the document this device holds. So a
/// device sync is deposit-only, deliberately against the usual "live leg first,
/// mailbox for whatever went unacknowledged". Until the direct path learns
/// instances, a live leg here is not a faster copy; it is a copy handed to the
/// wrong device.
SendRoute sendRouteFor(
  Uint8List? myIdentity,
  NodeId dst, {
  required bool anonymous,

  /// This node's OWN transport id. A send addressed here is a send to
  /// ourselves — never useful, and the shape a loop takes: the frame arrives,
  /// is ingested, and provokes the next one. Measured on a restored device as
  /// 286 entries in a device group against 34 on its sibling, from a caller
  /// that had guessed wrong about which member it was.
  ///
  /// Refused whatever the reason it was asked for, because a caller that gets
  /// this wrong cannot be the one to catch it.
  Uint8List? myNode,
}) {
  // Truly ourselves: this node's own transport id. Deposit-only, whoever asks.
  if (_addressesUs(myNode, dst)) return SendRoute.deviceSync;
  if (_addressesUs(myIdentity, dst)) {
    // The identity address, from a device PROVABLY not the master — our own
    // node id is known and differs. The anonymous path stays deposit-only:
    // every device publishes rendezvous under this address, so the resolve
    // picks one of them and for the sender that is itself (measured: seven
    // INBOUND from our own id for a snapshot reported sent). But a DIRECT
    // dial goes by node id to a session with a DIFFERENT node — the master is
    // a real listener at these 32 bytes — and refusing it kept every
    // sibling→master content stream waiting on a manifest that could never
    // come. With our own id unknown the answer stays deposit-only: we cannot
    // prove we are not the master, and a self-directed live send
    // short-circuits into a local delivery.
    final provablySibling = myNode != null && !_addressesUs(myNode, dst);
    if (!anonymous && provablySibling) return SendRoute.direct;
    return SendRoute.deviceSync;
  }
  return anonymous ? SendRoute.onion : SendRoute.direct;
}

bool _addressesUs(Uint8List? mine, NodeId dst) =>
    mine != null &&
    mine.length == dst.bytes.length &&
    _sameBytesFor(mine, dst.bytes);

bool _sameBytesFor(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The single surface through which the call media plane opens a datagram
/// channel. Every route goes through here and every route carries the same
/// mandatory directional keys, so the route→open mapping can be exercised
/// without a live node while the production implementation stays the only one
/// that talks to native.
abstract interface class CallMediaChannelOpener {
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct,
    bool relay,
  });
}

/// Merge the two inboxes a device answers on into one lane.
///
/// Extracted so the MERGE can be tested without a live node — the same reason
/// [peerFacingNodeIdOf] sits out here. What can go wrong with it is entirely
/// about lifetime, and lifetime is invisible from a passing send.
///
/// Hand-rolled rather than `StreamGroup`: `package:async` is not a dependency
/// of this app, and one merge does not earn one.
///
/// Closes only when BOTH sides are done. An inbox that ends first must not
/// take the other's frames with it: the sibling inbox is the one that can be
/// absent or fail, and the identity inbox carries every contact this person
/// has.
@visibleForTesting
Stream<InboundMessage> mergeInboundStreams(
  Stream<InboundMessage> a,
  Stream<InboundMessage> b,
) {
  late final StreamController<InboundMessage> out;
  StreamSubscription<InboundMessage>? subA;
  StreamSubscription<InboundMessage>? subB;
  var ended = 0;
  void endOne() {
    ended += 1;
    if (ended == 2) out.close();
  }

  out = StreamController<InboundMessage>(
    onListen: () {
      subA = a.listen(out.add, onError: out.addError, onDone: endOne);
      subB = b.listen(out.add, onError: out.addError, onDone: endOne);
    },
    onCancel: () async {
      await subA?.cancel();
      await subB?.cancel();
    },
  );
  return out.stream;
}

/// Which node id a peer knows this endpoint by, given what the boot found.
///
/// Extracted so the CHOICE can be tested without a live node: the defect it
/// exists for was never in the key derivation (which is symmetric and was
/// green) but in which id the call site handed it.
@visibleForTesting
NodeId peerFacingNodeIdOf({
  required NodeId deviceNodeId,
  required Uint8List? identityAddress,
}) => identityAddress == null ? deviceNodeId : NodeId(identityAddress);

/// Production [VeilTransport] over veil_flutter. Binds the shared `xveil/inbox`
/// named endpoint, so a peer is addressable from its node id alone (its app_id
/// is derived — see [chatAppIdFor], verified against the native bindNamed).
class VeilFlutterTransport
    implements
        VeilTransport,
        RealtimeTransport,
        RelayRealtimeTransport,
        RealtimeInboundTransport,
        StreamTransport,
        P2PStreamTransport,
        CallMediaChannelOpener {
  VeilFlutterTransport._(
    this._socketPath,
    this._nodeId,
    this._client,
    this._capabilityClient,
    this._realtimeClient,
    this._mediaClient,
    this._mailboxClient,
    this._app,
    this._mediaApp,
    this._realtimeApp,
    this._siblingClient,
    this._siblingApp,
  );

  final String _socketPath;
  final NodeId _nodeId;
  final VeilClient _client;
  final VeilClient _capabilityClient;
  final VeilClient _realtimeClient;
  final VeilClient _mediaClient;
  final VeilClient _mailboxClient;
  final AppHandle _app;
  final AppHandle _mediaApp;
  final AppHandle _realtimeApp;

  /// The inbox a SIBLING device addresses, bound under this node's device id.
  ///
  /// Null on a node whose two names coincide — one with no sovereign document,
  /// where the identity inbox already answers to the device id — and on an
  /// older node that cannot bind device-scoped. Both mean the same thing here:
  /// a sibling reaches this device through the mailbox only, exactly as it did
  /// before this inbox existed.
  final VeilClient? _siblingClient;
  final AppHandle? _siblingApp;

  /// Whether this node has an inbox a sibling device can address directly.
  /// Read by the stand: "did the second bind take" is otherwise only visible
  /// as a latency difference, which is the one thing it must not be judged by.
  bool get debugHasSiblingInbox => _siblingApp != null;
  /// This identity's receive address, once the boot knows it.
  ///
  /// Set rather than constructed: the transport connects before the sovereign
  /// material is read. Null on an identity with no document, where the node id
  /// is the whole story and nothing below changes.
  Uint8List? get identityAddress => _identityAddress;
  set identityAddress(Uint8List? value) {
    _identityAddress = value;
    // "Not known yet" and "known to be absent" are different answers and only
    // one of them is a reason to wait. Publishing BOTH is what lets
    // [peerFacingNodeId] block until the boot has decided, instead of racing
    // it and quietly answering with the device id.
    if (!_identityAddressKnown.isCompleted) _identityAddressKnown.complete();
  }

  Uint8List? _identityAddress;
  final Completer<void> _identityAddressKnown = Completer<void>();

  /// The node id a PEER derives this endpoint's addressing and per-call key
  /// material from: the IDENTITY when this device carries a document, its own
  /// node id when it does not.
  ///
  /// [deviceNodeId] answers "which device am I"; this answers "which address do
  /// others know me by", and call-media key derivation needs the second. Mixing
  /// them made both ends hash a different pair — one hashed its DEVICE against
  /// the peer's IDENTITY, the other the mirror image — so every sealed media
  /// cell arrived intact and failed to open. Measured on the stand 2026-09-19:
  /// `media.ingress.arrived n=1000` with `media.ingress.drop
  /// reason=seal-open-failed n=1000` on both sides of a live p2p call, while
  /// signalling over the same session was perfect.
  ///
  /// Awaits the boot's answer rather than sampling it: the address is published
  /// asynchronously, and a call that started first would otherwise derive
  /// unopenable keys on some launches and correct ones on others.
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!_identityAddressKnown.isCompleted) {
      try {
        await _identityAddressKnown.future.timeout(timeout);
      } on TimeoutException {
        // Say so. The fallback below is correct for an identity with no
        // document and WRONG for one that has a document we simply have not
        // read yet, and those two must not look alike in a log.
        devLog(
          () =>
              'xVeil[identity]: receive address still unknown after '
              '${timeout.inMilliseconds}ms — falling back to this device id '
              '${_nodeId.short}',
        );
      }
    }
    return peerFacingNodeIdOf(
      deviceNodeId: _nodeId,
      identityAddress: _identityAddress,
    );
  }

  int _debugRealtimeRxCount = 0;

  bool get debugChatBindingMatches =>
      _sameBytes(_app.appId, chatAppIdFor(_nodeId));
  bool get debugRealtimeBindingMatches =>
      _sameBytes(_realtimeApp.appId, realtimeAppIdFor(_nodeId));
  int get debugChatEndpointId => _app.endpointId;
  int get debugRealtimeEndpointId => _realtimeApp.endpointId;
  int get debugRealtimeRxCount => _debugRealtimeRxCount;

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Connect to a running node's app IPC socket and bind the chat endpoint.
  static Future<VeilFlutterTransport> connect(String socketPath) async {
    final client = await VeilClient.connect(socketPath);
    VeilClient? capabilityClient;
    VeilClient? realtimeClient;
    VeilClient? mediaClient;
    VeilClient? mailboxClient;
    VeilClient? siblingClient;
    AppHandle? realtimeApp;
    AppHandle? siblingApp;
    try {
      // Node identity is immutable for this transport lifetime. Cache it while
      // the IPC connection is otherwise idle so call setup never queues a
      // node-id RPC behind discovery/mailbox work on the shared client mutex.
      final nodeId = NodeId(await client.nodeId());
      // Capability hosting/fetch uses a separate IPC connection. The main
      // client may spend seconds inside mailbox/rendezvous lookups while
      // holding its native mutex; sharing it made public-link bind/send wait
      // behind unrelated traffic even though Flutter itself was responsive.
      capabilityClient = await VeilClient.connect(socketPath);
      // Call accept/end must not queue behind a slow mailbox/DHT operation on
      // the main IPC client. A separate sender-only binding preserves the same
      // node identity and destination inbox while isolating its writer/locks.
      realtimeClient = await VeilClient.connect(socketPath);
      // Per-packet call media gets its OWN IPC connection too. The node
      // handles each connection's requests inline in one loop, so a single
      // slow send on the shared main client (an anonymous send inside a
      // rendezvous resolve runs for SECONDS) froze both directions of every
      // endpoint bound to it — live RTP stalled 2-9 s bidirectionally while
      // the wire, the relay and the peer's node all measured healthy
      // (RTT-stall campaign, 2026-07-17). Same isolation precedent as
      // capabilityClient/realtimeClient above.
      mediaClient = await VeilClient.connect(socketPath);
      // The offline mailbox drives the node's SLOWEST inline IPC requests —
      // a drain FETCH warms the relay directory over the network (~5 s), a
      // relay-key lookup walks the DHT (3-9 s), sealing resolves the
      // recipient's cert. On the shared main client every one of those froze
      // messaging sends, file streams and the UI's peer polls for its full
      // duration (the node serves each connection's requests strictly in
      // order). Same isolation move as media above: the whole mailbox
      // domain — PUT source, FETCH reply endpoint, relay sends, crypto,
      // wake events — lives on this one dedicated connection, which also
      // keeps the non-spoofable src_app_id check (per-connection state)
      // intact.
      mailboxClient = await VeilClient.connect(socketPath);
      final app = await client.bindNamed(
        namespace: veilChatNamespace,
        name: veilChatName,
        endpointId: veilChatEndpointId,
      );
      final mediaApp = await mediaClient.bindNamed(
        namespace: veilChatNamespace,
        name: veilMediaName,
        endpointId: veilMediaEndpointId,
      );
      mediaApp.startDirectMediaReceiver(
        sourceNamespace: veilChatNamespace,
        sourceName: veilMediaName,
      );
      realtimeApp = await realtimeClient.bindNamed(
        namespace: veilChatNamespace,
        name: veilRealtimeName,
        endpointId: veilRealtimeEndpointId,
      );
      // THE INBOX A SIBLING DEVICE CAN ADDRESS.
      //
      // `app` above answers to this node's PEER-FACING name, which for a
      // device carrying an identity document is the IDENTITY — the address a
      // contact holds. Every device of one person shares it, so it cannot say
      // which of them a frame is for, and the device id it would be addressed
      // by had no endpoint bound under it at all.
      //
      // Measured on a two-device stand 2026-09-21: with a live direct session
      // up and `admitted=true` on both sides, twenty of twenty frames sent to
      // a sibling's device id were dropped in silence — the transport took
      // each one in 0 ms and reported no failure. Every arrival came from the
      // mailbox within ~10 ms of a drain, while an ordinary contact on the
      // same machine delivered 7 of 9 live.
      //
      // Its OWN IPC connection, not a second bind on `client`: the client-side
      // dispatch table is keyed by endpoint id ALONE, so binding both inboxes
      // at `veilChatEndpointId` over one connection would have the second
      // registration replace the first and silence the identity inbox — the
      // address every contact holds. The node's registry keys on
      // (app_id, endpoint_id) and tells them apart; only this table does not.
      //
      // The endpoint id stays `veilChatEndpointId` deliberately: a sender
      // already derives `chatAppIdFor(dst)` from whatever name it addresses,
      // so a frame aimed at a device id matches this binding with NO change on
      // the sending side and no new wire format.
      siblingClient = await VeilClient.connect(socketPath);
      try {
        siblingApp = await siblingClient.bindDeviceScoped(
          namespace: veilChatNamespace,
          name: veilChatName,
          endpointId: veilChatEndpointId,
        );
      } on Object catch (e) {
        // EXPECTED on a node whose two names coincide — one with no sovereign
        // document, where the device id IS the published address. There the
        // identity inbox already answers to it and the node's registry refuses
        // the duplicate (app_id, endpoint_id). Nothing is lost: this is the
        // behaviour that shipped before the second inbox existed.
        //
        // Not swallowed silently, because the OTHER reason to land here is an
        // old node without the device-scoped bind, and "sibling delivery is
        // quietly back on the mailbox" must be readable in a log rather than
        // inferred from latency.
        devLog(
          () =>
              'xVeil[transport]: no device-scoped inbox ($e) — a sibling '
              'reaches this device through the mailbox only',
        );
        await siblingClient.close();
        siblingClient = null;
        siblingApp = null;
      }
      return VeilFlutterTransport._(
        socketPath,
        nodeId,
        client,
        capabilityClient,
        realtimeClient,
        mediaClient,
        mailboxClient,
        app,
        mediaApp,
        realtimeApp,
        siblingClient,
        siblingApp,
      );
    } catch (_) {
      await siblingApp?.close();
      await siblingClient?.close();
      await realtimeApp?.close();
      await realtimeClient?.close();
      await mediaClient?.close();
      await mailboxClient?.close();
      await capabilityClient?.close();
      await client.close();
      rethrow;
    }
  }

  /// Ask the running node to assemble its own bootstrap-invite URI (from its
  /// in-memory `[identity]` + listener) over IPC — no config file, no veil-cli.
  /// This replaces the `veil-cli bootstrap invite` shell-out for the deniable
  /// boot path.
  Future<String> createInvite() async {
    final r = await _client.createBootstrapInvite();
    if (r.status != CreateBootstrapInviteStatus.ok || r.uri.isEmpty) {
      throw StateError(
        'create invite failed: ${r.status.name} ${r.detail ?? ''}',
      );
    }
    return r.uri;
  }

  // ── Media datagram channel (calls: Phase 2 lossy RTP/RTCP probe) ───────────
  // Concrete-only helpers (not on the VeilTransport/StreamTransport interface):
  // the debug soak hook casts to VeilFlutterTransport to drive the two-node
  // datagram test. Per-packet media is native↔native in production.

  /// Open a lossy media datagram channel to [dstNode] (32 bytes). Returns the
  /// channel id used by [sendMediaDatagram]/[closeMediaChannel].
  ///
  /// [txKey]/[rxKey] are the 32-byte directional call-media keys and are
  /// REQUIRED on every route. The native channel seals each cell with them and
  /// opens each inbound cell against them — there is no unsealed mode on any
  /// transport, so a channel that cannot be keyed simply does not open. The
  /// onion path in particular is NOT protected by its circuit envelope: the
  /// splicing relay must read the cell to route it.
  @override
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) async {
    if (direct && relay) {
      throw ArgumentError('media channel cannot be both direct and relay');
    }
    if (txKey.length != 32 || rxKey.length != 32) {
      throw ArgumentError('call-media keys must be 32 bytes');
    }
    if (!direct && !relay) {
      // ANONYMOUS-circuit media (group voice channels, onion 1:1 media) must
      // ride the MAIN client: its connection owns the node's single
      // onion-stream hub (endpoint 12, bound by the anon accept loop at
      // startup), and send/close/recvCount below already live on `_client`.
      // Opening on the dedicated media client binds a SECOND hub on another
      // connection and the node rejects it ("endpoint 12 is already bound") —
      // this silently killed every group voice channel when media moved to
      // its own connection (564008c). IPC head-of-line blocking on the main
      // connection has since been closed architecturally by per-request ids,
      // so anon media on `_client` is safe again.
      return _client.openMediaChannel(
        dstNodeId: dstNode,
        txKey: txKey,
        rxKey: rxKey,
      );
    }
    final peer = NodeId(dstNode);
    if (relay) {
      return _mediaApp.openRelayMediaChannel(
        dstNodeId: dstNode,
        dstAppId: mediaAppIdFor(peer),
        dstEndpointId: veilMediaEndpointId,
        txKey: txKey,
        rxKey: rxKey,
      );
    }
    return _mediaApp.openDirectMediaChannel(
      dstNodeId: dstNode,
      dstAppId: mediaAppIdFor(peer),
      dstEndpointId: veilMediaEndpointId,
      txKey: txKey,
      rxKey: rxKey,
    );
  }

  /// Enqueue one media datagram on [chan]. 0 queued / 1 dropped / -1 invalid.
  int sendMediaDatagram(int chan, Uint8List payload) =>
      _client.sendMediaDatagram(chan, payload);

  /// Select the batch envelope on a relay media channel. This is a WIRE FORMAT
  /// choice, not a security one: the batch header travels inside the same seal
  /// as every other cell, so it is never a fan-out instruction anyone on the
  /// path can read or rewrite. Nothing here needs the peer's protocol version.
  int setRelayMediaBatching(int chan, bool on, {bool compact = false}) =>
      _mediaApp.setRelayMediaBatching(chan, on, compact: compact);

  /// Relay drain queue/IPC timing for live call diagnostics.
  Map<String, int>? mediaChannelStats(int chan) =>
      _mediaApp.mediaChannelStats(chan);

  /// Refresh a black-holed anonymous media route after end-to-end silence.
  /// Direct channels reject this with -1; callers should only invoke it for an
  /// actual anonymous route.
  int repairMediaChannel(int chan) => _client.repairMediaChannel(chan);

  /// Inbound media datagrams from [peerNode] (32 bytes) that OPENED against the
  /// channel key, since process start. A stranger who writes into the receive
  /// point can no longer advance it, so this is a liveness signal about the
  /// peer rather than about the network — same units, strictly stronger
  /// meaning, so existing thresholds still hold.
  int mediaRecvCount(Uint8List peerNode) => _client.mediaRecvCount(peerNode);

  /// Close a media channel.
  void closeMediaChannel(int chan) => _client.closeMediaChannel(chan);

  /// Redeem a peer's invite on the running node (adds the bootstrap peer + dials
  /// it) over IPC — replaces the `veil-cli bootstrap join` shell-out.
  Future<void> joinInvite(String uri) async {
    final r = await _client.joinBootstrapUri(uri: uri);
    if (r.status != JoinBootstrapStatus.ok) {
      throw StateError('join failed: ${r.status.name} ${r.detail ?? ''}');
    }
  }

  /// Redeem a P2P direct-dial endpoint URI (LAN/observed address a contact
  /// shared over the E2E channel). Unlike [joinInvite], `alreadyRegistered` is
  /// SUCCESS here: the node refreshes the stored dial address and re-dials —
  /// that's the endpoint-exchange refresh semantic, not a conflict.
  Future<void> joinP2PEndpoint(String uri) async {
    final r = await _client.joinBootstrapUri(uri: uri);
    if (r.status != JoinBootstrapStatus.ok &&
        r.status != JoinBootstrapStatus.alreadyRegistered) {
      throw StateError('p2p join failed: ${r.status.name} ${r.detail ?? ''}');
    }
  }

  /// Live P-Net/session status for [peerNode] (32 bytes): `admitted` == true
  /// iff the node holds a live direct session — the same gate the direct
  /// media-channel open enforces. Poll after [joinP2PEndpoint] to learn when
  /// the direct session is actually up.
  Future<({bool admitted, bool hasCert})> peerPnetStatus(Uint8List peerNode) =>
      _client.peerPnetStatus(peerNode);

  /// Daemon listener-URI snapshot (real-P2P epic, Stage B). After the node's
  /// server-reflexive NAT probe the wildcard listener host is rewritten to
  /// the observed external IP — the app mines this for its own external
  /// `ip:port` endpoint candidate.
  Future<List<String>> listenTransports() => _client.listenTransports();

  /// Run one explicit, bounded UDP hole-punch attempt toward [peerNode]
  /// (real-P2P epic, Stage B: punch in the call path). The node drives
  /// reflector mapping discovery, coordinator signaling, the
  /// token-authenticated simultaneous punch, same-socket QUIC promotion and
  /// normal session registration under one 5-second budget;
  /// [VeilHolePunchStatus.connected] means a live direct session now exists
  /// and [peerPnetStatus] reports `admitted: true` the standard way. Repeat
  /// and concurrent calls for the same peer coalesce daemon-side.
  ///
  /// Runs on the CAPABILITY connection, not the main/media/realtime clients:
  /// the attempt holds its connection's mutex for up to ~10 s, so it must
  /// stay off the chat send path AND off the live-call media path — the very
  /// thing being negotiated.
  Future<VeilHolePunchStatus> attemptP2PHolePunch(Uint8List peerNode) =>
      _capabilityClient.attemptP2PHolePunch(peerNode);

  /// Native CLOUD-2B primitive: host a blinded service under a random
  /// application-owned identity. [identitySeed] is scrubbed by veil_flutter
  /// before this future yields and again by native at the ABI boundary.
  Future<Uint8List> registerEphemeralOnionService(
    Uint8List identitySeed, {
    int hopCount = 3,
    int providerSlot = 0,
  }) => _capabilityClient.registerEphemeralOnionService(
    identitySeed,
    hopCount: hopCount,
    providerSlot: providerSlot,
  );

  Future<void> withdrawEphemeralOnionService(Uint8List identityVk) =>
      _capabilityClient.withdrawEphemeralOnionService(identityVk);

  Future<AppHandle> bindCapabilityEndpoint({
    required String name,
    required int endpointId,
  }) => _capabilityClient.bindCapability(
    namespace: 'xveil-cloud-capability',
    name: name,
    endpointId: endpointId,
  );

  /// Bind an opaque app endpoint and advertise it under a random service
  /// identity. The returned endpoint owns both lifetimes; close withdraws the
  /// descriptor before releasing the app handle.
  Future<VeilCapabilityEndpoint> hostCapabilityEndpoint({
    required Uint8List identitySeed,
    required String name,
    required int endpointId,
    int providerSlot = 0,
  }) async {
    final app = await bindCapabilityEndpoint(
      name: name,
      endpointId: endpointId,
    );
    try {
      final servicePublicKey = await registerEphemeralOnionService(
        identitySeed,
        providerSlot: providerSlot,
      );
      return VeilCapabilityEndpoint._(_capabilityClient, app, servicePublicKey);
    } catch (_) {
      await app.close();
      rethrow;
    }
  }

  /// Derive the capability appId for [name] without hosting anything: a
  /// short-lived IPC client binds the endpoint, reads the natively-derived
  /// appId (node-independent for capability binds) and closes, which releases
  /// the binding server-side. A member content client uses this to compute
  /// the HOST's appId from the shared secret alias without registering the
  /// onion identity — registering would make this node a bogus provider.
  Future<Uint8List> capabilityAppId({
    required String name,
    required int endpointId,
  }) async {
    final client = await VeilClient.connect(_socketPath);
    try {
      final app = await client.bindCapability(
        namespace: 'xveil-cloud-capability',
        name: name,
        endpointId: endpointId,
      );
      final appId = Uint8List.fromList(app.appId);
      await app.close();
      return appId;
    } finally {
      await client.close();
    }
  }

  /// One public download gets a short-lived IPC client. Closing that client
  /// releases its return endpoint server-side; AppHandle.close alone does not
  /// APP_UNBIND, so a shared client would eventually exhaust endpoint ids.
  /// Mirrors `MAX_PROVIDER_SLOTS` in veil-anonymity: the native side refuses a
  /// slot at or above it, so a caller choosing one stops before asking. Its
  /// only reader used to be a loop that asked for several slots per service,
  /// which that side does not support (report27 X37).
  static const kMaxProviderSlots = 8;

  /// ONE SLOT, because that is what the API underneath can give.
  ///
  /// This used to take an `extraProviderSlots` count and loop, and the loop
  /// could not work in two independent ways. `registerEphemeralOnionService`
  /// ZEROES the seed it is handed — that is its contract — so every call after
  /// the first passed thirty-two zero bytes, which is not this service's
  /// identity but a well-known one anybody can derive. And the native side
  /// refuses the same identity in a second slot anyway, so even with the seed
  /// copied the loop would only have logged refusals (report27 X37).
  ///
  /// Removed rather than repaired: an option the layer below does not support
  /// is not an option, and a caller reading the old signature would reasonably
  /// think it had asked for something. Several introduction points for one
  /// service is a change to that API, not to this call.
  Future<VeilCapabilityEndpoint> hostTransientCapabilityEndpoint({
    required Uint8List identitySeed,
    required String name,
    required int endpointId,
    int providerSlot = 0,
  }) async {
    final client = await VeilClient.connect(_socketPath);
    AppHandle? app;
    try {
      app = await client.bindCapability(
        namespace: 'xveil-cloud-capability',
        name: name,
        endpointId: endpointId,
      );
      final servicePublicKey = await client.registerEphemeralOnionService(
        identitySeed,
        providerSlot: providerSlot,
      );
      return VeilCapabilityEndpoint._(
        client,
        app,
        servicePublicKey,
        closeClient: true,
      );
    } catch (_) {
      await app?.close();
      await client.close();
      rethrow;
    }
  }

  Future<void> sendToOnionServiceAnonymous({
    required Uint8List serviceIdentityVk,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List srcAppId,
    required Uint8List data,
  }) => _capabilityClient.sendToOnionServiceAnonymous(
    serviceIdentityVk: serviceIdentityVk,
    targetAppId: targetAppId,
    targetEndpointId: targetEndpointId,
    srcAppId: srcAppId,
    data: data,
  );

  @override
  Future<NodeId> nodeId() async => _nodeId;

  /// THIS DEVICE's transport id, synchronously.
  ///
  /// The same value [nodeId] returns — it is cached at connect — but callers
  /// that have to answer "is this member me?" cannot await, and the question is
  /// asked per member. On a device restored into an existing identity this is
  /// its OWN key and differs from the identity address; on a device that booted
  /// on the master key the two coincide. Both are correct, and confusing them
  /// is the mistake this whole area keeps making.
  NodeId get deviceNodeId => _nodeId;

  /// Recipient-bound mailbox crypto for shared-document epoch envelopes. It
  /// uses the same live node identity as offline delivery without exposing the
  /// underlying IPC client.
  VeilMailboxCrypto mailboxCrypto() =>
      VeilFlutterMailboxCrypto(_mailboxClient.mailbox);

  /// Endpoints (distinct from the chat inbox at [veilChatEndpointId] = 0) the
  /// offline-mailbox path binds on the DEDICATED mailbox client: a PUT source
  /// app (carries a non-spoofable src_app_id for anonymous deposits — the
  /// spoof check is per-connection, so source bind and relay sends must share
  /// one connection) and a FETCH reply app (the relay answers our drains over
  /// its one-time reply path here).
  static const _mailboxSrcEndpointId = 10;
  static const _mailboxReplyEndpointId = 11;

  /// Build the offline-delivery [MailboxService] over this node's client:
  /// binds the PUT-source + FETCH-reply endpoints, wires the network-path
  /// [VeilNetworkMailboxRelay] + node-side [VeilFlutterMailboxCrypto] into a
  /// [MailboxOrchestrator], and hands drained messages to [deliver] (the
  /// messaging layer routes + dedups them). Caller drives [MailboxService.start]
  /// with the relay to advertise.
  Future<MailboxService> buildMailboxService({
    required Future<void> Function(InboundMessage) deliver,
    RelayKeyCache? relayKeyCache,
    PoisonedBlobRegistry? poisonedBlobs,
    // The address this identity RECEIVES under, when it differs from the id the
    // node speaks under. Everything this service does is receiving — the
    // rendezvous ad, the cookie tying it to the relay registration, the relay
    // choice by XOR distance — so all of it follows this one.
    //
    // Null means "the same as the node's", which is the truth for every
    // identity in the field: a phrase-provisioned config key IS the master its
    // document names. See RealVeilStack.sovereignReceiveAddress.
    NodeId? receiveAddress,
  }) async {
    final src = await _mailboxClient.bind(
      namespace: veilChatNamespace,
      name: 'mailbox-src',
      endpointId: _mailboxSrcEndpointId,
    );
    final reply = await _mailboxClient.bind(
      namespace: veilChatNamespace,
      name: 'mailbox-reply',
      endpointId: _mailboxReplyEndpointId,
    );
    final relay = VeilNetworkMailboxRelay(
      client: _mailboxClient,
      fetchApp: reply,
      // The relay RETAINS the handle (not just its app_id): a dropped handle
      // is GC-finalized into veil_app_close → daemon unbind → every deposit
      // rejected SPOOFED_SRC. See VeilNetworkMailboxRelay.srcApp.
      srcApp: src,
      replyEndpointId: _mailboxReplyEndpointId,
      // The KEM-key-given FETCH: when this relay's published KEM key is cached
      // (populated at registration), the drain routes straight to it instead of
      // the flaky rendezvous-ad self-resolve. Best-effort; absent → self-resolve.
      relayKeyCache: relayKeyCache,
    );
    final crypto = VeilFlutterMailboxCrypto(_mailboxClient.mailbox);
    final me = receiveAddress ?? NodeId(await _mailboxClient.nodeId());
    return MailboxService(
      client: _mailboxClient,
      me: me,
      orchestrator: MailboxOrchestrator(crypto, relay, poisoned: poisonedBlobs),
      deliver: deliver,
      relayKeyCache: relayKeyCache,
    );
  }

  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) {
    // ADDRESSED AT OUR OWN IDENTITY: a sync to our other devices, and NO live
    // path can carry one today. Checked before the anonymous branch, because
    // anonymity is the default and that branch used to return first — which is
    // how a device sync ended up on a path that cannot deliver it.
    //
    // Every device of an identity registers as a rendezvous publisher under the
    // SAME address, so resolving it picks one device, and for the sender that
    // device is itself. Measured on a two-device stand: seven
    // `INBOUND from=<our own id>` at the source and `recovered=0` at the
    // sibling, for a snapshot the source reported sent. The plain path is no
    // better — the node short-circuits a self-addressed send into a local
    // delivery.
    //
    // The mailbox is the only path that knows an identity has several devices:
    // it seals one envelope per instance from the document we hold. So a device
    // sync is DEPOSIT-ONLY, deliberately against the usual "live leg first,
    // mailbox for what went unacknowledged" — the callers stash after every
    // send, and that deposit is the delivery. Until the direct path learns
    // instances, a live leg here would not be a faster copy; it would be a copy
    // handed to the wrong device.
    switch (sendRouteFor(
      identityAddress,
      dst,
      anonymous: anonymous,
      myNode: _nodeId.bytes,
    )) {
      case SendRoute.deviceSync:
        devLog(
          () =>
              'xVeil[send]: dst is our own identity — device sync by mailbox '
              'only (a live send resolves us, not our sibling)',
        );
        return Future<void>.value();
      case SendRoute.onion:
      case SendRoute.direct:
        break;
    }
    if (anonymous) {
      // Onion rendezvous send: the node resolves dst's rendezvous ad, builds a
      // circuit through relays, and seals an introduce — the recipient and the
      // network never see this node as the origin. The ONLY path taken for an
      // anonymous send: we never fall back to the clearnet _app.send, so the
      // sender's location can't leak even if the onion send can't complete. The
      // IPC send is fire-and-forget, so a circuit that can't be built yet does
      // NOT throw here — the message stays un-acked and the outbox retries it.
      // Proven end to end by test/native/onion_roundtrip_live_test.dart.
      return _app.sendAnonymousAuthenticated(
        dstNodeId: dst.bytes,
        dstAppId: chatAppIdFor(dst),
        dstEndpointId: veilChatEndpointId,
        data: payload,
      );
    }
    return _app.send(
      dstNodeId: dst.bytes,
      dstAppId: chatAppIdFor(dst),
      dstEndpointId: veilChatEndpointId,
      data: payload,
    );
  }

  @override
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) {
    if (anonymous) {
      return _realtimeApp.sendAnonymousAuthenticated(
        dstNodeId: dst.bytes,
        dstAppId: chatAppIdFor(dst),
        dstEndpointId: veilChatEndpointId,
        data: payload,
      );
    }
    // APP_RT_SEND is a genuine direct-session datagram at REALTIME priority.
    // The old implementation merely called ordinary `send` on a separate IPC
    // connection: it avoided a local mutex but still entered route discovery,
    // so an accepted call answer could arrive minutes after the ring timeout.
    // A no-session error is intentional; call control is also persisted through
    // the durable outbox/mailbox and will retry there.
    return _realtimeApp.sendRealtime(
      dstNodeId: dst.bytes,
      dstAppId: realtimeAppIdFor(dst),
      dstEndpointId: veilRealtimeEndpointId,
      data: payload,
    );
  }

  @override
  Future<void> sendRelayRealtime(NodeId dst, Uint8List payload) {
    return _realtimeApp.sendRelayRealtime(
      dstNodeId: dst.bytes,
      dstAppId: realtimeAppIdFor(dst),
      dstEndpointId: veilRealtimeEndpointId,
      data: payload,
    );
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) {
    // Anonymous send that attaches a one-time reply block routed back to OUR
    // chat endpoint — the recipient answers (the delivery ACK) over the circuit
    // we already built, surfacing as a non-zero IncomingMessage.replyId, instead
    // of resolving + building a fresh circuit to us. No clearnet fallback (same
    // as the anonymous `send`); the reply block is one-shot, so unlinkable.
    return _app.sendAnonymousAuthenticatedWithReply(
      dstNodeId: dst.bytes,
      dstAppId: chatAppIdFor(dst),
      dstEndpointId: veilChatEndpointId,
      replyEndpointId: veilChatEndpointId,
      data: payload,
    );
  }

  @override
  Future<void> sendReply(int replyId, Uint8List payload) =>
      _app.sendReply(replyId: replyId, data: payload);

  /// Open a reliable, flow-controlled byte-stream to [dst]'s chat endpoint — the
  /// transport for any-size file transfer (Stage 6). Same app_id/endpoint as a
  /// message, so it lands on the peer's bound chat endpoint accept queue.
  @override
  Future<ReliableStream?> openStream(NodeId dst) async {
    // ANONYMOUS stream: onion-routed + congestion-controlled (veil-onion-stream),
    // so it reaches NAT'd/anonymous peers — unlike veil's DIRECT veil_stream
    // (which rides the wire AppOpen/AppData session machinery and only works to a
    // directly-reachable peer). On any failure return null → datagram fallback.
    try {
      final s = await _client.openAnonStream(
        dstNodeId: dst.bytes,
        dstAppId: streamAppIdFor(dst),
      );
      return _VeilAnonReliableStream(s);
    } catch (e) {
      devLog(
        () =>
            'xVeil[stream]: openAnonStream(${dst.short}) failed → '
            'datagram fallback: $e',
      );
      return null;
    }
  }

  @override
  Future<ReliableStream?> openP2PStream(NodeId dst) async {
    try {
      final s = await _app.openStream(
        dstNodeId: dst.bytes,
        dstAppId: chatAppIdFor(dst),
        dstEndpointId: veilChatEndpointId,
      );
      return _VeilReliableStream(s);
    } catch (e) {
      devLog(
        () =>
            'xVeil[stream-p2p]: openStream(${dst.short}) failed, '
            'falling back if possible: $e',
      );
      return null;
    }
  }

  /// Kick the native outbound circuit-pool open toward [dst] in the
  /// background so the next openStream/serve skips the cold-pool latency
  /// (first serve attempt after a restart died on the peer's 25 s manifest
  /// timeout while the pool was still opening). Best-effort: failures only
  /// mean the next stream pays the old cold-start price.
  @override
  Future<void> warmStreamPeer(NodeId dst) async {
    try {
      await _client.warmAnonStreamPeer(dstNodeId: dst.bytes);
    } catch (e) {
      devLog(() => 'xVeil[stream]: warmStreamPeer(${dst.short}) failed: $e');
    }
  }

  /// Accept the next inbound anonymous stream a peer opened to us, or null on
  /// [timeout] (so a server loop polls). The receive side of file streaming.
  ///
  /// Always [SenderProvenance.claimed], and that is the truthful answer rather
  /// than a placeholder: veil's anonymous stream hub derives the initiator from
  /// an onion cell, which is what anonymity means. `veil_stream_accept` carries
  /// a level; `veil_anon_stream_accept` has nothing to carry, because there is
  /// nothing to say. Stating it here keeps the caller from inheriting a trust
  /// level nobody established.
  @override
  Future<({ReliableStream stream, NodeId src, SenderProvenance provenance})?>
  acceptStream({Duration timeout = const Duration(seconds: 2)}) async {
    final r = await _client.acceptAnonStream(timeout: timeout);
    if (r == null) return null;
    return (
      stream: _VeilAnonReliableStream(r.stream),
      src: NodeId(r.srcNodeId),
      provenance: SenderProvenance.claimed,
    );
  }

  /// The direct lane, where veil DOES know who opened the stream: a remote
  /// `APP_OPEN` is read off the authenticated OVL1 session it arrived on, never
  /// off the frame body. `veil_stream_accept` pre-seeds its out-param with the
  /// fail-closed value, so a native side that forgot to write it reads as
  /// [SenderProvenance.claimed] rather than as whatever the allocator left.
  @override
  Future<({ReliableStream stream, NodeId src, SenderProvenance provenance})?>
  acceptP2PStream({
    Duration timeout = const Duration(milliseconds: 250),
  }) async {
    final r = await _app.acceptStream(timeout: timeout);
    if (r == null) return null;
    return (
      stream: _VeilReliableStream(r.stream),
      src: NodeId(r.srcNodeId),
      provenance: SenderProvenance.fromWire(r.provenance.wireByte),
    );
  }

  /// What veil KNOWS about the sender of a live frame, carried the whole way
  /// (audit X/V-01).
  ///
  /// The node decides it where the claim turns into an identity — from the
  /// authenticated peer of the session the frame arrived on, never from
  /// anything the frame writes — and since veil `78d57520` it survives the last
  /// leg too: `VeilRecvCb` gained a `provenance` parameter beside the id it
  /// qualifies, so `veil_flutter`'s `IncomingMessage` carries it instead of
  /// dropping it one frame short of the app.
  ///
  /// Re-decoded through THIS app's [SenderProvenance.fromWire] rather than
  /// mapped enum-to-enum, so the two definitions are held to the same wire
  /// bytes and an unrecognised one fails closed on this side as well.
  static SenderProvenance _provenanceOf(IncomingMessage message) =>
      SenderProvenance.fromWire(message.provenance.wireByte);

  static InboundMessage _toInbound(IncomingMessage message) => InboundMessage(
    src: NodeId(message.srcNodeId),
    payload: message.data,
    replyId: message.replyId,
    provenance: _provenanceOf(message),
  );

  /// Everything addressed to this device, by EITHER of its names.
  ///
  /// One lane, deliberately: a frame is the same frame whichever inbox it
  /// landed in, and the messaging layer above already decides what to do with
  /// it from its contents and its sender. Splitting them would push "which
  /// address was this sent to" into every caller, and not one of them has a
  /// use for the answer.
  @override
  Stream<InboundMessage> messages() {
    final identity = _app.messages().map(_toInbound);
    final sibling = _siblingApp?.messages();
    if (sibling == null) return identity;
    return mergeInboundStreams(identity, sibling.map(_toInbound));
  }


  @override
  Stream<InboundMessage> realtimeMessages() =>
      _realtimeApp.messages().map((message) {
        _debugRealtimeRxCount += 1;
        return InboundMessage(
          src: NodeId(message.srcNodeId),
          payload: message.data,
          replyId: message.replyId,
          provenance: _provenanceOf(message),
        );
      });

  @override
  Stream<int> sessionCount() async* {
    // The events stream only emits on a CHANGE, so a UI subscribing AFTER the
    // node's sessions came up showed 0 until the next change ("0 nodes" while
    // actually connected). Seed with the current active-peer count first — now
    // that peers() runs off-isolate this no longer blocks the UI — then follow
    // live changes.
    try {
      yield (await peers()).where((p) => p.isActive).length;
    } catch (_) {
      // ignore — fall through to the live stream
    }
    yield* _client
        .events()
        .where((e) => e.kind == VeilEventKind.sessionsChanged)
        .map((e) => e.sessionCount ?? 0);
  }

  @override
  Future<List<PeerInfo>> peers() async {
    final raw = await _client.peers();
    return raw
        .map(
          (p) => PeerInfo(
            nodeId: NodeId(p.nodeId),
            state: _mapState(p.state),
            direction: _mapDir(p.direction),
            transport: p.transport,
          ),
        )
        .toList(growable: false);
  }

  static PeerState _mapState(VeilPeerState s) => switch (s) {
    VeilPeerState.connecting => PeerState.connecting,
    VeilPeerState.active => PeerState.active,
    VeilPeerState.closed => PeerState.closed,
    VeilPeerState.unknown => PeerState.unknown,
  };

  static PeerDirection _mapDir(VeilPeerDirection d) => switch (d) {
    VeilPeerDirection.inbound => PeerDirection.inbound,
    VeilPeerDirection.outbound => PeerDirection.outbound,
    VeilPeerDirection.unknown => PeerDirection.unknown,
  };

  @override
  Future<void> dispose() async {
    await _siblingApp?.close();
    await _realtimeApp.close();
    await _mediaApp.close();
    await _app.close();
    await _siblingClient?.close();
    await _realtimeClient.close();
    await _mediaClient.close();
    await _mailboxClient.close();
    await _capabilityClient.close();
    await _client.close();
  }
}

class VeilCapabilityEndpoint {
  VeilCapabilityEndpoint._(
    this._client,
    this._app,
    this.servicePublicKey, {
    this._closeClient = false,
  });

  final VeilClient _client;
  final AppHandle _app;
  final Uint8List servicePublicKey;
  final bool _closeClient;
  bool _closed = false;

  Uint8List get appId => Uint8List.fromList(_app.appId);
  int get endpointId => _app.endpointId;
  Stream<Uint8List> get messages =>
      _app.messages().map((message) => message.data);

  /// The daemon binds source app ids to their owning IPC connection. Sending
  /// through another client would be rejected as SPOOFED_SRC, so capability
  /// request/response traffic originates from this endpoint's own client.
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) => _client.sendToOnionServiceAnonymous(
    serviceIdentityVk: servicePublicKey,
    targetAppId: targetAppId,
    targetEndpointId: targetEndpointId,
    srcAppId: _app.appId,
    data: data,
  );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _client.withdrawEphemeralOnionService(servicePublicKey);
    } finally {
      try {
        await _app.close();
      } finally {
        if (_closeClient) await _client.close();
      }
    }
  }
}

/// Adapts veil_flutter's [VeilStream] to the transport-agnostic [ReliableStream]
/// port, so the messaging layer drives bulk transfers without depending on
/// veil_flutter directly (and a fake pipe can stand in for tests).
class _VeilReliableStream implements ReliableStream {
  _VeilReliableStream(this._s);
  final VeilStream _s;

  @override
  Future<void> write(Uint8List data) => _s.write(data);

  @override
  Future<Uint8List> read({int maxBytes = 65536}) => _s.read(maxBytes: maxBytes);

  @override
  Future<void> close() => _s.close();

  @override
  Future<void> abort() => _s.close();
}

class _VeilAnonReliableStream implements ReliableStream {
  _VeilAnonReliableStream(this._s);
  final VeilAnonStream _s;
  @override
  Future<void> write(Uint8List data) => _s.write(data);
  @override
  Future<Uint8List> read({int maxBytes = 65536}) => _s.read(maxBytes: maxBytes);
  @override
  // Send an explicit FIN before releasing the handle. Relying on handle-drop to
  // imply FIN is too racy for the pinned-circuit backend: the app can drop its
  // FFI handle before the driver has accepted the half-close, and the peer then
  // observes a reset instead of EOF under load.
  Future<void> close() async {
    try {
      await _s.finish();
    } finally {
      await _s.close();
    }
  }

  @override
  Future<void> abort() => _s.abort();
}
