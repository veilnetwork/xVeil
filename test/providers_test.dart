import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/fake_node_controller.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/state/providers.dart';

void main() {
  test('default wiring is loopback when no real stack is present', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(realStackProvider), isNull);
    expect(c.read(veilTransportProvider), isA<LoopbackTransport>());
    expect(c.read(nodeControllerProvider), isA<FakeNodeController>());
    expect(c.read(myInviteProvider), isNull);
  });
}
