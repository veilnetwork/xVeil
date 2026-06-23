import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/mailbox_service.dart';

NodeId _id(List<int> prefix) {
  final b = Uint8List(32);
  for (var i = 0; i < prefix.length && i < 32; i++) {
    b[i] = prefix[i];
  }
  return NodeId(b);
}

void main() {
  group('relaysByXorDistance', () {
    test('orders candidates by XOR distance to our node_id (closest first)', () {
      final me = _id([0x00]);
      final near = _id([0x01]); // distance 0x01..
      final mid = _id([0x10]); // distance 0x10..
      final far = _id([0x80]); // distance 0x80..

      final out = relaysByXorDistance(me, [far, near, mid]);
      expect(out, [near, mid, far]);
    });

    test('is anchor-relative: a different identity picks a different closest', () {
      final relays = [_id([0x10]), _id([0x20]), _id([0x30])];

      // Anchor 0x11 → XOR to 0x10 is 0x01 (closest of {0x01,0x31,0x21}).
      expect(relaysByXorDistance(_id([0x11]), relays).first, _id([0x10]));
      // Anchor 0x31 → XOR to 0x30 is 0x01 (closest of {0x21,0x11,0x01}). Same
      // set, different winner = the load-spreading property that matches veil's
      // XOR pick (XOR distance is NOT numeric proximity).
      expect(relaysByXorDistance(_id([0x31]), relays).first, _id([0x30]));
    });

    test('is deterministic and does not mutate the input', () {
      final me = _id([0xAA]);
      final input = [_id([0x01]), _id([0x40]), _id([0x05])];
      final snapshot = [...input];

      final a = relaysByXorDistance(me, input);
      final b = relaysByXorDistance(me, input);
      expect(a, b); // same input → same order, every call
      expect(input, snapshot); // input untouched
    });
  });
}
