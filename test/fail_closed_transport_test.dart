import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/fail_closed_transport.dart';
import 'package:xveil/data/transport/loopback_transport.dart';

/// `LoopbackTransport` echoes every send back ~700 ms later as an
/// `InboundMessage` whose `src` is the ADDRESSEE — right for developing the UI
/// on one machine, and a fabricated conversation anywhere else.
///
/// It was reachable in a packaged desktop build: a veil dylib that failed to
/// load left the boot state null, and the transport provider handed out a
/// loopback. The user would have watched their message be delivered and
/// answered while nothing had left the machine (audit XV-01).
void main() {
  final peer = NodeId(Uint8List.fromList(List.filled(32, 0x11)));
  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  group('the loopback really does fabricate a reply', () {
    test('a send comes back as an inbound message from the addressee',
        () async {
      // The precondition that makes the finding real. If this ever stops being
      // true, the fail-closed transport below is guarding nothing.
      final loop = LoopbackTransport();
      addTearDown(loop.dispose);

      final first = loop.messages().first;
      await loop.send(peer, bytes('hello'));
      final got = await first.timeout(const Duration(seconds: 5));

      expect(
        got.src,
        peer,
        reason: 'the echo claims to come FROM the person we wrote to',
      );
    });
  });

  group('the shipped stand-in refuses instead', () {
    test('every egress throws', () async {
      final t = FailClosedTransport();
      addTearDown(t.dispose);

      // Throwing, not dropping: a caller that appears to succeed writes a
      // "sent" row into the outbox, and the UI then shows a message on its way
      // that never existed.
      await expectLater(
        t.send(peer, bytes('hello')),
        throwsA(isA<TransportUnavailable>()),
      );
      await expectLater(
        t.sendWithReply(peer, bytes('hello')),
        throwsA(isA<TransportUnavailable>()),
      );
      await expectLater(
        t.sendReply(1, bytes('hello')),
        throwsA(isA<TransportUnavailable>()),
      );
    });

    test('nothing ever arrives', () async {
      final t = FailClosedTransport();
      var received = 0;
      final sub = t.messages().listen((_) => received++);
      addTearDown(sub.cancel);

      try {
        await t.send(peer, bytes('hello'));
      } catch (_) {
        /* expected */
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(
        received,
        0,
        reason: 'no invented peers and no invented replies — the whole point',
      );
      await t.dispose();
    });

    test('the peer count is a real zero, not an absence', () async {
      final t = FailClosedTransport();
      addTearDown(t.dispose);

      expect(await t.peers(), isEmpty);
      expect(
        await t.sessionCount().first.timeout(const Duration(seconds: 5)),
        0,
        reason: 'the network UI must show no peers rather than a stale value',
      );
    });

    test('its node id is visibly not a real one', () async {
      // Distinct from loopback's 0xA0 fill so a log or a screenshot tells the
      // two apart at a glance.
      final id = await FailClosedTransport().nodeId();
      expect(id.hex, matches(RegExp(r'^f+$')));
    });
  });
}
