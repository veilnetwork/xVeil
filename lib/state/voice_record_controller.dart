// Voice recording controller (voice epic, brick 2): drives the native
// veil_media recorder for the composer's hold-to-record UI. Owns the recorder
// lifetime, a poll timer that surfaces the live level + elapsed time, a max-
// duration auto-stop, and the mic-permission gate.
//
// The native recorder is behind a small [VoiceRecorder] interface with an
// injectable factory, so widget tests drive the whole flow with a fake (no
// native lib, no real mic) — same pattern as the storage/messaging fakes.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart';

import 'media_ffi.dart';

import '../core/log.dart';
import 'mac_media_permissions.dart';

/// The captured clip handed to the send path.
class VoiceClip {
  const VoiceClip({
    required this.bytes,
    required this.durationMs,
    required this.waveform,
  });

  final Uint8List bytes;
  final int durationMs;
  final List<double> waveform;
}

/// Minimal recorder surface the controller drives — the real impl wraps the
/// native [VeilAudioRecorder]; tests supply a fake.
abstract class VoiceRecorder {
  /// Begin capture. False if the mic can't be opened (permission/device).
  bool start();
  double get level;
  int get elapsedMs;

  /// Stop + finalize; null for an empty clip.
  VoiceClip? stop({int waveformBars});
  void dispose();
}

/// Real recorder: wraps the veil_media native recorder.
class NativeVoiceRecorder implements VoiceRecorder {
  NativeVoiceRecorder(this._rec);
  final VeilAudioRecorder _rec;

  /// Create the native recorder, or null if unavailable (no engine / no
  /// encoder).
  ///
  /// "No engine" used to be a different outcome from "no encoder": a build
  /// without libveil_media threw an uncaught `ArgumentError` out of
  /// `VeilAudioRecorder.create` — out of the mic button's tap handler — while a
  /// null from the native side landed in the caller's error phase and showed a
  /// toast. They are one outcome now, and it is the one that was already
  /// handled.
  static NativeVoiceRecorder? create() {
    if (!VeilMediaNative.available()) return null;
    final rec = VeilMediaNative.guard(VeilAudioRecorder.create);
    return rec == null ? null : NativeVoiceRecorder(rec);
  }

  @override
  bool start() => _rec.start();
  @override
  double get level => _rec.level;
  @override
  int get elapsedMs => _rec.elapsedMs;
  @override
  VoiceClip? stop({int waveformBars = 48}) {
    final r = _rec.stop(waveformBars: waveformBars);
    if (r == null) return null;
    return VoiceClip(
      bytes: r.bytes,
      durationMs: r.durationMs,
      waveform: r.waveform,
    );
  }

  @override
  void dispose() => _rec.dispose();
}

/// Factory the controller uses to build a recorder; overridden in tests.
typedef VoiceRecorderFactory = VoiceRecorder? Function();

final voiceRecorderFactoryProvider = Provider<VoiceRecorderFactory>(
  (ref) => NativeVoiceRecorder.create,
);

/// The mic-permission request, injectable for tests (defaults to the real
/// platform prompt).
typedef MicPermissionRequest = Future<bool> Function();

final micPermissionProvider = Provider<MicPermissionRequest>(
  (ref) => MacMediaPermissions.requestMicrophone,
);

enum VoiceRecordPhase { idle, recording, denied, error }

class VoiceRecordState {
  const VoiceRecordState({
    this.phase = VoiceRecordPhase.idle,
    this.elapsedMs = 0,
    this.level = 0,
  });

  final VoiceRecordPhase phase;
  final int elapsedMs;
  final double level;

  bool get isRecording => phase == VoiceRecordPhase.recording;

  VoiceRecordState copyWith({
    VoiceRecordPhase? phase,
    int? elapsedMs,
    double? level,
  }) => VoiceRecordState(
    phase: phase ?? this.phase,
    elapsedMs: elapsedMs ?? this.elapsedMs,
    level: level ?? this.level,
  );
}

class VoiceRecordController extends Notifier<VoiceRecordState> {
  VoiceRecorder? _rec;
  Timer? _poll;

