import 'dart:async';
import 'dart:typed_data';

import 'package:veil_flutter/veil_ffi.dart';

import '../../core/ids.dart';
import '../../core/log.dart';
import '../../state/mailbox_orchestrator.dart';
import '../../state/mailbox_service.dart';
import 'relay_key_cache.dart';
import 'veil_addressing.dart';
import 'veil_mailbox.dart';
import 'veil_mailbox_network.dart';
import 'veil_transport.dart';

/// Production [VeilTransport] over veil_flutter. Binds the shared `xveil/inbox`
/// named endpoint, so a peer is addressable from its node id alone (its app_id
/// is derived — see [chatAppIdFor], verified against the native bindNamed).
class VeilFlutterTransport
    implements VeilTransport, StreamTransport, P2PStreamTransport {
  VeilFlutterTransport._(
    this._socketPath,
    this._client,
    this._capabilityClient,
    this._app,
    this._mediaApp,
  ) {
    _mediaMessages = _mediaApp.messages().listen((m) {
      final src = NodeId(m.srcNodeId);
      if (!_bytesEqual(m.srcAppId, mediaAppIdFor(src))) {
        devLog(
          () =>
              'xVeil[media-p2p]: drop direct media from ${src.short} '
              '(unexpected app id)',
        );
        return;
      }
      _client.dispatchDirectMediaDatagram(
        srcNodeId: m.srcNodeId,
        payload: m.data,
      );
    });
  }

  final String _socketPath;
  final VeilClient _client;
  final VeilClient _capabilityClient;
  final AppHandle _app;
  final AppHandle _mediaApp;
  StreamSubscription<dynamic>? _mediaMessages;

  /// Connect to a running node's app IPC socket and bind the chat endpoint.
  static Future<VeilFlutterTransport> connect(String socketPath) async {
    final client = await VeilClient.connect(socketPath);
    VeilClient? capabilityClient;
    try {
      // Capability hosting/fetch uses a separate IPC connection. The main
      // client may spend seconds inside mailbox/rendezvous lookups while
      // holding its native mutex; sharing it made public-link bind/send wait
      // behind unrelated traffic even though Flutter itself was responsive.
      capabilityClient = await VeilClient.connect(socketPath);
      final app = await client.bindNamed(
        namespace: veilChatNamespace,
        name: veilChatName,
        endpointId: veilChatEndpointId,
      );
      final mediaApp = await client.bindNamed(
        namespace: veilChatNamespace,
        name: veilMediaName,
        endpointId: veilMediaEndpointId,
      );
      return VeilFlutterTransport._(
        socketPath,
        client,
        capabilityClient,
        app,
        mediaApp,
      );
    } catch (_) {
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
  Future<int> openMediaChannel(Uint8List dstNode, {bool direct = false}) async {
    if (!direct) return _client.openMediaChannel(dstNodeId: dstNode);
    final peer = NodeId(dstNode);
    return _mediaApp.openDirectMediaChannel(
      dstNodeId: dstNode,
      dstAppId: mediaAppIdFor(peer),
      dstEndpointId: veilMediaEndpointId,
    );
  }

  /// Enqueue one media datagram on [chan]. 0 queued / 1 dropped / -1 invalid.
  int sendMediaDatagram(int chan, Uint8List payload) =>
      _client.sendMediaDatagram(chan, payload);

  /// Refresh a black-holed anonymous media route after end-to-end silence.
  /// Direct channels reject this with -1; callers should only invoke it for an
  /// actual anonymous route.
  int repairMediaChannel(int chan) => _client.repairMediaChannel(chan);

  /// Inbound media datagrams received from [peerNode] (32 bytes) since start.
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

  /// One public download gets a short-lived IPC client. Closing that client
  /// releases its return endpoint server-side; AppHandle.close alone does not
  /// APP_UNBIND, so a shared client would eventually exhaust endpoint ids.
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
  Future<NodeId> nodeId() async => NodeId(await _client.nodeId());

  /// Recipient-bound mailbox crypto for shared-document epoch envelopes. It
  /// uses the same live node identity as offline delivery without exposing the
  /// underlying IPC client.
  VeilMailboxCrypto mailboxCrypto() =>
      VeilFlutterMailboxCrypto(_client.mailbox);

  /// Endpoints (distinct from the chat inbox at [veilChatEndpointId] = 0) the
  /// offline-mailbox path binds on this same client: a PUT source app (carries a
  /// non-spoofable src_app_id for anonymous deposits) and a FETCH reply app
  /// (the relay answers our drains over its one-time reply path here).
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
  }) async {
    final src = await _client.bind(
      namespace: veilChatNamespace,
      name: 'mailbox-src',
      endpointId: _mailboxSrcEndpointId,
    );
    final reply = await _client.bind(
      namespace: veilChatNamespace,
      name: 'mailbox-reply',
      endpointId: _mailboxReplyEndpointId,
    );
    final relay = VeilNetworkMailboxRelay(
      client: _client,
      fetchApp: reply,
      srcAppId: src.appId,
      replyEndpointId: _mailboxReplyEndpointId,
      // The KEM-key-given FETCH: when this relay's published KEM key is cached
      // (populated at registration), the drain routes straight to it instead of
      // the flaky rendezvous-ad self-resolve. Best-effort; absent → self-resolve.
      relayKeyCache: relayKeyCache,
    );
    final crypto = VeilFlutterMailboxCrypto(_client.mailbox);
    final me = NodeId(await _client.nodeId());
    return MailboxService(
      client: _client,
      me: me,
      orchestrator: MailboxOrchestrator(crypto, relay, poisoned: poisonedBlobs),
      deliver: deliver,
      relayKeyCache: relayKeyCache,
    );
  }

  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) {
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
  @override
  Future<({ReliableStream stream, NodeId src})?> acceptStream({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final r = await _client.acceptAnonStream(timeout: timeout);
    if (r == null) return null;
    return (
      stream: _VeilAnonReliableStream(r.stream),
      src: NodeId(r.srcNodeId),
    );
  }

  @override
  Future<({ReliableStream stream, NodeId src})?> acceptP2PStream({
    Duration timeout = const Duration(milliseconds: 250),
  }) async {
    final r = await _app.acceptStream(timeout: timeout);
    if (r == null) return null;
    return (stream: _VeilReliableStream(r.stream), src: NodeId(r.srcNodeId));
  }

  @override
  Stream<InboundMessage> messages() => _app.messages().map(
    (m) => InboundMessage(
      src: NodeId(m.srcNodeId),
      payload: m.data,
      replyId: m.replyId,
    ),
  );

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
    final mediaMessages = _mediaMessages;
    _mediaMessages = null;
    await mediaMessages?.cancel();
    await _mediaApp.close();
    await _app.close();
    await _capabilityClient.close();
    await _client.close();
  }
}

class VeilCapabilityEndpoint {
  VeilCapabilityEndpoint._(
    this._client,
    this._app,
    this.servicePublicKey, {
    bool closeClient = false,
  }) : // ignore: prefer_initializing_formals
       _closeClient = closeClient;

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

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
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
