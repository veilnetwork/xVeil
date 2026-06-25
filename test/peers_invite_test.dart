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

  test('skips entries with a malformed / injecting transport', () {
    // Build a payload by hand with one good entry and bad transports.
    String enc(List<Map<String, String>> arr) =>
        'veil:peers?p=${base64Url.encode(utf8.encode(jsonEncode(arr)))}';
    final good = {
      'pk': base64.encode(_peer('tcp://1.2.3.4:9000', 1).publicKey),
      't': 'tcp://1.2.3.4:9000',
      'nc': base64.encode(_peer('x', 1).nonce),
      'a': 'ed25519',
    };
    final bad = {
      ...good,
      't': 'tcp://1.2.3.4:9000"\n[evil]', // injection chars
    };
    // Only the good entry survives.
    final parsed = SharedPeers.parse(enc([good, bad]));
    expect(parsed.peers.length, 1);
    expect(parsed.peers.single.transport, 'tcp://1.2.3.4:9000');
    // A share with ONLY bad transports has no entries → rejected.
    expect(() => SharedPeers.parse(enc([bad])), throwsFormatException);
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

  test('rejects an over-large share BEFORE decoding (memory-DoS guard)', () {
    // 32 KiB of payload — past the 16 KiB cap — is refused without decoding it.
    final huge = 'veil:peers?p=${'A' * (32 * 1024)}';
    expect(() => SharedPeers.parse(huge), throwsFormatException);
  });

  test('caps the number of ingested peers from one share', () {
    // 80 valid peers (short transports, so the whole token stays under the
    // 16 KiB size cap) — only the first 64 are ingested.
    final many = [for (var i = 0; i < 80; i++) _peer('tcp://a.b:1', i)];
    final uri = SharedPeers(many).toUri();
    expect(uri.length, lessThan(16 * 1024)); // the size guard must NOT trip here
    expect(SharedPeers.parse(uri).peers.length, 64);
  });
}
