import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/messaging_core.dart';

/// Frames queued together must not come due together.
///
/// The live-resend backoff is per frame and it saturates: past about six
/// attempts every pending frame waits the same ten minutes, so a batch queued
/// together comes due together and one flush pass emits the whole set.
/// Exponential backoff bounds how OFTEN a frame retries and says nothing about
/// how many retry at the same instant. Measured on the phone against three
/// offline contacts over 38 minutes: 55 bursts, four of them carrying
/// 1100-1600 sends inside 6-7 seconds — ~175 sends per second, while the ticks
/// between them were three a minute. Each of those attempts is a DHT lookup
/// for a peer that is not there.
///
/// `durable_redrive_test` pins the LADDER and stays green with the offset
/// deleted: it advances a fake clock far enough for one frame and never asks
/// what a second frame would do. This asks that.
void main() {
  const base = 600000; // the saturated ten-minute step
  const jitterFraction = 0.25;

  List<int> delaysFor(Iterable<String> ids) => [
    for (final id in ids) MessagingService.debugLiveResendDelayMs(base, id),
  ];

  test('a batch of frames is spread across the window, not stacked', () {
    final ids = [for (var i = 0; i < 200; i++) 'frame-$i'];
    final delays = delaysFor(ids);

    // The property that matters: they do not all land on one instant.
    final distinct = delays.toSet();
    expect(
      distinct.length,
      greaterThan(100),
      reason:
          'frames queued together still come due together — this is the burst '
          'the spread exists to break up (${distinct.length} distinct delays '
          'across ${ids.length} frames)',
    );

    // And they are spread ACROSS the window rather than bunched at one end.
    final min = delays.reduce((a, b) => a < b ? a : b);
    final max = delays.reduce((a, b) => a > b ? a : b);
    expect(
      max - min,
      greaterThan((base * jitterFraction * 0.5).round()),
      reason: 'the spread must cover a real part of the window',
    );
  });

  test('the offset only ever pulls a frame EARLIER', () {
    // Jittering upward would let a frame retry LATER than the ladder promises,
    // so delivery could only get slower. The first cut added the offset and
    // durable_redrive_test caught it.
    for (final id in ['a', 'b', 'zz-long-frame-id', '0', 'grp:deadbeef:7']) {
      final delay = MessagingService.debugLiveResendDelayMs(base, id);
      expect(delay, lessThanOrEqualTo(base), reason: 'id=$id must not be late');
      expect(
        delay,
        greaterThanOrEqualTo(base - (base * jitterFraction).round()),
        reason: 'id=$id fell outside the declared window',
      );
    }
  });

  test('a frame keeps its own offset across recomputes', () {
    // Deterministic, not random: a fresh draw each pass would let a frame walk
    // around inside the window and re-bunch with whatever it lands beside.
    const id = 'frame-stable';
    final first = MessagingService.debugLiveResendDelayMs(base, id);
    for (var i = 0; i < 5; i++) {
      expect(MessagingService.debugLiveResendDelayMs(base, id), first);
    }
  });

  test('a zero or tiny delay is left alone', () {
    expect(MessagingService.debugLiveResendDelayMs(0, 'x'), 0);
    expect(MessagingService.debugLiveResendDelayMs(-5, 'x'), -5);
    // Too small to carry a spread: returned unchanged rather than rounded to 0.
    expect(MessagingService.debugLiveResendDelayMs(2, 'x'), 2);
  });
}
