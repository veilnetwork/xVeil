import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/peers_invite.dart';

BootstrapInvite _peer(String transport, int seed) => BootstrapInvite(
      publicKey:
          Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff)),
      transport: transport,
      nonce: Uint8List.fromList([seed & 0xff, (seed + 1) & 0xff]),
      algo: 'ed25519',
    );

void main() {
  test('round-trips a multi-peer share through the URI codec', () {
    final peers = [
      _peer('obfs4-tcp://203.12.31.146:5556', 1),
      _peer('obfs4-tcp://203.12.31.145:5556', 50),
    ];
    final uri = SharedPeers(peers).toUri();

    expect(SharedPeers.looksLikeSharedPeers(uri), isTrue);
    expect(uri.startsWith('veil:peers?p='), isTrue);

    final back = SharedPeers.parse(uri);
    expect(back.peers.length, 2);
    for (var i = 0; i < peers.length; i++) {
      expect(back.peers[i].transport, peers[i].transport);
      expect(base64.encode(back.peers[i].publicKey),
          base64.encode(peers[i].publicKey));
      expect(base64.encode(back.peers[i].nonce),
          base64.encode(peers[i].nonce));
      expect(back.peers[i].nodeId.hex, peers[i].nodeId.hex);
    }
  });

  test('a peers-share is NOT mistaken for a bootstrap invite, and vice versa',
      () {
    final uri = SharedPeers([_peer('tcp://1.2.3.4:9000', 7)]).toUri();
    expect(SharedPeers.looksLikeSharedPeers(uri), isTrue);
    // A bootstrap invite must not be read as a peers-share.
    const invite =
        'veil:bootstrap?pk=l/Mxk9sBuZDJh9fAFU/O0a+6vglkoE1bneO0K+OFwgM=&t=tcp://127.0.0.1:9100&a=ed25519&nc=AYX/vg==';
    expect(SharedPeers.looksLikeSharedPeers(invite), isFalse);
  });

  test('rejects malformed peers payloads', () {
    expect(() => SharedPeers.parse('veil:peers?'), throwsFormatException);
    expect(() => SharedPeers.parse('veil:peers?p='), throwsFormatException);
    expect(() => SharedPeers.parse('not-a-share'), throwsFormatException);
    // valid base64url but an empty list ⇒ no entries
    final emptyList = base64Url.encode(utf8.encode('[]'));
    expect(() => SharedPeers.parse('veil:peers?p=$emptyList'),
        throwsFormatException);
  });
}
