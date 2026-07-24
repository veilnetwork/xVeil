// Full-size video playback over the native ABI (media epic: the Linux player).
//
// Linux deliberately ships NO OS media stack (media_kit/libmpv rejected) — but
// the deployed libveil_media.so already plays VNOTE1 video (VP8, pull-decoded
// by position, keyframe rewind) and VOICE_OPUS audio (Opus → PCM → the WebRTC
// default ADM: PulseAudio/ALSA). This controller turns those two bricks into a
// full-size attachment player, reusing the exact video-note A/V model:
//
//   WebM bytes ──demux (pure Dart)──► VP8 frames + Opus packets
//     frames  → windowed VNOTE1 containers → VnoteFramePlayer.frameAt(ms)
//     packets → one VOICE_OPUS block      → VoicePlayer (the audio CLOCK)
//
// Frames are pulled at the audio position so A/V can never drift; a silent (or
// audio-dead: headless machines have no playout device) file runs on a
// stopwatch clock instead.
//
// RAM model — the part that makes long videos work:
//  * Nothing is ever fully decoded: the native player holds ONE decoded frame;
//    Dart holds the compressed source (exactly like the loopback server does
//    on the other platforms) plus one RGBA copy of the current frame.
//  * The native player COPIES whatever container it is given, so it is fed a
//    WINDOW of whole GOPs (~64 MB), not the entire film; playback crossing the
//    window edge (or a far seek) swaps in a new window starting at a keyframe.
//  * Seeks map to the cheap native path: backward = the player's own keyframe
//    rewind; far forward = a fresh window at the target's keyframe (the native
//    forward walk decodes EVERY skipped frame on the UI isolate — that walk is
//    kept under ~one GOP by construction).
//
// The screen owns one controller per open video (unlike the app-global
// voice/vnote singletons) and injects the two factories from the existing
// providers, so tests drive this with the same fakes the vnote tests use.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:veil_media/veil_media.dart' show VeilVideoFrame;

import '../domain/webm_media.dart';
import 'vnote_play_controller.dart'
    show VnoteFramePlayer, VnoteFramePlayerFactory;
import 'voice_play_controller.dart' show VoicePlayer, VoicePlayerFactory;

/// Compressed budget of one native frame window (whole GOPs). The native
/// player copies its container, so this caps native RAM regardless of the
/// video's size; a window swap is a bounded memcpy, not a decode.
const int kNativeVideoWindowBytes = 64 << 20;

/// A forward seek that would walk-decode more than this many frames inside
/// the current window is done by swapping to a fresh window at the target's
/// keyframe instead (the walk runs on the UI isolate — keep it ~one GOP).
const int kNativeVideoForwardWalkFrames = 90;

/// Full-size video player over the native VNOTE1 + VOICE_OPUS bricks.
///
/// Lifecycle: [open] → [play]/[pause]/[seekMs] → [dispose]. Position, playing
/// and ended state notify listeners; decoded frames go out through [frame]
/// (a ValueNotifier, NOT notifyListeners — 20 frames/s must not rebuild every
/// listener of the transport state).
class NativeVideoPlayer extends ChangeNotifier {
  NativeVideoPlayer._(
    this._x,
    this._frameFactory,
    this._audio,
    this._durationMs,
  ) : _clockIsAudio = _audio != null;

  final WebmExtract _x;
  final VnoteFramePlayerFactory _frameFactory;
  VoicePlayer? _audio;
  final int _durationMs;

  VnoteFramePlayer? _frames;
  int _windowStart = 0; // global frame index of the active window
  int _windowEnd = 0; // exclusive; always a keyframe index (or EOF)
  int _windowBudget = kNativeVideoWindowBytes;
  List<int> _keyIndexes = const [];

  bool _clockIsAudio;
  bool _audioStarted = false;
  final Stopwatch _silent = Stopwatch();
  int _silentBaseMs = 0;

  Timer? _poll;
  bool _ticking = false;
  bool _paused = true;
  bool _ended = false;
  bool _disposed = false;
  int _positionMs = 0;
  int _lastFramePollMs = -1;

  /// The current decoded frame; the video surface repaints off this.
  final ValueNotifier<VeilVideoFrame?> frame = ValueNotifier(null);

  static const Duration _pollEvery = Duration(milliseconds: 50);
  static const int _endSlackMs = 900;

