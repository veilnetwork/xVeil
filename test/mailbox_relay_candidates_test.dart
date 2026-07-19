import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart' show BootstrapPeerCfg;
import 'package:xveil/state/messaging.dart';

void main() {
  test('mailbox relays deduplicate alternate transports for one seed', () {
    final publicKey = base64.encode(List<int>.generate(32, (i) => i));
    final relays = mailboxRelayCandidates([
      BootstrapPeerCfg(
        transport: 'obfs4-tcp://seed.example:5556',
        publicKey: publicKey,
        nonce: 'nonce',
      ),
      BootstrapPeerCfg(
        transport: 'quic://seed.example:39998',
        publicKey: publicKey,
        nonce: 'nonce',
      ),
      const BootstrapPeerCfg(
        transport: 'quic://bad.example:39998',
        publicKey: 'not-base64!',
        nonce: 'nonce',
      ),
    ]);

    expect(relays, hasLength(1));
  });
}
