import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_probe.dart';

void main() {
  test('reports reachable for an open port', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final result = await probeTcp('127.0.0.1', server.port);
    expect(result, ProbeResult.reachable);
  });

  test('reports unreachable for a closed port (fast)', () async {
    // Bind then immediately release to get a port nothing listens on.
    final tmp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = tmp.port;
    await tmp.close();
    final result = await probeTcp('127.0.0.1', port,
        timeout: const Duration(seconds: 2));
    expect(result, ProbeResult.unreachable);
  });

  test('never throws on a bogus host', () async {
    final result = await probeTcp('this.host.does.not.exist.invalid', 22,
        timeout: const Duration(seconds: 2));
    expect(result, ProbeResult.unreachable);
  });
}
