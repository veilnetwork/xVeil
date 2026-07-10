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

  @override
  bool start() {
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
}
