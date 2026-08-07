// Voice playback controller (voice epic, brick 5): plays a stored voice clip
// by decoding the Opus natively to a RIFF/WAV in RAM (AVFoundation cannot
// decode Opus), serving it over the loopback LocalMediaServer and driving the
// platform player via video_player — the same canon-clean path in-chat video
// uses. Riding the host's real media session (instead of a standalone
// playout-only ADM, which the Flutter macOS host never pulls) makes playback
// work inside the app and gives exact seeking for free. One player at a time
// across the whole app (starting a new clip stops the current one), so the
// bubble UI can show a single live progress + play/pause and cycle speed.
//
// On Linux there is no video_player implementation at all, so the loopback
// path is dead there; playback instead uses libveil_media's OWN native player
// (the pre-loopback voice path, still shipped on every platform): Opus -> PCM
// in RAM -> the WebRTC default ADM (PulseAudio/ALSA, dlopen'd at runtime).
// Same canon (nothing plaintext on disk), same [VoicePlayer] surface.
//
// The player is behind a small [VoicePlayer] interface with an injectable
// factory, so widget tests drive the flow with a fake.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart';
import 'package:video_player/video_player.dart';

import '../domain/range_source.dart';
import 'media_stream_server.dart';
import 'providers.dart';

/// Minimal player surface the controller drives (fakeable in tests).
abstract class VoicePlayer {
  Future<bool> start();
  Future<void> pause();
  Future<void> resume();
  Future<void> seekMs(int ms);
  Future<void> setSpeed(double speed);
  Future<int> positionMs();
  int get durationMs;
  bool get isPlaying;
  Future<void> dispose();
}

/// The real player: native Opus->WAV decode, loopback serve, video_player.
class _WavVoicePlayer implements VoicePlayer {
  _WavVoicePlayer._(this._server, this._c);

  final LocalMediaServer _server;
  final VideoPlayerController _c;

  static Future<_WavVoicePlayer?> create(Uint8List voiceOpus) async {
    final wav = decodeVoiceWav(voiceOpus);
    if (wav == null) return null;
    final server = LocalMediaServer();
    try {
      // Already decoded in RAM and small (a voice message), so it is handed
      // over as an in-memory source rather than read from anywhere.
      final url = await server.serve(bytesRangeSource(wav), name: 'voice.wav');
      final c = VideoPlayerController.networkUrl(url);
      await c.initialize();
      return _WavVoicePlayer._(server, c);
    } catch (_) {
      await server.stop();
      return null;
    }
  }

  @override
  Future<bool> start() async {
    await _c.play();
    return true;
  }

  @override
  Future<void> pause() => _c.pause();
  @override
  Future<void> resume() => _c.play();
  @override
  Future<void> seekMs(int ms) => _c.seekTo(Duration(milliseconds: ms));
  @override
  Future<void> setSpeed(double speed) => _c.setPlaybackSpeed(speed);

  @override
  Future<int> positionMs() async =>
      (await _c.position ?? _c.value.position).inMilliseconds;

  @override
  int get durationMs => _c.value.duration.inMilliseconds;
  @override
  bool get isPlaying => _c.value.isPlaying;

  @override
  Future<void> dispose() async {
    await _c.dispose();
    await _server.stop();
  }
}

/// Native fallback for platforms without a video_player implementation
/// (Linux): play through libveil_media's own decoder + ADM speaker — the
/// clip is decoded to PCM in RAM and pulled by the platform audio thread,
/// so nothing plaintext touches disk and no OS media framework is needed.
class _NativeVoicePlayer implements VoicePlayer {
  _NativeVoicePlayer._(this._p);

  final VeilAudioPlayer _p;

  static Future<VoicePlayer?> create(Uint8List voiceOpus) async {
    final p = VeilAudioPlayer.create(voiceOpus);
    return p == null ? null : _NativeVoicePlayer._(p);
  }

  @override
  Future<bool> start() async => _p.start();
  @override
  Future<void> pause() async => _p.pause();
  @override
  Future<void> resume() async => _p.resume();
  @override
  Future<void> seekMs(int ms) async => _p.seekMs(ms);
  @override
  Future<void> setSpeed(double speed) async => _p.setSpeed(speed);
  @override
  Future<int> positionMs() async => _p.positionMs;
  @override
  int get durationMs => _p.durationMs;
  @override
  bool get isPlaying => _p.isPlaying;
  @override
  Future<void> dispose() async => _p.dispose();
}

/// Builds a player over the clip [bytes]; overridden in tests.
typedef VoicePlayerFactory = Future<VoicePlayer?> Function(Uint8List bytes);

final voicePlayerFactoryProvider = Provider<VoicePlayerFactory>(
  (ref) =>
      Platform.isLinux ? _NativeVoicePlayer.create : _WavVoicePlayer.create,
);

/// The available speeds, cycled by the bubble's speed chip.
const List<double> kVoiceSpeeds = [1.0, 1.5, 2.0];

class VoicePlayState {
  const VoicePlayState({
    this.playingId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.paused = false,
    this.speed = 1.0,
  });

