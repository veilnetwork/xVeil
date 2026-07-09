import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veil_media/veil_media.dart';

import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import 'android_camera_capture.dart';
import 'call_service.dart';
import 'mac_media_permissions.dart';

/// Latest decoded remote video frame for the active call (RGBA), or null. The
/// media controller pumps it at the display rate; the call UI (and the debug
/// hook) watch it. Global so the render surface can find it without threading
/// the controller through the widget tree.
final ValueNotifier<VeilVideoFrame?> remoteVideoFrame =
    ValueNotifier<VeilVideoFrame?>(null);

/// Latest local camera frame for the active video call (RGBA), or null. Used by
/// the draggable self-preview tile.
final ValueNotifier<VeilVideoFrame?> localVideoFrame =
    ValueNotifier<VeilVideoFrame?>(null);

/// The real [CallMediaController]: opens a veil media datagram channel to the
/// call peer and drives the libwebrtc audio engine (libveil_media.dylib) over
/// it. Per-packet RTP/RTCP flows native↔native (the C++ Transport shim calls
/// the veil_media_* ABI); this Dart layer is control only.
///
/// SSRCs are derived from the node ids inside the engine, so both ends agree
/// without extra negotiation. One engine per live call; [stop] is idempotent.
class VeilCallMediaController implements CallMediaController {
  VeilCallMediaController(this._transport);

  final VeilFlutterTransport _transport;
  VeilMediaEngine? _engine;
  int? _chan;
  String? _chanPeer; // hex of the peer _chan was opened for
  Timer? _frameTimer; // pulls decoded remote frames at the display rate
  AndroidCameraCapture? _androidCam; // Dart camera SEND path (Android only)
  Timer? _statsTimer; // polls rx_pkts for the call-liveness signal
  DateTime? _lastRxAt; // wall-clock when rx_pkts last increased
  int _lastRxPkts = 0;

  @override
  DateTime? get lastMediaRxAt => _lastRxAt;

  @override
  Future<void> prewarm(Call call) async {
    // Open the media channel toward the peer now — openMediaChannel kicks off the
    // onion circuit build (ensure_outbound_opening), so it's warm by the time
    // start() sends the first RTP. Idempotent: keep one channel per peer.
    final peerHex = call.peer.hex;
    if (_chan != null && _chanPeer == peerHex) return;
    try {
      final chan = await _transport.openMediaChannel(call.peer.bytes);
      // start() may have raced ahead and opened its own channel; don't clobber.
      if (_chan == null) {
        _chan = chan;
        _chanPeer = peerHex;
      } else if (_chan != chan) {
        _transport.closeMediaChannel(chan);
      }
    } catch (_) {
      // best-effort warmup; start() will open the channel if this failed
    }
  }

