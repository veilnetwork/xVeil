import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:veil_media/veil_media.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/group_call.dart';
import '../domain/call_signal.dart';
import 'android_call_foreground.dart';
import 'android_camera_capture.dart';
import 'android_screen_capture.dart';
import 'call_service.dart' show CallMediaDevice, screenSourceDeviceKind;
import 'call_audio_route.dart';
import 'call_microphone_state.dart';
import 'desktop_screen_capture_start.dart';
import 'call_bitrate_adapter.dart';
import 'call_audio_receive_activity.dart';
import 'call_audio_source_pressure.dart';
import 'group_call_service.dart';
import 'group_call_audio_adapter.dart';
import 'mac_media_permissions.dart';
import 'media_ffi.dart';

abstract interface class GroupMediaChannelTransport {
  Future<Uint8List> localNodeId();

  /// Open a media datagram channel to one room participant. The keys are
  /// required for the same reason as in a 1:1 call: the channel seals every
  /// cell with them and has no unsealed mode.
  Future<int> open(
    NodeId peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
  });

  void close(int channel);

  /// Select only this endpoint's independent screen producer.
  int setScreenSharing(int channel, bool on);

  /// Expiring, endpoint-local source admission; never sent to room peers.
  Future<bool> reportLocalSourcePressure({
    required bool pressured,
    required DateTime sampledAt,
  });
}

class VeilGroupMediaChannelTransport implements GroupMediaChannelTransport {
  VeilGroupMediaChannelTransport(this._transport);

  final VeilFlutterTransport _transport;

  @override
  // The authenticated room roster names identities. A linked device's SDK
  // node id differs: using it opens a channel to our own roster entry and
  // derives keys/SSRCs that the other participants cannot reproduce.
  Future<Uint8List> localNodeId() async =>
      (await _transport.peerFacingNodeId()).bytes;

  @override
  Future<int> open(
    NodeId peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
  }) => _transport.openMediaChannel(peer.bytes, txKey: txKey, rxKey: rxKey);

  @override
  int setScreenSharing(int channel, bool on) =>
      _transport.setMediaScreenSharing(channel, on);

  @override
  void close(int channel) => _transport.closeMediaChannel(channel);

  @override
  Future<bool> reportLocalSourcePressure({
    required bool pressured,
    required DateTime sampledAt,
  }) => _transport.reportLocalSourcePressure(
    pressured: pressured,
    sampledAt: sampledAt,
  );
}

/// Resolves the room-scoped root secret the per-pair media keys hang off.
/// Null means this device cannot seal for that room, and therefore must not
/// open a media channel into it.
typedef GroupCallMediaSecretResolver =
    Future<Uint8List?> Function(GroupCall call);

