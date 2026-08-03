import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_media/veil_media.dart';

import '../core/log.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'android_call_foreground.dart';
import 'android_camera_capture.dart';
import 'android_native_call_camera.dart';
import 'android_native_call_video.dart';
import 'android_screen_capture.dart';
import 'call_bitrate_adapter.dart';
import 'call_audio_route.dart';
import 'call_service.dart';
import 'mac_media_permissions.dart';

/// Latest decoded remote video frame for the active call (RGBA), or null. The
/// media controller pumps it at the display rate; the fallback call UI watches
/// it. Global so the render surface can find it without threading the
/// controller through the widget tree.
final ValueNotifier<VeilVideoFrame?> remoteVideoFrame =
    ValueNotifier<VeilVideoFrame?>(null);

VeilCallMediaController? _diagnosticMediaController;

/// Copies the latest decoded remote frame only when diagnostics explicitly
/// asks for it. Android's native texture path deliberately does not move RGBA
/// through Dart every frame, but `/media_last_frame` must remain capable of
/// proving the decoded pixels on demand.
VeilVideoFrame? pullRemoteVideoFrameForDiagnostics() {
  final alreadyPumped = remoteVideoFrame.value;
  if (alreadyPumped != null) return alreadyPumped;
  try {
    return _diagnosticMediaController?._engine?.getVideoFrame();
  } catch (_) {
    return null;
  }
}

/// Toggle batching on the currently active direct/relay media channel for a
/// debug-stand A/B. Returns null when no media controller is active, otherwise
/// the native channel result (0 = applied). The production policy remains in
/// [VeilCallMediaController.start]; release builds expose no caller for this.
int? setActiveMediaBatchingForDiagnostics(bool enabled) =>
    _diagnosticMediaController?._setMediaBatchingForDiagnostics(enabled);

/// Pins the active encoder target for a physical debug-stand A/B. Returns
/// null when no media controller is active and otherwise whether libwebrtc
/// accepted the target. Passing null clears the pin and reapplies the current
/// adaptive-ladder target.
bool? setActiveVideoTargetForDiagnostics({int? bitrateKbps, int? fps}) =>
    _diagnosticMediaController?._setVideoTargetForDiagnostics(
      bitrateKbps: bitrateKbps,
      fps: fps,
    );

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
  maxFps: 60,
  cameraWidth: 640,
  cameraHeight: 360,
);
const _anonymousVideoProfile = _CallVideoProfile(
  maxBitrateKbps: 150,
  maxFps: 15,
  cameraWidth: 352,
  cameraHeight: 198,
);

const int _compactRelayRtpPacketSize = 1000;

Uint8List _callMediaHash(Iterable<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  final material = builder.takeBytes();
  try {
    return Uint8List.fromList(sha256.convert(material).bytes);
  } finally {
    material.fillRange(0, material.length, 0);
  }
}

/// Derive the two directional relay-media keys from E2E-authenticated offer
/// and answer contributions. The ordering is call-role based, while TX/RX is
/// node-direction based, so both endpoints independently obtain opposite keys.
@visibleForTesting
({Uint8List txKey, Uint8List rxKey})? deriveRelayMediaKeys({
  required Call call,
  required Uint8List localNodeId,
}) {
  if ((call.peerProtocolVersion ?? 1) < kCallRelaySealedMediaMinVersion ||
      localNodeId.length != 32) {
    return null;
  }
  final localContribution = decodeCallMediaKeyContribution(call.localMediaKey);
  final peerContribution = decodeCallMediaKeyContribution(call.peerMediaKey);
  if (localContribution == null || peerContribution == null) return null;
  final localIsCaller = call.direction == CallDirection.outgoing;
  final callerContribution = localIsCaller
      ? localContribution
      : peerContribution;
  final calleeContribution = localIsCaller
      ? peerContribution
      : localContribution;
  final callerNode = localIsCaller ? localNodeId : call.peer.bytes;
  final calleeNode = localIsCaller ? call.peer.bytes : localNodeId;
  Uint8List? master;
  try {
    master = _callMediaHash([
      utf8.encode('xveil/call-media/master/v1'),
      const [0],
      utf8.encode(call.callId),
      const [0],
      callerNode,
      calleeNode,
      callerContribution,
      calleeContribution,
    ]);
    Uint8List directionKey(Uint8List from, Uint8List to) => _callMediaHash([
      utf8.encode('xveil/call-media/direction/v1'),
      const [0],
      master!,
      from,
      to,
    ]);
    return (
      txKey: directionKey(localNodeId, call.peer.bytes),
      rxKey: directionKey(call.peer.bytes, localNodeId),
    );
  } finally {
    localContribution.fillRange(0, localContribution.length, 0);
    peerContribution.fillRange(0, peerContribution.length, 0);
    master?.fillRange(0, master.length, 0);
  }
}

