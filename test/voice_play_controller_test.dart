import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/voice_play_controller.dart';

import 'support/fake_hv_container.dart';

class _FakePlayer implements VoicePlayer {
  _FakePlayer({this.startOk = true});
  final bool startOk;
  bool started = false;
  bool disposed = false;
  bool paused = false;
  double speed = 1.0;
  int _pos = 0;
  int _dur = 2000;
  bool _playing = true;

  void advance(int ms) => _pos += ms;
  void finish() {
    _playing = false;
    _pos = _dur;
  }

  @override
  bool start() {
    started = startOk;
    return startOk;
  }

  @override
  void pause() {
    paused = true;
    _playing = false;
  }

  @override
  void resume() {
    paused = false;
    _playing = true;
  }

  @override
  void seekMs(int ms) => _pos = ms;
  @override
  void setSpeed(double s) => speed = s;
  @override
  int get positionMs => _pos;
  @override
  int get durationMs => _dur;
  @override
  bool get isPlaying => _playing;
  @override
  void dispose() => disposed = true;
}

Future<ProviderContainer> _container(_FakePlayer? player) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  // A voice blob under a known key so loadFile returns bytes.
  await storage.storeFile('vkey', Uint8List.fromList([1, 2, 3]), name: 'v.opus');
  return ProviderContainer(overrides: [
    singleSpaceStorageProvider.overrideWithValue(storage),
    voicePlayerFactoryProvider.overrideWithValue((_) => player),
  ]);
}

void main() {
  test('toggle starts a clip, sets duration + speed, tracks it', () async {
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);

    await ctrl.toggle('m1', 'vkey');
    final s = c.read(voicePlayControllerProvider);
    expect(p.started, isTrue);
    expect(s.isActive('m1'), isTrue);
    expect(s.isPlaying('m1'), isTrue);
    expect(s.durationMs, 2000);
  });

  test('toggle again pauses, once more resumes', () async {
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);
    await ctrl.toggle('m1', 'vkey');

    await ctrl.toggle('m1', 'vkey');
    expect(p.paused, isTrue);
    expect(c.read(voicePlayControllerProvider).isPlaying('m1'), isFalse);

    await ctrl.toggle('m1', 'vkey');
    expect(p.paused, isFalse);
    expect(c.read(voicePlayControllerProvider).isPlaying('m1'), isTrue);
  });

  test('switching to another clip disposes the first player', () async {
    final p1 = _FakePlayer();
    final c = await _container(p1);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);
    await ctrl.toggle('m1', 'vkey');
    // Second clip reuses the same factory-provided fake would return p1; make
    // the factory hand a fresh fake by re-overriding is awkward — instead
    // verify the FIRST is disposed when a different id starts.
    await ctrl.toggle('m2', 'vkey');
    expect(p1.disposed, isTrue);
  });

  test('cycleSpeed walks 1x -> 1.5x -> 2x -> 1x and applies live', () async {
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);
    await ctrl.toggle('m1', 'vkey');
    expect(c.read(voicePlayControllerProvider).speed, 1.0);
    ctrl.cycleSpeed();
    expect(c.read(voicePlayControllerProvider).speed, 1.5);
    expect(p.speed, 1.5);
    ctrl.cycleSpeed();
    expect(c.read(voicePlayControllerProvider).speed, 2.0);
    ctrl.cycleSpeed();
    expect(c.read(voicePlayControllerProvider).speed, 1.0);
  });

  test('start failure leaves idle + disposes', () async {
    final p = _FakePlayer(startOk: false);
    final c = await _container(p);
    addTearDown(c.dispose);
    await c.read(voicePlayControllerProvider.notifier).toggle('m1', 'vkey');
    expect(c.read(voicePlayControllerProvider).playingId, isNull);
    expect(p.disposed, isTrue);
  });

  test('progress fraction is position/duration clamped', () {
    const s = VoicePlayState(playingId: 'm', positionMs: 500, durationMs: 2000);
    expect(s.progress, 0.25);
    const over = VoicePlayState(playingId: 'm', positionMs: 5000, durationMs: 2000);
    expect(over.progress, 1.0);
  });
}
