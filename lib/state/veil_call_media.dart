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
import '../core/ids.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'android_call_foreground.dart';
import 'android_camera_capture.dart';
import 'android_native_call_camera.dart';
import 'android_native_call_video.dart';
import 'android_screen_capture.dart';
import 'call_bitrate_adapter.dart';
import 'call_video_profile.dart';
import 'call_audio_receive_activity.dart';
import 'call_audio_source_pressure.dart';
import 'call_microphone_state.dart';
import 'call_camera_state.dart';
import 'desktop_screen_capture_start.dart';
import 'call_peer_audio_playout.dart';
import 'call_peer_audio_recovery.dart';
import 'call_video_prompt.dart';
import 'call_audio_route.dart';
import 'call_media_route_operations.dart';
import 'call_route_delivery_observer.dart';
import 'call_audio_mirror_lease.dart';
import 'call_service.dart';
import 'mac_media_permissions.dart';
import 'media_ffi.dart';

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

/// Exercise the existing route rebuild on a physical debug stand.
Future<bool> repairActiveCallMediaForDiagnostics() async =>
    await _diagnosticMediaController?.repairRoute() ?? false;

/// Compare pinned direct/relay delivery while retaining the live audio engine.
Future<Map<String, Object?>> observeActiveCallRoutesForDiagnostics({
  int samples = 20,
}) async =>
    await _diagnosticMediaController?._observeRoutesForDiagnostics(samples) ??
    {'ok': false, 'reason': 'no_media'};

Future<Map<String, Object?>> mirrorActiveCallAudioForDiagnostics({
  required bool enabled,
  int seconds = 30,
}) async =>
    await _diagnosticMediaController?._mirrorAudioForDiagnostics(
      enabled,
      seconds,
    ) ??
    {'ok': false, 'reason': 'no_media'};

/// Latest local camera frame for the active video call (RGBA), or null. Used by
/// the draggable self-preview tile.
final ValueNotifier<VeilVideoFrame?> localVideoFrame =
    ValueNotifier<VeilVideoFrame?>(null);

const _directVideoProfile = directCallVideoProfile;
const _anonymousVideoProfile = anonymousCallVideoProfile;

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

/// Derive the two directional call-media keys from E2E-authenticated offer and
/// answer contributions. The ordering is call-role based, while TX/RX is
/// node-direction based, so both endpoints independently obtain opposite keys.
///
/// ROUTE-NEUTRAL by construction. These are not "relay" keys: direct, relay and
/// onion all seal every cell with them, so there is no route on which the seal
/// is optional and no unsealed mode left to fall back to. Consequently there is
/// no peer-protocol-version gate here either — that version arrives inside an
/// UNAUTHENTICATED signal field, and any behaviour keyed off it is a lever an
/// attacker can pull to turn the seal off.
///
/// Throws rather than returning null: a caller holding no keys must not reach
/// an open, and an absent return value is exactly the shape that used to let it.
@visibleForTesting
({Uint8List txKey, Uint8List rxKey}) deriveCallMediaKeys({
  required Call call,
  required Uint8List localNodeId,
}) {
  if (localNodeId.length != 32) {
    throw ArgumentError('localNodeId must be 32 bytes');
  }
  final localContribution = decodeCallMediaKeyContribution(call.localMediaKey);
  final peerContribution = decodeCallMediaKeyContribution(call.peerMediaKey);
  if (localContribution == null || peerContribution == null) {
    localContribution?.fillRange(0, localContribution.length, 0);
    peerContribution?.fillRange(0, peerContribution.length, 0);
    throw StateError(
      'call ${call.callId} carries no end-to-end media key material',
    );
  }
  final localIsCaller = call.direction == CallDirection.outgoing;
  final callerContribution = localIsCaller
      ? localContribution
      : peerContribution;
  final calleeContribution = localIsCaller
      ? peerContribution
      : localContribution;
  final peerIdentity = call.mediaIdentity.bytes;
  final callerNode = localIsCaller ? localNodeId : peerIdentity;
  final calleeNode = localIsCaller ? peerIdentity : localNodeId;
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
      txKey: directionKey(localNodeId, peerIdentity),
      rxKey: directionKey(peerIdentity, localNodeId),
    );
  } finally {
    localContribution.fillRange(0, localContribution.length, 0);
    peerContribution.fillRange(0, peerContribution.length, 0);
    master?.fillRange(0, master.length, 0);
  }
}

/// Relay envelopes name the physical device even when P-Net is admitted.
/// Only direct session media is received under the authenticated identity.
@visibleForTesting
NodeId callMediaRoutePeer(Call call, {required bool sessionAdmitted}) {
  if (call.transport == CallTransportKind.onion) return call.mediaPeer;
  if (call.transport == CallTransportKind.p2p && sessionAdmitted) {
    return call.mediaIdentity;
  }
  return call.peerDevice ?? call.peer;
}

/// Open the media datagram channel for the route [call] negotiated, sealing it
/// with the already-derived directional keys.
///
/// Every branch passes the same [txKey]/[rxKey] because every transport carries
/// the same sealed cell — direct and onion are not "already protected": a
/// direct session is hop-to-hop, and an onion media cell must be READ by the
/// relay that splices the two circuits in order to route it.
///
/// [fallbackReason] is non-null only for the one permitted mid-open fallback,
/// negotiated P2P → non-onion relay, and answers "why not p2p?" for the
/// transport badge.
///
/// PRIVATE on purpose: [openSealedCallMediaChannel] is the only entry point, so
/// no caller can acquire a shortcut that reaches an open without deriving the
/// keys first.
Future<
  ({
    int channel,
    NodeId peer,
    CallTransportKind transport,
    String? fallbackReason,
  })
>
_openCallMediaChannel({
  required Call call,
  required CallMediaChannelOpener opener,
  required Uint8List txKey,
  required Uint8List rxKey,
  Duration directRetryDelay = const Duration(milliseconds: 300),
  Future<NodeId> Function()? resolveDirectPeerOnRetry,
}) async {
  if (call.transport == CallTransportKind.p2p) {
    var directPeer = call.mediaPeer;
    // A cold negotiated session may register just after a not-active reply;
    // an admission probe can also lose its budget to a mutex/rate-limit stall.
    // Give either case one short retry. Every open still requires native
    // admission; this cannot authorize a device or create a direct session.
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0 && resolveDirectPeerOnRetry != null) {
          // Recheck the particular answering device. Another device's admitted
          // identity session must not select its endpoint for this call.
          directPeer = await resolveDirectPeerOnRetry().timeout(
            const Duration(milliseconds: 300),
            onTimeout: () => throw StateError('direct session probe timed out'),
          );
        }
        final channel = await opener.openMediaChannel(
          directPeer.bytes,
          txKey: txKey,
          rxKey: rxKey,
          direct: true,
        );
        return (
          channel: channel,
          peer: directPeer,
          transport: CallTransportKind.p2p,
          fallbackReason: null,
        );
      } catch (e) {
        lastError = e;
        devLog(
          () =>
              'xVeil[call-media]: direct open attempt ${attempt + 1} failed '
              'for ${call.peer.short}: $e',
        );
        final error = '$e';
        final transient =
            error.contains('timed out') ||
            error.contains('probe failed') ||
            (error.contains('direct') && error.contains('not active'));
        if (!transient || attempt == 1) break;
        await Future<void>.delayed(directRetryDelay);
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
    final channel = await opener.openMediaChannel(
      (call.peerDevice ?? call.peer).bytes,
      txKey: txKey,
      rxKey: rxKey,
      relay: true,
    );
    return (
      channel: channel,
      peer: call.peerDevice ?? call.peer,
      transport: CallTransportKind.relay,
      fallbackReason: es.contains('not active')
          ? 'no direct session to peer'
          : es.contains('timed out')
          ? 'direct probe timed out'
          : 'direct open failed',
    );
  }
  if (call.transport == CallTransportKind.relay) {
    final channel = await opener.openMediaChannel(
      (call.peerDevice ?? call.peer).bytes,
      txKey: txKey,
      rxKey: rxKey,
      relay: true,
    );
    return (
      channel: channel,
      peer: call.peerDevice ?? call.peer,
      transport: CallTransportKind.relay,
      fallbackReason: null,
    );
  }
  if (call.transport != CallTransportKind.onion) {
    throw StateError(
      'negotiated ${call.transport?.name ?? 'unset'} media has no implemented route',
    );
  }
  final channel = await opener.openMediaChannel(
    call.mediaPeer.bytes,
    txKey: txKey,
    rxKey: rxKey,
  );
  return (
    channel: channel,
    peer: call.mediaPeer,
    transport: CallTransportKind.onion,
    fallbackReason: null,
  );
}

