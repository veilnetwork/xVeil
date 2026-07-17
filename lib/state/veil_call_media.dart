import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veil_media/veil_media.dart';

import '../core/log.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'android_camera_capture.dart';
import 'android_screen_capture.dart';
import 'call_bitrate_adapter.dart';
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

class _CallVideoProfile {
  const _CallVideoProfile({
    required this.maxBitrateKbps,
    required this.maxFps,
    required this.cameraWidth,
    required this.cameraHeight,
  });

  final int maxBitrateKbps;
  final int maxFps;
  final int cameraWidth;
  final int cameraHeight;
}

const _directVideoProfile = _CallVideoProfile(
  maxBitrateKbps: 900,
  maxFps: 20,
  cameraWidth: 640,
  cameraHeight: 360,
);
const _anonymousVideoProfile = _CallVideoProfile(
  maxBitrateKbps: 150,
  maxFps: 15,
  cameraWidth: 352,
  cameraHeight: 198,
);

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
  CallTransportKind? _chanTransport;
  Timer? _frameTimer; // pulls decoded remote frames at the display rate
  AndroidCameraCapture? _androidCam; // Dart camera SEND path (Android only)
  AndroidScreenCaptureSource? _androidScreen;
  bool _androidScreenPushLogged = false;
  final AndroidScreenCaptureFactory _screenCaptureFactory =
      createAndroidScreenCapture;
  final StreamController<void> _screenShareStops = StreamController.broadcast();
  Timer? _statsTimer; // polls rx_pkts for the call-liveness signal
  DateTime? _lastRxAt; // wall-clock when ENGINE rx_pkts last increased
  int _lastRxPkts = 0;
  int _lastNativeRxCount = 0;
  DateTime? _engineRxStalledSince; // node receives, engine doesn't — since when
  CallBitrateAdapter? _bitrateAdapter; // sender-side video quality ladder
  DateTime? _lastRepairAt;
  Call? _activeCall;
  bool _routeRepairing = false;
  int _mediaEpoch = 0;

  /// Whether the native relay channel currently batches audio/RTCP (v2-peer
  /// gate accepted). Surfaced in [diagnostics] so a live stand run can SEE
  /// the gate outcome — devLog is invisible on a shell-launched app.
  bool _relayBatching = false;

  @override
  CallTransportKind? get activeTransport =>
      _chan == null ? null : _chanTransport;

  bool get _highQualityRoute => _chanTransport != CallTransportKind.onion;

  @override
  DateTime? get lastMediaRxAt => _lastRxAt;

  @override
  Map<String, Object?> get diagnostics {
    final engine = _engine;
    if (engine == null) {
      return {'transport': _chanTransport?.name, 'running': false};
    }
    try {
      return {
        'transport': _chanTransport?.name,
        'running': true,
        'batching': _relayBatching,
        if (_bitrateAdapter != null) 'adaptLevel': _bitrateAdapter!.level,
        ...engine.getStats(),
      };
    } catch (_) {
      return {
        'transport': _chanTransport?.name,
        'running': true,
        'statsUnavailable': true,
      };
    }
  }

  @override
  Future<bool> repairRoute() async {
    final ch = _chan;
    if (ch == null || _routeRepairing) return false;
    final now = DateTime.now();
    final previous = _lastRepairAt;
    if (previous != null && now.difference(previous) < kCallMediaRepairAfter) {
      return true;
    }
    _lastRepairAt = now;
    if (_chanTransport != CallTransportKind.onion) {
      final call = _activeCall;
      if (call == null) return false;
      _routeRepairing = true;
      try {
        // A non-onion channel can be admitted yet black-holed end-to-end.
        // Rebuild its actual P2P/relay route. Failure is never implicit consent
        // to use the anonymous network.
        await _stopSession(clearActiveCall: false);
        if (_activeCall?.callId != call.callId) return false;
        final ok = await start(call);
        _lastRepairAt = now;
        devLog(
          () =>
              'xVeil[call-media]: silent ${call.transport?.name} route rebuilt '
              'call=${call.callId} ok=$ok',
        );
        return ok && activeTransport == call.transport;
      } finally {
        _routeRepairing = false;
      }
    }
    final rc = _transport.repairMediaChannel(ch);
    devLog(
      () =>
          'xVeil[call-media]: end-to-end silence route repair '
          'channel=$ch result=$rc',
    );
    return rc == 0;
  }

  @override
  Future<bool> switchRoute(CallTransportKind transport) async {
    final call = _activeCall;
    if (call == null || transport != CallTransportKind.relay) return false;
    await _stopSession(clearActiveCall: false);
    if (_activeCall?.callId != call.callId) return false;
    final ok = await start(call.copyWith(transport: transport));
    return ok && activeTransport == transport;
  }

  @override
  Stream<void> get screenShareStopped => _screenShareStops.stream;

  @override
  Future<bool> start(Call call) async {
    devLog(
      () =>
          'xVeil[call-media]: controller start platform=${Platform.operatingSystem}',
    );
    // Never open a route while the call is only ringing: the final route is
    // known only after both peers have applied their consent policy. Reuse is
    // therefore limited to this controller's already-finalized call lifecycle.
    if (_engine != null || (_chan != null && _chanPeer != call.peer.hex)) {
      await stop();
    }
    final epoch = ++_mediaEpoch;
    _activeCall = call;
    // Present the Apple mic (and camera for video) TCC prompt via
    // AVCaptureDevice BEFORE the engine touches CoreAudio — but NEVER let the
    // prompt block the call FSM: bound the wait, and proceed regardless (the
    // engine still comes up; capture starts once permission lands).
    if (call.media.audio) {
      final granted = await MacMediaPermissions.requestMicrophone().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      devLog(() => 'xVeil[call-media]: mic permission=$granted');
    }
    if (call.media.video) {
      final granted = await MacMediaPermissions.requestCamera().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      devLog(() => 'xVeil[call-media]: camera permission=$granted');
    }
    final localId = (await _transport.nodeId()).bytes;
    final peerId = call.peer.bytes;
    // Open only the route finalized by call negotiation.
    final int chan;
    final CallTransportKind transport;
    if (_chan != null && _chanPeer == call.peer.hex) {
      chan = _chan!;
      transport = _chanTransport!;
    } else {
      final opened = await _openMediaChannelFor(call);
      chan = opened.channel;
      transport = opened.transport;
    }
    if (epoch != _mediaEpoch || _activeCall?.callId != call.callId) {
      _transport.closeMediaChannel(chan);
      return false;
    }
    devLog(
      () =>
          'xVeil[call-media]: media channel=$chan '
          '(${transport.name})',
    );
    _chan = chan;
    _chanPeer = call.peer.hex;
    _chanTransport = transport;
    // Relay media pays a full E2E envelope + padding PER datagram (~24× for
    // Opus-sized packets — the device-measured last-mile saturation class,
    // ROADMAP section S). When the peer's call protocol version proves it
    // decodes batched cells, let the native sender amortize small audio/RTCP
    // datagrams into one envelope. Version-gated: to an older build a
    // batched cell is silent noise.
    _relayBatching = false;
    if (transport == CallTransportKind.relay &&
        (call.peerProtocolVersion ?? 1) >= kCallRelayBatchingMinVersion) {
      final rc = _transport.setRelayMediaBatching(chan, true);
      _relayBatching = rc == 0;
      devLog(() => 'xVeil[call-media]: relay batching enable rc=$rc');
    }
    // A negotiated P2P open may have taken the explicitly permitted non-onion
    // relay fallback. Keep subsequent repair/switch operations anchored to the
    // route that is actually carrying this call, not the stale proposal.
    _activeCall = call.copyWith(transport: transport);
    final highQuality = transport != CallTransportKind.onion;
    final engine = VeilMediaEngine.create(
      veilChan: chan,
      localId: localId,
      peerId: peerId,
    );
    if (engine == null) {
      devLog(() => 'xVeil[call-media]: engine create failed');
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
    _lastNativeRxCount = _transport.mediaRecvCount(call.peer.bytes);
    _engineRxStalledSince = null;
    _lastRepairAt = null;
    _bitrateAdapter = null; // re-armed below when this call carries video
    var statsTick = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_engine != engine) return;
      try {
        final stats = engine.getStats();
        // Per-second quality trace into the devLog ring (2 s cadence to leave
        // ring headroom): the live "delay grows over the call" report needs
        // the full curve — RTCP rtt/jitter AND the direct receive-pipeline
        // delays — from BOTH sides of a user-driven call, which one-shot
        // /call_state sampling around a short repro keeps missing.
        if ((statsTick++).isEven) {
          devLog(
            () =>
                'xVeil[call-stats]: rtt=${stats['rtt_ms']} '
                'jit=${stats['jitter_ms']}/${stats['tx_jitter_ms']} '
                'loss=${stats['loss_pct']}/${stats['tx_loss_pct']} '
                'aud=${stats['audio_delay_ms']}/${stats['audio_jb_ms']} '
                'vid=${stats['video_delay_ms']}/${stats['video_jb_ms']} '
                'pacer=${stats['pacer_delay_ms']} '
                'sdelay=${stats['video_send_delay_ms']} '
                'adapt=${_bitrateAdapter?.level} '
                'base=${_bitrateAdapter?.rttBaselineMs} '
                'tx=${stats['tx_pkts']} rx=${stats['rx_pkts']} '
                'drops=${stats['tx_drops']}/${stats['rx_drops']}',
          );
        }
        final rx = (stats['rx_pkts'] as num?)?.toInt() ?? 0;
        final nativeRx = _transport.mediaRecvCount(call.peer.bytes);
        if (rx > _lastRxPkts) {
          _lastRxAt = DateTime.now();
          _engineRxStalledSince = null;
        } else if (nativeRx > _lastNativeRxCount) {
          // The node keeps receiving the peer's media while the engine gets
          // none of it: the failure is OUR local channel/engine wiring, not
          // the peer's outbound route. Asking the peer to repair can't help
          // (its packets already arrive), and this native flow must NOT count
          // as media liveness — that would mask the outage from the FSM
          // forever. Self-heal with a local session rebuild instead.
          final now = DateTime.now();
          _engineRxStalledSince ??= now;
          if (now.difference(_engineRxStalledSince!) >= kCallMediaRepairAfter) {
            _engineRxStalledSince = null;
            devLog(
              () =>
                  'xVeil[call-media]: node receives but engine starved '
                  '(native=$nativeRx engine=$rx) — local session rebuild',
            );
            unawaited(repairRoute());
          }
        }
        _lastRxPkts = rx;
        _lastNativeRxCount = nativeRx;
        final adapter = _bitrateAdapter;
        if (adapter != null) {
          // Sender-side ladder driven by what the REMOTE receiver reports for
          // our outbound leg (RTCP report blocks) plus local queue drops. The
          // route profile stays the ceiling; adaptation only spends less.
          final change = adapter.onSample(
            rttMs: (stats['rtt_ms'] as num?)?.toInt() ?? 0,
            txJitterMs: (stats['tx_jitter_ms'] as num?)?.toInt() ?? 0,
            txLossPct: (stats['tx_loss_pct'] as num?)?.toInt() ?? 0,
            txDrops: (stats['tx_drops'] as num?)?.toInt() ?? 0,
          );
          if (change != null) {
            final ok = engine.setVideoBitrate(
              maxBitrateKbps: change.maxBitrateKbps,
              maxFps: change.maxFps,
            );
            devLog(
              () =>
                  'xVeil[call-media]: link-quality retune level='
                  '${adapter.level} ${change.maxBitrateKbps}kbps@'
                  '${change.maxFps}fps ok=$ok',
            );
          }
        }
      } catch (_) {}
    });
    final audioOk = engine.startAudio(send: true, recv: true);
    devLog(() => 'xVeil[call-media]: startAudio=$audioOk');
    var videoOk = false;
    // VP8 video over the same veil channel when the call requests video/screen.
    // Capture/render wiring lands with the platform capturer; the pipeline is
    // driven by the built-in test source under VEIL_MEDIA_TEST_VIDEO meanwhile.
    if (call.media.video || call.media.screen) {
      final profile = highQuality
          ? _directVideoProfile
          : _anonymousVideoProfile;
      videoOk = engine.startVideo(
        send: true,
        recv: true,
        maxBitrateKbps: profile.maxBitrateKbps,
        maxFps: profile.maxFps,
      );
      devLog(() => 'xVeil[call-media]: startVideo=$videoOk');
      if (videoOk) {
        _bitrateAdapter = CallBitrateAdapter(
          baseBitrateKbps: profile.maxBitrateKbps,
          baseFps: profile.maxFps,
        );
      }
      // Drive the send stream from the real camera for a video call (screen
      // capture is a separate path). Apple platforms capture natively inside
      // the engine (AVCaptureSession); Android streams via the `camera` plugin
      // and pushes I420 frames in from Dart.
      if (call.media.video) {
        if (Platform.isAndroid) {
          // Do not hold the call FSM in `connecting` while the camera plugin
          // opens or waits for permission; the native video pipeline is already
          // mounted, and frames will start flowing once capture is ready.
          unawaited(_startAndroidCam(engine, highQuality: highQuality));
        } else {
          try {
            engine.startCamera(
              width: profile.cameraWidth,
              height: profile.cameraHeight,
              fps: profile.maxFps,
            );
          } catch (_) {}
        }
      }
      _startFramePump(engine);
    }
    final ok = audioOk || videoOk;
    devLog(() => 'xVeil[call-media]: controller start result=$ok');
    return ok;
  }

  /// Pump decoded remote frames (~20fps) into the shared notifier for the UI.
  void _startFramePump(VeilMediaEngine engine) {
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

  @override
  Future<bool> setVideoEnabled(bool enabled) async {
    final engine = _engine;
    final call = _activeCall;
    if (!enabled || engine == null || call == null) return false;
    if (call.media.video || call.media.screen) return true; // already mounted
    // Same bounded Apple TCC pre-prompt as a video call's start(): never let
    // the permission sheet block the running call.
    final granted = await MacMediaPermissions.requestCamera().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    devLog(() => 'xVeil[call-media]: mid-call camera permission=$granted');
    final profile = _highQualityRoute
        ? _directVideoProfile
        : _anonymousVideoProfile;
    final bool ok;
    try {
      ok = engine.startVideo(
        send: true,
        recv: true,
        maxBitrateKbps: profile.maxBitrateKbps,
        maxFps: profile.maxFps,
      );
    } catch (_) {
      return false;
    }
    devLog(() => 'xVeil[call-media]: mid-call video mount=$ok');
    if (!ok) return false;
    // Keep the session's own call view carrying video, so a route repair or
    // switch rebuilds the upgraded media set rather than the audio-only offer.
    _activeCall = call.copyWith(media: call.media.copyWith(video: true));
    _bitrateAdapter ??= CallBitrateAdapter(
      baseBitrateKbps: profile.maxBitrateKbps,
      baseFps: profile.maxFps,
    );
    if (_frameTimer == null) _startFramePump(engine);
    return true;
  }

  @override
  Future<void> stop() => _stopSession(clearActiveCall: true);

  Future<void> _stopSession({required bool clearActiveCall}) async {
    _mediaEpoch++;
    if (clearActiveCall) _activeCall = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastRxAt = null;
    _lastRxPkts = 0;
    _lastNativeRxCount = 0;
    _engineRxStalledSince = null;
    _bitrateAdapter = null;
    remoteVideoFrame.value = null;
    localVideoFrame.value = null;
    final cam = _androidCam;
    _androidCam = null;
    if (cam != null) {
      try {
        await cam.stop();
      } catch (_) {}
    }
    final screen = _androidScreen;
    _androidScreen = null;
    if (screen != null) {
      try {
        await screen.stop();
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
    _chanTransport = null;
    _relayBatching = false;
    if (ch != null) {
      try {
        _transport.closeMediaChannel(ch);
      } catch (_) {}
    }
  }

  Future<({int channel, CallTransportKind transport})> _openMediaChannelFor(
    Call call,
  ) async {
    if (call.transport == CallTransportKind.p2p) {
      try {
        final channel = await _transport.openMediaChannel(
          call.peer.bytes,
          direct: true,
        );
        return (channel: channel, transport: CallTransportKind.p2p);
      } catch (e) {
        devLog(
          () =>
              'xVeil[call-media]: direct open failed for ${call.peer.short}; '
              'using non-onion relay: $e',
        );
        final channel = await _transport.openMediaChannel(
          call.peer.bytes,
          relay: true,
        );
        return (channel: channel, transport: CallTransportKind.relay);
      }
    }
    if (call.transport == CallTransportKind.relay) {
      final channel = await _transport.openMediaChannel(
        call.peer.bytes,
        relay: true,
      );
      return (channel: channel, transport: CallTransportKind.relay);
    }
    if (call.transport != CallTransportKind.onion) {
      throw StateError(
        'negotiated ${call.transport?.name ?? 'unset'} media has no implemented route',
      );
    }
    final channel = await _transport.openMediaChannel(call.peer.bytes);
    return (channel: channel, transport: CallTransportKind.onion);
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
        await _startAndroidCam(engine, highQuality: _highQualityRoute);
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
          final profile = _highQualityRoute
              ? _directVideoProfile
              : _anonymousVideoProfile;
          engine.startCamera(
            width: profile.cameraWidth,
            height: profile.cameraHeight,
            fps: profile.maxFps,
          );
        } else {
          engine.stopCamera();
        }
      } catch (_) {}
    }
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    final engine = _engine;
    if (engine == null) return false;
    if (Platform.isAndroid) {
      if (!enabled) {
        final screen = _androidScreen;
        _androidScreen = null;
        if (screen != null) await screen.stop();
        return true;
      }
      if (_androidScreen != null) return true;
      final cameraWasRunning = _androidCam != null;
      final cam = _androidCam;
      _androidCam = null;
      if (cam != null) await cam.stop();
      final started = await _startAndroidScreen(engine);
      if (!started && cameraWasRunning) {
        await _startAndroidCam(engine, highQuality: _highQualityRoute);
      }
      return started;
    }
    if (!Platform.isMacOS) return false;
    try {
      if (enabled) {
        return engine.startScreen(
          width: _highQualityRoute ? 960 : 640,
          fps: _highQualityRoute ? 15 : 10,
        );
      }
      return engine.stopScreen();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _startAndroidScreen(VeilMediaEngine engine) async {
    _androidScreenPushLogged = false;
    late final AndroidScreenCaptureSource screen;
    screen = _screenCaptureFactory(() {
      if (_androidScreen != screen) return;
      _androidScreen = null;
      localVideoFrame.value = null;
      _screenShareStops.add(null);
    });
    _androidScreen = screen;
    final started = await screen.start((y, u, v, w, h) {
      if (_engine != engine || _androidScreen != screen) return;
      try {
        final pushed = engine.pushVideoFrame(y, u, v, w, h);
        if (!_androidScreenPushLogged) {
          _androidScreenPushLogged = true;
          debugPrint('veil-screen: first direct engine push=$pushed');
        }
      } catch (_) {}
    });
    if (!started && _androidScreen == screen) _androidScreen = null;
    return started;
  }

  /// Start the Dart-side Android camera capture (camera plugin -> pushVideoFrame).
  /// Idempotent; used by both start() and setCameraEnabled().
  Future<void> _startAndroidCam(
    VeilMediaEngine engine, {
    required bool highQuality,
  }) async {
    if (_androidCam != null) return;
    final cam = AndroidCameraCapture(highQuality: highQuality);
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
