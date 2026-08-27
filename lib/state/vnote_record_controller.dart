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

import 'media_ffi.dart';

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

  /// Null when there is no engine to record with, as well as when the engine
  /// declined — see [NativeVoiceRecorder.create] for why those became one
  /// answer.
  static NativeVnoteRecorder? create() {
    if (!VeilMediaNative.available()) return null;
    final rec = VeilMediaNative.guard(VeilVnoteRecorder.create);
    return rec == null ? null : NativeVnoteRecorder(rec);
  }

  /// How long to wait for the first camera frame before recording without one.
  ///
  /// Opening Camera2 and getting a frame back is usually a few hundred
  /// milliseconds; a camera that opens and then delivers nothing must not
  /// leave the record button dead, so the clip starts anyway and any later
  /// frame still gets pushed.
  static const Duration _firstFrameGrace = Duration(seconds: 2);

  /// A moment to get ready, counted from the first frame the person can see.
  ///
  /// Recording the instant the camera is ready gives no chance to compose
  /// yourself — the opening of every note is the half-second of raising the
  /// phone. Frames pushed during this window reach the preview and nothing
  /// else (the native encoder drops them until the clip starts), so it costs a
  /// live round preview and no recorded footage.
  static const Duration _getReadyWindow = Duration(seconds: 1);

  @override
  Future<bool> start() async {
    // Elsewhere the recorder owns its own camera, so the clip and the capture
    // begin together.
    if (!Platform.isAndroid) return _rec.start();

    // Android has no native camera backend — the calls' Dart capturer feeds
    // frames through the push ABI (front lens, upright, ~12 fps). A capture
    // failure degrades to audio-only, mirroring the native mic policy.
    //
    // The clip's clock starts on the FIRST FRAME, not before opening the
    // camera. Starting it first meant the recording began during Camera2's
    // open + session configure, so its opening seconds held no video at all:
    // the timer ran, the preview sat on nothing, and playback showed a frozen
    // picture until the first frame finally landed.
    final cam = AndroidCameraCapture();
    _cam = cam;
    final firstFrame = Completer<void>();
    final opened = await cam.start((y, u, v, w, h) {
      if (_cam != cam) return;
      if (!firstFrame.isCompleted) firstFrame.complete();
      // Before the clip starts these only reach the preview; the native
      // encoder drops them until `start()` stamps the clock.
      _rec.pushFrame(y, u, v, w, h);
    });
    if (!opened) {
      _cam = null;
      devLog(() => 'xVeil[vnote]: android camera start failed — audio-only');
      return _rec.start();
    }
    // A camera that opens and then delivers nothing must not leave the record
    // button dead: fall through and record what we can.
    var sawFrame = true;
    await firstFrame.future.timeout(
      _firstFrameGrace,
      onTimeout: () {
        sawFrame = false;
        devLog(
          () =>
              'xVeil[vnote]: no camera frame in '
              '${_firstFrameGrace.inMilliseconds}ms — recording without video',
        );
      },
    );
    if (sawFrame) await Future<void>.delayed(_getReadyWindow);
    return _rec.start();
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

/// `preparing` is the camera warming up and the person getting ready: the
/// preview is live, the clip has not started, and nothing is being kept yet.
enum VnoteRecordPhase { idle, preparing, recording, denied, error }

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

  /// Capture is underway in either sense — the gate for "do not start a second
  /// one" and for "the composer is busy". Distinct from [isRecording], which
  /// answers the narrower question of whether anything is being KEPT.
  bool get isCapturing =>
      phase == VnoteRecordPhase.preparing ||
      phase == VnoteRecordPhase.recording;

  VnoteRecordState copyWith({
    VnoteRecordPhase? phase,
    int? elapsedMs,
    double? level,
  }) => VnoteRecordState(
    phase: phase ?? this.phase,
    elapsedMs: elapsedMs ?? this.elapsedMs,
    level: level ?? this.level,
  );
}

class VnoteRecordController extends Notifier<VnoteRecordState> {
  VnoteRecorder? _rec;
  Timer? _poll;

  /// Invalidates a start still waiting on the mic and camera permissions.
  /// See [VoiceRecordController._gen] — same window, two prompts wide.
  int _gen = 0;

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

  /// Request mic + camera (both needed) and begin capturing. No-op if capture
  /// is already underway.
  ///
  /// The recorder's own `start()` now spans the camera opening plus a moment
  /// to get ready, so the poll timer and the `preparing` phase are armed BEFORE
  /// awaiting it — otherwise the composer would sit on a dead frame for a
  /// second with nothing to show and no sign that anything was happening.
  Future<void> start() async {
    if (state.isCapturing) return;
    final gen = ++_gen;
    final micOk = await ref.read(micPermissionProvider)();
    final camOk = await ref.read(cameraPermissionProvider)();
    // Locked or switched while the prompts were up. Without this the camera
    // and the microphone opened AFTERWARDS (report17 XV17-M5).
    if (gen != _gen) return;
    if (!micOk || !camOk) {
      state = const VnoteRecordState(phase: VnoteRecordPhase.denied);
      return;
    }
    final rec = ref.read(vnoteRecorderFactoryProvider)();
    if (rec == null) {
      devLog(() => 'xVeil[vnote]: recorder unavailable');
      state = const VnoteRecordState(phase: VnoteRecordPhase.error);
      return;
    }
    _rec = rec;
    preview.value = null;
    state = const VnoteRecordState(phase: VnoteRecordPhase.preparing);
    _poll = Timer.periodic(_pollEvery, (_) => _tick());
    if (!await rec.start()) {
      if (gen != _gen) return; // already torn down by a lock or a switch
      // cancel(), not _teardown(): the latter belongs to provider disposal and
      // disposes `preview`, which outlives any one recording.
      cancel();
      devLog(() => 'xVeil[vnote]: recorder start failed');
      state = const VnoteRecordState(phase: VnoteRecordPhase.error);
      return;
    }
    // A cancel during the get-ready window already tore this down; do not
    // resurrect it into recording.
    if (_rec != rec) return;
    state = state.copyWith(phase: VnoteRecordPhase.recording);
  }

  void _tick() {
    final rec = _rec;
    if (rec == null) return;
    // The preview runs in BOTH phases — showing it is the whole point of the
    // get-ready window.
    final f = rec.frame();
    if (f != null) preview.value = f;
    if (!state.isRecording) return;
    final elapsed = rec.elapsedMs;
    state = state.copyWith(elapsedMs: elapsed, level: rec.level);
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
  ///
  /// Letting go during the get-ready window is a cancel, not a zero-length
  /// note: nothing has been kept yet. Returning early WITHOUT tearing down
  /// would leave the camera and the recorder running with no UI attached.
  VnoteClip? stop() {
    if (!state.isRecording) {
      if (state.isCapturing) cancel();
      return null;
    }
    final clip = _finish();
    state = const VnoteRecordState();
    return clip;
  }

  /// Discard the in-progress recording without producing a clip.
  /// Stop capturing and forget what was captured, now. See
  /// [VoiceRecordController.stopForPrivacy] — same contract, camera included.
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
