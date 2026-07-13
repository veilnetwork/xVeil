import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:veil_media/veil_media.dart';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/transport/veil_flutter_transport.dart';
import '../domain/group_call.dart';
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
  void dispose();
}

typedef GroupAudioEngineFactory = GroupAudioEngine? Function(Uint8List localId);

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
  void dispose() => _engine.dispose();
}

/// Production N-party audio controller.
///
/// One native engine owns the microphone, Opus encoder and WebRTC mixer. Dart
/// only reconciles the authenticated room roster with caller-owned veil media
/// channels; RTP/RTCP and decoded PCM never cross the isolate boundary.
class VeilGroupCallMediaController implements GroupCallMediaController {
  VeilGroupCallMediaController(
    this._transport, {
    this._engineFactory = NativeGroupAudioEngine.create,
    Future<bool> Function()? requestMicrophone,
    this._statsInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _requestMicrophone = requestMicrophone ?? _defaultMicPermission,
       _now = now ?? DateTime.now;

  // Keep this in sync with the platforms that bundle the group-engine ABI.
  // Linux source support exists, but its shipped libveil_media.so has not yet
  // been rebuilt with these symbols.
  static bool get isSupportedPlatform => Platform.isMacOS || Platform.isAndroid;

  final GroupMediaChannelTransport _transport;
  final GroupAudioEngineFactory _engineFactory;
  final Future<bool> Function() _requestMicrophone;
  final Duration _statsInterval;
  final DateTime Function() _now;
  final Map<String, _GroupPeerChannel> _peers = {};
  final Map<String, int> _lastRxPackets = {};
  final Map<String, DateTime> _lastRxAt = {};

  GroupAudioEngine? _engine;
  Timer? _statsTimer;
  Future<void> _tail = Future<void>.value();

  static Future<bool> _defaultMicPermission() async {
    if (!Platform.isMacOS) return true;
    return MacMediaPermissions.requestMicrophone().timeout(
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
  Future<bool> start(GroupCall call) => _locked(() async {
    await _stopLocked();
    if (!call.media.audio) return false;
    // Match direct calls: bound the permission prompt, then bring up playout
    // even when capture permission is denied or still pending.
    final micGranted = await _requestMicrophone();
    devLog(() => 'xVeil[group-call-media]: mic permission=$micGranted');
    final localId = await _transport.localNodeId();
    _localIdHex = NodeId(localId).hex;
    final engine = _engineFactory(localId);
    if (engine == null) return false;
    _engine = engine;
    await _syncPeersLocked(call);
    final audioReady = engine.startAudio();
    if (!audioReady) {
      await _stopLocked();
      return false;
    }
    _statsTimer = Timer.periodic(_statsInterval, (_) => _pollStats(engine));
    devLog(
      () =>
          'xVeil[group-call-media]: audio started peers=${_peers.length} '
          'videoRequested=${call.media.video || call.media.screen}',
    );
    // Audio is production-ready. A room asking for video remains connecting
    // until the separate native video fanout/renderer brick lands, while its
    // already-established audio continues to work.
    return !(call.media.video || call.media.screen);
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
    // The group video fanout brick will own the single capture source.
  }

  @override
  Future<bool> setScreenShareEnabled(bool enabled) async => false;

  @override
  Future<void> stop() => _locked(_stopLocked);

  Future<void> _stopLocked() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) {
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
    _peers.clear();
    _lastRxPackets.clear();
    _lastRxAt.clear();
    _localIdHex = null;
  }

  bool get audioRunning => _engine != null;
  int get connectedPeerCount => _peers.length;
  int get receivingPeerCount => _lastRxAt.length;
}

class _GroupPeerChannel {
  const _GroupPeerChannel(this.nodeId, this.channel);

  final NodeId nodeId;
  final int channel;
}
