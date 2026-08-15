// Which path a live send may take, and — the part that actually broke — in
// which ORDER the question is asked.
//
// A send addressed at our own identity is a sync to our other devices. No live
// path carries one: every device of an identity registers as a rendezvous
// publisher under the same address, so resolving it picks one device, and for
// the sender that device is itself. Measured on a two-device stand as seven
// inbound frames arriving back at the source and nothing at the sibling, for a
// snapshot the source reported sent.
//
// The check existed. It sat AFTER the anonymous branch, which returns first,
// and anonymity is on by default — so it was never reached on any real build.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

void main() {
  final me = _id(1);
  final peer = _id(2);

  // THE ONE THE DEFECT WAS ABOUT. Anonymous is the default, so if this asks
  // about anonymity first the answer is onion and the sync is lost.
  test('our own identity is a device sync even when anonymous', () {
    expect(
      sendRouteFor(me.bytes, me, anonymous: true),
      SendRoute.deviceSync,
      reason: 'anonymity must not decide before the destination does',
    );
    expect(sendRouteFor(me.bytes, me, anonymous: false), SendRoute.deviceSync);
  });

  // THE LOOP GUARD. A caller that has guessed wrong about which member it is
  // will address this node, and it cannot be the one to catch that — the frame
  // arrives, is ingested, and provokes the next. Measured on a restored device
  // as 286 entries in a device group against 34 on its sibling.
  test('our own node id is never live-sent to, whatever was asked', () {
    final myNode = _id(3);
    expect(
      sendRouteFor(me.bytes, myNode, anonymous: true, myNode: myNode.bytes),
      SendRoute.deviceSync,
    );
    expect(
      sendRouteFor(null, myNode, anonymous: false, myNode: myNode.bytes),
      SendRoute.deviceSync,
      reason: 'it holds even when the identity is not known yet',
    );
  });

  test('a peer still routes by anonymity', () {
    expect(sendRouteFor(me.bytes, peer, anonymous: true), SendRoute.onion);
    expect(sendRouteFor(me.bytes, peer, anonymous: false), SendRoute.direct);
  });

  // Before the boot resolves the identity there is nothing to compare against,
  // and refusing to send would be worse than sending: an identity with no
  // document has one device, and the ordinary paths are correct for it.
  test('an unknown identity changes nothing', () {
    expect(sendRouteFor(null, me, anonymous: true), SendRoute.onion);
    expect(sendRouteFor(null, peer, anonymous: false), SendRoute.direct);
  });

  test('a length mismatch is not a match', () {
    final short = Uint8List.fromList(List.filled(16, 1));
    expect(sendRouteFor(short, me, anonymous: true), SendRoute.onion);
  });
}
