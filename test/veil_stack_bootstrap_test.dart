import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/veil_stack.dart';

void main() {
  test(
    'runtime bootstrap registration redeems every seed and tolerates one failure',
    () async {
      const peers = [
        BootstrapPeerCfg(
          transport: 'obfs4-tcp://203.0.113.10:5556',
          publicKey: 'AQIDBA==',
          nonce: 'BQY=',
        ),
        BootstrapPeerCfg(
          transport: 'quic://198.51.100.20:39998',
          publicKey: 'BwgJCA==',
          nonce: 'Cgs=',
          algo: 'ml-dsa-65',
        ),
      ];
      final joined = <String>[];

      final count = await registerRuntimeBootstrapPeers(peers, (uri) async {
        joined.add(uri);
        if (joined.length == 1) throw StateError('offline');
      });

      expect(count, 1);
      expect(joined, [
        'veil:bootstrap?pk=AQIDBA==&t=obfs4-tcp://203.0.113.10:5556'
            '&a=ed25519&nc=BQY=',
        'veil:bootstrap?pk=BwgJCA==&t=quic://198.51.100.20:39998'
            '&a=ml-dsa-65&nc=Cgs=',
      ]);
    },
  );
}
