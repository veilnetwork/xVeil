import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/voice_record_controller.dart';

/// A fake recorder: no native lib, deterministic clip + level.
class _FakeRecorder implements VoiceRecorder {
  _FakeRecorder({this.startOk = true, this.emptyClip = false});
  final bool startOk;
  final bool emptyClip;
  bool started = false;
  bool disposed = false;
  int _elapsed = 0;

  @override
  bool start() {
    started = startOk;
    return startOk;
  }

  @override
  double get level => started ? 0.42 : 0;

  @override
  int get elapsedMs => _elapsed;
  set elapsedMs(int v) => _elapsed = v;

  @override
  VoiceClip? stop({int waveformBars = 48}) {
    if (emptyClip) return null;
    return VoiceClip(
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      durationMs: _elapsed == 0 ? 1500 : _elapsed,
      waveform: List<double>.filled(waveformBars, 0.5),
    );
  }

  @override
  void dispose() => disposed = true;
}

ProviderContainer _container({
  required VoiceRecorder? recorder,
  bool micGranted = true,
}) {
  return ProviderContainer(
    overrides: [
      voiceRecorderFactoryProvider.overrideWithValue(() => recorder),
      micPermissionProvider.overrideWithValue(() async => micGranted),
    ],
  );
}

/// The permission prompt is an AWAIT, and it is the window a lock lands in:
/// the person taps record, the prompt goes up, they lock the app, and the
/// answer arrives afterwards.
ProviderContainer _promptParkedContainer({
  required VoiceRecorder recorder,
  required Completer<bool> prompt,
}) {
  return ProviderContainer(
    overrides: [
      voiceRecorderFactoryProvider.overrideWithValue(() => recorder),
      micPermissionProvider.overrideWithValue(() => prompt.future),
    ],
  );
}

void main() {
  test('start -> recording; stop returns the clip and disposes', () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(voiceRecordControllerProvider.notifier);

    expect(c.read(voiceRecordControllerProvider).phase, VoiceRecordPhase.idle);
    await ctrl.start();
    expect(c.read(voiceRecordControllerProvider).isRecording, isTrue);
    expect(rec.started, isTrue);

    final clip = ctrl.stop();
    expect(clip, isNotNull);
    expect(clip!.bytes, [1, 2, 3, 4]);
    expect(clip.durationMs, 1500);
    expect(clip.waveform.length, 48);
    expect(rec.disposed, isTrue);
    expect(c.read(voiceRecordControllerProvider).phase, VoiceRecordPhase.idle);
  });

  test('denied mic -> denied phase, no recorder built', () async {
    var built = false;
    final c = ProviderContainer(
      overrides: [
        voiceRecorderFactoryProvider.overrideWithValue(() {
          built = true;
          return _FakeRecorder();
        }),
        micPermissionProvider.overrideWithValue(() async => false),
      ],
    );
    addTearDown(c.dispose);
    await c.read(voiceRecordControllerProvider.notifier).start();
    expect(
      c.read(voiceRecordControllerProvider).phase,
      VoiceRecordPhase.denied,
    );
    expect(built, isFalse);
  });

  test('recorder that fails to start -> error phase, disposed', () async {
    final rec = _FakeRecorder(startOk: false);
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    await c.read(voiceRecordControllerProvider.notifier).start();
    expect(c.read(voiceRecordControllerProvider).phase, VoiceRecordPhase.error);
    expect(rec.disposed, isTrue);
  });

  test('null factory (no native lib) -> error phase', () async {
    final c = _container(recorder: null);
    addTearDown(c.dispose);
    await c.read(voiceRecordControllerProvider.notifier).start();
    expect(c.read(voiceRecordControllerProvider).phase, VoiceRecordPhase.error);
  });

  test('cancel discards without returning a clip', () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(voiceRecordControllerProvider.notifier);
    await ctrl.start();
    ctrl.cancel();
    expect(c.read(voiceRecordControllerProvider).phase, VoiceRecordPhase.idle);
    expect(rec.disposed, isTrue);
    expect(ctrl.stop(), isNull); // not recording anymore
  });

  test('empty clip (silence) returns null from stop', () async {
    final rec = _FakeRecorder(emptyClip: true);
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(voiceRecordControllerProvider.notifier);
    await ctrl.start();
    expect(ctrl.stop(), isNull);
    expect(rec.disposed, isTrue);
  });

  test('the poll timer is cancelled on stop (no pending timers)', () async {
    final rec = _FakeRecorder();
    final c = _container(recorder: rec);
    addTearDown(c.dispose);
    final ctrl = c.read(voiceRecordControllerProvider.notifier);
    await ctrl.start();
    ctrl.stop();
    // If the periodic poll leaked, the test framework flags a pending timer.
  });

  group('a lock or a switch stops capture (report17 XV17-M5)', () {
    // This controller is a GLOBAL provider: a lock does not dispose it and an
    // identity switch does not rebuild it. So the microphone kept capturing
    // behind the lock screen — and a start still waiting on the permission
    // prompt opened the microphone AFTERWARDS.

    test('a recording in progress is stopped and discarded', () async {
      final rec = _FakeRecorder();
      final c = _container(recorder: rec);
      addTearDown(c.dispose);
      final ctrl = c.read(voiceRecordControllerProvider.notifier);
      await ctrl.start();
      expect(c.read(voiceRecordControllerProvider).isRecording, isTrue);

      ctrl.stopForPrivacy();

      expect(rec.disposed, isTrue, reason: 'the microphone is still open');
      expect(c.read(voiceRecordControllerProvider).isRecording, isFalse);
      expect(
        ctrl.takeAutoStopped(),
        isNull,
        reason: 'audio captured under the previous identity survived the lock',
      );
    });

    test('and a start waiting on the prompt never opens the mic', () async {
      final rec = _FakeRecorder();
      final prompt = Completer<bool>();
      final c = _promptParkedContainer(recorder: rec, prompt: prompt);
      addTearDown(c.dispose);
      final ctrl = c.read(voiceRecordControllerProvider.notifier);

      final pending = ctrl.start();
      ctrl.stopForPrivacy();
      prompt.complete(true);
      await pending;

      expect(
        rec.started,
        isFalse,
        reason: 'the microphone opened after the person locked the app',
      );
      expect(c.read(voiceRecordControllerProvider).isRecording, isFalse);
    });

    test('CONTROL: without the lock the same start records', () async {
      // Vacuity guard: a prompt that never grants would satisfy the above.
      final rec = _FakeRecorder();
      final prompt = Completer<bool>();
      final c = _promptParkedContainer(recorder: rec, prompt: prompt);
      addTearDown(c.dispose);
      final ctrl = c.read(voiceRecordControllerProvider.notifier);

      final pending = ctrl.start();
      prompt.complete(true);
      await pending;

      expect(rec.started, isTrue);
      expect(c.read(voiceRecordControllerProvider).isRecording, isTrue);
    });
  });
}
