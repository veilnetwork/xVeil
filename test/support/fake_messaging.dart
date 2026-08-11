// A MessagingService stand-in for the model-exchange path.
//
// It captures what left the device and exposes the inbound callbacks the real
// dispatcher would invoke, so the service can be driven end to end without a
// node, a transport or a peer.
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/messaging.dart';

class FakeMessagingForModels implements MessagingService {
  /// Who was asked, in order.
  final asked = <NodeId>[];

  /// Every answer this device sent, as (peer, body).
  final offersSent = <(NodeId, String)>[];

  @override
  void Function(NodeId peer)? onModelInventoryRequest;

  @override
  void Function(NodeId peer, String bodyJson)? onModelInventoryOffer;

  @override
  Future<void> sendModelInventoryRequest(NodeId peer) async => asked.add(peer);

  @override
  Future<void> sendModelInventoryOffer(NodeId peer, String bodyJson) async =>
      offersSent.add((peer, bodyJson));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