Uint8List _groupMediaHash(Iterable<List<int>> parts) {
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

/// Directional media keys for ONE pair of room participants, derived from the
/// room's [roomSecret] and the two node ids.
///
/// The pair master is order-independent (ids sorted), so both endpoints agree;
/// the directional keys are order-DEPENDENT, so A's tx is B's rx. Every member
/// of the room can derive every pair's keys, and that is not a weakness here:
/// who said what is settled by the signature the sender puts on its call
/// signal, while this seal exists to keep the RELAYS carrying the datagrams —
/// which are not members — out of the audio.
@visibleForTesting
({Uint8List txKey, Uint8List rxKey}) deriveGroupCallMediaKeys({
  required Uint8List roomSecret,
  required NodeId localNode,
  required NodeId peerNode,
}) {
  if (roomSecret.length != 32) {
    throw ArgumentError('roomSecret must be 32 bytes');
  }
  if (localNode == peerNode) {
    throw ArgumentError('a participant has no media channel to itself');
  }
  final ordered = localNode.hex.compareTo(peerNode.hex) < 0
      ? [localNode, peerNode]
      : [peerNode, localNode];
  Uint8List? master;
  try {
    master = _groupMediaHash([
      utf8.encode('xveil/group-call-media/pair/v1'),
      const [0],
      roomSecret,
      const [0],
      ordered[0].bytes,
      ordered[1].bytes,
    ]);
    Uint8List directionKey(NodeId from, NodeId to) => _groupMediaHash([
      utf8.encode('xveil/group-call-media/direction/v1'),
      const [0],
      master!,
      from.bytes,
      to.bytes,
    ]);
    return (
      txKey: directionKey(localNode, peerNode),
      rxKey: directionKey(peerNode, localNode),
    );
  } finally {
    master?.fillRange(0, master.length, 0);
  }
}

abstract interface class GroupAudioEngine {
  bool addPeer({required int channel, required NodeId peer});
  bool removePeer(NodeId peer);
  bool startAudio();
  bool stopAudio();
  void setMicMuted(bool muted);
  int peerRxPackets(NodeId peer);
  Map<String, dynamic> getStats() => const {};
  bool get supportsAudioBudget => false;
  bool setAudioBudget({required int packetMs, required int payloadBps}) =>
      false;
  bool setVideoBitrate({required int maxBitrateKbps, required num maxFps}) =>
      false;
  bool get supportsLowRateVideo => false;
  bool get supportsVideoSendPause => false;
  bool setVideoSendPaused(bool paused) => false;
  bool startVideo() => false;
  bool stopVideo() => true;
  bool startCamera() => false;
  bool stopCamera() => true;
  bool startScreen({String? sourceId}) => false;
  bool stopScreen() => true;
  List<MediaDevice> listScreens() => const [];
  bool pushVideoFrame(
    Uint8List y,
    Uint8List u,
    Uint8List v,
    int width,
    int height,
  ) => false;
  VeilVideoFrame? peerVideoFrame(NodeId peer) => null;
  VeilVideoFrame? localVideoFrame() => null;
  void dispose();
}

typedef GroupAudioEngineFactory = GroupAudioEngine? Function(Uint8List localId);

@visibleForTesting
bool supportsNativeGroupMedia(String operatingSystem) =>
    const {'macos', 'ios', 'android', 'linux'}.contains(operatingSystem);

class NativeGroupAudioEngine implements GroupAudioEngine {
  NativeGroupAudioEngine._(this._engine);

  final VeilGroupMediaEngine _engine;

  static NativeGroupAudioEngine? create(Uint8List localId) {
    final engine = VeilGroupMediaEngine.create(localId: localId);
    return engine == null ? null : NativeGroupAudioEngine._(engine);
  }

  @override
  bool addPeer({required int channel, required NodeId peer}) =>
      _engine.addPeer(veilChan: channel, peerId: peer.bytes);

  @override
  bool removePeer(NodeId peer) => _engine.removePeer(peer.bytes);

  @override
  bool startAudio() => _engine.startAudio();

  @override
  bool stopAudio() => _engine.stopAudio();

  @override
  void setMicMuted(bool muted) => _engine.setMicMuted(muted);

  @override
  int peerRxPackets(NodeId peer) => _engine.peerRxPackets(peer.bytes);

  @override
  Map<String, dynamic> getStats() => _engine.getStats();

  @override
  bool get supportsAudioBudget => _engine.supportsAudioBudget;

  @override
  bool setAudioBudget({required int packetMs, required int payloadBps}) =>
      _engine.setAudioBudget(packetMs: packetMs, payloadBps: payloadBps);

  @override
  bool get supportsLowRateVideo => _engine.supportsLowRateVideo;

  @override
  bool get supportsVideoSendPause => _engine.supportsVideoSendPause;

  @override
  bool setVideoSendPaused(bool paused) => _engine.setVideoSendPaused(paused);

  @override
  bool setVideoBitrate({required int maxBitrateKbps, required num maxFps}) =>
      _engine.setVideoBitrate(maxBitrateKbps: maxBitrateKbps, maxFps: maxFps);

  @override
  bool startVideo() => _engine.startVideo();

  @override
  bool stopVideo() => _engine.stopVideo();

  @override
  bool startCamera() => _engine.startCamera();

  @override
  bool stopCamera() => _engine.stopCamera();

  @override
  bool startScreen({String? sourceId}) =>
      _engine.startScreen(sourceId: sourceId);

  @override
  bool stopScreen() => _engine.stopScreen();

  @override
  List<MediaDevice> listScreens() => _engine.listScreenInputs();

  @override
  bool pushVideoFrame(
    Uint8List y,
    Uint8List u,
    Uint8List v,
    int width,
    int height,
  ) => _engine.pushVideoFrame(y, u, v, width, height);

  @override
  VeilVideoFrame? peerVideoFrame(NodeId peer) =>
      _engine.getPeerVideoFrame(peer.bytes);

  @override
  VeilVideoFrame? localVideoFrame() => _engine.getLocalVideoFrame();

  @override
  void dispose() => _engine.dispose();
}

/// Production N-party audio/video controller.
///
/// One native engine owns the microphone, Opus/VP8 encoders, shared capture
/// source and WebRTC mixer. Dart reconciles the authenticated room roster,
/// pumps Android camera I420 into the native source, and pulls only the latest
/// decoded RGBA frames for UI rendering. RTP/RTCP and decoded PCM stay native.
class VeilGroupCallMediaController implements GroupCallMediaController {
  VeilGroupCallMediaController(
    this._transport, {
    required GroupCallMediaSecretResolver roomMediaSecret,
    this._engineFactory = NativeGroupAudioEngine.create,
    Future<bool> Function()? requestMicrophone,
    Future<bool> Function()? requestCamera,
    bool? desktopScreenCaptureSupported,
    this._statsInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : // Public `roomMediaSecret:` param → private field, as with `media:` on
       // GroupCallService.
       // ignore: prefer_initializing_formals
       _roomMediaSecret = roomMediaSecret,
       _requestMicrophone = requestMicrophone ?? _defaultMicPermission,
       _requestCamera = requestCamera ?? _defaultCameraPermission,
       _desktopScreenCaptureSupported =
           desktopScreenCaptureSupported ?? Platform.isMacOS,
       _now = now ?? DateTime.now;

  // Keep this in sync with the platforms that bundle the group-engine ABI.
  static bool get isSupportedPlatform =>
      supportsNativeGroupMedia(Platform.operatingSystem);

  final GroupMediaChannelTransport _transport;
  final GroupCallMediaSecretResolver _roomMediaSecret;
  final GroupAudioEngineFactory _engineFactory;
  final Future<bool> Function() _requestMicrophone;
  final Future<bool> Function() _requestCamera;
  // The injected engine's screen capability can differ from the test host.
  final bool _desktopScreenCaptureSupported;
  final Duration _statsInterval;
  final DateTime Function() _now;
  final AndroidScreenCaptureFactory _screenCaptureFactory =
      createAndroidScreenCapture;
  final Map<String, _GroupPeerChannel> _peers = {};
  bool _screenSourceSelected = false;
  final Map<String, int> _lastRxPackets = {};
  final Map<String, DateTime> _lastRxAt = {};
  final Map<String, CallAudioReceiveActivity> _audioReceiveActivity = {};
  final _sourcePressure = CallAudioSourcePressure();
  final Set<String> _expectedMediaPeers = {};
  bool? _sourcePressured;
  int? _lastAudioLatencyRecoveryCount;
  GroupCallAudioAdapter? _audioAdapter;
  bool _sourceFeedbackPending = false;
  int _sourceFeedbackQueued = 0;
  int _sourceFeedbackSkipped = 0;
  bool _supportsAudioReceiveStats = false;
  bool _supportsAudioReceiveAgeStats = false;
  int _peerAudioPlayoutPeers = 0;
  Map<String, dynamic> _latestNativeStats = const {};
  DateTime? _latestNativeStatsAt;

  // The debug API reads the same sample used by the audio-priority policy;
  // polling the API must not cause additional native worker/RTCP sampling.
  Map<String, dynamic> get debugNativeStats => _engine == null
      ? const {}
      : {
          ..._latestNativeStats,
          'local_source_pressured': _sourcePressured,
          'local_source_feedback_queued': _sourceFeedbackQueued,
          'local_source_feedback_skipped': _sourceFeedbackSkipped,
          if (_audioAdapter case final adapter?)
            'local_audio_budget': {
              'packet_ms': adapter.target.packetMs,
              'payload_bps': adapter.target.payloadBps,
              'pending': adapter.pending,
              'level': adapter.level,
            },
        };
  DateTime? get debugNativeStatsAt => _latestNativeStatsAt;
  final Set<String> _expectedAudioPeers = {};
  final Map<String, ValueNotifier<VeilVideoFrame?>> _peerVideoFrames = {};
  final ValueNotifier<VeilVideoFrame?> localVideoFrame = ValueNotifier(null);

  GroupAudioEngine? _engine;
  Timer? _statsTimer;
  Timer? _frameTimer;
  AndroidCameraCapture? _androidCamera;
  AndroidScreenCaptureSource? _androidScreen;
  bool _androidScreenPushLogged = false;
  final StreamController<void> _screenShareStops = StreamController.broadcast();
  bool _videoRunning = false;
  bool _cameraEnabled = false;
  bool _audioEnabled = false;
  final _microphoneState = CallMicrophoneState();
  CallBitrateAdapter? _bitrateAdapter;
  bool _screenSharing = false;
  String? _selectedScreenId;
  Future<void> _tail = Future<void>.value();

  static Future<bool> _defaultMicPermission() async {
    if (!Platform.isMacOS) return true;
    return MacMediaPermissions.requestMicrophone().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  static Future<bool> _defaultCameraPermission() async {
    if (!Platform.isMacOS) return true;
    return MacMediaPermissions.requestCamera().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  @override
  Stream<void> get screenShareStopped => _screenShareStops.stream;

  // Guarded for the same reason as the 1:1 controller's pair: read from the
  // overlay outside any catch, and meaningless without an engine anyway.
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
  Future<bool> start(GroupCall call) => _locked(() async {
    _microphoneState.beginCall(call.callId, micOn: call.micOn);
    await _stopLocked(clearMicrophoneState: false);
    _audioEnabled = call.media.audio;
    // Match direct calls: bound the permission prompt, then bring up playout
    // even when capture permission is denied or still pending.
    if (call.media.audio) {
      final micGranted = await _requestMicrophone();
      devLog(() => 'xVeil[group-call-media]: mic permission=$micGranted');
    }
    if ((call.media.video || call.media.screen) &&
        (Platform.isMacOS || Platform.isIOS)) {
      final cameraGranted = await _requestCamera();
      devLog(() => 'xVeil[group-call-media]: camera permission=$cameraGranted');
    }
    final localId = await _transport.localNodeId();
    _localNode = NodeId(localId);
    _localIdHex = _localNode!.hex;
    final engine = _engineFactory(localId);
    if (engine == null) return false;
    _engine = engine;
    // Capture intent can change while permission or channel setup is pending.
    // Apply it before audio starts, then keep it as the video policy's source.
    engine.setMicMuted(_microphoneState.mutedForCall(call.callId));
    // Before capture opens: keeps AudioRecord unmuted once the screen locks;
    // released by _stopLocked on every teardown path.
    if (call.media.audio) {
      await AndroidCallForegroundService.setActive(true);
    }
    await _syncPeersLocked(call);
    if (call.media.audio && engine.supportsAudioBudget) {
      _audioAdapter = GroupCallAudioAdapter();
      if (_applyAudioBudget(engine, _audioAdapter!) == false) {
        await _stopLocked();
        return false;
      }
    }
    if (call.media.audio) {
      await callAudioRouter.useDefaultFor(call.media);
    }
    final audioReady = !call.media.audio || engine.startAudio();
    var videoReady = !(call.media.video || call.media.screen);
    if (!videoReady) {
      videoReady = await _startVideoLocked(
        startCamera: call.cameraOn && call.media.video,
        startScreen: call.screenOn || call.media.screen,
      );
    }
    if (!audioReady || !videoReady) {
      await _stopLocked();
      return false;
    }
    _statsTimer = Timer.periodic(_statsInterval, (_) => _pollStats(engine));
    devLog(
      () =>
          'xVeil[group-call-media]: audio started peers=${_peers.length} '
          'video=${call.media.video || call.media.screen}',
    );
    return true;
  });

  @override
  Future<void> update(GroupCall call) => _locked(() async {
    if (_engine == null) return;
    await _syncPeersLocked(call);
    final roomHasVideo =
        call.media.video ||
        call.media.screen ||
        call.participants.values.any(
          (participant) => participant.media.video || participant.media.screen,
        );
    if (roomHasVideo && !_videoRunning) {
      await _startVideoLocked(
        startCamera: call.cameraOn && call.media.video,
        startScreen: call.screenOn,
      );
    }
  });

  @override
  Future<bool> setVideoEnabled(bool enabled) async {
    if (!enabled) return false;
    if (Platform.isMacOS || Platform.isIOS) {
      final granted = await _requestCamera();
      if (!granted) return false;
    }
    return _locked(() async {
      final engine = _engine;
      if (engine == null) return false;
      if (_videoRunning) return true;
      return _startVideoLocked();
    });
  }

  Future<bool> _startVideoLocked({
    bool startCamera = false,
    bool startScreen = false,
  }) async {
    final engine = _engine;
    if (engine == null) return false;
    if (_videoRunning) return true;
    final adapter = _bitrateAdapter = CallBitrateAdapter(
      baseBitrateKbps: 150,
      baseFps: 15,
      supportsLowRateVideo: engine.supportsLowRateVideo,
    );
    if (engine.supportsVideoSendPause) {
      Map<String, dynamic> stats;
      try {
        stats = engine.getStats();
      } catch (_) {
        stats = {'worker_stalled': 1};
      }
      if (stats['audio_rx_native_age_supported'] == 1) {
        _supportsAudioReceiveAgeStats = true;
      }
      _observeAudioPlayoutPeers(stats);
      adapter.prepareVideoSend(
        stats,
        sendAudioExpected: _audioEnabled && !_microphoneState.muted,
        receiveAudioExpected: _hasExpectedIncomingAudio,
        requireAudioReceivePlayout:
            _hasExpectedIncomingAudio && _supportsAudioReceiveAgeStats,
        audioReceiveDelayMs: _groupAudioReceiveDelay(stats),
        audioInterrupted: _audioInterrupted,
        audioReceiveQuality: _groupAudioReceiveQuality(stats),
        peerAudioDelayMs: _groupPeerAudioDelay(stats),
        requirePeerAudioPlayout: _requirePeerAudioPlayout,
      );
      // Mount while transmission is paused: an older engine may reject the
      // cold budget and need its retry immediately after start.
      if (!engine.setVideoSendPaused(true)) {
        return false;
      }
    }
    adapter.applyPendingTarget(
      (target) => engine.setVideoBitrate(
        maxBitrateKbps: target.maxBitrateKbps,
        maxFps: target.maxFps,
      ),
    );
    final ready = engine.startVideo();
    if (!ready) return false;
    _videoRunning = true;
    _cameraEnabled = startCamera;
    _applyVideoPolicy(engine, adapter);
    await callAudioRouter.useDefaultFor(const CallMedia(audio: true, video: true));
    _frameTimer ??= Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _pollFrames(engine),
    );
    if (startScreen) {
      if (!_selectScreenSource(true)) return false;
      if (Platform.isAndroid) {
        _screenSharing = await _startAndroidScreen(engine);
      } else {
        try {
          _screenSharing = engine.startScreen(sourceId: _selectedScreenId);
        } catch (_) {}
      }
      if (!_screenSharing) _selectScreenSource(false);
    } else if (startCamera) {
      if (Platform.isAndroid) {
        unawaited(_startAndroidCamera(engine));
      } else {
        try {
          engine.startCamera();
        } catch (_) {}
      }
    }
    return true;
  }

  bool _selectScreenSource(bool on) {
    final changed = <int>[];
    for (final peer in _peers.values) {
      if (_transport.setScreenSharing(peer.channel, on) != 0) {
        for (final channel in changed) {
          _transport.setScreenSharing(channel, _screenSourceSelected);
        }
        return false;
      }
      changed.add(peer.channel);
    }
    _screenSourceSelected = on;
    return true;
  }

  Future<void> _syncPeersLocked(GroupCall call) async {
    final engine = _engine;
    if (engine == null) return;
    final nextAudioPeers = call.participants.values
        .where((peer) => peer.nodeId.hex != _localIdHex && peer.media.audio)
        .map((peer) => peer.nodeId.hex)
        .toSet();
    final nextMediaPeers = call.participants.keys
        .where((key) => key != _localIdHex)
        .toSet();
    if (!setEquals(nextMediaPeers, _expectedMediaPeers) ||
        !setEquals(nextAudioPeers, _expectedAudioPeers)) {
      // A new/unmuted/replaced receiver cannot spend the old roster's earned
      // source headroom while channel creation or its measurements are pending.
      _sourcePressure.reset();
      _sourcePressured = null;
    }
    _expectedMediaPeers
      ..clear()
      ..addAll(nextMediaPeers);
    if (_audioEnabled &&
        _videoRunning &&
        nextAudioPeers.any((key) => !_expectedAudioPeers.contains(key))) {
      // Reduce BEFORE opening/adding the fanout, including an existing peer
      // that unmutes. The next fresh samples must establish this peer's audio
      // health rather than spending the old roster's earned video budget.
      final adapter = _bitrateAdapter;
      if (adapter != null && engine.supportsVideoSendPause) {
        adapter.prepareVideoSend(
          const {},
          audioReceiveQuality: (expected: true, ageMs: null),
        );
        _applyVideoPolicy(engine, adapter);
      }
    }
    _expectedAudioPeers
      ..clear()
      ..addAll(nextAudioPeers);
    final desired = <String, NodeId>{
      for (final participant in call.participants.values)
        if (participant.nodeId.hex != _localIdHex)
          participant.nodeId.hex: participant.nodeId,
    };

    for (final key in _peers.keys.toList(growable: false)) {
      if (desired.containsKey(key)) continue;
      final peer = _peers.remove(key)!;
      _lastRxPackets.remove(key);
      _lastRxAt.remove(key);
      _audioReceiveActivity.remove(key);
      _peerVideoFrames[key]?.value = null;
      try {
        engine.removePeer(peer.nodeId);
      } finally {
        _transport.close(peer.channel);
      }
    }
    final missing = desired.entries
        .where((entry) => !_peers.containsKey(entry.key))
        .toList(growable: false);
    if (missing.isEmpty) return;
    final localNode = _localNode;
    // Resolved BEFORE any open, exactly once per reconcile: the room secret is
    // what the mandatory per-pair keys are derived from, so a device that
    // cannot resolve it opens nothing rather than opening something unsealed.
    final roomSecret = localNode == null ? null : await _roomMediaSecret(call);
    if (localNode == null || roomSecret == null) {
      devLog(
        () =>
            'xVeil[group-call-media]: no room media secret for ${call.callId}; '
            'refusing to open ${missing.length} unsealable peer channel(s)',
      );
      return;
    }
    try {
      for (final entry in missing) {
        int? channel;
        final keys = deriveGroupCallMediaKeys(
          roomSecret: roomSecret,
          localNode: localNode,
          peerNode: entry.value,
        );
        try {
          channel = await _transport.open(
            entry.value,
            txKey: keys.txKey,
            rxKey: keys.rxKey,
          );
          if ((_screenSourceSelected &&
                  _transport.setScreenSharing(channel, true) != 0) ||
              !engine.addPeer(channel: channel, peer: entry.value)) {
            _transport.close(channel);
            continue;
          }
          _peers[entry.key] = _GroupPeerChannel(entry.value, channel);
          _peerVideoFrames.putIfAbsent(entry.key, () => ValueNotifier(null));
        } catch (error) {
          if (channel != null) _transport.close(channel);
          devLog(
            () =>
                'xVeil[group-call-media]: peer open failed '
                '${entry.value.short}: $error',
          );
        } finally {
          keys.txKey.fillRange(0, keys.txKey.length, 0);
          keys.rxKey.fillRange(0, keys.rxKey.length, 0);
        }
      }
    } finally {
      roomSecret.fillRange(0, roomSecret.length, 0);
    }
  }

  String? _localIdHex;
  NodeId? _localNode;

  void _pollStats(GroupAudioEngine expected) {
    if (_engine != expected) return;
    final now = _now();
    for (final entry in _peers.entries) {
      final packets = expected.peerRxPackets(entry.value.nodeId);
      final previous = _lastRxPackets[entry.key] ?? 0;
      if (packets > previous) {
        _lastRxPackets[entry.key] = packets;
        _lastRxAt[entry.key] = now;
      }
    }
    Map<String, dynamic> stats;
    try {
      stats = expected.getStats();
    } catch (error) {
      stats = const {};
      devLog(
        () => 'xVeil[group-call-media]: quality sample unavailable: $error',
      );
    }
    _latestNativeStats = Map.unmodifiable(stats);
    _latestNativeStatsAt = now;
    var audioRecovered = false;
    final recoveries = stats['audio_latency_recovery_count'];
    if (stats['worker_stalled'] == 0 && recoveries is int && recoveries >= 0) {
      final previous = _lastAudioLatencyRecoveryCount;
      audioRecovered =
          _hasExpectedIncomingAudio &&
          previous != null &&
          recoveries > previous;
      _lastAudioLatencyRecoveryCount = recoveries;
    }
    _observeAudioPlayoutPeers(stats);
    if (stats['audio_rx_supported'] == 1) _supportsAudioReceiveStats = true;
    if (stats['audio_rx_native_age_supported'] == 1) {
      _supportsAudioReceiveAgeStats = true;
    }
    if (_supportsAudioReceiveStats) {
      final receivers = stats['audio_receivers'];
      for (final key in _peers.keys) {
        final receiver = receivers is Map ? receivers[key] : null;
        final activity = _audioReceiveActivity.putIfAbsent(
          key,
          CallAudioReceiveActivity.new,
        );
        activity.observe({
          if (receiver is Map && stats['worker_stalled'] == 0)
            'audio_rx_pkts': receiver['audio_rx_pkts'],
          'worker_stalled': stats['worker_stalled'],
          if (receiver is Map) 'audio_delay_ms': receiver['audio_delay_ms'],
          if (receiver is Map)
            'audio_interruption_count': receiver['audio_interruption_count'],
          if (receiver is Map && _supportsAudioReceiveAgeStats)
            'audio_rx_native_age_ms': receiver['audio_rx_native_age_ms'],
        }, now);
      }
    }
    _reportSourcePressure(expected, stats, now, recovered: audioRecovered);
    final audioAdapter = _audioAdapter;
    if (audioAdapter != null) {
      audioAdapter.observe(
        stats,
        now,
        expectedPeers: _expectedMediaPeers.length,
        sending: _audioEnabled && !_microphoneState.muted,
        receiving: _hasExpectedIncomingAudio,
      );
      _applyAudioBudget(expected, audioAdapter);
    }
    if (!_videoRunning) return;
    final adapter = _bitrateAdapter;
    if (adapter == null) return;
    try {
      // The encoder budget is shared by the whole fanout. One healthy peer
      // cannot establish audio quality for peers whose RTCP has gone missing.
      // Native aggregates count only fresh AUDIO reports, not video reports.
      adapter.onNativeStats(
        stats,
        videoSendExpected: _cameraEnabled || _screenSharing,
        sendAudioExpected: _audioEnabled && !_microphoneState.muted,
        receiveAudioExpected: _hasExpectedIncomingAudio,
        requireAudioReceivePlayout:
            _hasExpectedIncomingAudio && _supportsAudioReceiveAgeStats,
        audioReceiveDelayMs: _groupAudioReceiveDelay(stats),
        audioInterrupted: _audioInterrupted,
        audioRecoveryObserved: audioRecovered,
        requirePeerAudioPlayout: _requirePeerAudioPlayout,
        peerAudioDelayMs: _groupPeerAudioDelay(stats),
        peerCurrentAudioDelayMs: _groupPeerAudioDelay(stats),
        peerAudioSampleSequence: _groupPeerAudioSequence(stats),
        peerAudioBufferGrowing: _groupPeerAudioSequence(stats) == null
            ? false
            : null,
        audioReceiveQuality: _groupAudioReceiveQuality(stats),
        expectedVideoFeedbackReports: _peers.length,
        expectedAudioFeedbackReports: _audioEnabled && !_microphoneState.muted
            ? _peers.length
            : null,
      );
      // Retry an abandoned video-worker operation on the next poll. Advancing
      // the policy is separate from successfully applying an encoder budget.
      if (expected.supportsVideoSendPause && adapter.audioReserve) {
        adapter.applyPendingPause(expected.setVideoSendPaused);
      }
      final applied = adapter.applyPendingTarget(
        (target) => expected.setVideoBitrate(
          maxBitrateKbps: target.maxBitrateKbps,
          maxFps: target.maxFps,
        ),
      );
      if (expected.supportsVideoSendPause && !adapter.audioReserve) {
        // A busy bitrate operation must not resume the previous larger budget.
        if (applied != false) {
          adapter.applyPendingPause(expected.setVideoSendPaused);
        }
      }
      if (applied == true) {
        final target = adapter.target;
        devLog(
          () =>
              'xVeil[group-call-media]: audio-quality retune level='
              '${adapter.level} ${target.maxBitrateKbps}kbps@${target.maxFps}fps',
        );
      }
    } catch (error) {
      devLog(
        () => 'xVeil[group-call-media]: quality sample unavailable: $error',
      );
    }
  }

  bool get _hasExpectedIncomingAudio =>
      _audioEnabled && _peers.keys.any(_expectedAudioPeers.contains);

  bool? _applyAudioBudget(
    GroupAudioEngine engine,
    GroupCallAudioAdapter adapter,
  ) {
    try {
      return adapter.applyPending(
        (target) => engine.setAudioBudget(
          packetMs: target.packetMs,
          payloadBps: target.payloadBps,
        ),
        _now(),
      );
    } catch (error) {
      devLog(() => 'xVeil[group-call-media]: audio retune unavailable: $error');
      return false;
    }
  }

  void _reportSourcePressure(
    GroupAudioEngine engine,
    Map<String, dynamic> stats,
    DateTime now, {
    required bool recovered,
  }) {
    final sendExpected =
        _audioEnabled &&
        !_microphoneState.muted &&
        _expectedMediaPeers.isNotEmpty;
    final receiveExpected = _audioEnabled && _expectedAudioPeers.isNotEmpty;
    final channelsComplete = _expectedMediaPeers.every(_peers.containsKey);
    var peerDelay = _groupPeerAudioDelay(stats);
    final reports = stats['audio_playout_reports'];
    // Any known overloaded listener suffices. Recovery requires fresh reports
    // for the whole fanout, including listeners whose microphones are muted.
    // Older peers without this optional report cannot prove source headroom.
    if ((reports is! num ||
            !reports.isFinite ||
            reports < _expectedMediaPeers.length ||
            !channelsComplete) &&
        (peerDelay == null ||
            peerDelay < CallAudioSourcePressure.playoutDegradeMs)) {
      peerDelay = null;
    }
    final receiveQuality = _groupAudioReceiveQuality(stats);
    final pressure = _sourcePressure.observe(
      sendExpected: sendExpected,
      receiveExpected: receiveExpected,
      requirePeerPlayout: sendExpected,
      peerDelayMs: peerDelay,
      peerCurrentDelayMs: peerDelay,
      peerSampleSequence: _groupPeerAudioSequence(stats),
      peerBufferGrowing: _groupPeerAudioSequence(stats) == null ? false : null,
      receiveDelayMs: channelsComplete ? _groupAudioReceiveDelay(stats) : null,
      receiveAgeMs: channelsComplete ? receiveQuality.ageMs : null,
      interrupted: _audioInterrupted,
      recovered: recovered,
      audioLossReportUs: stats['audio_loss_report_us'],
      peerAudioRecoveryReportUs: stats['audio_peer_recovery_report_us'],
      audioTxDrops: stats['audio_tx_rtp_drops'] is int
          ? stats['audio_tx_rtp_drops'] as int
          : null,
    );
    _sourcePressured = pressure;
    if (pressure == null || _sourceFeedbackPending) return;
    final epoch = _mediaEpoch;
    _sourceFeedbackPending = true;
    unawaited(
      Future<bool>.sync(
            () => _transport.reportLocalSourcePressure(
              pressured: pressure,
              sampledAt: now,
            ),
          )
          .then<void>(
            (queued) {
              if (_engine != engine || _mediaEpoch != epoch) return;
              if (queued) {
                _sourceFeedbackQueued++;
              } else {
                _sourceFeedbackSkipped++;
              }
            },
            onError: (Object _) {
              // Unavailable/older local IPC lets the original lease expire.
              if (_engine == engine && _mediaEpoch == epoch) {
                _sourceFeedbackSkipped++;
              }
            },
          )
          .whenComplete(() => _sourceFeedbackPending = false),
    );
  }

  void _applyVideoPolicy(GroupAudioEngine engine, CallBitrateAdapter adapter) {
    final applied = adapter.applyPendingTarget(
      (target) => engine.setVideoBitrate(
        maxBitrateKbps: target.maxBitrateKbps,
        maxFps: target.maxFps,
      ),
    );
    if (applied == false) {
      // Keep the old encoder budget off the new fanout while the worker is
      // busy. The stats poll retries the budget before releasing this pause.
      if (engine.supportsVideoSendPause) engine.setVideoSendPaused(true);
      adapter.invalidateAppliedState();
    } else if (engine.supportsVideoSendPause) {
      adapter.applyPendingPause(engine.setVideoSendPaused);
    }
  }

  int? _groupAudioReceiveDelay(Map<String, dynamic> stats) {
    if (stats['worker_stalled'] != 0) return null;
    var complete = true;
    var worstDelay = 0;
    final receivers = stats['audio_receivers'];
    for (final key in _peers.keys.where(_expectedAudioPeers.contains)) {
      final receiver = receivers is Map ? receivers[key] : null;
      final packets = receiver is Map ? receiver['audio_rx_pkts'] : null;
      final delay = receiver is Map ? receiver['audio_delay_ms'] : null;
      if (packets is! num ||
          !packets.isFinite ||
          packets <= 0 ||
          delay is! num ||
          !delay.isFinite ||
          delay < 0 ||
          delay > 60000) {
        complete = false;
        continue;
      }
      if (delay > worstDelay) worstDelay = delay.toInt();
    }
    return complete || worstDelay >= CallBitrateAdapter.playoutDegradeMs
        ? worstDelay
        : null;
  }

  bool get _audioInterrupted =>
      _audioEnabled &&
      _expectedAudioPeers.any(
        (key) => _audioReceiveActivity[key]?.interrupted == true,
      );

  ({bool expected, int? ageMs}) _groupAudioReceiveQuality(
    Map<String, dynamic> stats,
  ) {
    final peers = _peers.keys.where(_expectedAudioPeers.contains);
    if (!_audioEnabled || !_supportsAudioReceiveAgeStats || peers.isEmpty) {
      return (expected: false, ageMs: null);
    }
    var complete = true;
    var worstAge = 0;
    final receivers = stats['audio_receivers'];
    for (final key in peers) {
      final receiver = receivers is Map ? receivers[key] : null;
      final packets = receiver is Map ? receiver['audio_rx_pkts'] : null;
      final age = receiver is Map ? receiver['audio_rx_native_age_ms'] : null;
      if (stats['worker_stalled'] != 0 ||
          packets is! num ||
          !packets.isFinite ||
          packets <= 0 ||
          age is! num ||
          !age.isFinite ||
          age < 0) {
        complete = false;
        continue;
      }
      if (age > worstAge) worstAge = age.toInt();
    }
    // A known outage suffices to pause even if another peer is unknown.
    // Recovery requires every expected peer; mute/removal changes that set.
    return (
      expected: true,
      ageMs: complete || worstAge >= CallBitrateAdapter.audioReceivePauseMs
          ? worstAge
          : null,
    );
  }

  bool get _requirePeerAudioPlayout =>
      _audioEnabled && !_microphoneState.muted && _peerAudioPlayoutPeers > 0;

  int? _groupPeerAudioSequence(Map<String, dynamic> stats) {
    final value = stats['audio_playout_sequence'];
    return value is int && value >= 0 ? value : null;
  }

  void _observeAudioPlayoutPeers(Map<String, dynamic> stats) {
    final peers = stats['audio_playout_peers'];
    // A missing/failed sample cannot revoke a capability already observed.
    // Native explicitly reports zero when the last capable peer leaves.
    if (peers is num && peers.isFinite && peers >= 0) {
      _peerAudioPlayoutPeers = peers.toInt();
    }
  }

  // Require every capable receiver before earning recovery. A known poor
  // estimate still substantiates congestion when another estimate is missing.
  int? _groupPeerAudioDelay(Map<String, dynamic> stats) {
    final peers = _peerAudioPlayoutPeers;
    final reports = stats['audio_playout_reports'];
    final delay = stats['audio_playout_ms'];
    if (delay is! num ||
        !delay.isFinite ||
        delay < 0 ||
        delay > 60000 ||
        peers <= 0 ||
        reports is! num ||
        !reports.isFinite ||
        reports <= 0) {
      return null;
    }
    return reports >= peers || delay >= CallBitrateAdapter.playoutDegradeMs
        ? delay.toInt()
        : null;
  }

  void _pollFrames(GroupAudioEngine expected) {
    if (_engine != expected || !_videoRunning) return;
    try {
      final local = expected.localVideoFrame();
      if (local != null) localVideoFrame.value = local;
    } catch (_) {}
    for (final entry in _peers.entries) {
      try {
        final frame = expected.peerVideoFrame(entry.value.nodeId);
        if (frame != null) {
          _peerVideoFrames
                  .putIfAbsent(entry.key, () => ValueNotifier(null))
                  .value =
              frame;
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> invalidatePeerChannel(NodeId peer) => _locked(() async {
    final engine = _engine;
    final cached = _peers.remove(peer.hex);
    if (cached == null) return;
    _sourcePressure.reset();
    _sourcePressured = null;
    _lastRxPackets.remove(peer.hex);
    _lastRxAt.remove(peer.hex);
    _audioReceiveActivity.remove(peer.hex);
    _peerVideoFrames[peer.hex]?.value = null;
    if (engine != null) {
      try {
        engine.removePeer(cached.nodeId);
      } catch (_) {}
    }
    try {
      _transport.close(cached.channel);
    } catch (_) {}
    devLog(
      () =>
          'xVeil[group-call-media]: invalidated stale channel to '
          '${peer.short} (peer rejoined)',
    );
  });

  ValueListenable<VeilVideoFrame?> videoFrameFor(NodeId peer) =>
      _peerVideoFrames.putIfAbsent(peer.hex, () => ValueNotifier(null));

  @override
  DateTime? lastMediaRxAt(NodeId peer) => _lastRxAt[peer.hex];

  @override
  bool get supportsAudioReceiveStats => _supportsAudioReceiveStats;

  @override
  DateTime? lastAudioRxAt(NodeId peer) =>
      _audioReceiveActivity[peer.hex]?.lastRxAt;

  @override
  Future<void> setMicMuted(bool muted) async {
    final changed = muted != _microphoneState.muted;
    _microphoneState.setMuted(muted);
    if (changed) {
      _sourcePressure.reset();
      _sourcePressured = null;
    }
    try {
      final adapter = _bitrateAdapter;
      final engine = _engine;
      if (changed &&
          !muted &&
          _audioEnabled &&
          _videoRunning &&
          adapter != null &&
          engine != null &&
          engine.supportsVideoSendPause) {
        adapter.prepareVideoSend(const {}, requirePeerAudioPlayout: true);
        _applyVideoPolicy(engine, adapter);
      }
      _engine?.setMicMuted(muted);
    } catch (_) {}
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final engine = _engine;
    if (engine == null || !_videoRunning) return;
    _cameraEnabled = enabled;
    if (enabled && (_screenSharing || _screenStarting != null)) return;
    if (enabled && !_selectScreenSource(false)) return;
    if (Platform.isAndroid) {
      if (enabled) {
        await _startAndroidCamera(engine);
      } else {
        final camera = _androidCamera;
        _androidCamera = null;
        if (camera != null) {
          try {
            await camera.stop();
          } catch (_) {}
        }
        localVideoFrame.value = null;
      }
      return;
    }
    try {
      if (enabled) {
        engine.startCamera();
      } else {
        engine.stopCamera();
        localVideoFrame.value = null;
      }
    } catch (_) {}
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async {
    final engine = _engine;
    if (engine == null || !_videoRunning) return false;
    if (Platform.isAndroid) {
      if (!enabled) {
        final screen = _androidScreen;
        _androidScreen = null;
        if (screen != null) await screen.stop();
        if (_engine != engine) return false;
        _selectScreenSource(false);
        _screenSharing = false;
        return true;
      }
      if (_androidScreen != null) return true;
      final inFlight = _screenStarting;
      if (inFlight != null) return inFlight;
      final start = _startAndroidScreenShare(engine);
      _screenStarting = start;
      try {
        return await start;
      } finally {
        if (identical(_screenStarting, start)) _screenStarting = null;
      }
    }
    if (!_desktopScreenCaptureSupported) return false;
    try {
      if (enabled) {
        final started = startDesktopScreenCapture(
          selectSource: _selectScreenSource,
          startCapture: () => engine.startScreen(sourceId: _selectedScreenId),
          mayRestoreCamera: () =>
              _engine == engine && _videoRunning && _cameraEnabled,
          restoreCamera: () {
            engine.startCamera();
          },
        );
        _screenSharing = started;
        return started;
      }
      final stopped = engine.stopScreen();
      if (stopped) {
        _selectScreenSource(false);
        _screenSharing = false;
      }
      return stopped;
    } catch (_) {
      if (enabled) _selectScreenSource(false);
      return false;
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
      if (engine.startScreen(sourceId: id)) return true;
      _selectedScreenId = previous;
      engine.startScreen(sourceId: previous);
      return false;
    } catch (_) {
      _selectedScreenId = previous;
      return false;
    }
  }

  @override
  Future<void> stop() => _locked(_stopLocked);

  /// Bumped by every teardown, so work started before one can tell.
  ///
  /// `setScreenShareEnabled` is not taken under `_locked` while `stop()` is,
  /// so the two interleave: enabling share nulls the camera field and awaits
  /// the platform stop, and a teardown landing in that window finds no camera
  /// and no screen, tears the session down, and the continuation then creates
  /// and starts a foreground MediaProjection on the far side of it (report19
  /// XV19-H3). The direct controller has carried this since report18 XV18-H3;
  /// the group one is the same code and did not.
  int _mediaEpoch = 0;

  /// One screen start at a time.
  ///
  /// Two enables in flight both stop the camera, then both create a source
  /// into the same field and the same platform handler: the second overwrites
  /// the first, the first's source is left with nobody holding it, and
  /// teardown cannot stop what it cannot see. A second caller waits for the
  /// first answer instead, which is what it was asking for anyway.
  Future<bool>? _screenStarting;

  /// Stop the camera, then take the screen — checking, at each await, that
  /// the session that asked for this is still the session running.
  Future<bool> _startAndroidScreenShare(GroupAudioEngine engine) async {
    final epoch = _mediaEpoch;
    final cameraWasRunning = _androidCamera != null;
    final camera = _androidCamera;
    _androidCamera = null;
    if (camera != null) await camera.stop();
    if (epoch != _mediaEpoch) return false;
    if (!_selectScreenSource(true)) return false;
    final bool started;
    try {
      started = await _startAndroidScreen(engine);
    } catch (_) {
      if (epoch == _mediaEpoch) _selectScreenSource(false);
      rethrow;
    }
    if (epoch != _mediaEpoch) {
      // `_startAndroidScreen` publishes its source before awaiting the
      // platform start, so a teardown landing there stops a source that has
      // not started yet and the start then succeeds behind it. Reclaim it.
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
    if (!started) _selectScreenSource(false);
    _screenSharing = started;
    if (!started && cameraWasRunning) await _startAndroidCamera(engine);
    return started;
  }

  Future<void> _stopLocked({bool clearMicrophoneState = true}) async {
    if (clearMicrophoneState) _microphoneState.clear();
    _audioEnabled = false;
    _sourcePressure.reset();
    _sourcePressured = null;
    _sourceFeedbackQueued = 0;
    _lastAudioLatencyRecoveryCount = null;
    _audioAdapter = null;
    _sourceFeedbackSkipped = 0;
    _expectedMediaPeers.clear();
    _peerAudioPlayoutPeers = 0;
    _supportsAudioReceiveAgeStats = false;
    _latestNativeStats = const {};
    _latestNativeStatsAt = null;
    _expectedAudioPeers.clear();
    _mediaEpoch++;
    _screenSourceSelected = false;
    _statsTimer?.cancel();
    _statsTimer = null;
    _bitrateAdapter = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    _screenSharing = false;
    final androidCamera = _androidCamera;
    _androidCamera = null;
    if (androidCamera != null) {
      try {
        await androidCamera.stop();
      } catch (_) {}
    }
    final androidScreen = _androidScreen;
    _androidScreen = null;
    if (androidScreen != null) {
      try {
        await androidScreen.stop();
      } catch (_) {}
    }
    localVideoFrame.value = null;
    for (final frame in _peerVideoFrames.values) {
      frame.value = null;
    }
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      if (_videoRunning) {
        try {
          engine.stopVideo();
        } catch (_) {}
      }
      _videoRunning = false;
      _cameraEnabled = false;
      try {
        engine.stopAudio();
      } catch (_) {}
      for (final peer in _peers.values) {
        try {
          engine.removePeer(peer.nodeId);
        } catch (_) {}
        try {
          _transport.close(peer.channel);
        } catch (_) {}
      }
      try {
        engine.dispose();
      } catch (_) {}
    } else {
      for (final peer in _peers.values) {
        try {
          _transport.close(peer.channel);
        } catch (_) {}
      }
    }
    _videoRunning = false;
    _cameraEnabled = false;
    _peers.clear();
    _lastRxPackets.clear();
    _lastRxAt.clear();
    _audioReceiveActivity.clear();
    _supportsAudioReceiveStats = false;
    _localIdHex = null;
    _localNode = null;
    await callAudioRouter.release();
    await AndroidCallForegroundService.setActive(false);
  }

  Future<void> _startAndroidCamera(GroupAudioEngine engine) async {
    if (_androidCamera != null) return;
    final camera = AndroidCameraCapture();
    _androidCamera = camera;
    final started = await camera.start((y, u, v, width, height) {
      if (_engine != engine || !_videoRunning) return;
      try {
        engine.pushVideoFrame(y, u, v, width, height);
      } catch (_) {}
    });
    if (!started && _androidCamera == camera) _androidCamera = null;
  }

  Future<bool> _startAndroidScreen(GroupAudioEngine engine) async {
    _androidScreenPushLogged = false;
    late final AndroidScreenCaptureSource screen;
    screen = _screenCaptureFactory(() {
      if (_androidScreen != screen) return;
      _androidScreen = null;
      if (_engine == engine) _selectScreenSource(false);
      _screenSharing = false;
      localVideoFrame.value = null;
      _screenShareStops.add(null);
    });
    _androidScreen = screen;
    final started = await screen.start((y, u, v, width, height) {
      if (_engine != engine || !_videoRunning || _androidScreen != screen) {
        return;
      }
      try {
        final pushed = engine.pushVideoFrame(y, u, v, width, height);
        if (!_androidScreenPushLogged) {
          _androidScreenPushLogged = true;
          devLog(() => 'veil-screen: first group engine push=$pushed');
        }
      } catch (_) {}
    });
    if (!started && _androidScreen == screen) _androidScreen = null;
    return started;
  }

  bool get audioRunning => _engine != null;
  bool get videoRunning => _videoRunning;
  bool get localVideoReady => localVideoFrame.value != null;
  int get renderingPeerCount =>
      _peerVideoFrames.values.where((frame) => frame.value != null).length;
  int get connectedPeerCount => _peers.length;
  int get receivingPeerCount => _lastRxAt.length;
}

class _GroupPeerChannel {
  const _GroupPeerChannel(this.nodeId, this.channel);

  final NodeId nodeId;
  final int channel;
}