/// Whether an initial media mount may physically start the camera.
///
/// Video receive and camera transmit are independent: the user can turn the
/// camera off while a call is still dialing/ringing, and the accepted session
/// must then mount receive-only video without a transient capture leak.
@visibleForTesting
bool shouldStartInitialCallCamera(Call call) =>
    call.media.video && call.cameraOn;

/// The real [CallMediaController]: opens a veil media datagram channel to the
/// call peer and drives the libwebrtc audio engine (libveil_media.dylib) over
/// it. Per-packet RTP/RTCP flows native↔native (the C++ Transport shim calls
/// the veil_media_* ABI); this Dart layer is control only.
///
/// SSRCs are derived from the node ids inside the engine, so both ends agree
/// without extra negotiation. One engine per live call; [stop] is idempotent.
class VeilCallMediaController implements CallMediaController {
  VeilCallMediaController(this._transport);

  @override
  int get signalProtocolVersion => VeilMediaEngine.supportsMaxRtpPacketSize
      ? kCallSignalProtocolVersion
      : kCallRelayBatchingMinVersion;

  final VeilFlutterTransport _transport;
  static const MethodChannel _androidCallNetwork = MethodChannel(
    'xveil/call_network',
  );
  static const MethodChannel _androidAudioDevices = MethodChannel(
    'xveil/audio_devices',
  );
  static String get _cameraPreferenceKey =>
      'call.capture.camera.${Platform.operatingSystem}';
  static String get _microphonePreferenceKey =>
      'call.capture.microphone.${Platform.operatingSystem}';
  VeilMediaEngine? _engine;
  int? _chan;
  String? _chanPeer; // hex of the peer _chan was opened for
  CallTransportKind? _chanTransport;
  Timer? _frameTimer; // pulls decoded remote frames at the display rate
  AndroidNativeCallCamera? _androidNativeCam; // zero-copy call camera path
  AndroidNativeCallVideoRenderer? _androidVideoRenderer;
  AndroidCameraCapture? _androidCam; // plugin fallback (Android only)
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
  // Full-session rebuilds triggered by the starved detector within ONE call.
  // A rebuild that failed to revive rx will fail again: the inbound leg does
  // not depend on the outbound channel, so tearing the session down repeatedly
  // only guarantees dead registry windows (device-observed repair storm:
  // channels churning 2→7 in ~60 s until liveness killed the call). Two
  // attempts cover a transient wiring glitch; after that keep the session and
  // let the diag trace show where the packets die.
  int _starvedRebuilds = 0;
  CallBitrateAdapter? _bitrateAdapter; // sender-side video quality ladder
  DateTime? _lastRepairAt;
  Call? _activeCall;
  bool _routeRepairing = false;
  bool _androidCallNetworkActive = false;
  int _mediaEpoch = 0;
  bool _devicePreferencesLoaded = false;
  String? _selectedCameraId;
  String? _selectedMicrophoneId;
  String? _selectedScreenId;
  String? _preferredMicrophoneLabel;
  bool _screenSharing = false;

  // Frame cadence measured at the Dart/native boundary. Packet counters can
  // look perfect while decoded video still arrives in visible bursts, so keep
  // this lightweight telemetry in /call_state for live diagnosis.
  final Stopwatch _frameCadenceClock = Stopwatch();
  int _remoteFrames = 0;
  int _localFrames = 0;
  int? _firstRemoteFrameUs;
  int? _lastRemoteFrameUs;
  int _maxRemoteGapUs = 0;
  int _remoteHoldsOver75Ms = 0;
  int? _firstLocalFrameUs;
  int? _lastLocalFrameUs;
  int _maxLocalGapUs = 0;
  int _localHoldsOver75Ms = 0;

  // Poll above the 60 fps source/display cadence instead of at the exact same
  // 16.7 ms period. Equal-rate timers drift in and out of phase: some ticks see
  // the previous native frame and the next tick skips ahead, producing visible
  // holds despite a steady decoder. Pulling at ~83 Hz is cheap because
  // getVideoFrame returns null without copying when the native sequence did
  // not advance; the renderer follows the display and coalesces latest.
  static const Duration _framePollInterval = Duration(milliseconds: 12);

  /// Whether the native channel currently batches media cells. Production
  /// enables this only for relay; the debug A/B hook can also exercise direct.
  /// Surfaced in [diagnostics] so a live stand run can see the gate outcome
  /// even when devLog is unavailable.
  bool _mediaBatching = false;
  bool _compactRelayMedia = false;
  ({int bitrateKbps, int fps})? _diagnosticVideoTarget;

  int _setMediaBatchingForDiagnostics(bool enabled) {
    final chan = _chan;
    if (chan == null || _chanTransport == CallTransportKind.onion) return -1;
    final rc = _transport.setRelayMediaBatching(
      chan,
      enabled,
      compact: enabled && _compactRelayMedia,
    );
    if (rc == 0) _mediaBatching = enabled;
    devLog(
      () =>
          'xVeil[call-media]: diagnostic batching=$enabled '
          'channel=$chan rc=$rc',
    );
    return rc;
  }

