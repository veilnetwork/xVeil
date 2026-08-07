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
  final int _dur = 2000;
  bool _playing = true;

  void advance(int ms) => _pos += ms;
  void finish() {
    _playing = false;
    _pos = _dur;
  }

  @override
  Future<bool> start() async {
    started = startOk;
    return startOk;
  }

  @override
  Future<void> pause() async {
    paused = true;
    _playing = false;
  }

  @override
  Future<void> resume() async {
    paused = false;
    _playing = true;
  }

  @override
  Future<void> seekMs(int ms) async => _pos = ms;
  @override
  Future<void> setSpeed(double s) async => speed = s;
  @override
  Future<int> positionMs() async => _pos;
  @override
  int get durationMs => _dur;
  @override
  bool get isPlaying => _playing;
  @override
  Future<void> dispose() async => disposed = true;
}

Future<ProviderContainer> _container(_FakePlayer? player) async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  // A voice blob under a known key so loadFile returns bytes.
  await storage.storeFile(
    'vkey',
    Uint8List.fromList([1, 2, 3]),
    name: 'v.opus',
  );
  return ProviderContainer(
    overrides: [
      singleSpaceStorageProvider.overrideWithValue(storage),
      voicePlayerFactoryProvider.overrideWithValue((_) async => player),
    ],
  );
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

  test('seekTo maps a fraction to ms on the active clip only', () async {
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);
    await ctrl.toggle('m1', 'vkey');

    await ctrl.seekTo('m1', 0.5);
    expect(await p.positionMs(), 1000);
    expect(c.read(voicePlayControllerProvider).positionMs, 1000);

    // Fraction is clamped and other clips are ignored.
    await ctrl.seekTo('m1', 1.5);
    expect(await p.positionMs(), 2000);
    await ctrl.seekTo('other', 0.25);
    expect(await p.positionMs(), 2000);
  });

  test(
    'toggleBytes plays in-hand bytes (group inline clip, no file key)',
    () async {
      final p = _FakePlayer();
      final c = await _container(p);
      addTearDown(c.dispose);
      final ctrl = c.read(voicePlayControllerProvider.notifier);

      await ctrl.toggleBytes('a:0', Uint8List.fromList([9, 9, 9]));
      expect(p.started, isTrue);
      expect(c.read(voicePlayControllerProvider).isActive('a:0'), isTrue);
      expect(c.read(voicePlayControllerProvider).durationMs, 2000);

      // Same clip id: pause / resume, exactly like the file-key path.
      await ctrl.toggleBytes('a:0', Uint8List.fromList([9, 9, 9]));
      expect(c.read(voicePlayControllerProvider).isPlaying('a:0'), isFalse);
      await ctrl.toggleBytes('a:0', Uint8List.fromList([9, 9, 9]));
      expect(c.read(voicePlayControllerProvider).isPlaying('a:0'), isTrue);
    },
  );

  test('progress fraction is position/duration clamped', () {
    const s = VoicePlayState(playingId: 'm', positionMs: 500, durationMs: 2000);
    expect(s.progress, 0.25);
    const over = VoicePlayState(
      playingId: 'm',
      positionMs: 5000,
      durationMs: 2000,
    );
    expect(over.progress, 1.0);
  });

  test('touching the bar of a clip that is not playing yet starts it AT that '
      'point rather than doing nothing', () async {
    // seekTo alone refuses an inactive clip, which is what made the waveform
    // look dead: the only way to reach the middle of a voice message was to
    // play it from the start and wait.
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);

    expect(c.read(voicePlayControllerProvider).isActive('m1'), isFalse);
    await ctrl.seekOrStart('m1', 'vkey', 0.5);

    final s = c.read(voicePlayControllerProvider);
    expect(s.isActive('m1'), isTrue, reason: 'it must start playing');
    expect(s.positionMs, 1000, reason: 'and start at the point touched');
    expect(await p.positionMs(), 1000, reason: 'the player really sought');
  });

  test('scrubbing an already-playing clip does not restart it', () async {
    // A drag sends many samples. The first may have to start the clip; the
    // rest must be plain seeks, or every drag pixel would stack another load.
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);

    await ctrl.toggle('m1', 'vkey');
    final firstPlayer = p.started;
    await ctrl.seekOrStart('m1', 'vkey', 0.25);
    await ctrl.seekTo('m1', 0.75);

    final s = c.read(voicePlayControllerProvider);
    expect(s.isActive('m1'), isTrue);
    expect(
      s.paused,
      isFalse,
      reason: 'seeking must not pause, as toggle would',
    );
    expect(s.positionMs, 1500);
    expect(p.disposed, isFalse, reason: 'the running player was reused');
    expect(firstPlayer, isTrue);
  });

  test('a fraction outside the clip is clamped, not thrown', () async {
    final p = _FakePlayer();
    final c = await _container(p);
    addTearDown(c.dispose);
    final ctrl = c.read(voicePlayControllerProvider.notifier);

    await ctrl.toggle('m1', 'vkey');
    await ctrl.seekTo('m1', 1.4);
    expect(c.read(voicePlayControllerProvider).positionMs, 2000);
    await ctrl.seekTo('m1', -0.3);
    expect(c.read(voicePlayControllerProvider).positionMs, 0);
  });
}