  /// Demuxes [bytes] and builds the native pair. Null when the container is
  /// not WebM or carries neither VP8 video nor Opus audio — the caller shows
  /// the honest "unsupported format" state. [windowBudgetBytes] is test-only.
  static Future<NativeVideoPlayer?> open(
    Uint8List bytes, {
    required VnoteFramePlayerFactory frameFactory,
    required VoicePlayerFactory audioFactory,
    int windowBudgetBytes = kNativeVideoWindowBytes,
  }) async {
    final x = demuxWebm(bytes);
    if (x == null) return null;

    VoicePlayer? audio;
    if (x.hasAudio) {
      final vop1 = buildVoiceOpus(x);
      if (vop1 != null) audio = await audioFactory(vop1);
    }

    // The native audio player decoded the real PCM — its duration is exact
    // where the container's Duration header may be missing or rounded.
    final durationMs = [
      x.durationMs,
      audio?.durationMs ?? 0,
    ].reduce((a, b) => a > b ? a : b);

    final p = NativeVideoPlayer._(x, frameFactory, audio, durationMs);
    p._windowBudget = windowBudgetBytes;
    if (x.hasVideo) {
      p._keyIndexes = [
        for (var i = 0; i < x.videoFrames.length; i++)
          if (x.videoFrames[i].key) i,
      ];
      p._rebuildWindow(0);
    }
    if (p._frames == null && audio == null) {
      p.dispose();
      return null;
    }
    // Prime the opening frame so the screen shows the video immediately.
    final f = p._frames?.frameAt(0);
    if (f != null) {
      p.frame.value = f;
      p._lastFramePollMs = 0;
    }
    return p;
  }

  int get positionMs => _positionMs;
  int get durationMs => _durationMs;
  bool get isPlaying => !_paused && !_ended;
  bool get ended => _ended;
  bool get hasVideo => _x.hasVideo;

  /// Source aspect ratio, or 0 when unknown (caller picks a fallback).
  double get aspectRatio =>
      _x.width > 0 && _x.height > 0 ? _x.width / _x.height : 0;

  /// Start or resume playback (from the top when [ended]).
  Future<void> play() async {
    if (_disposed) return;
    if (_ended) await seekMs(0);
    _paused = false;
    _ended = false;
    final audio = _audio;
    if (_clockIsAudio && audio != null) {
      if (!_audioStarted) {
        _audioStarted = await audio.start();
        if (_disposed) return;
        if (!_audioStarted) {
          // No playout device (headless box, dead PulseAudio): the video is
          // still watchable — drop the audio leg and run the silent clock.
          _audio = null;
          unawaited(audio.dispose());
          _clockIsAudio = false;
        }
      } else {
        await audio.resume();
        if (_disposed) return;
      }
    }
    if (!_clockIsAudio) _startSilentFrom(_positionMs);
    _poll ??= Timer.periodic(_pollEvery, (_) => _tick());
    notifyListeners();
  }

  Future<void> pause() async {
    if (_disposed || _paused) return;
    _paused = true;
    _silent.stop();
    await _audio?.pause();
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> togglePlay() => isPlaying ? pause() : play();

  /// Jump to [ms] (clamped). Cheap by construction: backward uses the native
  /// keyframe rewind, far forward swaps the window at the target's keyframe.
  Future<void> seekMs(int ms) async {
    if (_disposed) return;
    final target = ms.clamp(0, _durationMs);
    _positionMs = target;
    if (target < _durationMs) _ended = false;
    final audio = _audio;
    if (audio != null) {
      await audio.seekMs(target);
      if (_disposed) return;
      // Seeking back inside the audio track restores the audio clock after an
      // early audio end switched to the stopwatch.
      final audioDur = audio.durationMs;
      _clockIsAudio = audioDur <= 0 || target < audioDur;
      // A pause taken during the silent tail left the audio sink paused;
      // returning to the audio clock mid-playback must unfreeze it.
      if (_clockIsAudio && !_paused && _audioStarted) {
        await audio.resume();
        if (_disposed) return;
      }
    }
    if (!_clockIsAudio) _startSilentFrom(target);
    _retargetFrames(target);
    notifyListeners();
  }

  Future<void> seekFraction(double fraction) =>
      seekMs((_durationMs * fraction.clamp(0.0, 1.0)).round());

  void _startSilentFrom(int ms) {
    _silentBaseMs = ms;
    _silent
      ..reset()
      ..stop();
    if (!_paused) _silent.start();
  }

  Future<void> _tick() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    try {
      int pos;
      final audio = _audio;
      if (_clockIsAudio && audio != null) {
        pos = await audio.positionMs();
        if (_disposed) return;
        if (!audio.isPlaying && !_paused) {
          if (pos >= _durationMs - _endSlackMs) {
            _finish();
            return;
          }
          // The audio track ended before the video (shorter track): keep the
          // remaining frames rolling on the stopwatch clock.
          _clockIsAudio = false;
          _startSilentFrom(pos);
        }
      } else {
        pos = _silentBaseMs + _silent.elapsedMilliseconds;
        if (pos >= _durationMs && !_paused) {
          _finish();
          return;
        }
      }
      if (pos > _durationMs) pos = _durationMs;
      _positionMs = pos;
      _advanceWindowIfNeeded(pos);
      _pullFrame(pos);
      notifyListeners();
    } finally {
      _ticking = false;
    }
  }

