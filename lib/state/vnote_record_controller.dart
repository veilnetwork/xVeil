// Video-note recording controller (video-note epic, brick 3): drives the
// native VNOTE1 recorder for the composer's round-video capture UI. Owns the
// recorder lifetime, a poll timer surfacing elapsed time + the live preview
// frame, the 60 s auto-stop, and the mic+camera permission gates.
//
// Mirrors VoiceRecordController exactly: the native recorder sits behind a
// small [VnoteRecorder] interface with an injectable factory so tests drive
// the whole flow with a fake (no native lib, no camera).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_media/veil_media.dart';

import 'dart:io' show Platform;

import '../core/log.dart';
import 'android_camera_capture.dart';
import 'mac_media_permissions.dart';
import 'voice_record_controller.dart' show micPermissionProvider;

/// The captured note handed to the send path.
class VnoteClip {
  const VnoteClip({required this.bytes, required this.durationMs});
  final Uint8List bytes;
  final int durationMs;
}

/// Minimal recorder surface the controller drives — the real impl wraps the
/// native [VeilVnoteRecorder]; tests supply a fake.
abstract class VnoteRecorder {
  Future<bool> start();
  double get level;
  int get elapsedMs;

  /// Latest captured frame for the live round self-preview (null = no new).
  VeilVideoFrame? frame();

  /// Stop + finalize; null for an empty clip.
  VnoteClip? stop();
  void dispose();
}

/// Real recorder: wraps the veil_media native VNOTE1 recorder.
class NativeVnoteRecorder implements VnoteRecorder {
  NativeVnoteRecorder(this._rec);
  final VeilVnoteRecorder _rec;
  AndroidCameraCapture? _cam;

  static NativeVnoteRecorder? create() {
    final rec = VeilVnoteRecorder.create();
    return rec == null ? null : NativeVnoteRecorder(rec);
  }

  @override
  Future<bool> start() async {
    if (!_rec.start()) return false;
    // Android has no native camera backend — the calls' Dart capturer feeds
    // frames through the push ABI (front lens, upright, ~12 fps). A capture
    // failure degrades to audio-only, mirroring the native mic policy.
    if (Platform.isAndroid) {
      final cam = AndroidCameraCapture();
      _cam = cam;
      final ok = await cam.start((y, u, v, w, h) {
        if (_cam != cam) return;
        _rec.pushFrame(y, u, v, w, h);
      });
      if (!ok) {
        _cam = null;
        devLog(() => 'xVeil[vnote]: android camera start failed — audio-only');
      }
    }
    return true;
  }
  @override
  double get level => _rec.level;
  @override
  int get elapsedMs => _rec.elapsedMs;
  @override
  VeilVideoFrame? frame() => _rec.frame();
  @override
  VnoteClip? stop() {
    final cam = _cam;
    _cam = null;
    if (cam != null) unawaited(cam.stop());
    final r = _rec.stop();
    if (r == null) return null;
    return VnoteClip(bytes: r.bytes, durationMs: r.durationMs);
  }

  @override
  void dispose() {
    final cam = _cam;
    _cam = null;
    if (cam != null) unawaited(cam.stop());
    _rec.dispose();
  }
}

/// Factory the controller uses to build a recorder; overridden in tests.
typedef VnoteRecorderFactory = VnoteRecorder? Function();

final vnoteRecorderFactoryProvider = Provider<VnoteRecorderFactory>(
  (ref) => NativeVnoteRecorder.create,
);

/// The camera-permission request, injectable for tests (the mic one is shared
/// with voice via [micPermissionProvider] in voice_record_controller.dart).
typedef CameraPermissionRequest = Future<bool> Function();

final cameraPermissionProvider = Provider<CameraPermissionRequest>(
  (ref) => MacMediaPermissions.requestCamera,
);

enum VnoteRecordPhase { idle, recording, denied, error }

class VnoteRecordState {
  const VnoteRecordState({
    this.phase = VnoteRecordPhase.idle,
    this.elapsedMs = 0,
    this.level = 0,
  });

