import 'dart:async';
import 'dart:typed_data';

import '../../core/ids.dart';
import 'veil_transport.dart';

/// Raised when something tries to use the network while no real transport
/// exists.
class TransportUnavailable implements Exception {
  const TransportUnavailable([this.detail]);

  /// Why there is no node, when the boot path knows.
  final String? detail;

  @override
  String toString() =>
      'veil transport unavailable — this build has no running node, so '
      'nothing can be sent or received${detail == null ? '' : ' ($detail)'}';
}

/// The transport a SHIPPED build gets when no real node is up.
///
/// ## Why this exists rather than [LoopbackTransport]
///
/// The loopback stand-in echoes every `send` back ~700 ms later as an
/// `InboundMessage` whose `src` is the ADDRESSEE. That is exactly right for
/// developing the UI on one machine and exactly wrong anywhere else: it
/// fabricates a reply from someone who was never contacted (audit XV-01).
///
/// It was reachable in a packaged build. On mobile a native library that fails
/// to load is caught and surfaced as an honest boot error, but the desktop path
/// had no such branch — the veil dylib failing to load left the boot state
/// null, and the provider handed out a loopback. The user would have watched
/// their message be "delivered" and "answered" while nothing left the machine.
///
/// So a shipped build refuses instead. Sends throw, the inbound stream stays
/// empty for the life of the process, and the peer list is empty rather than
/// invented. Silence the user can see beats a conversation that is not
/// happening.
class FailClosedTransport implements VeilTransport {
  FailClosedTransport({this.reason = const TransportUnavailable()});

  /// What every send throws. Carried so the boot path can explain WHY.
  final Object reason;

  final _inbound = StreamController<InboundMessage>.broadcast();
  final _sessions = StreamController<int>.broadcast();
  bool _disposed = false;

  /// An obviously-unusable id. Distinct from loopback's `0xA0` fill so a log or
  /// a screenshot tells the two apart at a glance.
  static final _id = NodeId(Uint8List.fromList(List.filled(32, 0xFF)));

  @override
  Future<NodeId> nodeId() async => _id;

  // Every egress THROWS rather than dropping silently. A caller that appears to
  // succeed writes a "sent" row into the outbox, and the UI then shows a
  // message on its way that never existed — the failure has to reach the code
  // that records it.
  // `async` on purpose: an expression-bodied `=> throw` raises SYNCHRONOUSLY,
  // before a Future exists, which is not what a `Future<void>` signature
  // promises and not what a caller doing `send(...).catchError(...)` would
  // catch. These return a failed Future, like any other failing send.
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async =>
      throw reason;

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async =>
      throw reason;

  @override
  Future<void> sendReply(int replyId, Uint8List payload) async => throw reason;

  @override
  Stream<InboundMessage> messages() => _inbound.stream;

  /// Always zero, and it EMITS that: the network UI shows a real count of no
  /// peers instead of sitting on a stale or absent value.
  @override
  Stream<int> sessionCount() async* {
    yield 0;
    yield* _sessions.stream;
  }

  @override
  Future<List<PeerInfo>> peers() async => const [];

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _inbound.close();
    await _sessions.close();
  }
}
