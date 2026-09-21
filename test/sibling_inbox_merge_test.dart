// The two inboxes a device answers on arrive as ONE lane.
//
// A device that carries an identity document answers to two names: the
// IDENTITY, which is the address every contact holds, and its DEVICE id, which
// is the only name a sibling device can address — an identity is shared by all
// of one person's devices, so it cannot say which of them a frame is for.
//
// The second inbox was measured into existence on a two-device stand
// 2026-09-21: with a live direct session up and `admitted=true` on both sides,
// twenty of twenty frames sent to a sibling's device id were dropped in
// silence, because nothing was bound under that name. An ordinary contact on
// the same machine delivered 7 of 9 live.
//
// What can go wrong here is not delivery but LIFETIME, and lifetime is
// invisible from a passing send — hence these.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';

InboundMessage _msg(int tag) => InboundMessage(
  src: NodeId(Uint8List(32)..[0] = tag),
  payload: Uint8List.fromList([tag]),
  provenance: SenderProvenance.sessionPeer,
);

int _tagOf(InboundMessage m) => m.payload.first;

void main() {
  test('frames from both inboxes reach the one lane', () async {
    final identity = StreamController<InboundMessage>();
    final sibling = StreamController<InboundMessage>();
    final seen = <int>[];
    final sub = mergeInboundStreams(
      identity.stream,
      sibling.stream,
    ).listen((m) => seen.add(_tagOf(m)));

    identity.add(_msg(1));
    sibling.add(_msg(2));
    identity.add(_msg(3));
    await pumpEventQueue();

    expect(
      seen,
      containsAll(<int>[1, 2, 3]),
      reason:
          'a frame is the same frame whichever of this device\'s two names it '
          'was addressed to',
    );
    await sub.cancel();
    await identity.close();
    await sibling.close();
  });

  test('the identity inbox survives the sibling inbox ending', () async {
    final identity = StreamController<InboundMessage>();
    final sibling = StreamController<InboundMessage>();
    final seen = <int>[];
    var closed = false;
    final sub = mergeInboundStreams(identity.stream, sibling.stream).listen(
      (m) => seen.add(_tagOf(m)),
      onDone: () => closed = true,
    );

    // The sibling inbox is the one that can be absent or fail. Every contact
    // this person has arrives on the other one.
    await sibling.close();
    await pumpEventQueue();
    expect(closed, isFalse, reason: 'one inbox ending must not close the lane');

    identity.add(_msg(7));
    await pumpEventQueue();
    expect(
      seen,
      <int>[7],
      reason:
          'contacts must keep being delivered after the sibling inbox is gone',
    );

    await identity.close();
    await pumpEventQueue();
    expect(closed, isTrue, reason: 'both ended — now the lane may close');
    await sub.cancel();
  });

  _sourceGuards();

  test('cancelling the lane cancels both inboxes', () async {
    var identityCancelled = false;
    var siblingCancelled = false;
    final identity = StreamController<InboundMessage>(
      onCancel: () => identityCancelled = true,
    );
    final sibling = StreamController<InboundMessage>(
      onCancel: () => siblingCancelled = true,
    );

    final sub = mergeInboundStreams(
      identity.stream,
      sibling.stream,
    ).listen((_) {});
    await pumpEventQueue();
    await sub.cancel();

    expect(
      identityCancelled && siblingCancelled,
      isTrue,
      reason: 'a lane that leaks a subscription keeps a closed node\'s IPC '
          'connection draining forever',
    );
    await identity.close();
    await sibling.close();
  });
}

// ── the decisions a unit test cannot reach ────────────────────────────────
//
// Everything above exercises the MERGE. Neither of the two decisions that put
// it to work is reachable without a live node — the transport's constructor is
// private and takes real `AppHandle`s — and both can be undone in one line
// while every test above stays green. Same shape, and same reason, as veil's
// own `app_ids_are_derived_from_the_identity` guard.

const _transportPath = 'lib/data/transport/veil_flutter_transport.dart';

void _sourceGuards() {
  group('the sibling inbox is actually wired up', () {
    late String src;

    setUpAll(() {
      src = File(_transportPath).readAsStringSync();
      // Vacuity guard: a moved or renamed file must redden here rather than
      // satisfy the checks below by being empty.
      expect(
        src.length,
        greaterThan(20000),
        reason: '$_transportPath is unexpectedly small — did it move?',
      );
    });

    test('messages() merges the sibling inbox rather than returning one', () {
      final body = src.split('Stream<InboundMessage> messages() {');
      expect(
        body.length,
        2,
        reason: 'messages() no longer has this shape — re-point this guard',
      );
      final decision = body[1].split('\n  }').first;
      expect(
        decision.contains('mergeInboundStreams('),
        isTrue,
        reason:
            'messages() must merge both inboxes. Returning only the identity '
            'lane compiles, passes every test above, and silently puts sibling '
            'delivery back on the mailbox — measured at 0 of 20 frames live',
      );
    });

    test('the sibling inbox binds device-scoped, not named', () {
      expect(
        src.contains('bindDeviceScoped('),
        isTrue,
        reason:
            'the second inbox must bind under the DEVICE id. bindNamed would '
            'derive the identity address again — the one the first inbox '
            'already holds — and the node would refuse the duplicate',
      );
      expect(
        src.contains('siblingClient = await VeilClient.connect('),
        isTrue,
        reason:
            'the sibling inbox needs its OWN IPC connection: the client-side '
            'dispatch table is keyed by endpoint id alone, so a second bind at '
            'veilChatEndpointId over the shared client would replace the '
            'identity inbox and silence every contact',
      );
    });
  });
}
