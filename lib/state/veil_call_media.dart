import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:veil_media/veil_media.dart';
import 'package:veil_flutter/veil_ffi.dart' show MediaPacketSource;

import '../core/log.dart';
import '../core/capture_resource_lifetime.dart';
import '../core/diagnostic_journal.dart';
import '../core/diagnostic_audio_output.dart';
import '../core/ids.dart';
import '../data/storage/profile_preferences.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import '../domain/call_signal.dart';
import 'android_call_foreground.dart';
import 'android_camera_capture.dart';
import 'android_native_call_camera.dart';
import 'android_native_call_video.dart';
import 'android_screen_capture.dart';
import 'call_bitrate_adapter.dart';
import 'call_network_activity.dart';
import 'call_video_profile.dart';
import 'call_audio_receive_activity.dart';
import 'call_media_receive_activity.dart';
import 'call_audio_source_pressure.dart';
import 'call_audio_framing.dart';
import 'call_microphone_state.dart';
import 'call_audio_start_state.dart';
import 'call_camera_state.dart';
import 'desktop_screen_capture_start.dart';
import 'call_peer_audio_playout.dart';
import 'call_peer_audio_recovery.dart';
import 'call_video_prompt.dart';
import 'call_audio_route.dart';
import 'call_media_route_operations.dart';
import 'call_media_route_qualification.dart';
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

typedef CallMediaEngineFactory = VeilMediaEngine? Function({
  required int veilChan,
  required Uint8List localId,
  required Uint8List peerId,
});

/// The real [CallMediaController]: opens a veil media datagram channel to the
/// call peer and drives the libwebrtc audio engine (libveil_media.dylib) over
/// it. Per-packet RTP/RTCP flows native↔native (the C++ Transport shim calls
/// the veil_media_* ABI); this Dart layer is control only.
///
/// SSRCs are derived from the node ids inside the engine, so both ends agree
/// without extra negotiation. One engine per live call; [stop] is idempotent.
class VeilCallMediaController implements CallMediaController {
  VeilCallMediaController(
    this._transport, {
    CallMediaEngineFactory? engineFactory,
    Future<void>? audioProcessingReady,
    CallMicrophonePermission? Function(Future<bool>)? microphonePermissionFactory,
    @visibleForTesting bool? androidCameraCapture,
    @visibleForTesting
    AndroidNativeCallCamera Function()? nativeCameraFactory,
    @visibleForTesting
    AndroidCameraCapture Function(bool highQuality, String? cameraId)?
    cameraCaptureFactory,
  }) : // Public constructor parameter, private stored readiness gate.
       // ignore: prefer_initializing_formals
       _audioProcessingReady = audioProcessingReady,
       _engineFactory = engineFactory ?? VeilMediaEngine.create,
       _androidCameraCapture = androidCameraCapture ?? Platform.isAndroid,
       _nativeCameraFactory = nativeCameraFactory ?? AndroidNativeCallCamera.new,
       _injectedCameraFactory = cameraCaptureFactory,
       _microphonePermissionFactory =
           microphonePermissionFactory ?? _platformMicrophonePermission;

  final CallMediaEngineFactory _engineFactory;
  final Future<void>? _audioProcessingReady;
  final bool _androidCameraCapture;
  final AndroidNativeCallCamera Function() _nativeCameraFactory;
  final AndroidCameraCapture Function(bool highQuality, String? cameraId)?
  _injectedCameraFactory;
  final CallMicrophonePermission? Function(Future<bool>)
  _microphonePermissionFactory;

  static CallMicrophonePermission? _platformMicrophonePermission(
    Future<bool> result,
  ) => Platform.isAndroid ? CallMicrophonePermission(result) : null;

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
  final _microphoneUnavailable = StreamController<String>.broadcast();
  final _cameraUnavailable = StreamController<String>.broadcast();
  Timer? _controlPollTimer;

  @override
  Stream<CallSignal> get peerHealth => _peerHealth.stream;

  @override
  Stream<String> get microphoneUnavailable => _microphoneUnavailable.stream;

  @override
  Stream<String> get cameraUnavailable => _cameraUnavailable.stream;

  @override
  bool get canReceiveEphemeralHealth =>
      _engine != null && _chan != null && _transport.hasCallControl(_chan!);