/// Derive the call's directional keys and open the negotiated route with them,
/// or open NOTHING and return null when the call carries no key material.
///
/// The derive and the open are one step on purpose. Keeping them apart is what
/// used to allow "no keys → open anyway, unsealed"; here the keys are produced
/// immediately before the open that requires them, the Dart copies are wiped
/// straight after, and there is no branch in which [opener] is reached without
/// them.
@visibleForTesting
Future<
  ({
    int channel,
    NodeId peer,
    CallTransportKind transport,
    String? fallbackReason,
  })?
>
openSealedCallMediaChannel({
  required Call call,
  required CallMediaChannelOpener opener,
  required Uint8List localNodeId,
  Duration directRetryDelay = const Duration(milliseconds: 300),
  Future<NodeId> Function()? resolveDirectPeerOnRetry,
}) async {
  final ({Uint8List txKey, Uint8List rxKey}) keys;
  try {
    keys = deriveCallMediaKeys(call: call, localNodeId: localNodeId);
  } catch (error) {
    devLog(
      () =>
          'xVeil[call-media]: refusing to open an unsealable channel to '
          '${call.peer.short}: $error',
    );
    return null;
  }
  try {
    return await _openCallMediaChannel(
      call: call,
      opener: opener,
      txKey: keys.txKey,
      rxKey: keys.rxKey,
      directRetryDelay: directRetryDelay,
      resolveDirectPeerOnRetry: resolveDirectPeerOnRetry,
    );
  } finally {
    keys.txKey.fillRange(0, keys.txKey.length, 0);
    keys.rxKey.fillRange(0, keys.rxKey.length, 0);
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

  // Sealing remains unconditional v3 behavior. v5 also needs native accepted
  // audio counters and playout estimates from the independent feedback ABI.
  @override
  int get signalProtocolVersion =>
      VeilMediaEngine.supportsIndependentTransportFeedback
      ? (_transport.supportsCallControl
            ? kCallSignalProtocolVersion
            : kCallCompactHealthMinVersion - 1)
      : kCallIndependentTransportFeedbackMinVersion - 1;

  final VeilFlutterTransport _transport;
  final _peerHealth = StreamController<CallSignal>.broadcast();
  Timer? _controlPollTimer;

  @override
  Stream<CallSignal> get peerHealth => _peerHealth.stream;

  @override
  bool get canReceiveEphemeralHealth =>
      _engine != null && _chan != null && _transport.hasCallControl(_chan!);

  @override
  bool sendEphemeralHealth(CallSignal signal) {
    final call = _activeCall;
    final channel = _chan;
    final lastRx = _lastRxAt;
    if (call == null ||
        channel == null ||
        signal.callId != call.callId ||
        signal.type != CallSignalType.health ||
        signal.onBehalfOf != null ||
        signal.mediaRepairRequested ||
        (call.peerProtocolVersion ?? 1) < kCallCompactHealthMinVersion ||
        _chanTransport == CallTransportKind.onion ||
        _routeRepairing ||
        lastRx == null ||
        DateTime.now().difference(lastRx) >= kCallMediaRepairAfter) {
      return false;
    }
    return _transport.sendCallControl(
      channel,
      Uint8List.fromList(utf8.encode(signal.encode())),
    );
  }

  void _startControlPolling() {
    _controlPollTimer?.cancel();
    if (!_transport.supportsCallControl) return;
    _controlPollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final call = _activeCall;
      if (call == null ||
          (call.peerProtocolVersion ?? 1) < kCallCompactHealthMinVersion) {
        return;
      }
      // Older receive bindings remain valid through a make-before-break
      // handover. Replay protection is shared by their call-key ciphers.
      final channels = <int>{
        ?_chan,
        ..._retiringChannels.keys,
        ..._receiveOnlyChannels.values,
      };
      for (final channel in channels) {
        for (final bytes in _transport.pollCallControl(channel)) {
          CallSignal? signal;
          try {
            signal = CallSignal.tryDecode(utf8.decode(bytes));
          } catch (_) {}
          if (signal != null &&
              signal.callId == call.callId &&
              signal.type == CallSignalType.health &&
              signal.onBehalfOf == null &&
              signal.mediaKey == null &&
              signal.reason == null &&
              signal.protocolVersion >= kCallCompactHealthMinVersion) {
            _peerHealth.add(signal);
          }
        }
      }
    });
  }

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
  static String get _speakerPreferenceKey =>
      'call.playout.speaker.${Platform.operatingSystem}';
  final _microphoneState = CallMicrophoneState();
  final _cameraState = CallCameraState();
  VeilMediaEngine? _engine;
  int? _chan;
  String? _chanPeer; // hex of the peer _chan was opened for
  CallTransportKind? _chanTransport;
  bool _handoverPacketSizeReady = false;
  final Map<int, Timer> _retiringChannels = {};
  // Incoming and outgoing routes are independent. Keep one authenticated
  // receive binding per older physical peer until that peer is replaced or
  // the call ends, even when our outgoing route has already changed.
  final Map<String, int> _receiveOnlyChannels = {};
  final _routeDeliveryObserver = CallRouteDeliveryObserver();
  final _audioMirrorLease = CallAudioMirrorLease();
  final Set<int> _diagnosticRouteChannels = {};
  int _routeHandovers = 0;
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
  final _audioReceiveActivity = CallAudioReceiveActivity();
  CallPeerAudioPlayout _peerAudioPlayout = CallPeerAudioPlayout();
  CallPeerAudioRecovery _peerAudioRecovery = CallPeerAudioRecovery();
  final _sourcePressure = CallAudioSourcePressure();
  bool _sourceFeedbackPending = false;
  int _sourceFeedbackQueued = 0;
  int _sourceFeedbackSkipped = 0;
  bool? _sourcePressured;
  bool _peerAudioCaptureEnabled = true;
  DateTime? _receiveSessionStartedAt;
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
  final _routeOperations = CallMediaRouteOperations();
  bool get _routeRepairing => _routeOperations.busy;
  bool _androidCallNetworkActive = false;
  int _mediaEpoch = 0;
  bool _devicePreferencesLoaded = false;
  String? _selectedCameraId;
  String? _selectedMicrophoneId;
  String? _selectedScreenId;
  String? _preferredMicrophoneLabel;
  String? _selectedSpeakerId;
  String? _preferredSpeakerLabel;
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
  ({int bitrateKbps, double fps})? _diagnosticVideoTarget;

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
        : (bitrateKbps: bitrateKbps, fps: fps.toDouble());
    final ok = engine.setVideoBitrate(
      maxBitrateKbps: target.bitrateKbps,
      maxFps: target.fps,
    );
    if (ok) {
      adapter.invalidateAppliedTarget();
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
  bool get hasAudioReceiveTelemetry => _audioReceiveActivity.supported;

  @override
  DateTime? get lastAudioRxAt => _audioReceiveActivity.lastRxAt;

  @override
  Future<DateTime?> readLatestAudioRxAt() async {
    final engine = _engine;
    if (engine == null || _routeRepairing) return null;
    final stats = engine.getStats();
    return CallAudioReceiveActivity.nativeLastRxAt(stats, DateTime.now());
  }

  @override
  DateTime? get receiveSessionStartedAt => _receiveSessionStartedAt;

  @override
  bool get isRepairingReceiveSession => _routeRepairing;

  @override
  CallAudioPlayoutFeedback? get audioPlayoutFeedback =>
      _engine == null ||
          _routeRepairing ||
          signalProtocolVersion < kCallAudioPlayoutFeedbackMinVersion
      ? null
      : _audioReceiveActivity.outgoingPlayoutFeedback(DateTime.now());

  @override
  void observePeerAudioPlayout(CallAudioPlayoutFeedback feedback) {
    _peerAudioPlayout.observe(feedback, DateTime.now());
  }

  @override
  void observePeerAudioCapture(bool enabled) {
    _peerAudioCaptureEnabled = enabled;
  }

  @override
  Map<String, Object?> get diagnostics {
    final engine = _engine;
    if (engine == null) {
      return {
        'transport': _chanTransport?.name,
        'running': false,
        'media_repairing': _routeRepairing,
      };
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
      final engineStats = engine.getStats();
      final nativeAudioAge = engineStats['audio_rx_native_age_ms'];
      return {
        'transport': _chanTransport?.name,
        'running': true,
        'media_epoch': _mediaEpoch,
        'route_handovers': _routeHandovers,
        'receive_only_channels': _receiveOnlyChannels.length,
        'media_repairing': _routeRepairing,
        'audio_rx_supported': _audioReceiveActivity.supported,
        'peer_audio_playout_ms': _peerAudioPlayout.delayMs(DateTime.now()),
        'peer_audio_buffer_growing': _peerAudioPlayout.bufferGrowing(
          DateTime.now(),
        ),
        'local_source_pressured': _sourcePressured,
        'video_audio_buffer_pressure': _bitrateAdapter?.audioBufferPressure,
        'audio_adaptation': _bitrateAdapter?.bufferDiagnostics,
        'local_source_feedback_queued': _sourceFeedbackQueued,
        'local_source_feedback_skipped': _sourceFeedbackSkipped,
        'audio_rx_age_ms': engineStats.containsKey('audio_rx_native_age_ms')
            ? (engineStats['worker_stalled'] == 0 &&
                      nativeAudioAge is num &&
                      nativeAudioAge >= 0
                  ? nativeAudioAge
                  : null)
            : _audioReceiveActivity.lastRxAt == null
            ? null
            : DateTime.now()
                  .difference(_audioReceiveActivity.lastRxAt!)
                  .inMilliseconds,
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
        'video_paused_for_audio': callVideoSendPausedForAudio.value,
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
        ...engineStats,
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
      return _rebuildLocalSession();
    }
    final rc = _transport.repairMediaChannel(ch);
    devLog(
      () =>
          'xVeil[call-media]: end-to-end silence route repair '
          'channel=$ch result=$rc',
    );
    return rc == 0;
  }

  Future<bool> _rebuildLocalSession() async {
    if (_routeRepairing) return true;
    final active = _activeCall;
    final transport = _chanTransport;
    if (active == null || transport == null) return false;
    final call = active.copyWith(transport: transport);
    return _routeOperations.runForCall(
      call.callId,
      () => _activeCall?.callId,
      () async {
        try {
          // Rebuild local audio/engine wiring even for onion. Refreshing only the
          // outbound circuit cannot unblock a stalled local receive worker.
          await _stopSession(clearActiveCall: false);
          if (_activeCall?.callId != call.callId) return false;
          final ok = await start(_activeCall!.copyWith(transport: transport));
          _lastRepairAt = DateTime.now();
          devLog(
            () =>
                'xVeil[call-media]: local ${transport.name} session rebuilt '
                'call=${call.callId} ok=$ok',
          );
          // start() can restore the explicitly permitted relay after direct
          // admission disappears. The FSM checks the actual route and announces
          // that downgrade; reporting false here kills the restored live channel.
          return ok && activeTransport != null;
        } catch (error) {
          devLog(
            () => 'xVeil[call-media]: local session rebuild failed: $error',
          );
          return false;
        }
      },
    );
  }

  @override
  Future<bool> switchRoute(CallTransportKind transport) async {
    final call = _activeCall;
    if (call == null ||
        (transport != CallTransportKind.relay &&
            transport != CallTransportKind.p2p)) {
      return false;
    }
    // A peer can announce relay while a health-triggered repair is awaiting
    // camera teardown. Queue behind it instead of returning a fatal failure.
    return _routeOperations.runForCall(
      call.callId,
      () => _activeCall?.callId,
      () async {
        if (activeTransport == transport) return true;
        final engine = _engine;
        if (engine != null &&
            engine.supportsChannelRebind &&
            _handoverPacketSizeReady &&
            (activeTransport == CallTransportKind.relay ||
                activeTransport == CallTransportKind.p2p)) {
          return _switchRoutePreservingEngine(call, transport, engine);
        }
        if (engine != null &&
            (activeTransport == CallTransportKind.p2p ||
                activeTransport == CallTransportKind.relay)) {
          // An older engine cannot preserve its sender while a candidate is
          // verified. Keep the live session instead of tearing it down for a
          // replacement whose delivery has not been observed.
          return false;
        }
        await _stopSession(clearActiveCall: false);
        if (_activeCall?.callId != call.callId) return false;
        final ok = await start(_activeCall!.copyWith(transport: transport));
        return ok && activeTransport == transport;
      },
    );
  }

  Future<bool> _switchRoutePreservingEngine(
    Call call,
    CallTransportKind target,
    VeilMediaEngine engine,
  ) async {
    final previous = _chan;
    final previousPeer = _chanPeer;
    final epoch = _mediaEpoch;
    if (previous == null || previousPeer == null) return false;
    int? candidate;
    var committed = false;
    try {
      var next = _activeCall!.copyWith(transport: target);
      final device = next.peerDevice;
      if (device != null && device != next.mediaIdentity) {
        final admitted =
            target == CallTransportKind.p2p &&
            (await _transport
                    .peerPnetStatus(device.bytes)
                    .timeout(const Duration(seconds: 2)))
                .admitted;
        next = next.copyWith(
          mediaRoutePeer: callMediaRoutePeer(next, sessionAdmitted: admitted),
        );
      }
      final opened = await openSealedCallMediaChannel(
        call: next,
        opener: _transport,
        localNodeId: (await _transport.peerFacingNodeId()).bytes,
        resolveDirectPeerOnRetry: () async {
          final admitted = (await _transport.peerPnetStatus(
            (next.peerDevice ?? next.peer).bytes,
          )).admitted;
          return callMediaRoutePeer(next, sessionAdmitted: admitted);
        },
      );
      if (opened == null) return false;
      candidate = opened.channel;
      // Keep the old sender/receiver alive until the candidate has carried a
      // sealed peer echo in both directions. Local open/admission is not a
      // delivery observation. The echo's route stays inside the call AEAD.
      if (!await _configureRouteProbes(candidate, next, opened.transport) ||
          !await _transport.qualifyMediaRoute(candidate)) {
        devLog(() => 'xVeil[call-media]: candidate delivery unconfirmed');
        return false;
      }
      final current = _activeCall;
      if (_engine != engine ||
          epoch != _mediaEpoch ||
          current?.callId != call.callId ||
          current?.mediaIdentity != next.mediaIdentity ||
          current?.peerDevice != next.peerDevice ||
          opened.transport != target) {
        return false;
      }
      final relay = target == CallTransportKind.relay;
      if (relay &&
          _transport.setRelayMediaBatching(candidate, true, compact: true) !=
              0) {
        return false;
      }
      final keepReceiver = engine.supportsReceiveChannelOverlap;
      _audioMirrorLease.stop();
      if (!engine.rebindChannel(
        candidate,
        retainPreviousReceiver: keepReceiver,
      )) {
        return false;
      }
      committed = true;
      // Nothing below awaits: hangup cannot interleave between native commit
      // and host ownership. Keep the latest camera/mic/screen intent and all
      // receive counters, ADM, codec and playout state in the current engine.
      _chan = candidate;
      _chanPeer = opened.peer.hex;
      _chanTransport = target;
      _activeCall = current!.copyWith(
        transport: target,
        mediaRoutePeer: opened.peer,
      );
      _transportFallbackReason = opened.fallbackReason;
      _mediaBatching = relay;
      _compactRelayMedia = relay;
      _routeHandovers++;
      _lastNativeRxCount = 0;
      _engineRxStalledSince = null;
      if (keepReceiver) {
        final replaced = _receiveOnlyChannels.remove(opened.peer.hex);
        if (replaced != null) _retireReceiveChannel(engine, replaced);
        if (previousPeer != opened.peer.hex) {
          _receiveOnlyChannels[previousPeer] = previous;
        } else {
          _retireReceiveChannel(engine, previous);
        }
      } else {
        // Compatibility for older engines without inbound overlap. Already
        // queued packets retain their existing 200-ms local deadline.
        _retiringChannels[previous] = Timer(
          const Duration(milliseconds: 200),
          () {
            _retiringChannels.remove(previous);
            try {
              _transport.closeMediaChannel(previous);
            } catch (_) {}
          },
        );
      }
      devLog(
        () => 'xVeil[call-media]: route handover ${target.name} kept engine',
      );
      return true;
    } catch (error) {
      devLog(() => 'xVeil[call-media]: route handover failed: $error');
      return false;
    } finally {
      if (!committed && candidate != null) {
        _transport.closeMediaChannel(candidate);
      }
    }
  }

  Future<bool> _configureRouteProbes(
    int channel,
    Call call,
    CallTransportKind transport,
  ) {
    if (transport == CallTransportKind.onion ||
        call.localPosture != CallPosture.direct ||
        call.peerPosture != CallPosture.direct) {
      return Future.value(false);
    }
    return _transport.configureMediaRouteProbes(
      channel,
      directPeer: call.mediaIdentity,
      relayPeer: call.peerDevice ?? call.peer,
    );
  }

  Future<Map<String, Object?>> _mirrorAudioForDiagnostics(
    bool enabled,
    int seconds,
  ) async {
    if (!enabled) {
      _audioMirrorLease.stop();
      return {'ok': true, 'enabled': false};
    }
    final call = _activeCall;
    final channel = _chan;
    final engine = _engine;
    final epoch = _mediaEpoch;
    if (call == null ||
        channel == null ||
        engine == null ||
        !engine.supportsAudioMirror ||
        !call.media.audio ||
        _chanTransport != CallTransportKind.p2p ||
        call.localPosture != CallPosture.direct ||
        call.peerPosture != CallPosture.direct) {
      return {'ok': false, 'reason': 'requires_supported_direct_audio_call'};
    }
    bool owned() =>
        _activeCall?.callId == call.callId &&
        _engine == engine &&
        _mediaEpoch == epoch &&
        _chan == channel &&
        _chanTransport == CallTransportKind.p2p;
    void close(int candidate) {
      if (_diagnosticRouteChannels.remove(candidate)) {
        try {
          _transport.closeMediaChannel(candidate);
        } catch (_) {}
      }
    }

    return _audioMirrorLease.start(
      duration: Duration(seconds: seconds),
      stillOwned: owned,
      qualify: _transport.qualifyMediaRoute,
      bind: engine.setAudioMirrorChannel,
      close: close,
      openAlternate: () async {
        final next = call.copyWith(transport: CallTransportKind.relay);
        final opened = await openSealedCallMediaChannel(
          call: next,
          opener: _transport,
          localNodeId: (await _transport.peerFacingNodeId()).bytes,
        );
        if (opened == null) return null;
        final candidate = opened.channel;
        _diagnosticRouteChannels.add(candidate);
        try {
          if (owned() &&
              opened.transport == CallTransportKind.relay &&
              _transport.setRelayMediaBatching(
                    candidate,
                    true,
                    compact: true,
                  ) ==
                  0 &&
              await _configureRouteProbes(candidate, next, opened.transport) &&
              owned()) {
            return candidate;
          }
        } catch (_) {
          close(candidate);
          rethrow;
        }
        close(candidate);
        return null;
      },
    );
  }

  Future<Map<String, Object?>> _observeRoutesForDiagnostics(int samples) async {
    final call = _activeCall;
    final channel = _chan;
    final engine = _engine;
    final epoch = _mediaEpoch;
    // Only observe relay as an alternative to an already consented direct
    // call. Never use this hook to open a new P2P route or expose onion calls.
    if (call == null ||
        channel == null ||
        engine == null ||
        !call.media.audio ||
        _chanTransport != CallTransportKind.p2p ||
        call.localPosture != CallPosture.direct ||
        call.peerPosture != CallPosture.direct) {
      return {'ok': false, 'reason': 'requires_direct_audio_call'};
    }
    bool owned() =>
        _activeCall?.callId == call.callId &&
        _engine == engine &&
        _mediaEpoch == epoch &&
        _chan == channel &&
        _chanTransport == CallTransportKind.p2p;
    void close(int candidate) {
      if (!_diagnosticRouteChannels.remove(candidate)) return;
      try {
        _transport.closeMediaChannel(candidate);
      } catch (_) {}
    }

    final result = await _routeDeliveryObserver.observe(
      currentChannel: channel,
      stillOwned: owned,
      samples: samples,
      qualify: _transport.qualifyMediaRoute,
      closeAlternate: close,
      openAlternate: () async {
        int? candidate;
        var accepted = false;
        try {
          final next = call.copyWith(transport: CallTransportKind.relay);
          final opened = await openSealedCallMediaChannel(
            call: next,
            opener: _transport,
            localNodeId: (await _transport.peerFacingNodeId()).bytes,
          );
          if (opened == null) return null;
          candidate = opened.channel;
          _diagnosticRouteChannels.add(candidate);
          if (!owned() || opened.transport != CallTransportKind.relay) {
            return null;
          }
          if (!await _configureRouteProbes(candidate, next, opened.transport) ||
              !owned()) {
            return null;
          }
          accepted = true;
          return candidate;
        } finally {
          if (!accepted && candidate != null) close(candidate);
        }
      },
    );
    return {...result, 'current_route': 'p2p', 'alternate_route': 'relay'};
  }

  void _retireReceiveChannel(VeilMediaEngine engine, int channel) {
    try {
      engine.releaseReceiveChannel(channel);
    } catch (_) {}
    // Keep already-admitted outgoing packets within their original local
    // deadline, even when the older receive binding has been superseded.
    _retiringChannels[channel] = Timer(const Duration(milliseconds: 200), () {
      _retiringChannels.remove(channel);
      try {
        _transport.closeMediaChannel(channel);
      } catch (_) {}
    });
  }

  void _closeReceiveOnlyChannel(VeilMediaEngine engine, int channel) {
    try {
      engine.releaseReceiveChannel(channel);
    } catch (_) {}
    try {
      _transport.closeMediaChannel(channel);
    } catch (_) {}
  }

  @override
  Stream<void> get screenShareStopped => _screenShareStops.stream;

  // Both of these reach the engine, and both are read from the call overlay's
  // build/tap paths — OUTSIDE the blanket catch that wraps _startMedia. On a
  // build with no engine they were an uncaught throw from a widget. No engine
  // means no screen to capture, so the honest answer is "not granted".
  @override
  bool get screenCaptureAccessGranted =>
      !Platform.isMacOS ||
      (VeilMediaNative.guard(() => platformScreenCaptureAccessGranted) ??
          false);

  @override
  bool requestScreenCaptureAccess() =>
      !Platform.isMacOS ||
      (VeilMediaNative.guard(requestPlatformScreenCaptureAccess) ?? false);

  @override
  Future<bool> isDirectPeerAdmitted(Call call) async =>
      await currentDirectPeerAdmission(call) ?? false;

  @override
  Future<bool?> currentDirectPeerAdmission(Call call) async {
    try {
      final peer = call.peerDevice ?? call.peer;
      final session = await _transport
          .peerPnetStatus(peer.bytes)
          .timeout(const Duration(seconds: 2));
      return session.admitted;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> start(Call call) async {
    if (!_microphoneState.belongsToCall(call.callId)) {
      _bitrateAdapter = null;
      _peerAudioPlayout = CallPeerAudioPlayout();
      _peerAudioRecovery = CallPeerAudioRecovery();
      _sourceFeedbackQueued = 0;
      _sourceFeedbackSkipped = 0;
      _sourcePressured = null;
      _peerAudioCaptureEnabled = call.peerCapture?.audio ?? call.media.audio;
    }
    _microphoneState.beginCall(call.callId, micOn: call.micOn);
    _cameraState.beginCall(call.callId, enabled: call.cameraOn);
    final device = call.peerDevice;
    if (device != null && device != call.mediaIdentity) {
      // Select the receive address from the actual route. An admitted session
      // does not change the physical source of a presealed relay envelope.
      try {
        final admitted =
            call.transport == CallTransportKind.p2p &&
            (await _transport.peerPnetStatus(device.bytes)).admitted;
        call = call.copyWith(
          mediaRoutePeer: callMediaRoutePeer(call, sessionAdmitted: admitted),
        );
      } catch (e) {
        devLog(() => 'xVeil[call-media]: route status unavailable: $e');
        call = call.copyWith(mediaRoutePeer: device);
      }
    }
    devLog(
      () =>
          'xVeil[call-media]: controller start platform=${Platform.operatingSystem}',
    );
    // Never open a route while the call is only ringing: the final route is
    // known only after both peers have applied their consent policy. Reuse is
    // therefore limited to this controller's already-finalized call lifecycle.
    if (!_microphoneState.belongsToCall(call.callId)) return false;
    if (_engine != null || (_chan != null && _chanPeer != call.mediaPeer.hex)) {
      await _stopSession(
        clearActiveCall: _activeCall?.callId != call.callId,
        clearMicrophoneState: false,
      );
    }
    if (!_microphoneState.belongsToCall(call.callId)) return false;
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
    // The address the PEER knows us by, not this device's transport id. Both
    // ends hash (caller, callee) into the call-media master key, and the peer
    // can only put our IDENTITY there — a contact, an invite and a certificate
    // all carry that one. Asking the transport for its own node id made the two
    // ends hash different pairs on any device whose identity is not its own
    // key, and every sealed cell then arrived and failed to open.
    final localId = (await _transport.peerFacingNodeId()).bytes;
    final peerId = call.mediaIdentity.bytes;
    // Open only the route finalized by call negotiation.
    final int chan;
    final CallTransportKind transport;
    if (_chan != null && _chanPeer == call.mediaPeer.hex) {
      chan = _chan!;
      transport = _chanTransport!;
    } else {
      // Keys BEFORE the open, on every route: they are required parameters of
      // the open itself, so a call whose material cannot be derived never gets
      // a channel at all rather than getting an unsealed one. A route rebuild
      // re-derives the SAME pair from the same call, which is what lets the
      // native replay window outlive the channel.
      final opened = await openSealedCallMediaChannel(
        call: call,
        opener: _transport,
        localNodeId: localId,
        resolveDirectPeerOnRetry: () async {
          final admitted = (await _transport.peerPnetStatus(
            (call.peerDevice ?? call.peer).bytes,
          )).admitted;
          return callMediaRoutePeer(call, sessionAdmitted: admitted);
        },
      );
      if (opened == null) return false;
      _transportFallbackReason = opened.fallbackReason;
      chan = opened.channel;
      transport = opened.transport;
      // A failed direct open can fall back to a physical relay peer. Keep
      // channel reuse, receive counters and repairs on that actual address.
      call = call.copyWith(mediaRoutePeer: opened.peer);
    }
    if (epoch != _mediaEpoch || _activeCall?.callId != call.callId) {
      _transport.closeMediaChannel(chan);
      return false;
    }
    if (transport != CallTransportKind.onion &&
        !await _configureRouteProbes(chan, call, transport)) {
      _transport.closeMediaChannel(chan);
      return false;
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
    _chanPeer = call.mediaPeer.hex;
    _chanTransport = transport;
    // A negotiated P2P open may have taken the explicitly permitted non-onion
    // relay fallback. Keep subsequent repair/switch operations anchored to the
    // route that is actually carrying this call, not the stale proposal.
    // Screen-off during an asynchronous route open also retires the retained
    // projection. Do not restore the snapshot taken before that user action.
    final latestCall = _activeCall;
    if (latestCall != null && latestCall.callId == call.callId) {
      call = call.copyWith(
        screenOn: latestCall.screenOn,
        media: call.media.copyWith(screen: latestCall.media.screen),
      );
    }
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
    final feedback = useIndependentCallTransportFeedback(
      call.peerProtocolVersion,
      nativeSupportsFeedback:
          VeilMediaEngine.supportsIndependentTransportFeedback,
    );
    if (!engine.setIndependentTransportFeedback(feedback)) {
      engine.dispose();
      _transport.closeMediaChannel(chan);
      _chan = null;
      _chanPeer = null;
      return false;
    }
    if (feedback && highQuality) {
      // Direct QUIC AppRtData framing: media seal 36 + authenticated app header
      // 89 + OVL 24 + session seal 40 + opaque flow 20. RTP is separate. This
      // hint excludes QUIC/IP; endpoint control headroom is reserved natively.
      // This shared hint stays fixed across handover. Delivery/Forward and
      // ordered carriers have different costs; replacing it requires a model
      // that accounts for the actual route and batching, not just RTP bytes.
      final adaptive = engine.setAudioPacketOverhead(209);
      devLog(() => 'xVeil[call-media]: adaptive audio packets=$adaptive');
    }
    // Batching is now purely a wire format: the batch header rides inside the
    // channel seal, which every route already carries, so the compact envelope
    // is always available and there is no older envelope to fall back to. The
    // packet ceiling stays a quality knob — 1000-byte RTP packets keep a sealed
    // cell inside one QUIC DATAGRAM instead of fragmenting video.
    _mediaBatching = false;
    _compactRelayMedia = false;
    // Both non-onion routes can use the same fixed packet ceiling, allowing a
    // live handover after codec configuration has frozen without recreating it.
    _handoverPacketSizeReady =
        transport != CallTransportKind.onion &&
        engine.setMaxRtpPacketSize(_compactRelayRtpPacketSize);
    if (transport == CallTransportKind.relay) {
      final packetSizeOk = _handoverPacketSizeReady;
      final batchingRc = _transport.setRelayMediaBatching(
        chan,
        true,
        compact: true,
      );
      if (batchingRc != 0) {
        devLog(
          () => 'xVeil[call-media]: compact relay mode rejected rc=$batchingRc',
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
      devLog(
        () =>
            'xVeil[call-media]: compact relay packet_size=$packetSizeOk '
            'enabled=$_compactRelayMedia',
      );
    }
    _engine = engine;
    _startControlPolling();
    _diagnosticMediaController = this;
    await _restoreMicrophonePreference(engine);
    await _restoreSpeakerPreference(engine);
    // Liveness signal for the call FSM: poll rx_pkts so it can tell the peer's
    // media is still arriving even when the durable signaling heartbeat lags.
    _statsTimer?.cancel();
    _lastRxAt = null;
    _lastRxPkts = 0;
    _audioReceiveActivity.reset();
    _receiveSessionStartedAt = DateTime.now();
    _sourcePressure.reset();
    _lastNativeRxCount = _transport.mediaRecvCount(call.mediaPeer.bytes);
    _engineRxStalledSince = null;
    _lastRepairAt = null;
    var statsTick = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_engine != engine) return;
      try {
        final stats = engine.getStats();
        final now = DateTime.now();
        _audioReceiveActivity.observe(stats, now);
        final peerInterrupted = _peerAudioPlayout.takeInterruption();
        final peerRecovered = _peerAudioPlayout.takeRecovery();
        final localAudioRecovered =
            call.media.audio &&
            _peerAudioCaptureEnabled &&
            _audioReceiveActivity.recovered;
        final peerAudioRecovered = _peerAudioRecovery.observe(
          stats: stats,
          healthIdentity: _peerAudioPlayout.recoveryIdentity(now),
          healthRecovered: peerRecovered,
          expected: call.media.audio && !_microphoneState.muted,
        );
        final audioInterrupted =
            call.media.audio &&
            ((_peerAudioCaptureEnabled && _audioReceiveActivity.interrupted) ||
                (!_microphoneState.muted && peerInterrupted));
        final receiveDelay = _audioReceiveActivity.playoutFeedback(now).delayMs;
        final receiveAt = _audioReceiveActivity.lastRxAt;
        final nativeDrops = stats['audio_tx_rtp_drops'];
        final sourcePressured = _sourcePressure.observe(
          sendExpected: call.media.audio && !_microphoneState.muted,
          receiveExpected: call.media.audio && _peerAudioCaptureEnabled,
          requirePeerPlayout:
              (call.peerProtocolVersion ?? 1) >=
              kCallAudioPlayoutFeedbackMinVersion,
          peerDelayMs: _peerAudioPlayout.delayMs(now),
          peerCurrentDelayMs: _peerAudioPlayout.currentDelayMs(now),
          peerTargetDelayMs: _peerAudioPlayout.targetDelayMs(now),
          peerSampleSequence: _peerAudioPlayout.sampleSequence,
          peerBufferGrowing: _peerAudioPlayout.bufferGrowing(now),
          receiveDelayMs: receiveDelay,
          receiveTargetDelayMs: _audioReceiveActivity
              .playoutFeedback(now)
              .targetDelayMs,
          receiveAgeMs: receiveAt == null
              ? null
              : now.difference(receiveAt).inMilliseconds,
          interrupted: audioInterrupted,
          recovered: localAudioRecovered,
          peerRecoveryObserved: peerAudioRecovered,
          audioTxDrops: nativeDrops is int ? nativeDrops : null,
          audioLossReportUs: stats['audio_loss_report_us'],
          peerAudioRecoveryReportUs: stats['audio_peer_recovery_report_us'],
        );
        _sourcePressured = sourcePressured;
        if (sourcePressured != null && !_sourceFeedbackPending) {
          // One small outstanding report, with the ORIGINAL sampling time.
          // Delayed workers/writes cannot renew pressure after this call ends.
          _sourceFeedbackPending = true;
          unawaited(
            _transport
                .reportLocalSourcePressure(
                  pressured: sourcePressured,
                  sampledAt: now,
                )
                .then<void>(
                  (queued) {
                    if (_engine != engine) return;
                    if (queued) {
                      _sourceFeedbackQueued++;
                    } else {
                      _sourceFeedbackSkipped++;
                    }
                  },
                  onError: (Object _) {
                    // The lease expires naturally on unavailable/older IPC.
                    if (_engine == engine) _sourceFeedbackSkipped++;
                  },
                )
                .whenComplete(() => _sourceFeedbackPending = false),
          );
        }
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
                'aud_filtered=${stats['audio_filtered_delay_ms']} '
                'vid=${stats['video_delay_ms']}/${stats['video_jb_ms']} '
                'pacer=${stats['pacer_delay_ms']} '
                'sdelay=${stats['video_send_delay_ms']} '
                'adapt=${_bitrateAdapter?.level} '
                'peer_aud=${_peerAudioPlayout.delayMs(now)} '
                'base=${_bitrateAdapter?.rttBaselineMs} '
                'tx=${stats['tx_pkts']} rx=${stats['rx_pkts']} '
                'audio_rx=${stats['audio_rx_pkts']} worker=${stats['worker_stalled']} '
                'drops=${stats['tx_drops']}/${stats['rx_drops']}',
          );
        }
        final rx = (stats['rx_pkts'] as num?)?.toInt() ?? 0;
        final currentCall = _activeCall;
        if (currentCall?.callId != call.callId) return;
        final nativeRx = _transport.mediaRecvCount(
          currentCall!.mediaPeer.bytes,
        );
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
              unawaited(_rebuildLocalSession());
            }
          }
        }
        _lastRxPkts = rx;
        _lastNativeRxCount = nativeRx;
        final audioStalled = _audioReceiveActivity.workerStalledSince;
        if (!_routeRepairing &&
            audioStalled != null &&
            now.difference(audioStalled) >= kCallMediaRepairAfter) {
          // Video ingress can keep rx_pkts growing while the AUDIO worker is
          // stuck. Repair this endpoint; the peer cannot drain our worker.
          _audioReceiveActivity.workerStalledSince = null;
          if (_starvedRebuilds < 2) {
            _starvedRebuilds++;
            devLog(
              () =>
                  'xVeil[call-media]: audio worker stalled — local '
                  'session rebuild #$_starvedRebuilds',
            );
            unawaited(_rebuildLocalSession());
          }
        }
        final adapter = _bitrateAdapter;
        if (adapter != null) {
          // Sender-side ladder driven by what the REMOTE receiver reports for
          // our outbound leg (RTCP report blocks) plus local queue drops. The
          // route profile stays the ceiling; adaptation only spends less.
          adapter.onNativeStats(
            stats,
            videoSendExpected:
                _screenSharing ||
                ((_activeCall?.media.video == true ||
                        _activeCall?.media.screen == true) &&
                    _cameraState.enabledForCall(call.callId)),
            sendAudioExpected: call.media.audio && !_microphoneState.muted,
            requireAudioReceivePlayout:
                call.media.audio && _peerAudioCaptureEnabled,
            audioInterrupted: audioInterrupted,
            audioRecoveryObserved: localAudioRecovered,
            peerRecoveryObserved: peerAudioRecovered,
            receiveAudioExpected: call.media.audio && _peerAudioCaptureEnabled,
            peerAudioDelayMs: _peerAudioPlayout.delayMs(now),
            peerCurrentAudioDelayMs: _peerAudioPlayout.currentDelayMs(now),
            peerTargetAudioDelayMs: _peerAudioPlayout.targetDelayMs(now),
            peerAudioSampleSequence: _peerAudioPlayout.sampleSequence,
            peerAudioBufferGrowing: _peerAudioPlayout.bufferGrowing(now),
            requirePeerAudioPlayout:
                call.media.audio &&
                (call.peerProtocolVersion ?? 1) >=
                    kCallAudioPlayoutFeedbackMinVersion &&
                !_microphoneState.muted,
          );
          if (engine.supportsVideoSendPause) {
            final paused = adapter.applyPendingPause(
              (paused) => _setVideoSendPausedForAudio(engine, paused),
            );
            if (paused != null) {
              devLog(
                () =>
                    'xVeil[call-media]: audio-reserve video pause='
                    '${adapter.audioReserve} ok=$paused',
              );
            }
          }
          if (_diagnosticVideoTarget == null) {
            final ok = adapter.applyPendingTarget(
              (target) => engine.setVideoBitrate(
                maxBitrateKbps: target.maxBitrateKbps,
                maxFps: target.maxFps,
              ),
            );
            if (ok != null) {
              final target = adapter.target;
              devLog(
                () =>
                    'xVeil[call-media]: link-quality retune level='
                    '${adapter.level} ${target.maxBitrateKbps}kbps@'
                    '${target.maxFps}fps ok=$ok',
              );
            }
          }
          // Out of rungs on a link that is still failing. Until now this state
          // produced nothing at all — `onSample` returns null both for "held
          // the rung because all is well" and for "held it because there is
          // nothing smaller left", and the call went on pushing video into a
          // link measured losing 68% of it.
          //
          // Only ever RAISED here, never lowered: the adapter withdraws its
          // own advice when the ladder climbs back off the floor, and the
          // prompt follows that rather than flickering with each sample.
          final advising =
              adapter.videoAdvice == CallVideoAdvice.suggestDisable;
          // MEASURED, not assumed: the camera can be off while the video
          // sender still exists, and there is nothing to offer to drop then.
          // This sample already carries the answer.
          final sendingVideo = ((stats['video_tx_fps'] as num?) ?? 0) > 0;
          if (advising && sendingVideo && callVideoPrompt.value == null) {
            callVideoPrompt.value = CallVideoPromptCause.linkFailing;
            devLog(
              () =>
                  'xVeil[call-media]: link cannot carry video at the ladder '
                  'floor (${adapter.target.maxBitrateKbps}kbps) — offering to '
                  'drop it',
            );
          } else if (!advising &&
              callVideoPrompt.value == CallVideoPromptCause.linkFailing) {
            callVideoPrompt.value = null;
          }
        }
      } catch (_) {}
    });
    // Establish the initial privacy posture before the ADM is started. The
    // native engine now keeps physical capture stopped while muted, so an
    // Android endpoint configured mic-off neither opens AudioRecord briefly
    // nor burns capture/Opus CPU just to encode silence.
    engine.setMicMuted(_microphoneState.mutedForCall(call.callId));
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
      final adapter = _videoAdapterForProfile(profile, engine);
      if (!_prepareVideoAudioAdmission(call, engine, adapter)) return audioOk;
      final target = adapter.target;
      videoOk = engine.startVideo(
        send: true,
        recv: true,
        maxBitrateKbps: target.maxBitrateKbps,
        maxFps: target.maxFps,
      );
      devLog(() => 'xVeil[call-media]: startVideo=$videoOk');
      if (videoOk) {
        if (Platform.isAndroid) await _startAndroidVideoRenderer(engine);
      }
      // Drive the send stream from the real camera for a video call (screen
      // capture is a separate path). Apple platforms capture natively inside
      // the engine. Android uses an app-owned Camera2 SurfaceTexture + direct
      // JNI YUV bridge; the Flutter camera plugin is only a compatibility
      // fallback if the native session cannot open.
      if (videoOk &&
          shouldStartInitialCallCamera(
            call.copyWith(cameraOn: _cameraState.enabledForCall(call.callId)),
          )) {
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
    if (videoOk &&
        _activeCall?.callId == call.callId &&
        _activeCall?.screenOn == true) {
      if (Platform.isAndroid) {
        final screen = _androidScreen;
        final restored =
            _screenSharing &&
            screen != null &&
            _transport.setMediaScreenSharing(chan, true) == 0 &&
            screen.rebindFrameSink(_androidScreenSink(engine, screen));
        if (!restored) {
          // An expired grant must not silently start another projection.
          await setScreenShareEnabled(false);
          _screenShareStops.add(null);
        }
      } else if (Platform.isMacOS) {
        if (!await setScreenShareEnabled(true)) {
          _rememberScreenSharing(false);
          _screenShareStops.add(null);
        }
      }
    }
    final ok = audioOk || videoOk;
    devLog(() => 'xVeil[call-media]: controller start result=$ok');
    return ok;
  }

  CallBitrateAdapter _videoAdapterForProfile(
    CallVideoProfile profile,
    VeilMediaEngine engine,
  ) {
    final previous = _bitrateAdapter;
    if (previous != null &&
        previous.baseBitrateKbps == profile.maxBitrateKbps &&
        previous.baseFps == profile.maxFps &&
        previous.supportsLowRateVideo == engine.supportsLowRateVideo) {
      return previous;
    }
    return _bitrateAdapter = CallBitrateAdapter(
      baseBitrateKbps: profile.maxBitrateKbps,
      baseFps: profile.maxFps,
      supportsLowRateVideo: engine.supportsLowRateVideo,
    );
  }

  bool _setVideoSendPausedForAudio(VeilMediaEngine engine, bool paused) {
    final applied = engine.setVideoSendPaused(paused);
    // Publish only accepted native state. A busy worker leaves the previous
    // state visible while the adapter retries its pending change.
    if (applied) callVideoSendPausedForAudio.value = paused;
    return applied;
  }

  bool _prepareVideoAudioAdmission(
    Call call,
    VeilMediaEngine engine,
    CallBitrateAdapter adapter,
  ) {
    if (!engine.supportsVideoSendPause) return true;
    Map<String, dynamic> stats;
    try {
      stats = engine.getStats();
    } catch (_) {
      stats = {'worker_stalled': 1};
    }
    adapter.prepareVideoSend(
      stats,
      sendAudioExpected: call.media.audio && !_microphoneState.muted,
      requireAudioReceivePlayout: call.media.audio && _peerAudioCaptureEnabled,
      audioInterrupted:
          call.media.audio &&
          ((_peerAudioCaptureEnabled && _audioReceiveActivity.interrupted) ||
              (!_microphoneState.muted &&
                  _peerAudioPlayout.takeInterruption())),
      receiveAudioExpected: call.media.audio && _peerAudioCaptureEnabled,
      peerAudioDelayMs: _peerAudioPlayout.delayMs(DateTime.now()),
      requirePeerAudioPlayout:
          call.media.audio &&
          (call.peerProtocolVersion ?? 1) >=
              kCallAudioPlayoutFeedbackMinVersion &&
          !_microphoneState.muted,
      audioReceiveQuality:
          !stats.containsKey('audio_rx_native_age_ms') &&
              _audioReceiveActivity.supported
          ? (
              expected: call.media.audio && _peerAudioCaptureEnabled,
              ageMs: null,
            )
          : null,
    );
    final applied = adapter.applyPendingPause(
      (paused) => _setVideoSendPausedForAudio(engine, paused),
    );
    devLog(
      () =>
          'xVeil[call-media]: before-video audio pause=${adapter.audioReserve} ok=$applied',
    );
    return applied != false;
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
    final adapter = _videoAdapterForProfile(profile, engine);
    if (!_prepareVideoAudioAdmission(call, engine, adapter)) return false;
    final target = adapter.target;
    final bool ok;
    try {
      ok = engine.startVideo(
        send: true,
        recv: true,
        maxBitrateKbps: target.maxBitrateKbps,
        maxFps: target.maxFps,
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
    if (_frameTimer == null) _startFramePump(engine);
    return true;
  }

  @override
  Future<void> stop() => _stopSession(clearActiveCall: true);

  Future<void> _stopSession({
    required bool clearActiveCall,
    bool clearMicrophoneState = true,
  }) async {
    _mediaEpoch++;
    _audioMirrorLease.stop();
    for (final channel in _diagnosticRouteChannels) {
      try {
        _transport.closeMediaChannel(channel);
      } catch (_) {}
    }
    _diagnosticRouteChannels.clear();
    callVideoSendPausedForAudio.value = false;
    _handoverPacketSizeReady = false;
    for (final entry in _retiringChannels.entries) {
      entry.value.cancel();
      try {
        _transport.closeMediaChannel(entry.key);
      } catch (_) {}
    }
    _retiringChannels.clear();
    for (final channel in _receiveOnlyChannels.values) {
      final engine = _engine;
      if (engine != null) {
        _closeReceiveOnlyChannel(engine, channel);
      } else {
        try {
          _transport.closeMediaChannel(channel);
        } catch (_) {}
      }
    }
    _receiveOnlyChannels.clear();
    // A MediaProjection grant is scoped to the live call, not to one native
    // route. Detach the retiring engine synchronously before teardown awaits;
    // keep the consented source only for an internal rebuild of this call.
    final keepScreenCapture =
        !clearActiveCall &&
        _screenSharing &&
        _screenStarting == null &&
        _androidScreen != null;
    _androidScreen?.rebindFrameSink(null);
    if (clearActiveCall) {
      _routeHandovers = 0;
      _activeCall = null;
      _bitrateAdapter = null;
      if (clearMicrophoneState) {
        _microphoneState.clear();
        _cameraState.clear();
      }
      // The prompt belongs to a call, not to the app. A route repair
      // (clearActiveCall: false) deliberately keeps it: the link that could
      // not carry video a second ago is the same link.
      callVideoPrompt.value = null;
      // The rebuild cap is per CALL, not per session: a repair's stop+start
      // (clearActiveCall: false) must not refill the budget it just spent.
      _starvedRebuilds = 0;
    }
    _frameTimer?.cancel();
    _frameTimer = null;
    _frameCadenceClock.stop();
    _statsTimer?.cancel();
    _statsTimer = null;
    _controlPollTimer?.cancel();
    _controlPollTimer = null;
    _lastRxAt = null;
    _lastRxPkts = 0;
    _lastNativeRxCount = 0;
    _audioReceiveActivity.reset();
    _peerAudioPlayout.invalidateMeasurement();
    _receiveSessionStartedAt = clearActiveCall ? null : DateTime.now();
    _engineRxStalledSince = null;
    // Congestion belongs to the call, not the native engine. A route rebuild
    // must start video at its reduced budget instead of injecting a new burst.
    _bitrateAdapter?.invalidateAppliedState();
    if (!keepScreenCapture) _screenSharing = false;
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
    // The camera and screen teardowns are STARTED here and awaited at the end.
    //
    // Both detach their sinks synchronously, so nothing can reach the engine
    // from this line on — and both may then sit on a platform call that has
    // not answered. Awaiting them here put the audio engine, the media channel
    // and the call slot behind that wait: the call was over on screen while
    // the microphone was still running (report24 MEDIA-1).
    final closing = <Future<void>>[];
    final cam = _androidCam;
    _androidCam = null;
    if (cam != null) closing.add(cam.stop().catchError((Object _) {}));
    final screen = _androidScreen;
    if (!keepScreenCapture) {
      _androidScreen = null;
      if (screen != null) closing.add(screen.stop().catchError((Object _) {}));
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
    // Now that the audio, the engine and the channel are gone, wait for the
    // capture teardowns — they are bounded by their own grace, and nothing
    // downstream depends on them any more.
    if (closing.isNotEmpty) {
      try {
        await Future.wait(closing);
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

  @override
  Future<void> setMicMuted(bool muted) async {
    final changed = muted != _microphoneState.muted;
    if (changed) {
      _peerAudioPlayout.invalidateMeasurement();
    }
    // Remember choices made before the engine exists or during a repair gap.
    _microphoneState.setMuted(muted);
    try {
      final call = _activeCall;
      if (call != null && _microphoneState.belongsToCall(call.callId)) {
        final adapter = _bitrateAdapter;
        final engine = _engine;
        if (changed &&
            !muted &&
            call.media.audio &&
            adapter != null &&
            engine != null &&
            engine.supportsVideoSendPause) {
          // Reserve the outgoing leg before restarting capture. Old video
          // reports cannot prove that this newly enabled audio reaches peer.
          adapter.prepareVideoSend(const {}, requirePeerAudioPlayout: true);
          adapter.applyPendingPause(
            (paused) => _setVideoSendPausedForAudio(engine, paused),
          );
        }
        _engine?.setMicMuted(muted);
      }
    } catch (_) {}
  }

  Future<void> _loadDevicePreferences() async {
    if (_devicePreferencesLoaded) return;
    _devicePreferencesLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedCameraId = prefs.getString(_cameraPreferenceKey);
      _preferredMicrophoneLabel = prefs.getString(_microphonePreferenceKey);
      _preferredSpeakerLabel = prefs.getString(_speakerPreferenceKey);
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

  /// Re-select the output the user last chose, by LABEL.
  ///
  /// Ids are not stable across reboots or replugs; the label is what a person
  /// recognised when they picked it. Mirrors the microphone, which has done
  /// this since it had a picker at all — the output had neither.
  Future<void> _restoreSpeakerPreference(VeilMediaEngine engine) async {
    final preferred = _preferredSpeakerLabel;
    if (preferred == null || preferred.isEmpty) return;
    final devices = await listSpeakers();
    for (final device in devices) {
      if (device.label != preferred) continue;
      try {
        if (engine.selectAudioOutput(device.id)) {
          _selectedSpeakerId = device.id;
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

  /// The outputs a call can be played out of.
  ///
  /// Android is deliberately empty: its output choice is earpiece/speaker and
  /// belongs to [callAudioRouter], which the call sheet already offers. This
  /// is the desktop list, and the engine has been able to answer it all along
  /// — nothing ever asked.
  @override
  Future<List<CallMediaDevice>> listSpeakers() async {
    final engine = _engine;
    if (engine == null || Platform.isAndroid || Platform.isIOS) return const [];
    try {
      return engine
          .listAudioOutputs()
          .indexed
          .map(
            (entry) => CallMediaDevice(
              id: entry.$2.id,
              label: entry.$2.label,
              kind: CallMediaDeviceKind.speaker,
              selected:
                  entry.$2.id == _selectedSpeakerId ||
                  (_selectedSpeakerId == null && entry.$1 == 0),
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
  Future<bool> selectSpeaker(String id) async {
    final engine = _engine;
    if (engine == null) return false;
    final devices = await listSpeakers();
    CallMediaDevice? chosen;
    for (final device in devices) {
      if (device.id == id) chosen = device;
    }
    if (chosen == null) return false;
    try {
      if (!engine.selectAudioOutput(id)) return false;
      _selectedSpeakerId = id;
      _preferredSpeakerLabel = chosen.label;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_speakerPreferenceKey, chosen.label);
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
  void updateCameraIntent(bool enabled) => _cameraState.setEnabled(enabled);

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _cameraState.setEnabled(enabled);
    final engine = _engine;
    if (engine == null) return;
    if (enabled && (_screenSharing || _screenStarting != null)) return;
    final chan = _chan;
    if (enabled &&
        (chan == null || _transport.setMediaScreenSharing(chan, false) != 0)) {
      return;
    }
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
    final chan = _chan;
    if (!enabled) _rememberScreenSharing(false);
    if (Platform.isAndroid) {
      if (!enabled) {
        final screen = _androidScreen;
        _androidScreen = null;
        _screenSharing = false;
        if (screen != null) await screen.stop();
        // The old channel may have closed while capture was stopping.
        if (_chan != chan || _engine != engine) return false;
        if (chan != null) _transport.setMediaScreenSharing(chan, false);
        if (engine != null) _startFramePump(engine);
        return true;
      }
      if (engine == null || chan == null) return false;
      if (_androidScreen != null) return true;
      // One start at a time. Two enables in flight both stop the camera,
      // then both create a source into the same field and the same platform
      // handler: the second overwrites the first, whose source is then held
      // by nobody — and teardown cannot stop what it cannot see (report19
      // XV19-H3). A second caller waits for the first answer, which is what
      // it was asking for anyway.
      final inFlight = _screenStarting;
      if (inFlight != null) return inFlight;
      final starting = () async {
        // The session this request belongs to. Enabling share stops the camera
        // FIRST, and between nulling those fields and creating the screen source
        // there is nothing for `_stopSession` to find: it sees camera and screen
        // both null, tears the engine down and finishes — and the continuation
        // then creates and starts a foreground MediaProjection capture on the
        // far side of the privacy boundary the hangup drew (report18 XV18-H3).
        final epoch = _mediaEpoch;
        final cameraWasRunning =
            _androidNativeCam != null || _androidCam != null;
        final nativeCam = _androidNativeCam;
        _androidNativeCam = null;
        if (nativeCam != null) await nativeCam.stop();
        final cam = _androidCam;
        _androidCam = null;
        if (cam != null) await cam.stop();
        if (epoch != _mediaEpoch) return false;
        if (_chan != chan ||
            _transport.setMediaScreenSharing(chan, true) != 0) {
          return false;
        }
        final bool started;
        try {
          started = await _startAndroidScreen(engine);
        } catch (_) {
          if (epoch == _mediaEpoch && _chan == chan) {
            _transport.setMediaScreenSharing(chan, false);
          }
          rethrow;
        }
        // And again on the way out: `_startAndroidScreen` publishes the source
        // before it awaits `start`, so a teardown landing THERE stops a source
        // that has not started yet and the start then succeeds behind it —
        // capture running with nobody holding it.
        if (epoch != _mediaEpoch) {
          final orphan = _androidScreen;
          _androidScreen = null;
          _screenSharing = false;
          if (orphan != null) {
            try {
              await orphan.stop();
            } catch (_) {}
          }
          return false;
        }
        if (!started) _transport.setMediaScreenSharing(chan, false);
        _screenSharing = started;
        if (started) _rememberScreenSharing(true);
        if (started) _startFramePump(engine);
        if (!started && cameraWasRunning) {
          await _startAndroidCam(
            engine,
            highQuality: _highQualityRoute,
            restoringAfterScreenFailure: true,
          );
        }
        return started;
      }();
      _screenStarting = starting;
      try {
        return await starting;
      } finally {
        if (identical(_screenStarting, starting)) _screenStarting = null;
      }
    }
    if (engine == null || chan == null) return false;
    if (!Platform.isMacOS) return false;
    try {
      if (enabled) {
        final callId = _activeCall?.callId;
        final started = startDesktopScreenCapture(
          selectSource: (screen) =>
              _transport.setMediaScreenSharing(chan, screen) == 0,
          startCapture: () => engine.startScreen(
            width: _highQualityRoute ? 960 : 640,
            fps: _highQualityRoute ? 15 : 10,
            sourceId: _selectedScreenId,
          ),
          mayRestoreCamera: () =>
              callId != null &&
              _activeCall?.callId == callId &&
              _engine == engine &&
              _chan == chan &&
              _cameraState.enabledForCall(callId),
          restoreCamera: () {
            final profile = _highQualityRoute
                ? _directVideoProfile
                : _anonymousVideoProfile;
            engine.startCamera(
              width: profile.cameraWidth,
              height: profile.cameraHeight,
              fps: profile.maxFps,
              deviceId: _selectedCameraId,
            );
          },
        );
        _screenSharing = started;
        if (started) _rememberScreenSharing(true);
        return started;
      }
      final stopped = engine.stopScreen();
      if (stopped) {
        _transport.setMediaScreenSharing(chan, false);
        _screenSharing = false;
      }
      return stopped;
    } catch (_) {
      if (enabled) _transport.setMediaScreenSharing(chan, false);
      return false;
    }
  }

  /// One screen start, from the camera stop to the source that replaces it.
  Future<bool>? _screenStarting;

  void _rememberScreenSharing(bool enabled) {
    final call = _activeCall;
    if (call != null) {
      _activeCall = call.copyWith(
        screenOn: enabled,
        media: call.media.copyWith(screen: enabled),
      );
    }
  }

  I420FrameSink _androidScreenSink(
    VeilMediaEngine engine,
    AndroidScreenCaptureSource screen,
  ) {
    final callId = _activeCall?.callId;
    return (y, u, v, w, h) {
      if (_engine != engine ||
          _androidScreen != screen ||
          _activeCall?.callId != callId) {
        return;
      }
      try {
        final pushed = engine.pushVideoFrame(y, u, v, w, h);
        if (!_androidScreenPushLogged) {
          _androidScreenPushLogged = true;
          devLog(() => 'veil-screen: first direct engine push=$pushed');
        }
      } catch (_) {}
    };
  }

  Future<bool> _startAndroidScreen(VeilMediaEngine engine) async {
    _androidScreenPushLogged = false;
    late final AndroidScreenCaptureSource screen;
    screen = _screenCaptureFactory(() {
      if (_androidScreen != screen) return;
      _androidScreen = null;
      final chan = _chan;
      if (chan != null) {
        _transport.setMediaScreenSharing(chan, false);
      }
      _screenSharing = false;
      _rememberScreenSharing(false);
      localVideoFrame.value = null;
      _screenShareStops.add(null);
    });
    _androidScreen = screen;
    final started = await screen.start(_androidScreenSink(engine, screen));
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
    bool restoringAfterScreenFailure = false,
  }) async {
    bool mayCapture() =>
        _engine == engine &&
        _activeCall != null &&
        _cameraState.enabledForCall(_activeCall!.callId) &&
        !_screenSharing &&
        _androidScreen == null &&
        (_screenStarting == null || restoringAfterScreenFailure);
    if (!mayCapture()) return;
    final existingNative = _androidNativeCam;
    if (existingNative?.isRunning ?? false) return;
    if (existingNative != null) {
      _androidNativeCam = null;
      await existingNative.stop();
    }
    if (!mayCapture()) return;
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
    if (!mayCapture() || _androidNativeCam != nativeCam) {
      if (nativeOk) await nativeCam.stop();
      if (_androidNativeCam == nativeCam) _androidNativeCam = null;
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
      if (!mayCapture() || _androidCam != cam) return false;
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
    if (!ok || !mayCapture() || _androidCam != cam) {
      if (ok) await cam.stop();
      if (_androidCam == cam) _androidCam = null;
    } else {
      _startFramePump(engine);
    }
  }
}
