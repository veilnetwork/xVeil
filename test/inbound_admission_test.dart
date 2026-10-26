import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/state/inbound_admission.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

InboundMessage _frame(
  int peer,
  int bytes, {
  SenderProvenance provenance = SenderProvenance.sessionPeer,
}) => InboundMessage(
  src: _id(peer),
  payload: Uint8List(bytes),
  provenance: provenance,
);

void main() {
  late Completer<void> stall;
  late InboundAdmission lane;

  /// A handler that never finishes, so every admitted frame stays on the
  /// books — the state the un-awaited listener could reach without a bound.
  Future<void>? offer(InboundMessage m, {bool known = true}) =>
      lane.admit(m, known: known, handle: (_) => stall.future);

  setUp(() {
    stall = Completer<void>();
    lane = InboundAdmission(
      label: 'test',
      maxBytes: 1 << 20,
      maxFrames: 100,
      maxKnownPeerBytes: 512 << 10,
      maxStrangerPeerBytes: 64 << 10,
      maxStrangerBytes: 128 << 10,
    );
  });

  tearDown(() {
    if (!stall.isCompleted) stall.complete();
  });

  test('the budget is bytes: many small frames are harmless', () {
    // 90 one-byte frames spread over peers. A frame COUNTER would be the whole
    // story here; a byte budget correctly sees nothing worth refusing.
    for (var i = 0; i < 90; i++) {
      expect(offer(_frame(i % 9, 1)), isNotNull, reason: 'frame $i');
    }
    expect(lane.droppedFrames, 0);
    expect(lane.queuedBytes, 90);
  });

  test('...and a handful of large ones is not', () {
    // Eight peers × 256 KiB = 2 MiB offered against a 1 MiB lane.
    var admitted = 0;
    for (var peer = 0; peer < 8; peer++) {
      if (offer(_frame(peer, 256 << 10)) != null) admitted++;
    }
    expect(admitted, 4, reason: '1 MiB of lane, 256 KiB per frame');
    expect(lane.droppedFrames, 4);
    expect(lane.droppedBytes, 4 * (256 << 10));
  });

  test('overflow DROPS — the lane never grows past its budget', () {
    for (var peer = 0; peer < 40; peer++) {
      offer(_frame(peer, 128 << 10));
    }
    expect(
      lane.queuedBytes,
      lessThanOrEqualTo(1 << 20),
      reason: 'refused frames must be gone, not parked',
    );
    expect(lane.droppedFrames, greaterThan(0));
  });

  test('one peer cannot take the whole lane', () {
    for (var i = 0; i < 8; i++) {
      offer(_frame(1, 128 << 10));
    }
    expect(lane.queuedBytes, 512 << 10, reason: 'per-peer ceiling');
    // ...and the room it did NOT take is still there for somebody else.
    expect(offer(_frame(2, 128 << 10)), isNotNull);
  });

  test('a claimed name gets a small slice, and all of them share one', () {
    // Per stranger: 64 KiB. Minting a fresh name per frame must not multiply
    // that — `src` is a field the sender fills in.
    var admitted = 0;
    for (var peer = 0; peer < 40; peer++) {
      final got = offer(
        _frame(peer, 32 << 10, provenance: SenderProvenance.claimed),
        known: false,
      );
      if (got != null) admitted++;
    }
    expect(admitted, 4, reason: '128 KiB shared ceiling / 32 KiB frames');

    // An authenticated peer is unaffected by the strangers' ceiling.
    expect(offer(_frame(77, 256 << 10)), isNotNull);
  });

  test('a frame count backstop covers the empty-datagram case', () {
    for (var i = 0; i < 200; i++) {
      offer(_frame(i % 20, 0));
    }
    expect(lane.queuedFrames, 100);
    expect(lane.droppedFrames, 100);
  });

  test('finishing a frame gives its room back', () async {
    final done = Completer<void>();
    final held = lane.admit(
      _frame(1, 512 << 10),
      known: true,
      handle: (_) => done.future,
    );
    expect(held, isNotNull);
    expect(offer(_frame(1, 1)), isNull, reason: 'peer is at its ceiling');

    done.complete();
    await held;

    expect(lane.queuedBytes, 0);
    expect(lane.queuedFrames, 0);
    expect(offer(_frame(1, 1)), isNotNull);
  });

  test('a failing handler still gives its room back', () async {
    final blew = lane.admit(
      _frame(1, 512 << 10),
      known: true,
      handle: (_) async => throw StateError('boom'),
    );
    await expectLater(blew, throwsA(isA<StateError>()));
    expect(lane.queuedBytes, 0);
  });

  test('a closed lane admits nothing', () {
    lane.close();
    expect(offer(_frame(1, 1)), isNull);
    expect(lane.isClosed, isTrue);
  });

  test(
    'pending live replays leave room for a new frame and run again later',
    () async {
      final small = InboundAdmission(label: 'replays', maxFrames: 2);
      var handled = 0;
      Future<void>? deliver(InboundMessage frame) => small.admit(
        frame,
        known: true,
        coalesceIdentical: true,
        handle: (_) {
          handled++;
          return stall.future;
        },
      );
      final original = deliver(_frame(1, 30));
      for (var n = 0; n < 100; n++) {
        expect(identical(deliver(_frame(1, 30)), original), isTrue);
      }
      expect(handled, 1);
      expect(small.queuedFrames, 1);
      expect(small.queuedBytes, 30);
      expect(small.coalescedFrames, 100);
      expect(deliver(_frame(2, 40)), isNotNull);
      expect(small.droppedFrames, 0);
      stall.complete();
      await original;
      await Future<void>.delayed(Duration.zero);
      expect(small.queuedFrames, 0);
      await deliver(_frame(1, 30));
      expect(handled, 3, reason: 'completed chunks must be re-consumable');
    },
  );

  test(
    'payload, source device, proof and reply route do not collapse',
    () async {
      final held = <Future<void>>[];
      InboundMessage frame({
        int peer = 1,
        int? device = 2,
        int reply = 0,
        int byte = 0,
        SenderProvenance proof = SenderProvenance.sessionPeer,
        void Function(String)? declined,
      }) => InboundMessage(
        src: _id(peer),
        srcDevice: device == null ? null : _id(device),
        replyId: reply,
        payload: Uint8List.fromList([byte]),
        provenance: proof,
        onDeclined: declined,
      );
      var calls = 0;
      void deliver(InboundMessage message) {
        held.add(
          lane.admit(
            message,
            known: true,
            coalesceIdentical: true,
            handle: (_) {
              calls++;
              return stall.future;
            },
          )!,
        );
      }

      deliver(frame());
      deliver(frame(peer: 3));
      deliver(frame(device: 3));
      deliver(frame(device: null));
      deliver(frame(reply: 1));
      deliver(frame(byte: 1));
      deliver(frame(proof: SenderProvenance.signed));
      deliver(frame(proof: SenderProvenance.claimed));
      deliver(frame(proof: SenderProvenance.claimed));
      deliver(frame(declined: (_) {}));
      deliver(frame(declined: (_) {}));
      expect(calls, held.length);
      stall.complete();
      await Future.wait(held);
      expect(lane.queuedBytes, 0);
    },
  );

  test(
    'synchronous failure releases replay reservation and permits retry',
    () async {
      final bad = lane.admit(
        _frame(1, 100),
        known: true,
        coalesceIdentical: true,
        handle: (_) => throw StateError('failed before returning a future'),
      );
      await expectLater(bad, throwsStateError);
      expect(lane.queuedFrames, 0);
      final retry = lane.admit(
        _frame(1, 100),
        known: true,
        coalesceIdentical: true,
        handle: (_) async {},
      );
      await retry;
      expect(lane.queuedBytes, 0);
    },
  );

  test('closing refuses even an identical pending replay', () async {
    final first = lane.admit(
      _frame(1, 30),
      known: true,
      coalesceIdentical: true,
      handle: (_) => stall.future,
    );
    lane.close();
    expect(
      lane.admit(
        _frame(1, 30),
        known: true,
        coalesceIdentical: true,
        handle: (_) async {},
      ),
      isNull,
    );
    stall.complete();
    await first;
    expect(lane.queuedFrames, 0);
  });
}
