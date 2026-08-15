import 'dart:async';
import 'dart:typed_data';

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
}) {
  if (myIdentity != null &&
      myIdentity.length == dst.bytes.length &&
      _sameBytesFor(myIdentity, dst.bytes)) {
    return SendRoute.deviceSync;
  }
  return anonymous ? SendRoute.onion : SendRoute.direct;
}

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
  /// This identity's receive address, once the boot knows it.
  ///
  /// Set rather than constructed: the transport connects before the sovereign
  /// material is read. Null on an identity with no document, where the node id
  /// is the whole story and nothing below changes.
  Uint8List? identityAddress;

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
    AppHandle? realtimeApp;
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
      );
    } catch (_) {
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
  /// slot at or above it, so stop before asking.
  static const kMaxProviderSlots = 8;

  /// [extraProviderSlots] registers the SAME service identity into that many
  /// further provider slots, each of which builds its own circuit to its own
  /// rendezvous relay. A sender then has several introduction points to this
  /// one node and can round-robin a FRAGMENTED reply across them instead of
  /// funnelling redundant copies of every fragment through one relay — which
  /// is what caps bulk download throughput, since reassembly is
  /// all-or-nothing.
  ///
  /// Each extra slot costs a circuit build, so it is worth asking for only
  /// where the reply is large. Best-effort: a slot that fails to register is
  /// skipped, since the first one already makes the endpoint reachable.
  Future<VeilCapabilityEndpoint> hostTransientCapabilityEndpoint({
    required Uint8List identitySeed,
    required String name,
    required int endpointId,
    int providerSlot = 0,
    int extraProviderSlots = 0,
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
      for (var i = 1; i <= extraProviderSlots; i++) {
        final slot = providerSlot + i;
        if (slot >= kMaxProviderSlots) break;
        try {
          await client.registerEphemeralOnionService(
            identitySeed,
            providerSlot: slot,
          );
        } catch (error) {
          devLog(
            () =>
                'xVeil[capability]: extra provider slot $slot not '
                'registered ($error) — the endpoint stays reachable via the '
                'slots that did',
          );
          break;
        }
      }
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
    required void Function(InboundMessage) deliver,
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
    switch (sendRouteFor(identityAddress, dst, anonymous: anonymous)) {
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

  @override
  Stream<InboundMessage> messages() => _app.messages().map(
    (message) => InboundMessage(
      src: NodeId(message.srcNodeId),
      payload: message.data,
      replyId: message.replyId,
      provenance: _provenanceOf(message),
    ),
  );

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
    await _realtimeApp.close();
    await _mediaApp.close();
    await _app.close();
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
