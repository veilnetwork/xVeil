// Video-note playback controller (video-note epic, brick 5). One note plays
// at a time across the app (starting another stops the current).
//
// A/V model (matches the native pull design): the AUDIO section is a
// byte-compatible VOICE_OPUS block, so it plays through the EXISTING voice
// player (decode-to-WAV -> loopback -> platform player — exact position,
// pause for free, and fakeable via voicePlayerFactoryProvider). Video frames
// are pulled from the native VNOTE1 player at that audio position
// (frameAt(ms) decodes forward on demand). A silent note is driven by a
// Stopwatch instead. Frames go out through a ValueNotifier, NOT the Notifier
// state — 12 frames/s must not rebuild every watcher of the play state.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart';

import 'media_ffi.dart';
import 'providers.dart';
import 'voice_play_controller.dart' show VoicePlayer, voicePlayerFactoryProvider;

/// Minimal frame-source surface over the native VNOTE1 player (fakeable).
abstract class VnoteFramePlayer {
  int get durationMs;

  /// The embedded VOICE_OPUS block, or null for a silent note.
  Uint8List? audio();

  /// The frame at [ms] (RGBA), or null when nothing decoded yet.
  VeilVideoFrame? frameAt(int ms);
  void dispose();
}

class _NativeVnoteFramePlayer implements VnoteFramePlayer {
  _NativeVnoteFramePlayer(this._p);
  final VeilVnotePlayer _p;

  /// Null when the note cannot be decoded — including because this build has
  /// no engine at all, which the caller already renders as "nothing happens"
  /// rather than as a crash.
  static _NativeVnoteFramePlayer? create(Uint8List bytes) {
    if (!VeilMediaNative.available()) return null;
    final p = VeilMediaNative.guard(() => VeilVnotePlayer.create(bytes));
    return p == null ? null : _NativeVnoteFramePlayer(p);
  }

  @override
  int get durationMs => _p.durationMs;
  @override
  Uint8List? audio() => _p.audio();
  @override
  VeilVideoFrame? frameAt(int ms) => _p.frameAt(ms);
  @override
  void dispose() => _p.dispose();
}

/// Builds a frame player over the note bytes; overridden in tests.
typedef VnoteFramePlayerFactory = VnoteFramePlayer? Function(Uint8List bytes);

final vnoteFramePlayerFactoryProvider = Provider<VnoteFramePlayerFactory>(
  (ref) => _NativeVnoteFramePlayer.create,
);

class VnotePlayState {
  const VnotePlayState({
    this.playingId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.paused = false,
  });

  /// The message id of the note currently loaded (playing or paused), or null.
  final String? playingId;
  final int positionMs;
  final int durationMs;
  final bool paused;

  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  bool isActive(String id) => playingId == id;
  bool isPlaying(String id) => playingId == id && !paused;

  VnotePlayState copyWith({
    Object? playingId = _unset,
    int? positionMs,
    int? durationMs,
    bool? paused,
  }) =>
      VnotePlayState(
        playingId:
            identical(playingId, _unset) ? this.playingId : playingId as String?,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        paused: paused ?? this.paused,
      );

  static const Object _unset = Object();
}

class VnotePlayController extends Notifier<VnotePlayState> {
  VnoteFramePlayer? _frames;
  VoicePlayer? _audio; // null for a silent note
  Stopwatch? _silent; // drives position when there is no audio (pause = stop)
  Timer? _poll;
  int _gen = 0;
  bool _ticking = false;

  /// The current frame for the active note; the bubble repaints off this.
  final ValueNotifier<VeilVideoFrame?> frame = ValueNotifier(null);

  static const Duration _pollEvery = Duration(milliseconds: 80);

  @override
  VnotePlayState build() {
    ref.onDispose(_teardown);
    return const VnotePlayState();
  }

  /// Tap on a note: start it, pause/resume the active one, or switch notes.
  Future<void> toggle(String messageId, String fileKey) async {
    if (state.isActive(messageId)) {
      if (state.paused) {
        await _audio?.resume();
        _silent?.start();
        state = state.copyWith(paused: false);
      } else {
        await _audio?.pause();
        _silent?.stop();
        state = state.copyWith(paused: true);
      }
      return;
    }
    _stopPlayer();
    final gen = ++_gen;
    final bytes = await ref.read(storageProvider).loadFile(fileKey);
    if (bytes == null || gen != _gen) return;
    final frames = ref.read(vnoteFramePlayerFactoryProvider)(bytes);
    if (frames == null) return;
    if (gen != _gen) {
      frames.dispose();
      return;
    }
    VoicePlayer? audio;
    final audioBlock = frames.audio();
    if (audioBlock != null) {
      audio = await ref.read(voicePlayerFactoryProvider)(audioBlock);
      if (gen != _gen) {
        await audio?.dispose();
        frames.dispose();
        return;
      }
      if (audio == null || !await audio.start()) {
        await audio?.dispose();
        frames.dispose();
        return;
      }
    } else {
      _silent = Stopwatch()..start();
    }
    _frames = frames;
    _audio = audio;
    frame.value = frames.frameAt(0);
    state = VnotePlayState(
      playingId: messageId,
      durationMs: frames.durationMs,
    );
    _poll = Timer.periodic(_pollEvery, (_) => _tick());
  }

  Future<void> _tick() async {
    final frames = _frames;
    if (frames == null || _ticking) return;
    _ticking = true;
    try {
      final int pos;
      final bool stillPlaying;
      final audio = _audio;
      if (audio != null) {
        pos = await audio.positionMs();
        if (!identical(frames, _frames)) return; // switched mid-await
        stillPlaying = audio.isPlaying;
      } else {
        pos = _silent?.elapsedMilliseconds ?? 0;
        stillPlaying = pos < frames.durationMs;
      }
      final f = frames.frameAt(pos);
      if (f != null) frame.value = f;
      state = state.copyWith(positionMs: pos);
      if (!stillPlaying && !state.paused) {
        _stopPlayer();
        state = const VnotePlayState();
      }
    } finally {
      _ticking = false;
    }
  }

  void _stopPlayer() {
    _poll?.cancel();
    _poll = null;
    final a = _audio;
    _audio = null;
    if (a != null) unawaited(a.dispose());
    _frames?.dispose();
    _frames = null;
    _silent = null;
    frame.value = null;
  }

  void _teardown() {
    _gen++;
    _stopPlayer();
    frame.dispose();
  }
}

final vnotePlayControllerProvider =
    NotifierProvider<VnotePlayController, VnotePlayState>(
  VnotePlayController.new,
);
