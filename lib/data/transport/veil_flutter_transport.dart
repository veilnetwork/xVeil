import 'dart:async';
import 'dart:typed_data';

import 'package:veil_flutter/veil_flutter.dart';

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
class VeilFlutterTransport implements VeilTransport, StreamTransport {
  VeilFlutterTransport._(this._client, this._app);

  final VeilClient _client;
  final AppHandle _app;

  /// Connect to a running node's app IPC socket and bind the chat endpoint.
  static Future<VeilFlutterTransport> connect(String socketPath) async {
    final client = await VeilClient.connect(socketPath);
    try {
      final app = await client.bindNamed(
        namespace: veilChatNamespace,
        name: veilChatName,
        endpointId: veilChatEndpointId,
      );
      return VeilFlutterTransport._(client, app);
    } catch (_) {
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

  /// Redeem a peer's invite on the running node (adds the bootstrap peer + dials
  /// it) over IPC — replaces the `veil-cli bootstrap join` shell-out.
  Future<void> joinInvite(String uri) async {
    final r = await _client.joinBootstrapUri(uri: uri);
    if (r.status != JoinBootstrapStatus.ok) {
      throw StateError('join failed: ${r.status.name} ${r.detail ?? ''}');
    }
  }

  @override
  Future<NodeId> nodeId() async => NodeId(await _client.nodeId());

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
      orchestrator: MailboxOrchestrator(crypto, relay),
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
    await _app.close();
    await _client.close();
  }
}

/// Adapts veil_flutter's [VeilStream] to the transport-agnostic [ReliableStream]
/// port, so the messaging layer drives bulk transfers without depending on
/// veil_flutter directly (and a fake pipe can stand in for tests).
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
}
