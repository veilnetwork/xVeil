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
}
