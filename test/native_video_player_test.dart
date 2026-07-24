// NativeVideoPlayer (the Linux full-size video controller): fakes stand in
// for the two native bricks exactly like the vnote-controller tests — the
// frame factory records every VNOTE1 window it is handed (so the windowing
// and seek-rebuild policy is asserted on real container bytes), the audio
// fake drives the clock.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;
import 'package:xveil/state/native_video_player.dart';
import 'package:xveil/state/vnote_play_controller.dart';
import 'package:xveil/state/voice_play_controller.dart';

import 'support/webm_test_builder.dart';

int _u32(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

/// Introspectable fake over one VNOTE1 window the factory was handed.
class _FakeWindow implements VnoteFramePlayer {
  _FakeWindow(this.container);
  final Uint8List container;
  final List<int> frameAtMs = [];
  bool disposed = false;

  int get frameCount => _u32(container, 20);
  int get firstTsMs => _u32(container, 24);
  bool get opensOnKey => container[28] == 1;

  @override
  int get durationMs => _u32(container, 12);

  @override
  Uint8List? audio() => null;

  @override
  VeilVideoFrame? frameAt(int ms) {
    frameAtMs.add(ms);
    return VeilVideoFrame(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);
  }

  @override
  void dispose() => disposed = true;
}

class _FakeFactory {
  final windows = <_FakeWindow>[];
  VnoteFramePlayer? call(Uint8List bytes) {
    final w = _FakeWindow(bytes);
    windows.add(w);
    return w;
  }
}

class _FakeAudio implements VoicePlayer {
  _FakeAudio({this.startOk = true, this.durMs = 2000});
  final bool startOk;
  final int durMs;
  bool started = false;
  bool disposed = false;
  bool playing = false;
  bool pausedFlag = false;
  int pos = 0;

  @override
  Future<bool> start() async {
    started = startOk;
    playing = startOk;
    return startOk;
  }

  @override
  Future<void> pause() async {
    pausedFlag = true;
    playing = false;
  }

  @override
  Future<void> resume() async {
    pausedFlag = false;
    playing = true;
  }

  @override
  Future<void> seekMs(int ms) async {
    pos = ms;
    if (ms < durMs) playing = !pausedFlag;
  }

  @override
  Future<void> setSpeed(double s) async {}

  @override
  Future<int> positionMs() async => pos;

  @override
  int get durationMs => durMs;

  @override
  bool get isPlaying => playing;

  @override
  Future<void> dispose() async => disposed = true;
}

Future<VoicePlayer?> _noAudio(Uint8List bytes) async =>
    fail('audio factory must not be called for a silent clip');

void main() {
  // 24 frames @ 25 fps (40 ms), keyframe every 6 → 4 GOPs of 6×(9+40) B.
  Uint8List clip({bool withAudio = false}) => buildStandardWebm(
    frameCount: 24,
    fps: 25,
    keyEvery: 6,
    frameBytes: 40,
    withAudio: withAudio,
  );

  test('open primes frame 0 and reports geometry + duration', () async {
    final ff = _FakeFactory();
    final p = (await NativeVideoPlayer.open(
      clip(),
      frameFactory: ff.call,
      audioFactory: _noAudio,
    ))!;
    addTearDown(p.dispose);
    expect(p.durationMs, 960);
    expect(p.hasVideo, isTrue);
    expect(p.aspectRatio, closeTo(64 / 48, 1e-9));
    expect(p.frame.value, isNotNull, reason: 'opening frame primed');
    expect(ff.windows, hasLength(1));
    expect(ff.windows.single.frameCount, 24, reason: 'clip fits one window');
    expect(ff.windows.single.opensOnKey, isTrue);
    expect(p.isPlaying, isFalse, reason: 'open does not autoplay');
  });

  test('unsupported bytes give null', () async {
    final ff = _FakeFactory();
    expect(
      await NativeVideoPlayer.open(
        Uint8List.fromList(List.filled(100, 7)),
        frameFactory: ff.call,
        audioFactory: _noAudio,
      ),
      isNull,
    );
    expect(ff.windows, isEmpty);
  });

  test('audio-backed playback pulls frames at the audio position', () async {
    final ff = _FakeFactory();
    final audio = _FakeAudio(durMs: 960);
    final p = (await NativeVideoPlayer.open(
      clip(withAudio: true),
      frameFactory: ff.call,
      audioFactory: (_) async => audio,
    ))!;
    addTearDown(p.dispose);
    await p.play();
    expect(audio.started, isTrue);
    expect(p.isPlaying, isTrue);

    audio.pos = 400;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(p.positionMs, 400);
    expect(ff.windows.single.frameAtMs, contains(400));

    await p.pause();
    expect(audio.pausedFlag, isTrue);
    expect(p.isPlaying, isFalse);
    await p.play();
    expect(audio.pausedFlag, isFalse);
    expect(p.isPlaying, isTrue);
  });

  test('failed audio start degrades to the silent clock (headless box)',
      () async {
    final ff = _FakeFactory();
    final audio = _FakeAudio(startOk: false);
    final p = (await NativeVideoPlayer.open(
      clip(withAudio: true),
      frameFactory: ff.call,
      audioFactory: (_) async => audio,
    ))!;
    addTearDown(p.dispose);
    await p.play();
    expect(audio.disposed, isTrue, reason: 'dead audio leg dropped');
    expect(p.isPlaying, isTrue, reason: 'video still plays');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(p.positionMs, greaterThan(0), reason: 'stopwatch clock running');
  });

  test('end of audio finishes playback; replay restarts from zero', () async {
    final ff = _FakeFactory();
    final audio = _FakeAudio(durMs: 960);
    final p = (await NativeVideoPlayer.open(
      clip(withAudio: true),
      frameFactory: ff.call,
      audioFactory: (_) async => audio,
    ))!;
    addTearDown(p.dispose);
    await p.play();
    audio.pos = 960;
    audio.playing = false;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(p.ended, isTrue);
    expect(p.isPlaying, isFalse);
    expect(p.positionMs, 960);

    await p.togglePlay(); // replay
    expect(p.ended, isFalse);
    expect(audio.pos, 0, reason: 'audio seeked back to the top');
    expect(p.isPlaying, isTrue);
  });

  test('a small window budget splits the clip; playback advances windows',
      () async {
    final ff = _FakeFactory();
    // One GOP = 6 × (9 + 40) = 294 B → budget for exactly two GOPs.
    final p = (await NativeVideoPlayer.open(
      clip(),
      frameFactory: ff.call,
      audioFactory: _noAudio,
      windowBudgetBytes: 600,
    ))!;
    addTearDown(p.dispose);
    expect(ff.windows, hasLength(1));
    expect(ff.windows[0].frameCount, 12, reason: 'two whole GOPs fit');
    expect(ff.windows[0].firstTsMs, 0);

    await p.play();
    await p.seekMs(500); // frame 12 territory: beyond the first window
    expect(ff.windows, hasLength(2), reason: 'crossing the edge swaps windows');
    expect(ff.windows[0].disposed, isTrue);
    expect(ff.windows[1].firstTsMs, 480, reason: 'new window opens at key 12');
    expect(ff.windows[1].opensOnKey, isTrue);
    expect(ff.windows[1].frameAtMs, contains(500));
  });

  test('a short forward hop stays in-window; far hop rebuilds at the keyframe',
      () async {
    final ff = _FakeFactory();
    final p = (await NativeVideoPlayer.open(
      clip(),
      frameFactory: ff.call,
      audioFactory: _noAudio,
    ))!;
    addTearDown(p.dispose);
    expect(ff.windows, hasLength(1));

    await p.seekMs(80); // 2 frames ahead: native walk, same window
    expect(ff.windows, hasLength(1));
    expect(ff.windows.single.frameAtMs, contains(80));

    // Backward inside the window: the native keyframe rewind path, no swap.
    await p.seekMs(0);
    expect(ff.windows, hasLength(1));
  });

  test('a silent clip plays on the stopwatch and ends at duration', () async {
    final ff = _FakeFactory();
    final p = (await NativeVideoPlayer.open(
      buildStandardWebm(frameCount: 6, fps: 25, keyEvery: 3),
      frameFactory: ff.call,
      audioFactory: _noAudio,
    ))!;
    addTearDown(p.dispose);
    expect(p.durationMs, 240);
    await p.play();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(p.positionMs, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(p.ended, isTrue);
    expect(p.isPlaying, isFalse);
  });

  test('dispose tears down the window, the audio leg and the frame notifier',
      () async {
    final ff = _FakeFactory();
    final audio = _FakeAudio(durMs: 960);
    final p = (await NativeVideoPlayer.open(
      clip(withAudio: true),
      frameFactory: ff.call,
      audioFactory: (_) async => audio,
    ))!;
    await p.play();
    p.dispose();
    expect(ff.windows.single.disposed, isTrue);
    expect(audio.disposed, isTrue);
  });
}