  /// Invalidates a start still waiting on the microphone permission.
  ///
  /// The prompt is an await, and a lock or an identity switch can land inside
  /// it: without this the capture began AFTERWARDS — a live microphone behind
  /// a lock screen, or under an identity that never asked for it
  /// (report17 XV17-M5).
  int _gen = 0;

  /// Hard ceiling so a stuck press can't grow the RAM buffer unbounded (the
  /// native side also caps at 6 min; keep the UI cap a touch under it).
  static const Duration maxDuration = Duration(minutes: 5);

  /// UI poll cadence for the level meter + elapsed counter.
  static const Duration _pollEvery = Duration(milliseconds: 80);

  @override
  VoiceRecordState build() {
    ref.onDispose(_teardown);
    return const VoiceRecordState();
  }

  /// Request the mic (if needed) and begin capturing. Sets [VoiceRecordPhase]
  /// to recording on success, or denied/error otherwise. No-op if already
  /// recording.
  Future<void> start() async {
    if (state.isRecording) return;
    final gen = ++_gen;
    final granted = await ref.read(micPermissionProvider)();
    if (gen != _gen) return; // locked or switched while the prompt was up
    if (!granted) {
      state = const VoiceRecordState(phase: VoiceRecordPhase.denied);
      return;
    }
    final rec = ref.read(voiceRecorderFactoryProvider)();
    if (rec == null || !rec.start()) {
      rec?.dispose();
      devLog(() => 'xVeil[voice]: recorder start failed');
      state = const VoiceRecordState(phase: VoiceRecordPhase.error);
      return;
    }
    _rec = rec;
    state = const VoiceRecordState(phase: VoiceRecordPhase.recording);
    _poll = Timer.periodic(_pollEvery, (_) => _tick());
  }

  void _tick() {
    final rec = _rec;
    if (rec == null) return;
    final elapsed = rec.elapsedMs;
    state = state.copyWith(elapsedMs: elapsed, level: rec.level);
    if (elapsed >= maxDuration.inMilliseconds) {
      // Auto-stop is fire-and-forget: the UI watches for the phase flip.
      unawaited(_autoStop());
    }
  }

  Future<void> _autoStop() async {
    // A max-duration stop still yields the clip — surfaced via [stop] the same
    // way a manual release does; here we just end capture and leave the clip on
    // [_lastClip] for the composer to pick up.
    _lastClip = _finish();
    state = const VoiceRecordState();
  }

  VoiceClip? _lastClip;

  /// The clip produced by the most recent auto-stop (max-duration), consumed
  /// once by the composer. Null after a manual [stop] (which returns directly).
  VoiceClip? takeAutoStopped() {
    final c = _lastClip;
    _lastClip = null;
    return c;
  }

  /// Stop capture and return the finished clip (null if empty / not recording).
  VoiceClip? stop() {
    if (!state.isRecording) return null;
    final clip = _finish();
    state = const VoiceRecordState();
    return clip;
  }

  /// Discard the in-progress recording without producing a clip.
  /// Stop capturing and forget what was captured, now.
  ///
  /// Called synchronously before a lock or an identity switch. [cancel] does
  /// the work; the generation is what stops a start still waiting on the
  /// permission prompt from beginning capture afterwards.
  void stopForPrivacy() {
    _gen++;
    cancel();
  }

  void cancel() {
    _poll?.cancel();
    _poll = null;
    _rec?.stop();
    _rec?.dispose();
    _rec = null;
    _lastClip = null;
    state = const VoiceRecordState();
  }

  VoiceClip? _finish() {
    _poll?.cancel();
    _poll = null;
    final rec = _rec;
    _rec = null;
    if (rec == null) return null;
    VoiceClip? clip;
    try {
      clip = rec.stop();
    } finally {
      rec.dispose();
    }
    return clip;
  }

  void _teardown() {
    _poll?.cancel();
    _poll = null;
    _rec?.dispose();
    _rec = null;
  }
}

final voiceRecordControllerProvider =
    NotifierProvider<VoiceRecordController, VoiceRecordState>(
      VoiceRecordController.new,
    );
