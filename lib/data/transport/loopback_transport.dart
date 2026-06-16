import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import 'veil_transport.dart';

/// In-memory stand-in for [VeilTransport] used until the native veil stack is
/// wired. It lets the full messenger UX run on a single device.
///
/// Behaviour: any payload you `send` to a peer is echoed back ~700ms later as
/// an inbound message *from that peer*, so conversations look two-sided. This
/// is a development aid only — it never touches the network.
class LoopbackTransport implements VeilTransport {
  LoopbackTransport({NodeId? localNodeId})
      : _local = localNodeId ?? _deterministicLocalId();

  final NodeId _local;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final _pending = <Timer>[];
  bool _disposed = false;

  static NodeId _deterministicLocalId() {
    // Stable, obviously-fake id (0xA0 repeated) so dev sessions are reproducible.
    return NodeId(Uint8List.fromList(List.filled(32, 0xa0)));
  }

  @override
  Future<NodeId> nodeId() async => _local;

  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) async {
    // The dev loopback never touches the network, so anonymity is a no-op here —
    // it echoes regardless. The flag only matters for the real transport.
    if (_disposed) return;
    final text = utf8.decode(payload, allowMalformed: true);
    final reply = utf8.encode('↩︎ echo: $text');
    final t = Timer(const Duration(milliseconds: 700), () {
      if (_disposed) return;
      _inbound.add(InboundMessage(src: dst, payload: Uint8List.fromList(reply)));
    });
    _pending.add(t);
  }

  @override
  Stream<InboundMessage> messages() => _inbound.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final t in _pending) {
      t.cancel();
    }
    await _inbound.close();
  }
}
