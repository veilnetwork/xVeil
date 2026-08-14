// What pressing "send the encrypted setup" does when it does not work.
//
// From a report: someone linked a phone to a desktop, pressed send, and was
// still watching the spinner five minutes later. `_send` awaited
// `broadcastDeviceGroup()` — which awaits delivery to every member in turn —
// with no timeout anywhere in the chain, and swallowed every failure into one
// "could not complete device linking". A device that is simply not online
// therefore produced a wait with no end and no explanation.
//
// The four outcomes below are separated because they need four different
// things from the person: nothing, wait and retry, link a device first, and
// report a bug.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/settings/devices_screen.dart';

void main() {
  group('sendDeviceSnapshotBounded', () {
    test('delivered to somebody is "sent"', () async {
      expect(
        await sendDeviceSnapshotBounded(() async => 2),
        DeviceSnapshotSend.sent,
      );
    });

    // Zero is not a failure and must not be reported as one: it means the
    // group has nobody else in it yet, and the answer is "link a device",
    // not "try again".
    test('nobody to send to is its own answer, not a failure', () async {
      expect(
        await sendDeviceSnapshotBounded(() async => 0),
        DeviceSnapshotSend.noTargets,
      );
    });

    test('a throw is a failure', () async {
      expect(
        await sendDeviceSnapshotBounded(() async => throw StateError('x')),
        DeviceSnapshotSend.failed,
      );
    });

    // THE ONE THE REPORT WAS ABOUT. Before this, the send never came back at
    // all — so this test is the difference between an answer and a spinner.
    test('a send that never finishes gives up and says so', () async {
      final never = Completer<int>();
      addTearDown(() => never.complete(0));
      final outcome = await sendDeviceSnapshotBounded(
        () => never.future,
        timeout: const Duration(milliseconds: 50),
      );
      expect(outcome, DeviceSnapshotSend.timedOut);
    });

    test('a slow but finishing send is not cut off', () async {
      final outcome = await sendDeviceSnapshotBounded(
        () => Future.delayed(const Duration(milliseconds: 20), () => 1),
        timeout: const Duration(seconds: 5),
      );
      expect(outcome, DeviceSnapshotSend.sent);
    });

    // The timeout bounds the WAITING, not the sending. A broadcast that is
    // still in flight may yet land, and cancelling it would turn a slow
    // delivery into a failed one for no benefit.
    test('giving up on the wait does not stop the send', () async {
      var finished = false;
      final slow = Future.delayed(const Duration(milliseconds: 80), () {
        finished = true;
        return 1;
      });
      final outcome = await sendDeviceSnapshotBounded(
        () => slow,
        timeout: const Duration(milliseconds: 20),
      );
      expect(outcome, DeviceSnapshotSend.timedOut);
      expect(finished, isFalse, reason: 'sanity: it had not finished yet');
      await slow;
      expect(
        finished,
        isTrue,
        reason: 'the underlying send must keep running after we stop waiting',
      );
    });

    // A minute is the shipped bound. Asserted so that shortening it into a
    // race — the same transfer measures seconds over the live overlay, but a
    // cold path can be slower — is a deliberate edit rather than a typo.
    test('the shipped timeout is a minute, not a few seconds', () {
      expect(kDeviceSnapshotSendTimeout, const Duration(seconds: 60));
    });
  });
}
