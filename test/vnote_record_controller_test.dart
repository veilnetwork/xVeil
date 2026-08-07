import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;
import 'package:xveil/state/vnote_record_controller.dart';
import 'package:xveil/state/voice_record_controller.dart'
    show micPermissionProvider;

/// A fake recorder: no native lib, deterministic clip + preview frames.
class _FakeRecorder implements VnoteRecorder {
  _FakeRecorder({this.startOk = true, this.emptyClip = false});
  final bool startOk;
  final bool emptyClip;
  bool started = false;
  bool disposed = false;
  int elapsed = 0;
  int framesServed = 0;

  /// Held open to model the real recorder, whose `start()` spans the camera
  /// opening plus the get-ready window.
  Completer<void>? gate;

  @override
  Future<bool> start() async {
    final g = gate;
    if (g != null) await g.future;
    started = startOk;
    return startOk;
  }

  @override
  double get level => started ? 0.42 : 0;

  @override
  int get elapsedMs => elapsed;

  @override
  VeilVideoFrame? frame() {
    framesServed++;
    return VeilVideoFrame(
        rgba: Uint8List(4 * 4 * 4), width: 4, height: 4);
  }

  @override
  VnoteClip? stop() {
    if (emptyClip) return null;
    return VnoteClip(
      bytes: Uint8List.fromList([9, 8, 7]),
      durationMs: elapsed == 0 ? 2000 : elapsed,
    );
  }

  @override
  void dispose() => disposed = true;
}

ProviderContainer _container({
  required VnoteRecorder? recorder,
  bool micGranted = true,
  bool camGranted = true,
}) {
  return ProviderContainer(overrides: [
    vnoteRecorderFactoryProvider.overrideWithValue(() => recorder),
    micPermissionProvider.overrideWithValue(() async => micGranted),
    cameraPermissionProvider.overrideWithValue(() async => camGranted),
  ]);
}

void main() {
  test('start -> recording; stop returns the note and disposes', () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(vnoteRecordControllerProvider.notifier);

    expect(c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.idle);
    await ctrl.start();
    expect(c.read(vnoteRecordControllerProvider).isRecording, isTrue);
    expect(rec.started, isTrue);

    final clip = ctrl.stop();
    expect(clip, isNotNull);
    expect(clip!.bytes, [9, 8, 7]);
    expect(clip.durationMs, 2000);
    expect(rec.disposed, isTrue);
    expect(c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.idle);
  });

  test('denied camera -> denied phase even with the mic granted', () async {
    var built = false;
    final c = ProviderContainer(overrides: [
      vnoteRecorderFactoryProvider.overrideWithValue(() {
        built = true;
        return _FakeRecorder();
      }),
      micPermissionProvider.overrideWithValue(() async => true),
      cameraPermissionProvider.overrideWithValue(() async => false),
    ]);
    addTearDown(c.dispose);
    await c.read(vnoteRecordControllerProvider.notifier).start();
    expect(
        c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.denied);
    expect(built, isFalse, reason: 'no recorder must be built when denied');
  });

  test('recorder start failure -> error phase + dispose', () async {
    final rec = _FakeRecorder(startOk: false);
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    await c.read(vnoteRecordControllerProvider.notifier).start();
    expect(
        c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.error);
    expect(rec.disposed, isTrue);
  });

  test('cancel discards without a clip', () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(vnoteRecordControllerProvider.notifier);
    await ctrl.start();
    ctrl.cancel();
    expect(rec.disposed, isTrue);
    expect(c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.idle);
    expect(ctrl.takeAutoStopped(), isNull);
  });

  test('poll surfaces elapsed/level and the preview frame', () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(vnoteRecordControllerProvider.notifier);
    await ctrl.start();
    rec.elapsed = 1234;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final s = c.read(vnoteRecordControllerProvider);
    expect(s.elapsedMs, 1234);
    expect(s.level, closeTo(0.42, 0.001));
    expect(ctrl.preview.value, isNotNull);
    expect(ctrl.preview.value!.width, 4);
    ctrl.stop();
    expect(ctrl.preview.value, isNull, reason: 'preview clears on stop');
  });

  test('auto-stop at the 60 s cap parks the clip for takeAutoStopped',
      () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(vnoteRecordControllerProvider.notifier);
    await ctrl.start();
    rec.elapsed = VnoteRecordController.maxDuration.inMilliseconds + 100;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.idle);
    final clip = ctrl.takeAutoStopped();
    expect(clip, isNotNull);
    expect(ctrl.takeAutoStopped(), isNull, reason: 'consumed once');
  });

  test('empty clip -> stop returns null', () async {
    final rec = _FakeRecorder(emptyClip: true);
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(vnoteRecordControllerProvider.notifier);
    await ctrl.start();
    expect(ctrl.stop(), isNull);
  });

  group('the get-ready window', () {
    // The recorder's start() now spans the camera opening plus a second to
    // compose yourself. The composer must show the round preview through all
    // of it — arming the phase and the poll only after start() returns would
    // leave a dead frame and no sign anything was happening.
    test('the preview runs while preparing, and nothing is kept yet', () async {
      final rec = _FakeRecorder()..gate = Completer<void>();
      final c = _container(recorder: rec);
      addTearDown(c.dispose);
      final ctrl = c.read(vnoteRecordControllerProvider.notifier);

      final starting = ctrl.start();
      await pumpEventQueue();

      final s = c.read(vnoteRecordControllerProvider);
      expect(s.phase, VnoteRecordPhase.preparing);
      expect(s.isRecording, isFalse, reason: 'nothing is being kept yet');
      expect(s.isCapturing, isTrue, reason: 'but the composer IS busy');

      // The poll is already running, so the preview has a source.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(rec.framesServed, greaterThan(0));
      expect(ctrl.preview.value, isNotNull);

      rec.gate!.complete();
      await starting;
      expect(
        c.read(vnoteRecordControllerProvider).phase,
        VnoteRecordPhase.recording,
      );
    });

    test('a second start while preparing is a no-op', () async {
      final rec = _FakeRecorder()..gate = Completer<void>();
      final c = _container(recorder: rec);
      addTearDown(c.dispose);
      final ctrl = c.read(vnoteRecordControllerProvider.notifier);

      final first = ctrl.start();
      await pumpEventQueue();
      await ctrl.start(); // must not build a second recorder
      expect(
        c.read(vnoteRecordControllerProvider).phase,
        VnoteRecordPhase.preparing,
      );
      rec.gate!.complete();
      await first;
      expect(rec.disposed, isFalse);
    });

    test('letting go while preparing cancels instead of yielding a clip',
        () async {
      // Nothing has been recorded, so there is no note to hand back — but the
      // camera and recorder must not be left running either.
      final rec = _FakeRecorder()..gate = Completer<void>();
      final c = _container(recorder: rec);
      addTearDown(c.dispose);
      final ctrl = c.read(vnoteRecordControllerProvider.notifier);

      final starting = ctrl.start();
      await pumpEventQueue();
      expect(ctrl.stop(), isNull);
      expect(rec.disposed, isTrue, reason: 'the recorder must be torn down');
      expect(c.read(vnoteRecordControllerProvider).phase, VnoteRecordPhase.idle);

      rec.gate!.complete();
      await starting;
      expect(
        c.read(vnoteRecordControllerProvider).phase,
        VnoteRecordPhase.idle,
        reason: 'a cancelled start must not resurrect into recording',
      );
    });
  });
}
