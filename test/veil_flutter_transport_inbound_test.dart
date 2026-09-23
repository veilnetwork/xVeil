import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_ffi.dart' show IncomingMessage;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';

void main() {
  // The node names the device a direct frame came from so the ack can go to
  // it; this is the hop where the app turns the delivery into its own type,
  // and a field left out here is gone with nothing to say so.
  test('the origin device survives into InboundMessage, and its absence too',
      () {
    IncomingMessage delivery(Uint8List? device) => IncomingMessage(
          srcNodeId: Uint8List.fromList(List.filled(32, 0xC4)),
          srcAppId: Uint8List(32),
          data: Uint8List.fromList([1, 2, 3]),
          srcDevice: device,
        );
    final device = Uint8List.fromList(List.filled(32, 0x13));
    final named = VeilFlutterTransport.debugToInbound(delivery(device));
    expect(named.srcDevice, NodeId(device));
    expect(named.src, NodeId(Uint8List.fromList(List.filled(32, 0xC4))));
    expect(VeilFlutterTransport.debugToInbound(delivery(null)).srcDevice, isNull);
  });
}