  @override
  bool sendEphemeralHealth(CallSignal signal) {
    final call = _activeCall;
    final channel = _chan;
    final lastRx = _mediaReceiveActivity.lastRxAt;
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
  bool _startedWithoutMicrophone = false;
  @override
  bool get startedWithoutMicrophone => _startedWithoutMicrophone;
  CallMicrophonePermission? _microphonePermission;
  final _cameraState = CallCameraState();
  bool _startedWithoutCamera = false;
  @override
  bool get startedWithoutCamera => _startedWithoutCamera;
  VeilMediaEngine? _engine;
  bool _noiseSuppressionEnabled = true;

  bool setNoiseSuppression(bool enabled) {
    final engine = _engine;
    if (engine != null) {
      try {
        if (!engine.setNoiseSuppression(enabled)) return false;
      } catch (_) {
        return false;
      }
    }
    _noiseSuppressionEnabled = enabled;
    return true;
  }

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
  // A choice or ON/OFF intent can supersede a stop fence within the same call.
  // Its late continuation owns no newer source.
  int _cameraOperationEpoch = 0;
  // Sources can be detached by a toggle/selection while native stop is still
  // pending. Their engine must retain those JNI fences after the field is null.
  // Screen handoff also tracks the plugin camera's platform stop here so the
  // call slot cannot release over that detached capture's teardown.
  final _nativeRetirements = Map<VeilMediaEngine, Set<Future<void>>>.identity();
  final _microphoneForeground = AndroidCallForegroundService.bind();
  final _cameraLifetime = CaptureResourceLifetime.current();
  final _networkActivity = CallNetworkActivity.shared;
  AndroidScreenCaptureSource? _androidScreen;
  bool _androidScreenPushLogged = false;
  AndroidScreenCaptureSource _screenCaptureFactory(
    VoidCallback onUnexpectedStop,
  ) => createAndroidScreenCapture(
    onUnexpectedStop,
    captureLifetime: _cameraLifetime,
  );
  final _screenShareStops =
      StreamController<({String callId, int epoch})>.broadcast();
  Timer? _statsTimer; // polls rx_pkts for the call-liveness signal
  final _mediaReceiveActivity = CallMediaReceiveActivity();
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
  final _networkActivityOwner = Object();
  int _mediaEpoch = 0;
  // Unlike mediaEpoch, this is claimed BEFORE start's first await, including
  // the teardown of a previous engine. A later same-call start must win too.
  int _startOperationEpoch = 0;
  Future<void>? _devicePreferencesReady;
  String? _selectedCameraId;
  String? _selectedMicrophoneId;
  String? _selectedScreenId;
  int _screenSelectionEpoch = 0;
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
  int _localPreviewReadErrors = 0;
  int _remotePreviewReadErrors = 0;
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
  bool _audioFramingEnabled = false;
  int _audioPacketOverhead = 0;
  int _audioCostLastPackets = 0, _audioCostLastBytes = 0;
  int _audioCostPacketBytes = 200;
  Map<String, Object?>? _audioSourceCost;
  bool _videoFramingEligible = false;
  CallVideoFraming _videoFraming = CallVideoFraming();
  ({int bitrateKbps, double fps})? _diagnosticVideoTarget;

  void _refreshAudioFraming(
    VeilMediaEngine engine,
    int channel, {
    Map<String, dynamic>? stats,
  }) {
    if (!_audioFramingEnabled || _chanTransport == CallTransportKind.onion) {
      return;
    }
    final packets = stats?['audio_tx_payload_pkts'];
    final bytes = stats?['audio_tx_payload_bytes'];
    if (packets is int && bytes is int) {
      final count = packets - _audioCostLastPackets;
      final payload = bytes - _audioCostLastBytes;
      if (count > 0 && payload > 0) {
        // Negotiated audio carries one TWCC extension: RTP header20. Padding
        // and RTCP are excluded from these native payload counters.
        _audioCostPacketBytes = ((payload / count).ceil() + 20).clamp(12, 1000);
      }
      _audioCostLastPackets = packets;
      _audioCostLastBytes = bytes;
    }
    _audioSourceCost = _transport.mediaPacketCost(
      channel,
      packetBytes: _audioCostPacketBytes,
    );
    final overhead = callMediaFramingOverhead(_audioSourceCost);
    if (overhead == null || overhead == _audioPacketOverhead) return;
    // Failure leaves the existing encoder and hint intact. Retry on the next
    // observation after a worker stall or unprepared replacement child.
    if (engine.setAudioPacketOverhead(overhead)) {
      _audioPacketOverhead = overhead;
      devLog(() => 'xVeil[call-media]: audio framing updated bytes=$overhead');
    }
  }

  void _refreshVideoFraming(
    VeilMediaEngine engine,
    int channel, {
    Map<String, dynamic>? stats,
  }) {
    if (!_videoFramingEligible || _chanTransport == CallTransportKind.onion) {
      return;
    }
    _videoFraming.refresh(
      stats: stats,
      query: (packetBytes) => _transport.mediaPacketCost(
        channel,
        packetBytes: packetBytes,
        source: _activeCall?.screenOn == true
            ? MediaPacketSource.screen
            : MediaPacketSource.video,
      ),
      apply: engine.setVideoPacketOverhead,
    );
  }

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
  DateTime? get lastMediaRxAt => _mediaReceiveActivity.lastRxAt;

  @override
  Future<DateTime?> readLatestMediaRxAt() async {
    final engine = _engine;
    if (engine == null || _routeRepairing) return null;
    return _mediaReceiveActivity.observe(engine.getStats(), DateTime.now());
  }

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
        'call_network_activity_active': _networkActivity.heldBy(
          _networkActivityOwner,
        ),
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
        'call_network_activity_active': _networkActivity.heldBy(
          _networkActivityOwner,
        ),
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
        'audio_source_cost': _audioSourceCost,
        'audio_framing_applied_bytes': _audioPacketOverhead,
        'video_source_cost': _videoFraming.sourceCost,
        'video_framing_applied_bytes': _videoFraming.appliedOverheadBytes,
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
          return await _restartSessionForRoute(call, transport);
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
  Future<bool> switchRoute(
    CallTransportKind transport, {
    Future<bool> Function()? canCommit,
  }) async {
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
        if (canCommit != null && !await canCommit()) return false;
        if (_activeCall?.callId != call.callId) return false;
        if (activeTransport == transport) return true;
        final engine = _engine;
        if (engine != null &&
            engine.supportsChannelRebind &&
            _handoverPacketSizeReady &&
            (activeTransport == CallTransportKind.relay ||
                activeTransport == CallTransportKind.p2p)) {
          return _switchRoutePreservingEngine(
            call,
            transport,
            engine,
            canCommit: canCommit,
          );
        }
        if (engine != null &&
            (activeTransport == CallTransportKind.p2p ||
                activeTransport == CallTransportKind.relay)) {
          // An older engine cannot preserve its sender while a candidate is
          // verified. Keep the live session instead of tearing it down for a
          // replacement whose delivery has not been observed.
          return false;
        }
        if (canCommit != null) return false;
        return _restartSessionForRoute(call, transport, requireTarget: true);
      },
    );
  }

  Future<bool> _restartSessionForRoute(
    Call call,
    CallTransportKind transport, {
    bool requireTarget = false,
  }) async {
    bool sameCall() => _activeCall?.callId == call.callId;
    // A newer same-call start owns readiness, including its pending phase.
    // The FSM already treats true + no open channel as converging. A route
    // switch, however, can report success only on its requested transport.
    bool transferred() =>
        sameCall() && (!requireTarget || activeTransport == transport);
    // Claim BEFORE stop can notify a synchronous listener. Call-id equality
    // alone cannot distinguish a newer session of this same call.
    final request = ++_startOperationEpoch;
    try {
      await _stopSession(clearActiveCall: false, startingRequest: request);
    } catch (_) {
      if (request != _startOperationEpoch) return transferred();
      rethrow;
    }
    if (!sameCall()) return false;
    if (request != _startOperationEpoch) return transferred();
    final startingRequest = ++_startOperationEpoch;
    final bool ok;
    try {
      ok = await _startForRequest(
        _activeCall!.copyWith(transport: transport),
        startingRequest,
      );
    } catch (_) {
      // An old lookup/engine failure must not end the newer working session.
      if (startingRequest != _startOperationEpoch) return transferred();
      rethrow;
    }
    if (!sameCall()) return false;
    if (startingRequest != _startOperationEpoch) return transferred();
    // Keep effects and readiness inside this ownership turn; the callers do
    // not reinterpret an older outcome after another await.
    if (!requireTarget) {
      _lastRepairAt = DateTime.now();
      devLog(
        () =>
            'xVeil[call-media]: local ${transport.name} session rebuilt '
            'call=${call.callId} ok=$ok',
      );
    }
    return ok &&
        (requireTarget
            ? activeTransport == transport
            : activeTransport != null);
  }

  Future<bool> _switchRoutePreservingEngine(
    Call call,
    CallTransportKind target,
    VeilMediaEngine engine, {
    Future<bool> Function()? canCommit,
  }) async {
    final previous = _chan;
    final previousPeer = _chanPeer;
    final previousTransport = _chanTransport;
    final epoch = _mediaEpoch;
    if (previous == null || previousPeer == null || previousTransport == null) {
      return false;
    }
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
      bool stillOwned() =>
          _engine == engine &&
          epoch == _mediaEpoch &&
          _chan == previous &&
          _chanTransport == previousTransport &&
          _activeCall?.callId == call.callId &&
          _activeCall?.mediaIdentity == next.mediaIdentity &&
          _activeCall?.peerDevice == next.peerDevice;
      var observations = 0;
      // Keep the old sender/receiver alive until the candidate has carried a
      // sealed peer echo in both directions. Local open/admission is not a
      // delivery observation. The echo's route stays inside the call AEAD.
      if (!await _configureRouteProbes(candidate, next, opened.transport) ||
          !await qualifyCallMediaHandover(
            from: previousTransport,
            to: target,
            stillOwned: stillOwned,
            qualify: () {
              observations++;
              devLog(
                () =>
                    'xVeil[call-media]: ${target.name} candidate '
                    'delivery observation=$observations',
              );
              return _transport.qualifyMediaRoute(opened.channel);
            },
          )) {
        devLog(() => 'xVeil[call-media]: candidate delivery unconfirmed');
        return false;
      }
      if (canCommit != null && !await canCommit()) return false;
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
      _refreshAudioFraming(engine, candidate);
      _refreshVideoFraming(engine, candidate);
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
  // A paused subscriber can receive this after capture has recovered or the
  // engine changed. Validate on delivery, while keeping the public void stream.
  Stream<void> get screenShareStopped => _screenShareStops.stream
      .where(
        (event) =>
            event.callId == _activeCall?.callId &&
            event.epoch == _mediaEpoch &&
            !_screenSharing &&
            _androidScreen == null,
      )
      .map<void>((_) {});

  void _reportScreenShareStopped(String callId, int epoch) {
    if (_activeCall?.callId != callId || _mediaEpoch != epoch) return;
    _screenShareStops.add((callId: callId, epoch: epoch));
  }

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
  Future<bool> start(Call call) =>
      _startForRequest(call, ++_startOperationEpoch);

  Future<bool> _startForRequest(Call call, int request) async {
    bool requested() => request == _startOperationEpoch;
    _startedWithoutCamera = false;
    final previousCall = _activeCall;
    final preserveReceiveHistory =
        previousCall?.callId == call.callId &&
        previousCall?.peer == call.peer &&
        previousCall?.peerIdentity == call.peerIdentity &&
        previousCall?.peerDevice == call.peerDevice;
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
    if (!requested() || !_microphoneState.belongsToCall(call.callId)) {
      return false;
    }
    if (_engine != null || (_chan != null && _chanPeer != call.mediaPeer.hex)) {
      await _stopSession(
        clearActiveCall: _activeCall?.callId != call.callId,
        clearMicrophoneState: false,
        startingRequest: request,
      );
    }
    if (!requested() || !_microphoneState.belongsToCall(call.callId)) {
      return false;
    }
    final epoch = ++_mediaEpoch;
    _activeCall = call;
    bool currentStart() =>
        requested() &&
        _mediaEpoch == epoch &&
        _activeCall?.callId == call.callId &&
        _microphoneState.belongsToCall(call.callId);
    await _loadDevicePreferences();
    if (!currentStart()) return false;
    await _networkActivity.acquire(_networkActivityOwner);
    if (!currentStart()) return false;
    // Before capture opens: the grant must exist by the time the screen can
    // lock, and the typed service may only start while the app is visible.
    if (call.media.audio) {
      await _microphoneForeground.setActive(true);
      if (!currentStart()) return false;
    }
    // Present the platform mic/camera prompts before native capture starts,
    // but do not serialize them: two independent five-second waits used to
    // exceed CallService's whole media-start budget and tear down an otherwise
    // usable receive-only call. Begin both requests together and give the OS a
    // short shared preflight window. The futures keep running after the bound,
    // so a prompt can still complete while the call comes up.
    final permissionRequests = <Future<void>>[];
    Future<bool>? cameraPermission;
    _microphonePermission = null;
    if (call.media.audio) {
      diagnosticJournal.recordMediaPermission(video: false);
      final microphonePermission = MacMediaPermissions.requestMicrophone().then(
        (granted) async {
          devLog(() => 'xVeil[call-media]: mic permission=$granted');
          diagnosticJournal.recordMediaPermission(video: false, granted: granted);
          await _microphoneForeground.activateWhenMicrophoneGranted(
            Future<bool>.value(granted),
            isCurrent: () =>
                _mediaEpoch == epoch &&
                _activeCall?.callId == call.callId &&
                _microphoneState.belongsToCall(call.callId),
          );
          return granted;
        },
      );
      _microphonePermission = _microphonePermissionFactory(microphonePermission);
      permissionRequests.add(microphonePermission.then<void>((_) {}));
    }
    if (call.media.video) {
      diagnosticJournal.recordMediaPermission(video: true);
      cameraPermission = MacMediaPermissions.requestCamera().then((granted) {
        devLog(() => 'xVeil[call-media]: camera permission=$granted');
        diagnosticJournal.recordMediaPermission(video: true, granted: granted);
        return granted;
      });
      permissionRequests.add(cameraPermission.then<void>((_) {}));
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
    if (!currentStart()) return false;
    // The address the PEER knows us by, not this device's transport id. Both
    // ends hash (caller, callee) into the call-media master key, and the peer
    // can only put our IDENTITY there — a contact, an invite and a certificate
    // all carry that one. Asking the transport for its own node id made the two
    // ends hash different pairs on any device whose identity is not its own
    // key, and every sealed cell then arrived and failed to open.
    final localId = (await _transport.peerFacingNodeId()).bytes;
    if (!currentStart()) return false;
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
    // The identity's saved off-choice must reach the very first capture
    // frame, including a call immediately after unlocking the container.
    // This wait precedes the existing cancellation guard and native creation.
    try {
      if (_audioProcessingReady != null) await _audioProcessingReady;
    } catch (_) {
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
    final engine = _engineFactory(
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
    _videoFramingEligible = feedback && highQuality;
    if (feedback && highQuality) {
      _audioSourceCost = _transport.mediaPacketCost(
        chan,
        packetBytes: _audioCostPacketBytes,
      );
      _refreshVideoFraming(engine, chan);
      // A prepared child supplies its actual carrier/fragmentation model.
      // Legacy/unknown nodes retain the old direct hint, explicitly marked
      // unknown in diagnostics until a truthful source snapshot is available.
      final overhead = callMediaFramingOverhead(_audioSourceCost) ?? 209;
      _audioFramingEnabled = engine.setAudioPacketOverhead(overhead);
      _audioPacketOverhead = _audioFramingEnabled ? overhead : 0;
      devLog(
        () =>
            'xVeil[call-media]: adaptive audio packets=$_audioFramingEnabled overhead=$overhead',
      );
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
    // Older local diagnostic binaries may lack this optional symbol. They can
    // still receive, but a live UI change must report refusal, not success.
    if (engine.supportsNoiseSuppression &&
        !engine.setNoiseSuppression(_noiseSuppressionEnabled)) {
      engine.dispose();
      _transport.closeMediaChannel(chan);
      _chan = null;
      _chanPeer = null;
      return false;
    }
    _engine = engine;
    _startControlPolling();
    _diagnosticMediaController = this;
    // Device discovery and routing yield to stop/rebuild. Neither an old call
    // nor the previous engine of this same call may resume native startup or
    // reset the successor's liveness state after those waits.
    bool currentEngine() =>
        _mediaEpoch == epoch &&
        _engine == engine &&
        _activeCall?.callId == call.callId;
    await _restoreMicrophonePreference(engine, isCurrent: currentEngine);
    if (!currentEngine()) return false;
    await _restoreSpeakerPreference(engine, isCurrent: currentEngine);
    if (!currentEngine()) return false;
    // Liveness signal for the call FSM: poll rx_pkts so it can tell the peer's
    // media is still arriving even when the durable signaling heartbeat lags.
    _statsTimer?.cancel();
    _mediaReceiveActivity.reset(preserveLastRxAt: preserveReceiveHistory);
    _lastRxPkts = 0;
    _audioReceiveActivity.reset();
    _receiveSessionStartedAt = DateTime.now();
    _sourcePressure.reset();
    _lastNativeRxCount = _transport.mediaRecvCount(call.mediaPeer.bytes);
    _engineRxStalledSince = null;
    _lastRepairAt = null;
    var statsTick = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_engine != engine || _activeCall?.callId != call.callId) return;
      try {
        // Camera2 owns independent source evidence. A failed C++ statistics
        // read must not hide its already observed terminal state.
        if (_androidCameraCapture) _observeCameraCapture(engine, const {});
        final stats = engine.getStats();
        final now = DateTime.now();
        _mediaReceiveActivity.observe(stats, now);
        if (!_androidCameraCapture) _observeCameraCapture(engine, stats);
        diagnosticJournal.recordMediaStats(stats);
        if (diagnosticJournal.enabled && !Platform.isAndroid) {
          final lastPreviewUs = _lastLocalFrameUs;
          diagnosticJournal.recordDesktopVideoPreview(
            cameraExpected:
                _cameraState.enabledForCall(call.callId) &&
                _activeCall?.media.video == true &&
                !_screenSharing &&
                _screenStarting == null,
            framePumpRunning: _frameTimer?.isActive ?? false,
            frames: _localFrames,
            localReadErrors: _localPreviewReadErrors,
            remoteReadErrors: _remotePreviewReadErrors,
            lastFrameAgeMs: lastPreviewUs == null
                ? null
                : (_frameCadenceClock.elapsedMicroseconds - lastPreviewUs) ~/
                      1000,
          );
        }
        unawaited(
          diagnosticAudioOutput.sample(
            duringCall: true,
            stillCurrent: () =>
                _engine == engine && _activeCall?.callId == call.callId,
          ),
        );
        final channel = _chan;
        if (channel != null) {
          _refreshAudioFraming(engine, channel, stats: stats);
          _refreshVideoFraming(engine, channel, stats: stats);
        }
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
          nativeStats: stats,
          sampledAt: now,
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
          peerAudioConcealmentReportUs:
              stats['audio_peer_concealment_report_us'],
          localAudioConcealmentReportUs:
              stats['audio_local_concealment_report_us'],
        );
        _sourcePressured = sourcePressured;
        engine.setAudioSourcePressure(
          _sourcePressure.measuredAudioPressure,
          sampledAt: now,
          growthHoldStartedAt: _sourcePressure.growthHoldStartedAt,
        );
        if (sourcePressured != null && !_sourceFeedbackPending) {
          // One small outstanding report, with the ORIGINAL sampling time.
          // Delayed workers/writes cannot renew pressure after this call ends.
          _sourceFeedbackPending = true;
          unawaited(
            _transport
                .reportLocalSourcePressure(
                  pressured: sourcePressured,
                  sampledAt: now,
                  growthHoldStartedAt: _sourcePressure.growthHoldStartedAt,
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
            sampledAt: now,
            sourceBudgetPressured:
                _sourceFeedbackQueued > 0 && _sourcePressured == true,
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
              final target = adapter.targetForStart;
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
          if (kDiagnosticReportEnabled) {
            diagnosticJournal.recordVideoDelivery(
              adapter.videoDeliveryDiagnostics,
            );
          }
        }
      } catch (_) {}
    });
    // Establish the initial privacy posture before the ADM is started. The
    // native engine now keeps physical capture stopped while muted, so an
    // Android endpoint configured mic-off neither opens AudioRecord briefly
    // nor burns capture/Opus CPU just to encode silence. A pending Android
    // permission also keeps capture stopped while the receive path starts.
    final microphonePermission = _microphonePermission;
    final requestedMuted = _microphoneState.mutedForCall(call.callId);
    engine.setMicMuted(
      microphonePermission?.captureMuted(requestedMuted) ?? requestedMuted,
    );
    // Select communication/headset routing before opening the physical streams.
    await callAudioRouter.useDefaultFor(call.media);
    if (!currentEngine()) return false;
    final nativeAudioOk = engine.startAudio(send: true, recv: true);
    final startupStats = nativeAudioOk
        ? const <String, dynamic>{}
        : engine.getStats();
    final audioStart = callAudioStartState(
      started: nativeAudioOk,
      stats: startupStats,
    );
    _startedWithoutMicrophone = false;
    if (audioStart == CallAudioStartState.receiveOnly) {
      // A desktop without an input device must still hear its caller. Keep
      // only the proven working output, and expose the actual mute posture.
      if (!engine.trySetMicMuted(true)) {
        diagnosticJournal.recordAudioStart(success: false, stats: startupStats);
        return false;
      }
      _microphoneState.setMuted(true);
      _activeCall = call.copyWith(micOn: false);
      _startedWithoutMicrophone = true;
      // Initial startup reads the flag, but an active call can also reach this
      // branch during a rebuild. Report it through the same scoped feedback as
      // a later capture refusal so the FSM and peer stop advertising audio.
      _microphoneUnavailable.add(call.callId);
      devLog(
        () =>
            'xVeil[call-media]: capture unavailable; receiving audio with mic off',
      );
    }
    // Every exit below, including audio-only calls and deferred video, must
    // use the usable session result rather than the combined native result.
    final audioOk = audioStart != CallAudioStartState.failed;
    diagnosticJournal.recordAudioStart(success: audioOk, stats: startupStats);
    devLog(
      () => 'xVeil[call-media]: startAudio=$nativeAudioOk usable=$audioOk',
    );
    // An unavailable output or unknown startup failure still prevents a live
    // audio session. Only the positively measured capture-only failure above
    // permits receive-only audio, with mute reflected in CallService.
    if (call.media.audio && audioStart == CallAudioStartState.failed) {
      return false;
    }
    if (microphonePermission != null) {
      bool isCurrent() =>
          _mediaEpoch == epoch &&
          _engine == engine &&
          _activeCall?.callId == call.callId &&
          _microphoneState.belongsToCall(call.callId);
      void unavailable() {
        if (!isCurrent()) return;
        final requestedMuted = _microphoneState.mutedForCall(call.callId);
        _microphoneState.setMuted(true);
        _activeCall = _activeCall!.copyWith(micOn: false);
        _startedWithoutMicrophone = true;
        try {
          engine.trySetMicMuted(true);
        } catch (_) {}
        diagnosticJournal.record(
          DiagnosticEvent.microphoneControl,
          values: {
            DiagnosticMetric.enabled: requestedMuted ? 0 : 1,
            DiagnosticMetric.success: 0,
          },
        );
        _microphoneUnavailable.add(call.callId);
      }
      unawaited(
        microphonePermission.applyWhenGranted(
          isCurrent: isCurrent,
          isMuted: () => _microphoneState.mutedForCall(call.callId),
          onDenied: unavailable,
          apply: (muted) {
            if (!engine.trySetMicMuted(muted)) {
              unavailable();
              devLog(
                () => 'xVeil[call-media]: microphone capture refused after grant',
              );
              return;
            }
            if (!muted) _startedWithoutMicrophone = false;
            devLog(
              () => 'xVeil[call-media]: microphone grant applied captureMuted=$muted',
            );
          },
        ).catchError((Object _) {
          unavailable();
          devLog(() => 'xVeil[call-media]: microphone grant capture failed');
        }),
      );
    }
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
      final target = adapter.targetForStart;
      videoOk = engine.startVideo(
        send: true,
        recv: true,
        maxBitrateKbps: target.maxBitrateKbps,
        maxFps: target.maxFps,
      );
      if (!videoOk && !Platform.isAndroid) {
        _reportCameraStartOutcome(engine, false);
      }
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
        if (_androidCameraCapture) {
          // Do not hold the call FSM in `connecting` while camera permission or
          // device opening completes; the receive pipeline is already mounted.
          unawaited(_cameraState.startWhenGranted(
            callId: call.callId,
            permission: cameraPermission ?? Future<bool>.value(false),
            isCurrent: () => _mediaEpoch == epoch && _engine == engine &&
                _activeCall?.callId == call.callId,
            onDenied: () {
              // The old permission result cannot reject a newer capture that
              // the person has already started through the live controls.
              if (_androidNativeCam != null || _androidCam != null) return;
              diagnosticJournal.recordCameraStart(
                success: false,
                origin: CameraStartOrigin.callStart,
              );
              _reportCameraStartOutcome(engine, false);
            },
            start: () => _startAndroidCam(
              engine,
              highQuality: highQuality,
              origin: CameraStartOrigin.callStart,
            ),
          ));
        } else {
          _startDesktopCamera(
            engine,
            origin: CameraStartOrigin.callStart,
            deviceId: _selectedCameraId,
          );
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
          _reportScreenShareStopped(call.callId, epoch);
        }
      } else if (Platform.isMacOS) {
        if (!await setScreenShareEnabled(true)) {
          _rememberScreenSharing(false);
          _reportScreenShareStopped(call.callId, epoch);
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
    final now = DateTime.now();
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
      peerAudioDelayMs: _peerAudioPlayout.delayMs(now),
      peerCurrentAudioDelayMs: _peerAudioPlayout.currentDelayMs(now),
      peerTargetAudioDelayMs: _peerAudioPlayout.targetDelayMs(now),
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
    _localPreviewReadErrors = 0;
    _remotePreviewReadErrors = 0;
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
      } catch (_) {
        _remotePreviewReadErrors++;
      }
      // A bad remote frame must not suppress reading the independent local
      // camera preview (and vice versa). Neither read owns camera capture.
      try {
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
      } catch (_) {
        _localPreviewReadErrors++;
      }
    });
  }

  @override
  Future<bool> setVideoEnabled(bool enabled) async {
    final call = _activeCall;
    if (!enabled || call == null || (_engine == null && !_routeRepairing)) {
      return false;
    }
    if (call.media.video || call.media.screen) return true; // already mounted
    bool sameCall() =>
        _activeCall?.callId == call.callId &&
        _activeCall?.mediaIdentity == call.mediaIdentity;
    // Same bounded Apple TCC pre-prompt as a video call's start(): never let
    // the permission sheet hold the route-repair queue of the running call.
    final granted = await MacMediaPermissions.requestCamera().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!sameCall()) return false;
    devLog(() => 'xVeil[call-media]: mid-call camera permission=$granted');
    return _routeOperations.runForCall(
      call.callId,
      () => _activeCall?.callId,
      () async {
        // Permission belongs to the logical call. A repair may have replaced
        // its engine while the prompt was pending; mount on the current one.
        final engine = _engine;
        if (!sameCall() || engine == null) return false;
        final currentCall = _activeCall!;
        if (currentCall.media.video || currentCall.media.screen) return true;
        final epoch = _mediaEpoch;
        bool isCurrent() =>
            sameCall() && _mediaEpoch == epoch && _engine == engine;
        final profile = _highQualityRoute
            ? _directVideoProfile
            : _anonymousVideoProfile;
        final adapter = _videoAdapterForProfile(profile, engine);
        if (!_prepareVideoAudioAdmission(currentCall, engine, adapter)) {
          return false;
        }
        final target = adapter.targetForStart;
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
        await callAudioRouter.useDefaultFor(
          currentCall.media.copyWith(video: true),
        );
        if (!isCurrent()) return false;
        if (Platform.isAndroid) await _startAndroidVideoRenderer(engine);
        if (!isCurrent()) return false;
        // Keep newer mic/camera/screen intent and a committed route instead of
        // restoring the snapshot taken before permission or platform awaits.
        final current = _activeCall!;
        _activeCall = current.copyWith(
          media: current.media.copyWith(video: true),
        );
        if (_frameTimer == null) _startFramePump(engine);
        return true;
      },
    );
  }

  @override
  Future<void> stop() => _stopSession(clearActiveCall: true);

  Future<void> _retireNativeSource(
    VeilMediaEngine? engine,
    Future<void> Function() stop,
  ) {
    if (engine == null) return Future<void>.sync(stop);
    final completion = Completer<void>();
    final pending = _nativeRetirements.putIfAbsent(
      engine,
      Set<Future<void>>.identity,
    );
    pending.add(completion.future);
    // Register BEFORE invoking stop: clearing the native preview can notify a
    // synchronous listener which tears down this engine inside the call.
    unawaited(
      Future<void>.sync(stop).then<void>(
        (_) => completion.complete(),
        onError: (Object error, StackTrace stack) =>
            completion.completeError(error, stack),
      ),
    );
    void forget() {
      pending.remove(completion.future);
      if (pending.isEmpty && identical(_nativeRetirements[engine], pending)) {
        _nativeRetirements.remove(engine);
      }
    }

    unawaited(
      completion.future.then<void>(
        (_) => forget(),
        onError: (Object _, StackTrace _) => forget(),
      ),
    );
    return completion.future;
  }

  Future<void> _joinNativeRetirements(VeilMediaEngine engine) async {
    for (;;) {
      final pending = _nativeRetirements[engine];
      if (pending == null || pending.isEmpty) return;
      // The command's own caller retains its error contract. Engine teardown
      // joins all known replies with the existing best-effort stop policy.
      await Future.wait(
        pending.toList().map((stopped) => stopped.catchError((Object _) {})),
      );
    }
  }

  Future<void> _stopSession({
    required bool clearActiveCall,
    bool clearMicrophoneState = true,
    int? startingRequest,
  }) async {
    if (startingRequest == null) ++_startOperationEpoch;
    final epoch = ++_mediaEpoch;
    _audioMirrorLease.stop();
    for (final channel in _diagnosticRouteChannels) {
      try {
        _transport.closeMediaChannel(channel);
      } catch (_) {}
    }
    _diagnosticRouteChannels.clear();
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
    // A pending share belongs to the retiring media session. Its camera stop
    // or consent reply may still be outstanding after this teardown completes;
    // it must not suppress capture or answer a share request in the successor.
    // The request's finally clears only its own future.
    _screenStarting = null;
    _androidScreen?.rebindFrameSink(null);
    if (clearActiveCall) {
      _routeHandovers = 0;
      _startedWithoutMicrophone = false;
      _startedWithoutCamera = false;
      _activeCall = null;
      _microphonePermission = null;
      _bitrateAdapter = null;
      if (clearMicrophoneState) {
        _microphoneState.clear();
        _cameraState.clear();
      }
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
    // Retain the last real receipt across an internal rebuild. Rebase the
    // counter only after the replacement engine exists in start(): an old
    // engine still finishing teardown must not replay its count as new life.
    if (clearActiveCall) _mediaReceiveActivity.reset();
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
    // Detach this session's complete resource set BEFORE any teardown await.
    // A new start can proceed while native detaches acknowledge; it must not
    // discover/free this engine, and this continuation must never read its
    // replacement's fields after the fence.
    final videoRenderer = _androidVideoRenderer;
    _androidVideoRenderer = null;
    final nativeCam = _androidNativeCam;
    _androidNativeCam = null;
    final cam = _androidCam;
    _androidCam = null;
    final screen = _androidScreen;
    if (!keepScreenCapture) _androidScreen = null;
    final e = _engine;
    _engine = null;
    final ch = _chan;
    _chan = null;
    _chanPeer = null;
    _chanTransport = null;
    if (identical(_diagnosticMediaController, this)) {
      _diagnosticMediaController = null;
    }
    _mediaBatching = false;
    _compactRelayMedia = false;
    _audioFramingEnabled = false;
    _audioPacketOverhead = 0;
    _audioCostLastPackets = _audioCostLastBytes = 0;
    _audioCostPacketBytes = 200;
    _audioSourceCost = null;
    _videoFramingEligible = false;
    _videoFraming = CallVideoFraming();

    // Publishing may synchronously start another call. No remaining shared
    // session field is reset below; all cleanup uses only the captured owners.
    callVideoSendPausedForAudio.value = false;
    // A route repair keeps its call-scoped low-video prompt.
    if (clearActiveCall) callVideoPrompt.value = null;
    remoteVideoFrame.value = null;
    localVideoFrame.value = null;
    Future<void> settle(Future<void> Function() stop) async {
      try {
        await stop();
      } catch (_) {}
    }
    final nativeClosing = <Future<void>>[
      if (videoRenderer != null)
        settle(() => _retireNativeSource(e, videoRenderer.stop)),
      if (nativeCam != null)
        settle(() => _retireNativeSource(e, nativeCam.stop)),
    ];
    final closing = <Future<void>>[
      if (cam != null) settle(cam.stop),
      if (!keepScreenCapture && screen != null) settle(screen.stop),
    ];
    // Stop physical audio immediately. Only freeing the engine/video requires
    // the native Surface/Camera2 JNI fences; a delayed reply must not keep the
    // ended call recording or playing while its UI is already gone.
    if (e != null) {
      try {
        e.stopAudio();
      } catch (_) {}
    }
    if (ch != null) {
      try {
        _transport.closeMediaChannel(ch);
      } catch (_) {}
    }
    if (nativeClosing.isNotEmpty) await Future.wait(nativeClosing);
    if (e != null && (_nativeRetirements[e]?.isNotEmpty ?? false)) {
      await _joinNativeRetirements(e);
    }
    if (e != null) {
      try {
        e.stopVideo();
      } catch (_) {}
      try {
        e.dispose();
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
    if (clearActiveCall && epoch == _mediaEpoch) {
      await callAudioRouter.release();
      if (epoch != _mediaEpoch) return;
      await _networkActivity.release(_networkActivityOwner);
      if (epoch != _mediaEpoch) return;
      await _microphoneForeground.setActive(false);
    }
  }

  @override
  Future<bool> setMicMuted(bool muted) async {
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
        final captureMuted = _microphonePermission?.captureMuted(muted) ?? muted;
        final applied = _engine?.trySetMicMuted(captureMuted);
        if (!captureMuted && applied == true) {
          // A successful retry (including one during startup) supersedes the
          // old capture failure; the FSM must not remute a now-working input.
          _startedWithoutMicrophone = false;
        } else if (applied == false) {
          if (!captureMuted) {
            // A failed unmute may already have changed native intent before
            // capture failed. Close that intent again and preserve receive.
            _microphoneState.setMuted(true);
            _startedWithoutMicrophone = true;
            try {
              engine?.trySetMicMuted(true);
            } catch (_) {}
          }
          diagnosticJournal.record(
            DiagnosticEvent.microphoneControl,
            values: {
              DiagnosticMetric.enabled: muted ? 0 : 1,
              DiagnosticMetric.success: 0,
            },
          );
          return false;
        }
      }
    } catch (_) {
      if (!muted) {
        _microphoneState.setMuted(true);
        _startedWithoutMicrophone = true;
        try {
          _engine?.trySetMicMuted(true);
        } catch (_) {}
      }
      diagnosticJournal.record(
        DiagnosticEvent.microphoneControl,
        values: {
          DiagnosticMetric.enabled: muted ? 0 : 1,
          DiagnosticMetric.success: 0,
        },
      );
      return false;
    }
    diagnosticJournal.record(
      DiagnosticEvent.microphoneControl,
      values: {
        DiagnosticMetric.enabled: muted ? 0 : 1,
        DiagnosticMetric.success: 1,
      },
    );
    return true;
  }

  // A replacement start must await the same read, rather than treating an
  // in-flight load as completed and starting on the default devices.
  Future<void> _loadDevicePreferences() =>
      _devicePreferencesReady ??= _readDevicePreferences();

  Future<void> _readDevicePreferences() async {
    try {
      final prefs = await profilePreferences();
      _selectedCameraId = prefs.getString(_cameraPreferenceKey);
      _preferredMicrophoneLabel = prefs.getString(_microphonePreferenceKey);
      _preferredSpeakerLabel = prefs.getString(_speakerPreferenceKey);
    } catch (_) {
      // A device preference must never prevent media startup.
    }
  }

  Future<void> _restoreMicrophonePreference(
    VeilMediaEngine engine, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return;
    _selectedMicrophoneId = null;
    final preferred = _preferredMicrophoneLabel;
    final devices = await listMicrophones();
    if (!isCurrent()) return;
    // The ADM remembers numeric indices across engines. If a saved microphone
    // disappears, its former index may now identify a different input. Clear
    // that stale selection through the native role, not guessed device zero.
    // Retain the saved label so reconnecting the device can restore it later.
    final chosen =
        devices
            .where((device) => preferred != null && device.label == preferred)
            .firstOrNull ??
        devices.where((device) => device.followsSystem).firstOrNull;
    if (chosen == null) return;
    try {
      if (engine.selectAudioInput(chosen.id)) {
        _selectedMicrophoneId = chosen.id;
      }
    } catch (_) {}
  }

  /// Re-select the output the user last chose, by LABEL.
  ///
  /// Ids are not stable across reboots or replugs; the label is what a person
  /// recognised when they picked it. Mirrors the microphone, which has done
  /// this since it had a picker at all — the output had neither.
  Future<void> _restoreSpeakerPreference(
    VeilMediaEngine engine, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return;
    _selectedSpeakerId = null;
    final preferred = _preferredSpeakerLabel;
    final devices = await listSpeakers();
    if (!isCurrent()) return;
    final chosen =
        devices
            .where((device) => preferred != null && device.label == preferred)
            .firstOrNull ??
        devices.where((device) => device.followsSystem).firstOrNull;
    if (chosen == null) return;
    try {
      if (engine.selectAudioOutput(chosen.id)) {
        _selectedSpeakerId = chosen.id;
      }
    } catch (_) {}
  }

  @override
  Future<List<CallMediaDevice>> listCameras() async {
    final engine = _engine;
    if (engine == null) return const [];
    if (_androidCameraCapture) {
      final bridge = _androidNativeCam ?? _nativeCameraFactory();
      final devices = await bridge.listDevices();
      final selected =
          _androidNativeCam?.cameraId ??
          _androidCam?.cameraId ??
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
              followsSystem: entry.$2.id == systemAudioInputDeviceId,
              selected:
                  entry.$2.id == _selectedMicrophoneId ||
                  (Platform.isAndroid &&
                      _selectedMicrophoneId == null &&
                      entry.$1 == 0),
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
          .map(
            (device) => CallMediaDevice(
              id: device.id,
              label: device.label,
              kind: CallMediaDeviceKind.speaker,
              followsSystem: device.id == systemAudioOutputDeviceId,
              selected: device.id == _selectedSpeakerId,
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
    final call = _activeCall;
    final epoch = _mediaEpoch;
    if (engine == null || call == null) return false;
    // Discovery may outlive this call/profile. Bind before its first await,
    // without making optional preference I/O a gate on native audio routing.
    final preferencesOwner = ProfilePreferencesLifetime.current();
    bool current() =>
        _mediaEpoch == epoch &&
        _engine == engine &&
        _activeCall?.callId == call.callId &&
        preferencesOwner.isCurrent;
    final devices = await listMicrophones();
    if (!current()) return false;
    CallMediaDevice? chosen;
    for (final device in devices) {
      if (device.id == id) chosen = device;
    }
    if (chosen == null) return false;
    try {
      if (!engine.selectAudioInput(id)) return false;
      _selectedMicrophoneId = id;
      _preferredMicrophoneLabel = chosen.followsSystem ? null : chosen.label;
      final prefs = await preferencesOwner.preferences;
      if (chosen.followsSystem) {
        await prefs.remove(_microphonePreferenceKey);
      } else {
        await prefs.setString(_microphonePreferenceKey, chosen.label);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> selectSpeaker(String id) async {
    final engine = _engine;
    final call = _activeCall;
    final epoch = _mediaEpoch;
    if (engine == null || call == null) return false;
    final preferencesOwner = ProfilePreferencesLifetime.current();
    bool current() =>
        _mediaEpoch == epoch &&
        _engine == engine &&
        _activeCall?.callId == call.callId &&
        preferencesOwner.isCurrent;
    final devices = await listSpeakers();
    if (!current()) return false;
    CallMediaDevice? chosen;
    for (final device in devices) {
      if (device.id == id) chosen = device;
    }
    if (chosen == null) return false;
    try {
      if (!engine.selectAudioOutput(id)) return false;
      _selectedSpeakerId = id;
      _preferredSpeakerLabel = chosen.followsSystem ? null : chosen.label;
      final prefs = await preferencesOwner.preferences;
      if (chosen.followsSystem) {
        await prefs.remove(_speakerPreferenceKey);
      } else {
        await prefs.setString(_speakerPreferenceKey, chosen.label);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> selectScreen(String id) async {
    final engine = _engine;
    final call = _activeCall;
    final epoch = _mediaEpoch;
    if (engine == null || call == null || !Platform.isMacOS) return false;
    final operation = ++_screenSelectionEpoch;
    final preferencesOwner = ProfilePreferencesLifetime.current();
    bool current() =>
        _engine == engine &&
        _mediaEpoch == epoch &&
        _activeCall?.callId == call.callId &&
        operation == _screenSelectionEpoch &&
        preferencesOwner.isCurrent;
    final devices = await listScreens();
    if (!current()) return false;
    if (!devices.any((device) => device.id == id)) return false;
    final previous = _selectedScreenId;
    if (!_screenSharing) {
      _selectedScreenId = id;
      return true;
    }
    try {
      if (!engine.stopScreen()) return false;
    } catch (_) {
      return false;
    }
    bool start(String? sourceId) {
      if (!current()) return false;
      try {
        return engine.startScreen(
          width: _highQualityRoute ? 960 : 640,
          fps: _highQualityRoute ? 15 : 10,
          sourceId: sourceId,
        );
      } catch (_) {
        return false;
      }
    }

    if (start(id)) {
      if (!current()) return false;
      _selectedScreenId = id;
      return true;
    }
    if (!current()) return false;
    if (!start(previous) && current()) {
      // Stop succeeded and neither source could restart. Keep the call alive,
      // but report the actual loss so the FSM/peer stop advertising a share.
      _screenSharing = false;
      _rememberScreenSharing(false);
      _reportScreenShareStopped(call.callId, epoch);
    }
    return false;
  }

  @override
  Future<bool> selectCamera(String id) async {
    final engine = _engine;
    final call = _activeCall;
    final epoch = _mediaEpoch;
    if (engine == null || call == null) return false;
    final operation = ++_cameraOperationEpoch;
    final preferencesOwner = ProfilePreferencesLifetime.current();
    bool current() =>
        _mediaEpoch == epoch &&
        _engine == engine &&
        _activeCall?.callId == call.callId &&
        operation == _cameraOperationEpoch &&
        preferencesOwner.isCurrent;
    final devices = await listCameras();
    if (!current()) return false;
    if (!devices.any((device) => device.id == id)) return false;
    final captureNow =
        _cameraState.enabledForCall(call.callId) &&
        _activeCall?.screenOn != true &&
        !_screenSharing &&
        _screenStarting == null;
    if (!_androidCameraCapture && captureNow) {
      final previous = _selectedCameraId;
      var started = false;
      try {
        if (!engine.stopCamera()) return false;
        started = _startDesktopCamera(
          engine,
          origin: CameraStartOrigin.deviceSelection,
          deviceId: id,
        );
      } catch (_) {}
      if (!started) {
        // A rejected selection is not a new preference. Try the exact former
        // choice once; never silently open a different camera as fallback.
        try {
          if (engine.stopCamera()) {
            _startDesktopCamera(
              engine,
              origin: CameraStartOrigin.recovery,
              deviceId: previous,
            );
          }
        } catch (_) {}
        return false;
      }
    }
    if (_androidCameraCapture && captureNow) {
      final previous = _selectedCameraId;
      // Probe refusal must not turn camera intent OFF before the old source
      // has had its recovery attempt. Both attempts retain this exact owner.
      final selectionCurrent = current;
      Future<bool> stopOwnedSources() async {
        if (!current()) return false;
        final native = _androidNativeCam;
        _androidNativeCam = null;
        if (native != null) await _retireNativeSource(engine, native.stop);
        // A newer choice may already own a source after the native stop.
        if (!current()) return false;
        final fallback = _androidCam;
        _androidCam = null;
        if (fallback != null) await fallback.stop();
        return current();
      }

      if (!await stopOwnedSources()) return false;
      await _startAndroidCam(
        engine,
        highQuality: _highQualityRoute,
        origin: CameraStartOrigin.deviceSelection,
        requestedCameraId: id,
        isCurrent: selectionCurrent,
        reportOutcome: false,
      );
      if (!current()) return false;
      final selected =
          _androidNativeCam?.cameraId == id || _androidCam?.cameraId == id;
      if (!selected) {
        if (!await stopOwnedSources()) return false;
        _selectedCameraId = previous;
        await _startAndroidCam(
          engine,
          highQuality: _highQualityRoute,
          origin: CameraStartOrigin.recovery,
          requestedCameraId: previous,
          isCurrent: selectionCurrent,
          reportOutcome: false,
        );
        if (current()) {
          _reportCameraStartOutcome(
            engine,
            (_androidNativeCam?.isRunning ?? false) || _androidCam != null,
          );
        }
        return false;
      }
      _reportCameraStartOutcome(engine, true);
    }
    if (!current()) return false;
    _selectedCameraId = id;
    try {
      final prefs = await preferencesOwner.preferences;
      if (!current()) return false;
      await prefs.setString(_cameraPreferenceKey, id);
    } catch (_) {}
    // Off/share choices are deferred intentions. A live Android choice is
    // persisted only after the requested source actually starts.
    return current();
  }

  bool _startDesktopCamera(
    VeilMediaEngine engine, {
    required CameraStartOrigin origin,
    required String? deviceId,
  }) {
    final profile = _highQualityRoute
        ? _directVideoProfile
        : _anonymousVideoProfile;
    var started = false;
    try {
      started = engine.startCamera(
        width: profile.cameraWidth,
        height: profile.cameraHeight,
        fps: profile.maxFps,
        deviceId: deviceId,
      );
    } catch (_) {
      // The report retains a categorical result, never driver text or IDs.
    }
    Map<String, dynamic> captureStats = const {};
    if (diagnosticJournal.enabled) {
      try {
        captureStats = engine.getStats();
      } catch (_) {}
    }
    diagnosticJournal.recordCameraStart(
      success: started,
      origin: origin,
      stats: captureStats,
    );
    _reportCameraStartOutcome(engine, started);
    return started;
  }

  void _observeCameraCapture(
    VeilMediaEngine engine,
    Map<String, dynamic> stats,
  ) {
    // An explicit terminal state from the owned capturer, never a frame-rate
    // timeout: paused encoding and a slow network do not mean capture failed.
    final call = _activeCall;
    if (_engine != engine ||
        call == null ||
        _startedWithoutCamera ||
        _screenSharing ||
        _screenStarting != null ||
        !_cameraState.enabledForCall(call.callId)) {
      return;
    }
    if (_androidCameraCapture) {
      // The Camera2 bridge clears its own preview on an explicit native stop.
      // Its source-owned status, not the C++ engine's absent Android capturer,
      // decides whether the camera failed. Missing/malformed stats prove none.
      if (_androidNativeCam?.diagnostics['camera_running'] != false) return;
      diagnosticJournal.recordCameraStopped(const {});
    } else {
      final capture = stats['camera_capturing'];
      if (capture is! int || capture != 0) return;
      diagnosticJournal.recordCameraStopped(stats);
    }
    _reportCameraStartOutcome(engine, false);
  }

  void _reportCameraStartOutcome(VeilMediaEngine engine, bool started) {
    final call = _activeCall;
    if (_engine != engine ||
        call == null ||
        !_cameraState.enabledForCall(call.callId)) {
      return;
    }
    _startedWithoutCamera = !started;
    if (!started) _cameraUnavailable.add(call.callId);
  }

  @override
  void updateCameraIntent(bool enabled) {
    ++_cameraOperationEpoch;
    _cameraState.setEnabled(enabled);
    // A new intent supersedes queued failure evidence from the older attempt.
    if (enabled) _startedWithoutCamera = false;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    updateCameraIntent(enabled);
    final operation = _cameraOperationEpoch;
    final epoch = _mediaEpoch;
    final engine = _engine;
    if (engine == null) return;
    bool current() =>
        operation == _cameraOperationEpoch &&
        epoch == _mediaEpoch &&
        _engine == engine;
    if (enabled && (_screenSharing || _screenStarting != null)) return;
    final chan = _chan;
    if (enabled) {
      var admitted = false;
      try {
        admitted =
            chan != null && _transport.setMediaScreenSharing(chan, false) == 0;
      } catch (_) {}
      if (!admitted) {
        // The camera never starts if channel preparation refuses it. Report
        // the same failed posture as a capture refusal, without claiming a
        // driver failure or leaving the call UI waiting for nonexistent video.
        diagnosticJournal.recordCameraStart(
          success: false,
          origin: CameraStartOrigin.channelAdmission,
        );
        _reportCameraStartOutcome(engine, false);
        return;
      }
    }
    if (_androidCameraCapture) {
      if (enabled) {
        await _startAndroidCam(engine, highQuality: _highQualityRoute);
      } else {
        final nativeCam = _androidNativeCam;
        _androidNativeCam = null;
        if (nativeCam != null) {
          try {
            await _retireNativeSource(engine, nativeCam.stop);
          } catch (_) {}
        }
        if (!current()) return;
        final cam = _androidCam;
        _androidCam = null;
        if (cam != null) {
          try {
            await cam.stop();
          } catch (_) {}
        }
        if (!current()) return;
        _startFramePump(engine);
      }
    } else {
      try {
        if (enabled) {
          _startDesktopCamera(
            engine,
            origin: CameraStartOrigin.toggle,
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
        final cam = _androidCam;
        _androidCam = null;
        if (nativeCam != null) {
          await _retireNativeSource(engine, nativeCam.stop);
        }
        // This source is no longer visible to teardown. Retain its platform
        // stop with the engine so hangup cannot release the call slot while
        // the fallback camera is still retiring.
        if (cam != null) await _retireNativeSource(engine, cam.stop);
        if (epoch != _mediaEpoch) return false;
        if (_chan != chan ||
            _transport.setMediaScreenSharing(chan, true) != 0) {
          return false;
        }
        final bool started;
        try {
          started = await _startAndroidScreen(engine, epoch: epoch);
        } catch (_) {
          if (epoch == _mediaEpoch && _chan == chan) {
            _transport.setMediaScreenSharing(chan, false);
          }
          rethrow;
        }
        // The helper retires only the source this request created. Never read
        // the successor's shared source or reset its sharing state here.
        if (epoch != _mediaEpoch) return false;
        if (!started) _transport.setMediaScreenSharing(chan, false);
        _screenSharing = started;
        if (started) _rememberScreenSharing(true);
        if (started) _startFramePump(engine);
        if (!started && cameraWasRunning) {
          await _startAndroidCam(
            engine,
            highQuality: _highQualityRoute,
            restoringAfterScreenFailure: true,
            origin: CameraStartOrigin.recovery,
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
            _startDesktopCamera(
              engine,
              origin: CameraStartOrigin.recovery,
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

  Future<bool> _startAndroidScreen(
    VeilMediaEngine engine, {
    required int epoch,
  }) async {
    final callId = _activeCall?.callId;
    if (callId == null || _engine != engine) return false;
    _androidScreenPushLogged = false;
    late final AndroidScreenCaptureSource screen;
    screen = _screenCaptureFactory(() {
      // The same consented source can rebind to a replacement engine during
      // this call. Its identity, not its original engine/epoch, owns OS stop.
      if (_androidScreen != screen || _activeCall?.callId != callId) return;
      _androidScreen = null;
      final chan = _chan;
      if (chan != null) {
        _transport.setMediaScreenSharing(chan, false);
      }
      _screenSharing = false;
      _rememberScreenSharing(false);
      localVideoFrame.value = null;
      _reportScreenShareStopped(callId, _mediaEpoch);
    });
    _androidScreen = screen;
    final started = await screen.start(_androidScreenSink(engine, screen));
    if (_mediaEpoch != epoch ||
        _engine != engine ||
        _androidScreen != screen) {
      if (_androidScreen == screen) _androidScreen = null;
      try {
        await screen.stop();
      } catch (_) {}
      return false;
    }
    if (!started && _androidScreen == screen) _androidScreen = null;
    return started;
  }

  Future<void> _startAndroidVideoRenderer(VeilMediaEngine engine) async {
    final existing = _androidVideoRenderer;
    if (existing?.isRunning ?? false) return;
    if (existing != null) {
      _androidVideoRenderer = null;
      await _retireNativeSource(engine, existing.stop);
    }
    final renderer = AndroidNativeCallVideoRenderer();
    _androidVideoRenderer = renderer;
    final ok = await renderer.start(engineAddress: engine.nativeAddress);
    if (_engine != engine || _androidVideoRenderer != renderer) {
      if (ok) await _retireNativeSource(engine, renderer.stop);
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
    CameraStartOrigin origin = CameraStartOrigin.toggle,
    String? requestedCameraId,
    bool Function()? isCurrent,
    bool reportOutcome = true,
  }) async {
    final cameraId = requestedCameraId ?? _selectedCameraId;
    bool mayCapture() =>
        (isCurrent?.call() ?? true) &&
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
      await _retireNativeSource(engine, existingNative.stop);
    }
    if (!mayCapture()) return;
    if (_androidCam != null) return;
    final profile = highQuality ? _directVideoProfile : _anonymousVideoProfile;
    final nativeCam = _nativeCameraFactory();
    _androidNativeCam = nativeCam;
    final nativeOk = await nativeCam.start(
      engineAddress: engine.nativeAddress,
      width: profile.cameraWidth,
      height: profile.cameraHeight,
      fps: profile.maxFps,
      cameraId: cameraId,
    );
    if (!mayCapture() || _androidNativeCam != nativeCam) {
      if (nativeOk) await _retireNativeSource(engine, nativeCam.stop);
      if (_androidNativeCam == nativeCam) _androidNativeCam = null;
      return;
    }
    if (nativeOk) {
      _selectedCameraId = nativeCam.cameraId;
      diagnosticJournal.recordCameraStart(success: true, origin: origin);
      if (reportOutcome) _reportCameraStartOutcome(engine, true);
      devLog(
        () =>
            'xVeil[call-media]: native Camera2 started '
            '${profile.cameraWidth}x${profile.cameraHeight}@${profile.maxFps}',
      );
      return;
    }
    _androidNativeCam = null;
    devLog(() => 'xVeil[call-media]: native Camera2 failed; plugin fallback');
    final cam =
        _injectedCameraFactory?.call(highQuality, cameraId) ??
        AndroidCameraCapture(
          captureLifetime: _cameraLifetime,
          highQuality: highQuality,
          requestedCameraId: cameraId,
        );
    _androidCam = cam;
    var ok = false;
    try {
      ok = await cam.startAndroid420((
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
    } catch (_) {
      // A failed teardown during source startup can surface as an exception.
      // Retain receive/audio and report only while this source still owns ON.
    }
    final owned = mayCapture() && _androidCam == cam;
    if (owned) {
      diagnosticJournal.recordCameraStart(success: ok, origin: origin);
      if (reportOutcome) _reportCameraStartOutcome(engine, ok);
    }
    if (!ok || !owned) {
      if (_androidCam == cam) _androidCam = null;
      try {
        await cam.stop();
      } catch (_) {
        // The source lifetime retains any failed backend retirement.
      }
    } else {
      _selectedCameraId = cam.cameraId;
      _startFramePump(engine);
    }
  }
}
