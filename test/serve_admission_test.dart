// The bound on how many anonymous requests a host answers at once.
//
// What is being guarded is circuits, not bytes: each accepted request makes the
// host build a return circuit, so an unbounded `unawaited` per inbound datagram
// lets one holder of a valid capability turn tiny requests into as many onion
// round trips as it likes.
//
// The peak-concurrency assertions below are only worth something if the harness
// CAN see a peak above one — a measurement that never observes overlap looks
// exactly like a gate that works. The first test is that control.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/serve_admission.dart';

/// Runs [count] bodies through [gate] concurrently, each held open until
/// released, and reports the highest number that were inside together.
Future<int> _peakUnder(
  ServeAdmission gate,
  int count, {
  Duration hold = const Duration(milliseconds: 5),
}) async {
  var running = 0;
  var peak = 0;
  await Future.wait([
    for (var i = 0; i < count; i++)
      gate.run(() async {
        running++;
        if (running > peak) peak = running;
        await Future<void>.delayed(hold);
        running--;
        return i;
      }),
  ]);
  return peak;
}

void main() {
  test('the peak measurement can see an overlap when there is one', () async {
    // No gate in the way — ten bodies, all admitted. If this reports one, the
    // measurement is blind and every assertion below is vacuous.
    final wide = ServeAdmission(maxConcurrent: 10, maxWaiting: 0);
    expect(
      await _peakUnder(wide, 10),
      10,
      reason:
          'ten unrestricted bodies never registered as concurrent, so this '
          'harness cannot tell a serialized gate from an open one',
    );
  });

  test('never more answers in flight than the cap', () async {
    final gate = ServeAdmission(maxConcurrent: 3, maxWaiting: 100);
    expect(await _peakUnder(gate, 20), 3);
    expect(gate.refused, 0, reason: 'the queue was deep enough for all of them');
    expect(gate.running, 0, reason: 'every slot came back');
    expect(gate.waiting, 0);
  });

  test('a full queue is refused, and the refusal is counted', () async {
    final gate = ServeAdmission(maxConcurrent: 1, maxWaiting: 2);
    final release = Completer<void>();
    // One admitted and held, two queued, the rest refused.
    final admitted = gate.run(() => release.future);
    final queued = [gate.run(() async => 'a'), gate.run(() async => 'b')];
    final refused = [gate.run(() async => 'c'), gate.run(() async => 'd')];

    expect(await Future.wait(refused), [null, null]);
    expect(gate.refused, 2);
    expect(gate.waiting, 2, reason: 'the two queued ones are still waiting');

    release.complete();
    await admitted;
    expect(await Future.wait(queued), ['a', 'b'], reason: 'both were served');
    expect(gate.running, 0);
  });

  test('a body that throws still gives its slot back', () async {
    final gate = ServeAdmission(maxConcurrent: 1, maxWaiting: 1);
    await expectLater(
      gate.run(() async => throw StateError('answering failed')),
      throwsStateError,
    );
    expect(gate.running, 0, reason: 'the slot leaked and the host is now dead');
    expect(await gate.run(() async => 'next'), 'next');
  });

  test('a freed slot is handed over, not re-contested', () async {
    // The reason `_release` transfers instead of decrementing: a request
    // arriving in the gap between "slot freed" and "waiter resumes" would
    // otherwise take it too, and one release would admit two.
    final gate = ServeAdmission(maxConcurrent: 1, maxWaiting: 10);
    var running = 0;
    var peak = 0;
    Future<void> body() async {
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      running--;
    }

    final first = gate.run(body);
    final queued = [for (var i = 0; i < 4; i++) gate.run(body)];
    // Arrives while the queue is draining — the contender for a freed slot.
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final late = gate.run(body);
    await Future.wait([first, ...queued, late]);
    expect(peak, 1, reason: 'one release admitted two');
  });

  test('closing wakes whoever is waiting instead of stranding them', () async {
    final gate = ServeAdmission(maxConcurrent: 1, maxWaiting: 4);
    final release = Completer<void>();
    final admitted = gate.run(() => release.future);
    var queuedRan = false;
    final queued = gate.run(() async {
      queuedRan = true;
      return 'ran';
    });

    gate.close();
    expect(
      await queued.timeout(const Duration(seconds: 2)),
      isNull,
      reason: 'a waiter left pending holds everything it captured forever',
    );
    expect(queuedRan, isFalse, reason: 'a closed host must not answer');
    expect(await gate.run(() async => 'after'), isNull);

    release.complete();
    await admitted;
  });
}
