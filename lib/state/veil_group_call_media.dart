import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:veil_media/veil_media.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/group_call.dart';
import 'android_camera_capture.dart';
import 'android_screen_capture.dart';
import 'group_call_service.dart';
import 'mac_media_permissions.dart';

abstract interface class GroupMediaChannelTransport {
  Future<Uint8List> localNodeId();
  Future<int> open(NodeId peer);
  void close(int channel);
}

class VeilGroupMediaChannelTransport implements GroupMediaChannelTransport {
  VeilGroupMediaChannelTransport(this._transport);

  final VeilFlutterTransport _transport;

  @override
  Future<Uint8List> localNodeId() async => (await _transport.nodeId()).bytes;

  @override
  Future<int> open(NodeId peer) => _transport.openMediaChannel(peer.bytes);

  @override
  void close(int channel) => _transport.closeMediaChannel(channel);
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
  bool startScreen() => false;
  bool stopScreen() => true;
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
  bool startScreen() => _engine.startScreen();

  @override
  bool stopScreen() => _engine.stopScreen();

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
    this._engineFactory = NativeGroupAudioEngine.create,
    Future<bool> Function()? requestMicrophone,
    Future<bool> Function()? requestCamera,
    this._statsInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _requestMicrophone = requestMicrophone ?? _defaultMicPermission,
       _requestCamera = requestCamera ?? _defaultCameraPermission,
       _now = now ?? DateTime.now;

  // Keep this in sync with the platforms that bundle the group-engine ABI.
  static bool get isSupportedPlatform =>
      supportsNativeGroupMedia(Platform.operatingSystem);

  final GroupMediaChannelTransport _transport;
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
    _localIdHex = NodeId(localId).hex;
    final engine = _engineFactory(localId);
    if (engine == null) return false;
    _engine = engine;
    await _syncPeersLocked(call);
    final audioReady = !call.media.audio || engine.startAudio();
    var videoReady = !(call.media.video || call.media.screen);
    if (!videoReady) {
      videoReady = engine.startVideo();
      _videoRunning = videoReady;
      if (videoReady) {
        _frameTimer = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => _pollFrames(engine),
        );
        if (call.screenOn || call.media.screen) {
          if (Platform.isAndroid) {
            await _startAndroidScreen(engine);
          } else {
            try {
              engine.startScreen();
            } catch (_) {}
          }
        } else if (call.cameraOn && call.media.video) {
          if (Platform.isAndroid) {
            unawaited(_startAndroidCamera(engine));
          } else {
            try {
              engine.startCamera();
            } catch (_) {}
          }
        }
      }
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
  });

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
    for (final entry in desired.entries) {
      if (_peers.containsKey(entry.key)) continue;
      int? channel;
      try {
        channel = await _transport.open(entry.value);
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
      }
    }
  }

  String? _localIdHex;

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
        return true;
      }
      if (_androidScreen != null) return true;
      final cameraWasRunning = _androidCamera != null;
      final camera = _androidCamera;
      _androidCamera = null;
      if (camera != null) await camera.stop();
      final started = await _startAndroidScreen(engine);
      if (!started && cameraWasRunning) await _startAndroidCamera(engine);
      return started;
    }
    if (!Platform.isMacOS) return false;
    try {
      if (enabled) return engine.startScreen();
      return engine.stopScreen();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() => _locked(_stopLocked);

  Future<void> _stopLocked() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _frameTimer?.cancel();
    _frameTimer = null;
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
          debugPrint('veil-screen: first group engine push=$pushed');
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