  /// The message id of the clip currently loaded (playing or paused), or null.
  final String? playingId;
  final int positionMs;
  final int durationMs;
  final bool paused;
  final double speed;

  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  bool isActive(String id) => playingId == id;
  bool isPlaying(String id) => playingId == id && !paused;

  VoicePlayState copyWith({
    Object? playingId = _unset,
    int? positionMs,
    int? durationMs,
    bool? paused,
    double? speed,
  }) => VoicePlayState(
    playingId: identical(playingId, _unset)
        ? this.playingId
        : playingId as String?,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    paused: paused ?? this.paused,
    speed: speed ?? this.speed,
  );

  static const Object _unset = Object();
}

class VoicePlayController extends Notifier<VoicePlayState> {
  VoicePlayer? _player;
  Timer? _poll;
  double _speed = 1.0;
  int _gen = 0; // invalidates in-flight toggles when a newer one starts
  bool _ticking = false;

  static const Duration _pollEvery = Duration(milliseconds: 100);

  @override
  VoicePlayState build() {
    ref.onDispose(_teardown);
    return const VoicePlayState();
  }

  /// Tap on a clip's play control: start it (loading its bytes), toggle
  /// pause/resume if it's the active clip, or switch to a different clip.
  Future<void> toggle(String messageId, String fileKey) =>
      _toggle(messageId, () => ref.read(storageProvider).loadFile(fileKey));

  /// [toggle] for a clip whose bytes are already in hand — a group message's
  /// inline voice attachment has no file-store key to load from.
  Future<void> toggleBytes(String messageId, Uint8List bytes) =>
      _toggle(messageId, () async => bytes);

  Future<void> _toggle(
    String messageId,
    Future<Uint8List?> Function() load,
  ) async {
    if (state.isActive(messageId)) {
      // Same clip: pause/resume.
      if (state.paused) {
        await _player?.resume();
        state = state.copyWith(paused: false);
      } else {
        await _player?.pause();
        state = state.copyWith(paused: true);
      }
      return;
    }
    // Different (or first) clip: tear down any current player, load + start.
    _stopPlayer();
    final gen = ++_gen;
    final bytes = await load();
    if (bytes == null || gen != _gen) return;
    final player = await ref.read(voicePlayerFactoryProvider)(bytes);
    if (gen != _gen) {
      await player?.dispose();
      return;
    }
    if (player == null || !await player.start()) {
      await player?.dispose();
      return;
    }
    await player.setSpeed(_speed);
    _player = player;
    state = VoicePlayState(
      playingId: messageId,
      durationMs: player.durationMs,
      speed: _speed,
    );
    _poll = Timer.periodic(_pollEvery, (_) => _tick());
  }

  /// Seek the ACTIVE clip to [fraction] (0..1) of its duration — the bubble
  /// maps a waveform tap position to this. Ignored for inactive clips.
  Future<void> seekTo(String messageId, double fraction) async {
    final p = _player;
    if (p == null || !state.isActive(messageId)) return;
    final ms = (state.durationMs * fraction.clamp(0.0, 1.0)).round();
    await p.seekMs(ms);
    state = state.copyWith(positionMs: ms);
  }

  /// Seek within [messageId], loading and starting it first when it is not the
  /// clip currently in the player.
  ///
  /// [seekTo] alone refuses an inactive clip, which made the waveform look
  /// dead: touching a voice message you had not played yet did nothing at all,
  /// and the only way to reach a point in the middle was to start from the
  /// beginning and wait. Pointing at a moment is the way people ask to hear it.
  Future<void> seekOrStart(
    String messageId,
    String fileKey,
    double fraction,
  ) async {
    if (!state.isActive(messageId)) {
      await toggle(messageId, fileKey);
      // Load or decode can fail, and toggle reports that by leaving the clip
      // inactive; seeking a player that never started would be a no-op anyway.
      if (!state.isActive(messageId)) return;
    }
    await seekTo(messageId, fraction);
  }

  /// Cycle playback speed (1.0 → 1.5 → 2.0 → 1.0), applied live.
  void cycleSpeed() {
    final i = kVoiceSpeeds.indexOf(_speed);
    _speed = kVoiceSpeeds[(i + 1) % kVoiceSpeeds.length];
    unawaited(_player?.setSpeed(_speed));
    state = state.copyWith(speed: _speed);
  }

  Future<void> _tick() async {
    final p = _player;
    if (p == null || _ticking) return;
    _ticking = true;
    try {
      final pos = await p.positionMs();
      if (!identical(p, _player)) return; // player switched mid-await
      state = state.copyWith(positionMs: pos);
      // The platform player reports not-playing at end-of-clip → reset to idle.
      if (!p.isPlaying && !state.paused) {
        _stopPlayer();
        state = const VoicePlayState();
      }
    } finally {
      _ticking = false;
    }
  }

  void _stopPlayer() {
    _poll?.cancel();
    _poll = null;
    final p = _player;
    _player = null;
    if (p != null) unawaited(p.dispose());
  }

  void _teardown() {
    _gen++;
    _stopPlayer();
  }
}

final voicePlayControllerProvider =
    NotifierProvider<VoicePlayController, VoicePlayState>(
      VoicePlayController.new,
    );
