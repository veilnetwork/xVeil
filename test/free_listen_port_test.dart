import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_stack.dart';

void main() {
  // Two running profiles could land on one listener port (a profile's port
  // spreads over base+1..99, an all-online session takes port + 1 + i), and
  // the second node came up with no listener: EADDRINUSE on apply-config.
  test('a held listener port is stepped past, a free one is kept', () async {
    final held = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      reuseAddress: false,
    );
    addTearDown(held.close);
    final port = held.port;
    expect(
      await firstFreeListenPort(port, lanListen: false),
      isNot(port),
      reason: 'the port another node holds must not be handed out',
    );

    held.close();
    expect(
      await firstFreeListenPort(port, lanListen: false),
      port,
      reason: 'control: a free port is kept as asked',
    );
    expect(await firstFreeListenPort(0, lanListen: false), 0);
  });
}
