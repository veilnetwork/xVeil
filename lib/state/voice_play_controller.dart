// Voice playback controller (voice epic, brick 5): plays a stored voice clip
// through the native veil_media player (Opus -> PCM -> ADM speaker). One player
// at a time across the whole app (starting a new clip stops the current one),
// so the bubble UI can show a single live progress + play/pause and cycle speed.
//
// The native player is behind a small [VoicePlayer] interface with an
// injectable factory, so widget tests drive the flow with a fake.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart';

import 'providers.dart';

/// Minimal player surface the controller drives (fakeable in tests).
abstract class VoicePlayer {
  bool start();
  void pause();
  void resume();
  void seekMs(int ms);
  void setSpeed(double speed);
  int get positionMs;
  int get durationMs;
  bool get isPlaying;
  void dispose();
}

class _NativeVoicePlayer implements VoicePlayer {
  _NativeVoicePlayer(this._p);
  final VeilAudioPlayer _p;

  static _NativeVoicePlayer? create(Uint8List bytes) {
    final p = VeilAudioPlayer.create(bytes);
    return p == null ? null : _NativeVoicePlayer(p);
  }

  @override
  bool start() => _p.start();
  @override
  void pause() => _p.pause();
  @override
  void resume() => _p.resume();
  @override
  void seekMs(int ms) => _p.seekMs(ms);
  @override
  void setSpeed(double speed) => _p.setSpeed(speed);
  @override
  int get positionMs => _p.positionMs;
  @override
  int get durationMs => _p.durationMs;
  @override
  bool get isPlaying => _p.isPlaying;
  @override
  void dispose() => _p.dispose();
}

/// Builds a player over the clip [bytes]; overridden in tests.
typedef VoicePlayerFactory = VoicePlayer? Function(Uint8List bytes);

final voicePlayerFactoryProvider = Provider<VoicePlayerFactory>(
  (ref) => _NativeVoicePlayer.create,
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
  }) =>
      VoicePlayState(
        playingId:
            identical(playingId, _unset) ? this.playingId : playingId as String?,
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

  static const Duration _pollEvery = Duration(milliseconds: 100);

  @override
  VoicePlayState build() {
    ref.onDispose(_teardown);
    return const VoicePlayState();
  }

  /// Tap on a clip's play control: start it (loading its bytes), toggle
  /// pause/resume if it's the active clip, or switch to a different clip.
  Future<void> toggle(String messageId, String fileKey) async {
    if (state.isActive(messageId)) {
      // Same clip: pause/resume.
      if (state.paused) {
        _player?.resume();
        state = state.copyWith(paused: false);
      } else {
        _player?.pause();
        state = state.copyWith(paused: true);
      }
      return;
    }
    // Different (or first) clip: tear down any current player, load + start.
    _stopPlayer();
    final bytes = await ref.read(storageProvider).loadFile(fileKey);
    if (bytes == null) return;
    final player = ref.read(voicePlayerFactoryProvider)(bytes);
    if (player == null || !player.start()) {
      player?.dispose();
      return;
    }
    player.setSpeed(_speed);
    _player = player;
    state = VoicePlayState(
      playingId: messageId,
      durationMs: player.durationMs,
      speed: _speed,
    );
    _poll = Timer.periodic(_pollEvery, (_) => _tick());
  }

  /// Cycle playback speed (1.0 → 1.5 → 2.0 → 1.0), applied live.
  void cycleSpeed() {
    final i = kVoiceSpeeds.indexOf(_speed);
    _speed = kVoiceSpeeds[(i + 1) % kVoiceSpeeds.length];
    _player?.setSpeed(_speed);
    state = state.copyWith(speed: _speed);
  }

  void _tick() {
    final p = _player;
    if (p == null) return;
    final pos = p.positionMs;
    final playing = p.isPlaying;
    state = state.copyWith(positionMs: pos);
    // Native reports not-playing at end-of-clip → reset to idle.
    if (!playing && !state.paused) {
      _stopPlayer();
      state = const VoicePlayState();
    }
  }

  void _stopPlayer() {
    _poll?.cancel();
    _poll = null;
    _player?.dispose();
    _player = null;
  }

  void _teardown() {
    _stopPlayer();
  }
}

final voicePlayControllerProvider =
    NotifierProvider<VoicePlayController, VoicePlayState>(
  VoicePlayController.new,
);
