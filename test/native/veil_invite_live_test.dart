import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/veil_node.dart';

/// Verifies the node-management invite wrapper against the real veil-cli.
/// Env-gated: XVEIL_TEST_VEIL_CLI + XVEIL_TEST_VEIL_CONFIG (an initialised,
/// listener-bearing config).
void main() {
  final cli = Platform.environment['XVEIL_TEST_VEIL_CLI'];
  final config = Platform.environment['XVEIL_TEST_VEIL_CONFIG'];
  final skip = (cli == null || config == null || cli.isEmpty || config.isEmpty)
      ? 'set XVEIL_TEST_VEIL_CLI + XVEIL_TEST_VEIL_CONFIG'
      : false;

  test('veilBootstrapInvite returns a parseable invite for this identity',
      () async {
    final invite =
        await veilBootstrapInvite(veilCliPath: cli!, configPath: config!);
    expect(invite.publicKey.length, 32);
    expect(invite.transport, startsWith('tcp://'));
    expect(invite.nodeId.hex.length, 64);
    // The CLI round-trips through our parser/serialiser.
    expect(invite.toUri(), startsWith('veil:bootstrap?pk='));
  }, skip: skip);
}
