import 'dart:async';
import 'dart:typed_data';

import 'package:veil_flutter/veil_flutter.dart';

import '../../core/ids.dart';
import 'veil_addressing.dart';
import 'veil_transport.dart';

/// Production [VeilTransport] over veil_flutter. Binds the shared `xveil/inbox`
/// named endpoint, so a peer is addressable from its node id alone (its app_id
/// is derived — see [chatAppIdFor], verified against the native bindNamed).
class VeilFlutterTransport implements VeilTransport {
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
      throw StateError('create invite failed: ${r.status.name} ${r.detail ?? ''}');
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

  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) {
    if (anonymous) {
      // Onion rendezvous send: the node resolves dst's rendezvous ad, builds a
      // circuit through relays, and seals an introduce — the recipient and the
      // network never see this node as the origin. Fail-closed by contract: if
      // dst publishes no ad this throws (no clearnet fallback that would leak
      // our location). Proven end to end by test/native/onion_roundtrip_live_test.dart.
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
  Stream<InboundMessage> messages() => _app.messages().map(
        (m) => InboundMessage(src: NodeId(m.srcNodeId), payload: m.data),
      );

  @override
  Future<void> dispose() async {
    await _app.close();
    await _client.close();
  }
}