  final VnoteRecordPhase phase;
  final int elapsedMs;
  final double level;

  bool get isRecording => phase == VnoteRecordPhase.recording;

  VnoteRecordState copyWith({
    VnoteRecordPhase? phase,
    int? elapsedMs,
    double? level,
  }) =>
      VnoteRecordState(
        phase: phase ?? this.phase,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        level: level ?? this.level,
      );
}

class VnoteRecordController extends Notifier<VnoteRecordState> {
  VnoteRecorder? _rec;
  Timer? _poll;

  /// The live self-preview frame; the recording UI listens and repaints. Kept
  /// OUT of the Notifier state on purpose — a full state emit per video frame
  /// would rebuild the whole composer ~12x/s.
  final ValueNotifier<VeilVideoFrame?> preview = ValueNotifier(null);

  /// Telegram-style cap for a round message.
  static const Duration maxDuration = Duration(seconds: 60);

  static const Duration _pollEvery = Duration(milliseconds: 80);

  @override
  VnoteRecordState build() {
    ref.onDispose(_teardown);
    return const VnoteRecordState();
  }

  /// Request mic + camera (both needed) and begin capturing. No-op if already
  /// recording.
  Future<void> start() async {
    if (state.isRecording) return;
    final micOk = await ref.read(micPermissionProvider)();
    final camOk = await ref.read(cameraPermissionProvider)();
    if (!micOk || !camOk) {
      state = const VnoteRecordState(phase: VnoteRecordPhase.denied);
      return;
    }
    final rec = ref.read(vnoteRecorderFactoryProvider)();
    if (rec == null || !await rec.start()) {
      rec?.dispose();
      devLog(() => 'xVeil[vnote]: recorder start failed');
      state = const VnoteRecordState(phase: VnoteRecordPhase.error);
      return;
    }
    _rec = rec;
    preview.value = null;
    state = const VnoteRecordState(phase: VnoteRecordPhase.recording);
    _poll = Timer.periodic(_pollEvery, (_) => _tick());
  }

  void _tick() {
    final rec = _rec;
    if (rec == null) return;
    final elapsed = rec.elapsedMs;
    state = state.copyWith(elapsedMs: elapsed, level: rec.level);
    final f = rec.frame();
    if (f != null) preview.value = f;
    if (elapsed >= maxDuration.inMilliseconds) {
      unawaited(_autoStop());
    }
  }

  Future<void> _autoStop() async {
    _lastClip = _finish();
    state = const VnoteRecordState();
  }

  VnoteClip? _lastClip;

  /// The clip produced by the most recent auto-stop (max duration), consumed
  /// once by the composer. Null after a manual [stop].
  VnoteClip? takeAutoStopped() {
    final c = _lastClip;
    _lastClip = null;
    return c;
  }

  /// Stop capture and return the finished note (null if empty/not recording).
  VnoteClip? stop() {
    if (!state.isRecording) return null;
    final clip = _finish();
    state = const VnoteRecordState();
    return clip;
  }

  /// Discard the in-progress recording without producing a clip.
  void cancel() {
    _poll?.cancel();
    _poll = null;
    _rec?.stop();
    _rec?.dispose();
    _rec = null;
    _lastClip = null;
    preview.value = null;
    state = const VnoteRecordState();
  }

  VnoteClip? _finish() {
    _poll?.cancel();
    _poll = null;
    final rec = _rec;
    _rec = null;
    if (rec == null) return null;
    VnoteClip? clip;
    try {
      clip = rec.stop();
    } finally {
      rec.dispose();
    }
    preview.value = null;
    return clip;
  }

  void _teardown() {
    _poll?.cancel();
    _poll = null;
    _rec?.dispose();
    _rec = null;
    preview.dispose();
  }
}

final vnoteRecordControllerProvider =
    NotifierProvider<VnoteRecordController, VnoteRecordState>(
  VnoteRecordController.new,
);
