import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';

/// audit XV-14 — the master/keys space was still opened on the UI isolate.
///
/// The claim under test is not "it feels faster". It is that the isolate that
/// CALLS the opener is no longer the isolate that executes the container open.
/// That is directly observable: a synchronous open gives the calling isolate's
/// event loop zero turns for its entire duration, and an off-isolate one cannot
/// help but give it turns.

/// Turns of the CALLING isolate's event loop that happened while [body] ran.
///
/// Each timer callback schedules the next, so one tick is one turn of this
/// isolate's loop. Nothing here can fire while this isolate sits inside a
/// synchronous FFI call — which is exactly the property being measured.
Future<({int ticks, Duration elapsed})> _ticksDuring(
  Future<void> Function() body,
) async {
  var ticks = 0;
  var running = true;
  void tick() {
    if (!running) return;
    ticks++;
    Timer.run(tick);
  }

  Timer.run(tick);
  // Prove the ticker is actually ticking before anything is measured, so a
  // reading of zero below means "starved", never "never started".
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final started = ticks;
  expect(started, greaterThan(0), reason: 'the ticker must be live');

  final stopwatch = Stopwatch()..start();
  await body();
  stopwatch.stop();
  running = false;
  return (ticks: ticks - started, elapsed: stopwatch.elapsed);
}

void main() {
  final available = ensureHiddenVolumeLoaded();
  final skipReason = available
      ? null
      : 'libhidden_volume_ffi not built — run scripts/build-native.sh';

  test('the inline lift starves the caller for the whole open', () async {
    // What production wired for the keys path until now. The inner opener here
    // stands in for `hvKeysSpaceOpener`: synchronous, and slow in proportion to
    // the container. On a large container the real one takes long enough that
    // Android kills the app for it — the ANR is this measurement with a bigger
    // number.
    const block = Duration(milliseconds: 300);

    // Calibrate on THIS machine rather than assert a constant: how many turns
    // does the loop get in [block] when nothing is holding the isolate?
    final idle = await _ticksDuring(
      () => Future<void>.delayed(block),
    );
    expect(idle.ticks, greaterThan(100), reason: 'the ticker must be lively');

    final opener = syncWrappedKeysOpener((keys) {
      final spin = Stopwatch()..start();
      while (spin.elapsed < block) {
        // Busy, not sleeping: an FFI call holds the isolate, it does not yield.
      }
      return FakeKvLogStore();
    });
    final blocked = await _ticksDuring(() async {
      expect(await opener(Uint8List(64)), isNotNull);
    });

    expect(
      blocked.elapsed,
      greaterThanOrEqualTo(block),
      reason: 'the open really did take that long',
    );
    // Not "exactly zero": the turn in which the block ends still gets to run an
    // overdue timer, and pinning the scheduler that precisely would be testing
    // Dart, not this. The claim is starvation, and starvation is a ratio.
    expect(
      blocked.ticks * 100,
      lessThan(idle.ticks),
      reason:
          'the caller got ${blocked.ticks} turns where an unblocked one gets '
          '${idle.ticks} — under 1%, i.e. frozen for the whole open. On the UI '
          'isolate that is a stopped app, and past 5s on Android a fatal ANR',
    );
  });

  test('the worker keys opener leaves the caller free', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_keys_worker_');
    final path = '${dir.path}/test.store';
    try {
      // A child space with something to read back. Closed before the measured
      // open: the container's flock is exclusive, and every production flow
      // closes the previous space first for the same reason.
      final child = HiddenVolumeStorage(
        hvSpaceOpener(path, argon: hv.ArgonPreset.min),
      );
      expect(
        await child.open(password: 'pw-child', createIfMissing: true),
        isTrue,
      );
      await child.putSetting('who', 'alice');
      final keys = await child.exportSpaceKeys();
      await child.close();

      // A/B on the SAME container, back to back: the wiring production had,
      // then the wiring it has now. A container this small opens in
      // milliseconds, so an absolute tick count would not separate "off the
      // caller" from "on the caller but quick" — the old path is the yardstick,
      // which needs no guessed constant and no model of the scheduler.
      AsyncKvLogStore? opened;
      final inlineRun = await _ticksDuring(() async {
        opened = await syncWrappedKeysOpener(hvKeysSpaceOpener(path))(keys);
      });
      expect(opened, isNotNull);
      await opened!.close(); // the container's flock is exclusive

      final opener = workerKeysSpaceOpener(path);
      final workerRun = await _ticksDuring(() async {
        opened = await opener(keys);
      });

      expect(
        opened,
        isNotNull,
        reason: 'the worker must genuinely open the space, not merely not block',
      );
      // The right space, opened correctly — an off-isolate open that lost the
      // data would be a worse bug than the one being fixed.
      expect(
        await HiddenVolumeStorage.fromAsyncStore(opened!).getSetting('who'),
        'alice',
      );
      expect(
        workerRun.ticks,
        greaterThan(inlineRun.ticks.clamp(1, 1 << 30) * 10),
        reason:
            'opening the same space by keys left the caller ${inlineRun.ticks} '
            'event-loop turns inline and ${workerRun.ticks} through the worker '
            '— an order of magnitude is the difference between "this isolate '
            'did the open" and "this isolate waited for it"',
      );
      await opened!.close();

      // Keys that match no space still answer null, not an error: the lock
      // screen must not be able to tell "wrong keys" from "no such space".
      final wrong = Uint8List.fromList(keys)..[0] ^= 0xff;
      expect(await opener(wrong), isNull);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);
}
