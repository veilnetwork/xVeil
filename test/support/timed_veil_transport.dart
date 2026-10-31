import 'dart:typed_data';

import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';

typedef WireTiming =
    void Function(
      String phase,
      NodeId peer,
      Uint8List wire,
      int? attempt,
      bool? success,
    );

/// Passive native stand decorator. Preserve every capability of the real
/// transport so MessagingService keeps its production lane/receive selection.
class TimedVeilTransport
    implements
        VeilTransport,
        LocalSourceTransport,
        RealtimeTransport,
        DeviceRealtimeTransport,
        RelayRealtimeTransport,
        RealtimeInboundTransport,
        StreamTransport,
        P2PStreamTransport,
        CallMediaChannelOpener {
  TimedVeilTransport(this.inner, this.observe);
  final VeilFlutterTransport inner;
  final WireTiming observe;
  int _nextAttempt = 0;

  Future<void> _send(
    NodeId peer,
    Uint8List wire,
    Future<void> Function() body,
  ) async {
    final attempt = ++_nextAttempt;
    observe('wire_send_start', peer, wire, attempt, null);
    var success = false;
    try {
      await body();
      success = true;
    } finally {
      observe('wire_send_end', peer, wire, attempt, success);
    }
  }

  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) =>
      _send(dst, payload, () => inner.send(dst, payload, anonymous: anonymous));

  @override
  Future<void> sendOnLocalLane(
    NodeId dst,
    Uint8List payload, {
    required int localLane,
    bool anonymous = false,
  }) => _send(
    dst,
    payload,
    () => inner.sendOnLocalLane(
      dst,
      payload,
      localLane: localLane,
      anonymous: anonymous,
    ),
  );

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      _send(dst, payload, () => inner.sendWithReply(dst, payload));
  @override
  Future<void> sendReply(int replyId, Uint8List payload) =>
      inner.sendReply(replyId, payload);
  @override
  Future<NodeId> nodeId() => inner.nodeId();
  @override
  Stream<InboundMessage> messages() => inner.messages();
  @override
  Stream<InboundMessage> realtimeMessages() => inner.realtimeMessages();
  @override
  Stream<int> sessionCount() => inner.sessionCount();
  @override
  Future<List<PeerInfo>> peers() => inner.peers();
  @override
  Future<void> dispose() => inner.dispose();
  @override
  Future<void> sendRealtime(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) => inner.sendRealtime(dst, payload, anonymous: anonymous);
  @override
  Future<void> sendRealtimeToDevice(
    NodeId identity,
    NodeId device,
    Uint8List payload,
  ) => inner.sendRealtimeToDevice(identity, device, payload);
  @override
  Future<void> sendRelayRealtime(NodeId dst, Uint8List payload) =>
      inner.sendRelayRealtime(dst, payload);
  @override
  Future<ReliableStream?> openStream(NodeId dst) => inner.openStream(dst);
  @override
  Future<ReliableStream?> openP2PStream(NodeId dst) => inner.openP2PStream(dst);
  @override
  Future<void> warmStreamPeer(NodeId dst) => inner.warmStreamPeer(dst);
  @override
  Future<({ReliableStream stream, NodeId src, SenderProvenance provenance})?>
  acceptStream({Duration timeout = const Duration(seconds: 2)}) =>
      inner.acceptStream(timeout: timeout);
  @override
  Future<({ReliableStream stream, NodeId src, SenderProvenance provenance})?>
  acceptP2PStream({Duration timeout = const Duration(milliseconds: 250)}) =>
      inner.acceptP2PStream(timeout: timeout);
  @override
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) => inner.openMediaChannel(
    dstNode,
    txKey: txKey,
    rxKey: rxKey,
    direct: direct,
    relay: relay,
  );
}

/// Observe the actual durable boundary without replacing outbox persistence.
class TimedOutboxStorage extends HiddenVolumeStorage {
  TimedOutboxStorage(super.opener, {required this.observe}) : super.async();
  final WireTiming observe;

  @override
  Future<void> enqueueOutboxFrame(
    String frameId,
    String peerHex,
    Uint8List wire,
  ) async {
    final peer = NodeId.fromHex(peerHex);
    observe('wire_enqueue_start', peer, wire, null, null);
    var success = false;
    try {
      await super.enqueueOutboxFrame(frameId, peerHex, wire);
      success = true;
    } finally {
      observe('wire_enqueue_end', peer, wire, null, success);
    }
  }
}
