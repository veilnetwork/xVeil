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
import 'android_call_foreground.dart';
import 'android_camera_capture.dart';
import 'android_screen_capture.dart';
import 'call_service.dart' show CallMediaDevice, screenSourceDeviceKind;
import 'call_audio_route.dart';
import 'group_call_service.dart';
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
}

class VeilGroupMediaChannelTransport implements GroupMediaChannelTransport {
  VeilGroupMediaChannelTransport(this._transport);

  final VeilFlutterTransport _transport;

  @override
  Future<Uint8List> localNodeId() async => (await _transport.nodeId()).bytes;

  @override
  Future<int> open(
    NodeId peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
  }) => _transport.openMediaChannel(peer.bytes, txKey: txKey, rxKey: rxKey);

  @override
  void close(int channel) => _transport.closeMediaChannel(channel);
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
    this._statsInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : // Public `roomMediaSecret:` param → private field, as with `media:` on
       // GroupCallService.
       // ignore: prefer_initializing_formals
       _roomMediaSecret = roomMediaSecret,
       _requestMicrophone = requestMicrophone ?? _defaultMicPermission,
       _requestCamera = requestCamera ?? _defaultCameraPermission,
       _now = now ?? DateTime.now;

  // Keep this in sync with the platforms that bundle the group-engine ABI.
  static bool get isSupportedPlatform =>
      supportsNativeGroupMedia(Platform.operatingSystem);

  final GroupMediaChannelTransport _transport;
  final GroupCallMediaSecretResolver _roomMediaSecret;
  final GroupAudioEngineFactory _engineFactory;
  final Future<bool> Function() _requestMicrophone;
  final Future<bool> Function() _requestCamera;
  final Duration _statsInterval;
  final DateTime Function() _now;
  final AndroidScreenCaptureFactory _screenCaptureFactory =
      createAndroidScreenCapture;
  final Map<String, _GroupPeerChannel> _peers = {};
  final Map<String, int> _lastRxPackets = {};
  final Map<String, DateTime> _lastRxAt = {};
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
    await _stopLocked();
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
    // Before capture opens: keeps AudioRecord unmuted once the screen locks;
    // released by _stopLocked on every teardown path.
    if (call.media.audio) {
      await AndroidCallForegroundService.setActive(true);
    }
    await _syncPeersLocked(call);
    final audioReady = !call.media.audio || engine.startAudio();
    if (audioReady && call.media.audio) {
      await callAudioRouter.useDefaultFor(call.media);
    }
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
    final ready = engine.startVideo();
    if (!ready) return false;
    _videoRunning = true;
    await callAudioRouter.setRoute(CallAudioRoute.speaker);
    _frameTimer ??= Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _pollFrames(engine),
    );
    if (startScreen) {
      if (Platform.isAndroid) {
        _screenSharing = await _startAndroidScreen(engine);
      } else {
        try {
          _screenSharing = engine.startScreen(sourceId: _selectedScreenId);
        } catch (_) {}
      }
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

  Future<void> _syncPeersLocked(GroupCall call) async {
    final engine = _engine;
    if (engine == null) return;
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
          if (!engine.addPeer(channel: channel, peer: entry.value)) {
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
    _lastRxPackets.remove(peer.hex);
    _lastRxAt.remove(peer.hex);
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
  Future<void> setMicMuted(bool muted) async {
    try {
      _engine?.setMicMuted(muted);
    } catch (_) {}
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final engine = _engine;
    if (engine == null || !_videoRunning) return;
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
    if (!Platform.isMacOS) return false;
    try {
      if (enabled) {
        final started = engine.startScreen(sourceId: _selectedScreenId);
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
    final started = await _startAndroidScreen(engine);
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
    _screenSharing = started;
    if (!started && cameraWasRunning) await _startAndroidCamera(engine);
    return started;
  }

  Future<void> _stopLocked() async {
    _mediaEpoch++;
    _statsTimer?.cancel();
    _statsTimer = null;
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
    _peers.clear();
    _lastRxPackets.clear();
    _lastRxAt.clear();
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
