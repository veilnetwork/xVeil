import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vnote_play_controller.dart';
import 'package:xveil/state/voice_play_controller.dart'
    show VoicePlayer, voicePlayerFactoryProvider;

import 'support/fake_hv_container.dart';

class _FakeFrames implements VnoteFramePlayer {
  _FakeFrames({this.withAudio = true});
  final bool withAudio;
  bool disposed = false;
  int lastAskedMs = -1;

  @override
  int get durationMs => 2000;

  @override
  Uint8List? audio() =>
      withAudio ? Uint8List.fromList([0x56, 0x4F, 0x50, 0x31]) : null;

  @override
  VeilVideoFrame? frameAt(int ms) {
    lastAskedMs = ms;
    return VeilVideoFrame(rgba: Uint8List(4 * 4 * 4), width: 4, height: 4);
  }

  @override
  void dispose() => disposed = true;
}

class _FakeAudio implements VoicePlayer {
  bool started = false;
  bool disposed = false;
  bool paused = false;
  int pos = 0;
  bool playing = true;

  @override
  Future<bool> start() async {
    started = true;
    return true;
  }

  @override
  Future<void> pause() async {
    paused = true;
    playing = false;
  }

  @override
  Future<void> resume() async {
    paused = false;
    playing = true;
  }

  @override
  Future<void> seekMs(int ms) async => pos = ms;
  @override
  Future<void> setSpeed(double s) async {}
  @override
  Future<int> positionMs() async => pos;
  @override
  int get durationMs => 2000;
  @override
  bool get isPlaying => playing;
  @override
  Future<void> dispose() async => disposed = true;
}

Future<ProviderContainer> _container(
  _FakeFrames frames,
  _FakeAudio? audio,
) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  await storage.storeFile(
    'nkey',
    Uint8List.fromList([1, 2, 3]),
    name: 'n.vnote',
  );
  return ProviderContainer(
    overrides: [
      singleSpaceStorageProvider.overrideWithValue(storage),
      vnoteFramePlayerFactoryProvider.overrideWithValue((_) => frames),
      voicePlayerFactoryProvider.overrideWithValue((_) async => audio),
    ],
  );
}

void main() {
  test(
    'toggle starts audio-backed playback; frames follow the audio clock',
    () async {
      final frames = _FakeFrames();
      final audio = _FakeAudio();
      final c = await _container(frames, audio);
      addTearDown(c.dispose);
      final ctrl = c.read(vnotePlayControllerProvider.notifier);

      await ctrl.toggle('m1', 'nkey');
      expect(audio.started, isTrue);
      expect(c.read(vnotePlayControllerProvider).isPlaying('m1'), isTrue);
      expect(ctrl.frame.value, isNotNull, reason: 'frame 0 primes the circle');

      audio.pos = 640;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.read(vnotePlayControllerProvider).positionMs, 640);
      expect(
        frames.lastAskedMs,
        640,
        reason: 'frames pulled at audio position',
      );
    },
  );

  test(
    'toggle again pauses; end-of-audio resets to idle and disposes',
    () async {
      final frames = _FakeFrames();
      final audio = _FakeAudio();
      final c = await _container(frames, audio);
      addTearDown(c.dispose);
      final ctrl = c.read(vnotePlayControllerProvider.notifier);
      await ctrl.toggle('m1', 'nkey');

      await ctrl.toggle('m1', 'nkey');
      expect(audio.paused, isTrue);
      expect(c.read(vnotePlayControllerProvider).isPlaying('m1'), isFalse);
      await ctrl.toggle('m1', 'nkey');
      expect(audio.paused, isFalse);

      audio.playing = false; // end of clip
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.read(vnotePlayControllerProvider).playingId, isNull);
      expect(audio.disposed, isTrue);
      expect(frames.disposed, isTrue);
      expect(ctrl.frame.value, isNull);
    },
  );

  test(
    'a silent note plays on the stopwatch clock and ends at duration',
    () async {
      final frames = _FakeFrames(withAudio: false);
      final c = await _container(frames, null);
      addTearDown(c.dispose);
      final ctrl = c.read(vnotePlayControllerProvider.notifier);

      await ctrl.toggle('m1', 'nkey');
      expect(c.read(vnotePlayControllerProvider).isPlaying('m1'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.read(vnotePlayControllerProvider).positionMs, greaterThan(0));
      // Well past the 2000 ms duration → resets to idle.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(c.read(vnotePlayControllerProvider).playingId, isNull);
      expect(frames.disposed, isTrue);
    },
  );

  test('switching notes disposes the first pair', () async {
    final frames = _FakeFrames();
    final audio = _FakeAudio();
    final c = await _container(frames, audio);
    addTearDown(c.dispose);
    final ctrl = c.read(vnotePlayControllerProvider.notifier);
    await ctrl.toggle('m1', 'nkey');
    await ctrl.toggle('m2', 'nkey');
    expect(frames.disposed, isTrue);
    expect(audio.disposed, isTrue);
    expect(c.read(vnotePlayControllerProvider).isActive('m2'), isTrue);
  });

  test(
    'a lock stops the note and drops its frame (report17 XV17-M5)',
    () async {
      // The video half of the same defect: this is a global provider, so a lock
      // does not dispose it and a switch does not rebuild it. A round message
      // went on playing — picture and sound — over the lock screen.
      final frames = _FakeFrames();
      final audio = _FakeAudio();
      final c = await _container(frames, audio);
      addTearDown(c.dispose);
      final ctrl = c.read(vnotePlayControllerProvider.notifier);
      await ctrl.toggle('m1', 'nkey');
      expect(c.read(vnotePlayControllerProvider).isPlaying('m1'), isTrue);

      ctrl.stopForPrivacy();
      await Future<void>.delayed(Duration.zero);

      expect(audio.disposed, isTrue, reason: 'the note is still audible');
      expect(frames.disposed, isTrue, reason: 'the note is still on screen');
      expect(
        ctrl.frame.value,
        isNull,
        reason: 'the last frame of the note stayed in the circle',
      );
      expect(c.read(vnotePlayControllerProvider).playingId, isNull);
    },
  );
}