  bool _setVideoTargetForDiagnostics({int? bitrateKbps, int? fps}) {
    final engine = _engine;
    final adapter = _bitrateAdapter;
    if (engine == null || adapter == null) return false;
    final target = bitrateKbps == null || fps == null
        ? (
            bitrateKbps: adapter.target.maxBitrateKbps,
            fps: adapter.target.maxFps,
          )
        : (bitrateKbps: bitrateKbps, fps: fps);
    final ok = engine.setVideoBitrate(
      maxBitrateKbps: target.bitrateKbps,
      maxFps: target.fps,
    );
    if (ok) {
      _diagnosticVideoTarget = bitrateKbps == null || fps == null
          ? null
          : target;
    }
    devLog(
      () =>
          'xVeil[call-media]: diagnostic video target='
          '${target.bitrateKbps}kbps@${target.fps}fps pinned='
          '${_diagnosticVideoTarget != null} ok=$ok',
    );
    return ok;
  }

  /// WHY a negotiated p2p route fell back to relay (real-P2P epic, layer 5) —
  /// null while the active route is the negotiated one. Set/cleared on every
  /// channel open; the badge and /call_state surface it verbatim.
  String? _transportFallbackReason;

  @override
  String? get transportFallbackReason =>
      _chan == null ? null : _transportFallbackReason;

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
      final chan = _chan;
      final relayDiagnostics =
          chan != null && _chanTransport == CallTransportKind.relay
          ? _transport.mediaChannelStats(chan) ?? const <String, int>{}
          : const <String, int>{};
      final nativeCamera = _androidNativeCam;
      final nativeDiagnostics = nativeCamera?.diagnostics ?? const {};
      final nativeVideoDiagnostics =
          _androidVideoRenderer?.diagnostics ?? const {};
      final androidCamera = _androidCam;
      final cameraDiagnostics = nativeDiagnostics.isNotEmpty
          ? nativeDiagnostics
          : androidCamera?.diagnostics ?? const <String, Object?>{};
      return {
        'transport': _chanTransport?.name,
        'running': true,
        'batching': _mediaBatching,
        'compact_relay_media': _compactRelayMedia,
        'capture_camera_id': _selectedCameraId,
        'capture_microphone_id': _selectedMicrophoneId,
        'capture_microphone_label': _preferredMicrophoneLabel,
        'capture_screen_id': _selectedScreenId,
        if (_diagnosticVideoTarget case final target?)
          'diagnostic_video_target':
              '${target.bitrateKbps}kbps@${target.fps}fps',
        if (_bitrateAdapter != null) 'adaptLevel': _bitrateAdapter!.level,
        'remote_frame_fps':
            nativeVideoDiagnostics['video_texture_fps'] ?? _remoteFrameFps,
        'remote_frame_max_gap_ms':
            nativeVideoDiagnostics['video_texture_max_gap_ms'] ??
            _maxRemoteGapUs ~/ 1000,
        'remote_frame_holds_75ms':
            nativeVideoDiagnostics['video_texture_holds_75ms'] ??
            _remoteHoldsOver75Ms,
        'remote_frames':
            nativeVideoDiagnostics['video_texture_frames'] ?? _remoteFrames,
        'local_frame_fps':
            cameraDiagnostics['camera_capture_fps'] ??
            androidCamera?.captureFps ??
            _localFrameFps,
        'local_frame_max_gap_ms':
            cameraDiagnostics['camera_capture_max_gap_ms'] ??
            _maxLocalGapUs ~/ 1000,
        'local_frame_holds_75ms':
            cameraDiagnostics['camera_capture_holds_75ms'] ??
            _localHoldsOver75Ms,
        'local_frames':
            cameraDiagnostics['camera_capture_frames'] ?? _localFrames,
        if (cameraDiagnostics.isNotEmpty) ...cameraDiagnostics,
        if (nativeVideoDiagnostics.isNotEmpty) ...nativeVideoDiagnostics,
        if (relayDiagnostics.isNotEmpty) ...relayDiagnostics,
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

  double get _remoteFrameFps {
    final first = _firstRemoteFrameUs;
    final last = _lastRemoteFrameUs;
    if (first == null || last == null || last <= first || _remoteFrames < 2) {
      return 0;
    }
    return ((_remoteFrames - 1) * 1000000 / (last - first) * 10).round() / 10;
  }

  double get _localFrameFps {
    final first = _firstLocalFrameUs;
    final last = _lastLocalFrameUs;
    if (first == null || last == null || last <= first || _localFrames < 2) {
      return 0;
    }
    return ((_localFrames - 1) * 1000000 / (last - first) * 10).round() / 10;
  }

  @override
  Future<bool> repairRoute() async {
    // A repair already in flight is PENDING, not failed: a peer repair request
    // landing mid-rebuild (the rebuild leaves _chan null for seconds) must not
    // read as a broken route — the FSM fails closed on false and would kill a
    // call whose repair was about to converge (device-observed repair storm).
    if (_routeRepairing) return true;
    final ch = _chan;
    if (ch == null) return false;
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
  bool get screenCaptureAccessGranted =>
      !Platform.isMacOS || platformScreenCaptureAccessGranted;

  @override
  bool requestScreenCaptureAccess() =>
      !Platform.isMacOS || requestPlatformScreenCaptureAccess();

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
    await _loadDevicePreferences();
    await _setAndroidCallNetworkActive(true);
    // Before capture opens: the grant must exist by the time the screen can
    // lock, and the typed service may only start while the app is visible.
    if (call.media.audio) {
      await AndroidCallForegroundService.setActive(true);
    }
    // Present the platform mic/camera prompts before native capture starts,
    // but do not serialize them: two independent five-second waits used to
    // exceed CallService's whole media-start budget and tear down an otherwise
    // usable receive-only call. Begin both requests together and give the OS a
    // short shared preflight window. The futures keep running after the bound,
    // so a prompt can still complete while the call comes up.
    final permissionRequests = <Future<void>>[];
    if (call.media.audio) {
      permissionRequests.add(
        MacMediaPermissions.requestMicrophone().then(
          (granted) =>
              devLog(() => 'xVeil[call-media]: mic permission=$granted'),
        ),
      );
    }
    if (call.media.video) {
      permissionRequests.add(
        MacMediaPermissions.requestCamera().then(
          (granted) =>
              devLog(() => 'xVeil[call-media]: camera permission=$granted'),
        ),
      );
    }
    if (permissionRequests.isNotEmpty) {
      await Future.wait(permissionRequests).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          devLog(() => 'xVeil[call-media]: permission preflight continuing');
          return const <void>[];
        },
      );
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
    // v3 removes the per-packet ML-KEM expansion: both E2E-authenticated call
    // contributions derive directional keys, the native channel seals each
    // cell once, and 1000-byte RTP packets fit one QUIC DATAGRAM. Configure the
    // packet ceiling before enabling sealing; a setup mismatch falls back to
    // the independently secure v2 envelope path rather than fragmenting video.
    _mediaBatching = false;
    _compactRelayMedia = false;
    if (transport == CallTransportKind.relay) {
      final keys = deriveRelayMediaKeys(call: call, localNodeId: localId);
      if (keys != null) {
        final packetSizeOk = engine.setMaxRtpPacketSize(
          _compactRelayRtpPacketSize,
        );
        int cipherRc = -1;
        if (packetSizeOk) {
          try {
            cipherRc = _transport.configureRelayMediaCipher(
              chan,
              txKey: keys.txKey,
              rxKey: keys.rxKey,
            );
          } finally {
            keys.txKey.fillRange(0, keys.txKey.length, 0);
            keys.rxKey.fillRange(0, keys.rxKey.length, 0);
          }
        } else {
          keys.txKey.fillRange(0, keys.txKey.length, 0);
          keys.rxKey.fillRange(0, keys.rxKey.length, 0);
        }
        if (cipherRc == 0) {
          final batchingRc = _transport.setRelayMediaBatching(
            chan,
            true,
            compact: true,
          );
          if (batchingRc != 0) {
            devLog(
              () =>
                  'xVeil[call-media]: compact relay mode rejected rc=$batchingRc',
            );
            engine.dispose();
            _transport.closeMediaChannel(chan);
            _chan = null;
            _chanPeer = null;
            _chanTransport = null;
            return false;
          }
          _mediaBatching = true;
          _compactRelayMedia = true;
        }
        devLog(
          () =>
              'xVeil[call-media]: compact relay packet_size=$packetSizeOk '
              'cipher_rc=$cipherRc enabled=$_compactRelayMedia',
        );
      }
      if (!_compactRelayMedia &&
          (call.peerProtocolVersion ?? 1) >= kCallRelayBatchingMinVersion) {
        final rc = _transport.setRelayMediaBatching(chan, true);
        _mediaBatching = rc == 0;
        devLog(() => 'xVeil[call-media]: legacy relay batching rc=$rc');
      }
    }
    _engine = engine;
    _diagnosticMediaController = this;
    await _restoreMicrophonePreference(engine);
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
            if (_starvedRebuilds >= 2) {
              devLog(
                () =>
                    'xVeil[call-media]: engine starved persists '
                    '(native=$nativeRx engine=$rx chan=$_chan) — rebuild cap '
                    'reached, keeping session',
              );
            } else {
              _starvedRebuilds++;
              devLog(
                () =>
                    'xVeil[call-media]: node receives but engine starved '
                    '(native=$nativeRx engine=$rx chan=$_chan) — local session '
                    'rebuild #$_starvedRebuilds',
              );
              unawaited(repairRoute());
            }
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
          if (change != null && _diagnosticVideoTarget == null) {
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
    // Establish the initial privacy posture before the ADM is started. The
    // native engine now keeps physical capture stopped while muted, so an
    // Android endpoint configured mic-off neither opens AudioRecord briefly
    // nor burns capture/Opus CPU just to encode silence.
    if (!call.micOn) {
      engine.setMicMuted(true);
    }
    final audioOk = engine.startAudio(send: true, recv: true);
    devLog(() => 'xVeil[call-media]: startAudio=$audioOk');
    if (audioOk) await callAudioRouter.useDefaultFor(call.media);
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
        if (Platform.isAndroid) await _startAndroidVideoRenderer(engine);
      }
      // Drive the send stream from the real camera for a video call (screen
      // capture is a separate path). Apple platforms capture natively inside
      // the engine. Android uses an app-owned Camera2 SurfaceTexture + direct
      // JNI YUV bridge; the Flutter camera plugin is only a compatibility
      // fallback if the native session cannot open.
      if (shouldStartInitialCallCamera(call)) {
        if (Platform.isAndroid) {
          // Do not hold the call FSM in `connecting` while camera permission or
          // device opening completes; the receive pipeline is already mounted.
          unawaited(_startAndroidCam(engine, highQuality: highQuality));
        } else {
          try {
            engine.startCamera(
              width: profile.cameraWidth,
              height: profile.cameraHeight,
              fps: profile.maxFps,
              deviceId: _selectedCameraId,
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

  /// Pump the latest decoded frames into the shared notifier for the UI.
  void _startFramePump(VeilMediaEngine engine) {
    _frameTimer?.cancel();
    _frameTimer = null;
    _frameCadenceClock
      ..reset()
      ..start();
    _remoteFrames = 0;
    _localFrames = 0;
    _firstRemoteFrameUs = null;
    _lastRemoteFrameUs = null;
    _maxRemoteGapUs = 0;
    _remoteHoldsOver75Ms = 0;
    _firstLocalFrameUs = null;
    _lastLocalFrameUs = null;
    _maxLocalGapUs = 0;
    _localHoldsOver75Ms = 0;
    final nativeRemote =
        Platform.isAndroid && (_androidVideoRenderer?.isRunning ?? false);
    final needsDartLocalFrames =
        Platform.isAndroid && (_androidScreen != null || _androidCam != null);
    // Camera2 preview and decoded remote video are both native textures on the
    // normal Android call path. An 83 Hz Dart timer used to wake the UI isolate
    // anyway only to discover that neither RGBA frame needed copying. Besides
    // wasting a core, that empty polling contributed directly to phone heat.
    // Keep a slower pump only for the plugin/screen fallback's local preview.
    if (nativeRemote && !needsDartLocalFrames) return;
    final interval = nativeRemote
        ? const Duration(milliseconds: 30)
        : _framePollInterval;
    _frameTimer = Timer.periodic(interval, (_) {
      if (_engine != engine) return;
      try {
        final f = nativeRemote ? null : engine.getVideoFrame();
        if (f != null) {
          final nowUs = _frameCadenceClock.elapsedMicroseconds;
          final previousUs = _lastRemoteFrameUs;
          _firstRemoteFrameUs ??= nowUs;
          if (previousUs != null) {
            final gapUs = nowUs - previousUs;
            if (gapUs > _maxRemoteGapUs) _maxRemoteGapUs = gapUs;
            if (gapUs >= 75000) _remoteHoldsOver75Ms++;
          }
          _lastRemoteFrameUs = nowUs;
          _remoteFrames++;
          remoteVideoFrame.value = f;
        }
        // Android renders the camera self-preview through Camera2's native
        // texture. Pulling the same frame back as RGBA here copied nearly a MB
        // per tick on the UI isolate and was the main source of preview hitches.
        // Screen sharing and other platforms still use the RGBA notifier.
        final local =
            Platform.isAndroid &&
                (_androidNativeCam != null || _androidCam != null) &&
                _androidScreen == null
            ? null
            : engine.getLocalVideoFrame();
        if (local != null) {
          final nowUs = _frameCadenceClock.elapsedMicroseconds;
          final previousUs = _lastLocalFrameUs;
          _firstLocalFrameUs ??= nowUs;
          if (previousUs != null) {
            final gapUs = nowUs - previousUs;
            if (gapUs > _maxLocalGapUs) _maxLocalGapUs = gapUs;
            if (gapUs >= 75000) _localHoldsOver75Ms++;
          }
          _lastLocalFrameUs = nowUs;
          _localFrames++;
          localVideoFrame.value = local;
        }
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
    await callAudioRouter.setRoute(CallAudioRoute.speaker);
    if (Platform.isAndroid) await _startAndroidVideoRenderer(engine);
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
    if (clearActiveCall) {
      _activeCall = null;
      // The rebuild cap is per CALL, not per session: a repair's stop+start
      // (clearActiveCall: false) must not refill the budget it just spent.
      _starvedRebuilds = 0;
    }
    _frameTimer?.cancel();
    _frameTimer = null;
    _frameCadenceClock.stop();
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastRxAt = null;
    _lastRxPkts = 0;
    _lastNativeRxCount = 0;
    _engineRxStalledSince = null;
    _bitrateAdapter = null;
    _screenSharing = false;
    remoteVideoFrame.value = null;
    localVideoFrame.value = null;
    final videoRenderer = _androidVideoRenderer;
    _androidVideoRenderer = null;
    if (videoRenderer != null) {
      try {
        await videoRenderer.stop();
      } catch (_) {}
    }
    final nativeCam = _androidNativeCam;
    _androidNativeCam = null;
    if (nativeCam != null) {
      try {
        // Awaited platform stop is also the JNI-handler lifetime fence. The
        // engine below cannot be destroyed while a frame push is in flight.
        await nativeCam.stop();
      } catch (_) {}
    }
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
    if (identical(_diagnosticMediaController, this)) {
      _diagnosticMediaController = null;
    }
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
    _mediaBatching = false;
    _compactRelayMedia = false;
    if (ch != null) {
      try {
        _transport.closeMediaChannel(ch);
      } catch (_) {}
    }
    // A route repair tears down and recreates only the media session. Keep the
    // radio in low-latency mode and the microphone foreground grant across
    // that internal gap; release them only when the call itself ends.
    if (clearActiveCall) {
      await callAudioRouter.release();
      await _setAndroidCallNetworkActive(false);
      await AndroidCallForegroundService.setActive(false);
    }
  }

  Future<void> _setAndroidCallNetworkActive(bool active) async {
    if (!Platform.isAndroid || _androidCallNetworkActive == active) return;
    try {
      final held = await _androidCallNetwork.invokeMethod<bool>('setActive', {
        'active': active,
      });
      _androidCallNetworkActive = active && held == true;
      devLog(
        () =>
            'xVeil[call-media]: Android low-latency Wi-Fi '
            'requested=$active held=${held == true}',
      );
    } catch (error) {
      _androidCallNetworkActive = false;
      devLog(
        () => 'xVeil[call-media]: Android low-latency Wi-Fi failed: $error',
      );
    }
  }

  Future<({int channel, CallTransportKind transport})> _openMediaChannelFor(
    Call call,
  ) async {
    if (call.transport == CallTransportKind.p2p) {
      // The native admission probe is bounded but can lose its whole budget
      // to a transient stall (busy client mutex, silently rate-limited
      // query) even while the direct session is admitted. A timed-out probe
      // is NOT an authoritative "no session" — give it one more attempt
      // before surrendering the negotiated p2p route to relay.
      Object? lastError;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final channel = await _transport.openMediaChannel(
            call.peer.bytes,
            direct: true,
          );
          _transportFallbackReason = null;
          return (channel: channel, transport: CallTransportKind.p2p);
        } catch (e) {
          lastError = e;
          devLog(
            () =>
                'xVeil[call-media]: direct open attempt ${attempt + 1} failed '
                'for ${call.peer.short}: $e',
          );
          final transient =
              '$e'.contains('timed out') || '$e'.contains('probe failed');
          if (!transient) break;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      devLog(
        () =>
            'xVeil[call-media]: direct open failed for ${call.peer.short}; '
            'using non-onion relay: $lastError',
      );
      // Layer-5 diagnostics (real-P2P epic): keep WHY the negotiated p2p
      // route fell back so the transport badge / /call_state can say
      // "relay — no direct session" instead of a bare "relay".
      final es = '$lastError';
      _transportFallbackReason = es.contains('not active')
          ? 'no direct session to peer'
          : es.contains('timed out')
          ? 'direct probe timed out'
          : 'direct open failed';
      final channel = await _transport.openMediaChannel(
        call.peer.bytes,
        relay: true,
      );
      return (channel: channel, transport: CallTransportKind.relay);
    }
    _transportFallbackReason = null;
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

  Future<void> _loadDevicePreferences() async {
    if (_devicePreferencesLoaded) return;
    _devicePreferencesLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedCameraId = prefs.getString(_cameraPreferenceKey);
      _preferredMicrophoneLabel = prefs.getString(_microphonePreferenceKey);
    } catch (_) {
      // A device preference must never prevent media startup.
    }
  }

  Future<void> _restoreMicrophonePreference(VeilMediaEngine engine) async {
    final preferred = _preferredMicrophoneLabel;
    if (preferred == null || preferred.isEmpty) return;
    final devices = await listMicrophones();
    for (final device in devices) {
      if (device.label != preferred) continue;
      try {
        if (engine.selectAudioInput(device.id)) {
          _selectedMicrophoneId = device.id;
        }
      } catch (_) {}
      return;
    }
  }

  @override
  Future<List<CallMediaDevice>> listCameras() async {
    final engine = _engine;
    if (engine == null) return const [];
    if (Platform.isAndroid) {
      final bridge = _androidNativeCam ?? AndroidNativeCallCamera();
      final devices = await bridge.listDevices();
      final selected =
          _androidNativeCam?.cameraId ??
          _selectedCameraId ??
          devices.where((device) => device.facing == 'front').firstOrNull?.id ??
          devices.firstOrNull?.id;
      return devices
          .map(
            (device) => CallMediaDevice(
              id: device.id,
              label: device.label,
              kind: CallMediaDeviceKind.camera,
              facing: device.facing,
              selected: device.id == selected,
            ),
          )
          .toList(growable: false);
    }
    try {
      return engine
          .listVideoInputs()
          .indexed
          .map(
            (entry) => CallMediaDevice(
              id: entry.$2.id,
              label: entry.$2.label,
              kind: CallMediaDeviceKind.camera,
              facing: entry.$2.facing,
              selected:
                  entry.$2.id == _selectedCameraId ||
                  (_selectedCameraId == null && entry.$1 == 0),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<CallMediaDevice>> listMicrophones() async {
    final engine = _engine;
    if (engine == null) return const [];
    try {
      final List<MediaDevice> devices;
      if (Platform.isAndroid) {
        final raw = await _androidAudioDevices.invokeListMethod<Object?>(
          'listInputs',
        );
        devices = (raw ?? const <Object?>[])
            .whereType<Map<Object?, Object?>>()
            .map(
              (value) => MediaDevice(
                id: value['id']?.toString() ?? '',
                label: value['label']?.toString() ?? '',
                kind: 'input',
              ),
            )
            .where((device) => device.id.isNotEmpty)
            .toList(growable: false);
      } else {
        devices = engine.listAudioInputs();
      }
      return devices.indexed
          .map(
            (entry) => CallMediaDevice(
              id: entry.$2.id,
              label: entry.$2.label,
              kind: CallMediaDeviceKind.microphone,
              selected:
                  entry.$2.id == _selectedMicrophoneId ||
                  (_selectedMicrophoneId == null && entry.$1 == 0),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<CallMediaDevice>> listScreens() async {
    if (!Platform.isMacOS) return const [];
    try {
      return listPlatformScreenInputs().indexed
          .map(
            (entry) => CallMediaDevice(
              id: entry.$2.id,
              label: entry.$2.label,
              kind: screenSourceDeviceKind(entry.$2.kind),
              selected:
                  entry.$2.id == _selectedScreenId ||
                  (_selectedScreenId == null && entry.$1 == 0),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> selectMicrophone(String id) async {
    final engine = _engine;
    if (engine == null) return false;
    final devices = await listMicrophones();
    CallMediaDevice? chosen;
    for (final device in devices) {
      if (device.id == id) chosen = device;
    }
    if (chosen == null) return false;
    try {
      if (!engine.selectAudioInput(id)) return false;
      _selectedMicrophoneId = id;
      _preferredMicrophoneLabel = chosen.label;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_microphonePreferenceKey, chosen.label);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> selectScreen(String id) async {
    final engine = _engine;
    if (engine == null || !Platform.isMacOS) return false;
    final devices = await listScreens();
    if (!devices.any((device) => device.id == id)) return false;
    final previous = _selectedScreenId;
    _selectedScreenId = id;
    if (!_screenSharing) return true;
    try {
      engine.stopScreen();
      final started = engine.startScreen(
        width: _highQualityRoute ? 960 : 640,
        fps: _highQualityRoute ? 15 : 10,
        sourceId: id,
      );
      if (started) return true;
      _selectedScreenId = previous;
      engine.startScreen(
        width: _highQualityRoute ? 960 : 640,
        fps: _highQualityRoute ? 15 : 10,
        sourceId: previous,
      );
      return false;
    } catch (_) {
      _selectedScreenId = previous;
      return false;
    }
  }

  @override
  Future<bool> selectCamera(String id) async {
    final engine = _engine;
    final call = _activeCall;
    if (engine == null || call == null) return false;
    final devices = await listCameras();
    if (!devices.any((device) => device.id == id)) return false;
    _selectedCameraId = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cameraPreferenceKey, id);
    } catch (_) {}
    // A screen share owns the video source; remember the choice and apply it
    // when sharing ends. Likewise an off camera needs no eager hardware open.
    if (call.screenOn || !call.cameraOn) return true;
    if (Platform.isAndroid) {
      final native = _androidNativeCam;
      _androidNativeCam = null;
      if (native != null) await native.stop();
      final fallback = _androidCam;
      _androidCam = null;
      if (fallback != null) await fallback.stop();
      await _startAndroidCam(engine, highQuality: _highQualityRoute);
      return _androidNativeCam?.cameraId == id;
    }
    try {
      engine.stopCamera();
      final profile = _highQualityRoute
          ? _directVideoProfile
          : _anonymousVideoProfile;
      return engine.startCamera(
        width: profile.cameraWidth,
        height: profile.cameraHeight,
        fps: profile.maxFps,
        deviceId: id,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final engine = _engine;
    if (engine == null) return;
    if (Platform.isAndroid) {
      if (enabled) {
        await _startAndroidCam(engine, highQuality: _highQualityRoute);
      } else {
        final nativeCam = _androidNativeCam;
        _androidNativeCam = null;
        if (nativeCam != null) {
          try {
            await nativeCam.stop();
          } catch (_) {}
        }
        final cam = _androidCam;
        _androidCam = null;
        if (cam != null) {
          try {
            await cam.stop();
          } catch (_) {}
        }
        _startFramePump(engine);
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
            deviceId: _selectedCameraId,
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
        _screenSharing = false;
        _startFramePump(engine);
        return true;
      }
      if (_androidScreen != null) return true;
      final cameraWasRunning = _androidNativeCam != null || _androidCam != null;
      final nativeCam = _androidNativeCam;
      _androidNativeCam = null;
      if (nativeCam != null) await nativeCam.stop();
      final cam = _androidCam;
      _androidCam = null;
      if (cam != null) await cam.stop();
      final started = await _startAndroidScreen(engine);
      _screenSharing = started;
      if (started) _startFramePump(engine);
      if (!started && cameraWasRunning) {
        await _startAndroidCam(engine, highQuality: _highQualityRoute);
      }
      return started;
    }
    if (!Platform.isMacOS) return false;
    try {
      if (enabled) {
        final started = engine.startScreen(
          width: _highQualityRoute ? 960 : 640,
          fps: _highQualityRoute ? 15 : 10,
          sourceId: _selectedScreenId,
        );
        _screenSharing = started;
        return started;
      }
      final stopped = engine.stopScreen();
      if (stopped) _screenSharing = false;
      return stopped;
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
      _screenSharing = false;
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
          devLog(() => 'veil-screen: first direct engine push=$pushed');
        }
      } catch (_) {}
    });
    if (!started && _androidScreen == screen) _androidScreen = null;
    return started;
  }

  Future<void> _startAndroidVideoRenderer(VeilMediaEngine engine) async {
    final existing = _androidVideoRenderer;
    if (existing?.isRunning ?? false) return;
    if (existing != null) {
      _androidVideoRenderer = null;
      await existing.stop();
    }
    final renderer = AndroidNativeCallVideoRenderer();
    _androidVideoRenderer = renderer;
    final ok = await renderer.start(engineAddress: engine.nativeAddress);
    if (_engine != engine || _androidVideoRenderer != renderer) {
      if (ok) await renderer.stop();
      return;
    }
    if (!ok) {
      _androidVideoRenderer = null;
      devLog(
        () => 'xVeil[call-media]: native decoded texture failed; RGBA fallback',
      );
      return;
    }
    devLog(() => 'xVeil[call-media]: native decoded texture attached');
  }

  /// Start the Android call camera. Camera2 normally owns preview and pushes
  /// direct buffers into libveil_media; the plugin path remains a bounded
  /// compatibility fallback for devices whose Camera2 session cannot open.
  Future<void> _startAndroidCam(
    VeilMediaEngine engine, {
    required bool highQuality,
  }) async {
    final existingNative = _androidNativeCam;
    if (existingNative?.isRunning ?? false) return;
    if (existingNative != null) {
      _androidNativeCam = null;
      await existingNative.stop();
    }
    if (_androidCam != null) return;
    final profile = highQuality ? _directVideoProfile : _anonymousVideoProfile;
    final nativeCam = AndroidNativeCallCamera();
    _androidNativeCam = nativeCam;
    final nativeOk = await nativeCam.start(
      engineAddress: engine.nativeAddress,
      width: profile.cameraWidth,
      height: profile.cameraHeight,
      fps: profile.maxFps,
      cameraId: _selectedCameraId,
    );
    if (_engine != engine || _androidNativeCam != nativeCam) {
      if (nativeOk) await nativeCam.stop();
      return;
    }
    if (nativeOk) {
      _selectedCameraId = nativeCam.cameraId;
      devLog(
        () =>
            'xVeil[call-media]: native Camera2 started '
            '${profile.cameraWidth}x${profile.cameraHeight}@${profile.maxFps}',
      );
      return;
    }
    _androidNativeCam = null;
    devLog(() => 'xVeil[call-media]: native Camera2 failed; plugin fallback');
    final cam = AndroidCameraCapture(highQuality: highQuality);
    _androidCam = cam;
    final ok = await cam.startAndroid420((
      y,
      u,
      v,
      w,
      h,
      yStride,
      uStride,
      vStride,
      uvPixelStride,
      rotation,
    ) {
      if (_engine != engine) return false;
      try {
        return engine.pushAndroid420Frame(
          y,
          u,
          v,
          w,
          h,
          yStride: yStride,
          uStride: uStride,
          vStride: vStride,
          uvPixelStride: uvPixelStride,
          rotation: rotation,
        );
      } catch (_) {
        return false;
      }
    });
    if (!ok) {
      _androidCam = null;
    } else {
      _startFramePump(engine);
    }
  }
}