  @override
  Future<bool> start(Call call) async {
    // Reuse the channel prewarm() opened for this peer (its circuit is already
    // warming); only tear down a stale session for a different peer.
    if (_engine != null || (_chan != null && _chanPeer != call.peer.hex)) {
      await stop();
    }
    // Present the macOS mic (and camera for video) TCC prompt via
    // AVCaptureDevice BEFORE the engine touches CoreAudio — but NEVER let the
    // prompt block the call FSM: bound the wait, and proceed regardless (the
    // engine still comes up; capture starts once permission lands).
    if (call.media.audio) {
      await MacMediaPermissions.requestMicrophone().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    }
    if (call.media.video) {
      await MacMediaPermissions.requestCamera().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    }
    final localId = (await _transport.nodeId()).bytes;
    final peerId = call.peer.bytes;
    // Reuse the prewarmed channel if present (circuit already warming); else open.
    final chan = (_chan != null && _chanPeer == call.peer.hex)
        ? _chan!
        : await _transport.openMediaChannel(peerId);
    _chan = chan;
    _chanPeer = call.peer.hex;
    final engine = VeilMediaEngine.create(
      veilChan: chan,
      localId: localId,
      peerId: peerId,
    );
    if (engine == null) {
      _transport.closeMediaChannel(chan);
      _chan = null;
      _chanPeer = null;
      return false;
    }
    _engine = engine;
    // Liveness signal for the call FSM: poll rx_pkts so it can tell the peer's
    // media is still arriving even when the durable signaling heartbeat lags.
    _statsTimer?.cancel();
    _lastRxAt = null;
    _lastRxPkts = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_engine != engine) return;
      try {
        final rx = (engine.getStats()['rx_pkts'] as num?)?.toInt() ?? 0;
        if (rx > _lastRxPkts) {
          _lastRxPkts = rx;
          _lastRxAt = DateTime.now();
        }
      } catch (_) {}
    });
    final audioOk = engine.startAudio(send: true, recv: true);
    // VP8 video over the same veil channel when the call requests video/screen.
    // Capture/render wiring lands with the platform capturer; the pipeline is
    // driven by the built-in test source under VEIL_MEDIA_TEST_VIDEO meanwhile.
    if (call.media.video || call.media.screen) {
      engine.startVideo(send: true, recv: true);
      // Drive the send stream from the real camera for a video call (screen
      // capture is a separate path). macOS captures natively inside the engine
      // (AVCaptureSession); Android streams via the `camera` plugin and pushes
      // I420 frames in from Dart.
      if (call.media.video) {
        if (Platform.isAndroid) {
          await _startAndroidCam(engine);
        } else {
          try {
            engine.startCamera();
          } catch (_) {}
        }
      }
      // Pump decoded remote frames (~20fps) into the shared notifier for the UI.
      _frameTimer?.cancel();
      _frameTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (_engine != engine) return;
        try {
          final f = engine.getVideoFrame();
          if (f != null) remoteVideoFrame.value = f;
          final local = engine.getLocalVideoFrame();
          if (local != null) localVideoFrame.value = local;
        } catch (_) {}
      });
    }
    return audioOk;
  }

  @override
  Future<void> stop() async {
    _frameTimer?.cancel();
    _frameTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastRxAt = null;
    _lastRxPkts = 0;
    remoteVideoFrame.value = null;
    localVideoFrame.value = null;
    final cam = _androidCam;
    _androidCam = null;
    if (cam != null) {
      try {
        await cam.stop();
      } catch (_) {}
    }
    final e = _engine;
    _engine = null;
    if (e != null) {
      try {
        e.stopVideo();
      } catch (_) {}
      try {
        e.stopAudio();
      } catch (_) {}
      try {
        e.dispose();
      } catch (_) {}
    }
    final ch = _chan;
    _chan = null;
    _chanPeer = null;
    if (ch != null) {
      try {
        _transport.closeMediaChannel(ch);
      } catch (_) {}
    }
  }

  @override
  Future<void> setMicMuted(bool muted) async {
    try {
      _engine?.setMicMuted(muted);
    } catch (_) {}
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final engine = _engine;
    if (engine == null) return;
    if (Platform.isAndroid) {
      if (enabled) {
        await _startAndroidCam(engine);
      } else {
        final cam = _androidCam;
        _androidCam = null;
        if (cam != null) {
          try {
            await cam.stop();
          } catch (_) {}
        }
      }
    } else {
      try {
        if (enabled) {
          engine.startCamera();
        } else {
          engine.stopCamera();
        }
      } catch (_) {}
    }
  }

  /// Start the Dart-side Android camera capture (camera plugin -> pushVideoFrame).
  /// Idempotent; used by both start() and setCameraEnabled().
  Future<void> _startAndroidCam(VeilMediaEngine engine) async {
    if (_androidCam != null) return;
    final cam = AndroidCameraCapture();
    _androidCam = cam;
    final ok = await cam.start((y, u, v, w, h) {
      if (_engine != engine) return;
      try {
        engine.pushVideoFrame(y, u, v, w, h);
      } catch (_) {}
    });
    if (!ok) _androidCam = null;
  }
}