  void _finish() {
    _positionMs = _durationMs;
    _ended = true;
    _paused = true;
    _silent.stop();
    _poll?.cancel();
    _poll = null;
    // Show the closing frame; the last decoded one stays on screen.
    _pullFrame(_durationMs);
    notifyListeners();
  }

  void _pullFrame(int ms) {
    final frames = _frames;
    if (frames == null || ms == _lastFramePollMs) return;
    // Past the last frame (audio outliving a shorter video track): the shown
    // frame can no longer change — skip the per-tick RGBA copy.
    final lastTs = _x.videoFrames.last.tsMs;
    if (ms > lastTs && _lastFramePollMs >= lastTs) return;
    final f = frames.frameAt(ms);
    _lastFramePollMs = ms;
    if (f != null) frame.value = f;
  }

  // ── Frame windows ─────────────────────────────────────────────────────────

  /// Index into [_keyIndexes] of the last keyframe at/before [ms] (ts order).
  int _keyAtOrBefore(int ms) {
    final frames = _x.videoFrames;
    var lo = 0, hi = _keyIndexes.length - 1, best = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (frames[_keyIndexes[mid]].tsMs <= ms) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return _keyIndexes[best];
  }

  /// Count of frames with ts in ([fromMs], [toMs]] — the native forward-walk
  /// cost of seeking without a window swap.
  int _framesBetween(int fromMs, int toMs) {
    final frames = _x.videoFrames;
    var lo = 0, hi = frames.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (frames[mid].tsMs <= fromMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final start = lo;
    lo = 0;
    hi = frames.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (frames[mid].tsMs <= toMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - start;
  }

  void _retargetFrames(int ms) {
    if (!_x.hasVideo || _keyIndexes.isEmpty) return;
    final targetKey = _keyAtOrBefore(ms);
    if (_frames == null ||
        targetKey < _windowStart ||
        targetKey >= _windowEnd) {
      _rebuildWindow(targetKey);
    } else if (ms > _lastFramePollMs &&
        _x.videoFrames[targetKey].tsMs > _lastFramePollMs &&
        _framesBetween(_lastFramePollMs, ms) > kNativeVideoForwardWalkFrames) {
      // Far forward inside the window: a fresh window starting at the target
      // keyframe turns an every-frame decode walk into one bounded GOP.
      _rebuildWindow(targetKey);
    }
    _lastFramePollMs = -1; // force the pull even at an identical ms
    _pullFrame(ms);
  }

  /// Playback crossed the window's edge: swap in the next window. [_windowEnd]
  /// is a keyframe index by construction, so the swap opens on a keyframe.
  void _advanceWindowIfNeeded(int pos) {
    final frames = _x.videoFrames;
    if (_frames == null ||
        _windowEnd >= frames.length ||
        pos < frames[_windowEnd].tsMs) {
      return;
    }
    _rebuildWindow(_keyAtOrBefore(pos));
  }

  /// Builds the window of whole GOPs from keyframe index [fromKey] within the
  /// compressed-byte budget (always at least one GOP).
  void _rebuildWindow(int fromKey) {
    final frames = _x.videoFrames;
    var end = fromKey;
    var bytes = 0;
    while (end < frames.length) {
      // Extend GOP by GOP: [end, nextKey) is one GOP.
      var nextKey = end + 1;
      var gopBytes = 9 + frames[end].length;
      while (nextKey < frames.length && !frames[nextKey].key) {
        gopBytes += 9 + frames[nextKey].length;
        nextKey++;
      }
      if (end > fromKey && bytes + gopBytes > _windowBudget) break;
      bytes += gopBytes;
      end = nextKey;
    }
    _frames?.dispose();
    _frames = _frameFactory(
      buildVnote1Video(_x, fromFrame: fromKey, toFrame: end),
    );
    _windowStart = fromKey;
    _windowEnd = end;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _poll = null;
    final audio = _audio;
    _audio = null;
    if (audio != null) unawaited(audio.dispose());
    _frames?.dispose();
    _frames = null;
    frame.dispose();
    super.dispose();
  }
}
