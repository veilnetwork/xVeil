import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/state/veil_group_call_media.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

GroupCall _call(NodeId self, List<NodeId> peers, {bool video = false}) {
  final now = DateTime(2026, 7, 13);
  return GroupCall(
    groupId: _id(9),
    callId: 'group-media',
    initiator: self,
    membershipEpoch: 1,
    media: CallMedia(audio: true, video: video),
    status: GroupCallStatus.connecting,
    startedAt: now,
    joinedAt: now,
    participants: {
      for (final node in [self, ...peers])
        node.hex: GroupCallParticipant(
          nodeId: node,
          media: CallMedia(audio: true, video: video),
          joinedAt: now,
          lastSeenAt: now,
        ),
    },
  );
}

void main() {
  test('native group media capability includes iOS and rebuilt Linux ABI', () {
    expect(supportsNativeGroupMedia('macos'), isTrue);
    expect(supportsNativeGroupMedia('ios'), isTrue);
    expect(supportsNativeGroupMedia('android'), isTrue);
    expect(supportsNativeGroupMedia('linux'), isTrue);
    expect(supportsNativeGroupMedia('windows'), isFalse);
  });

  test(
    'one engine reconciles peer channels and never opens a self channel',
    () async {
      final self = _id(1);
      final alice = _id(2);
      final bob = _id(3);
      final transport = _FakeTransport(self);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        transport,
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      addTearDown(controller.stop);

      expect(await controller.start(_call(self, [alice])), isTrue);
      expect(transport.opened, [alice]);
      expect(engine.added, [alice]);
      expect(engine.started, 1);

      await controller.update(_call(self, [bob]));
      expect(engine.removed, [alice]);
      expect(transport.closed, [1]);
      expect(transport.opened, [alice, bob]);
      expect(engine.added, [alice, bob]);
    },
  );

  test('native packet counters become per-peer media liveness', () async {
    final self = _id(1);
    final peer = _id(2);
    final engine = _FakeEngine();
    final at = DateTime(2026, 7, 13, 18);
    final controller = VeilGroupCallMediaController(
      _FakeTransport(self),
      engineFactory: (_) => engine,
      requestMicrophone: () async => true,
      requestCamera: () async => true,
      statsInterval: const Duration(milliseconds: 1),
      now: () => at,
    );
    addTearDown(controller.stop);

    await controller.start(_call(self, [peer]));
    expect(controller.lastMediaRxAt(peer), isNull);
    engine.rx[peer.hex] = 4;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.lastMediaRxAt(peer), at);
  });

  test(
    'video room starts one shared video engine and becomes media-ready',
    () async {
      final self = _id(1);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      addTearDown(controller.stop);

      expect(
        await controller.start(_call(self, const [], video: true)),
        isTrue,
      );
      expect(engine.started, 1);
      expect(engine.videoStarted, 1);
      expect(engine.cameraStarted, 1);
      await controller.setMicMuted(true);
      expect(engine.muted, isTrue);
    },
  );

  test('latest local and per-peer frames are exposed as listenables', () async {
    final self = _id(1);
    final peer = _id(2);
    final engine = _FakeEngine();
    final controller = VeilGroupCallMediaController(
      _FakeTransport(self),
      engineFactory: (_) => engine,
      requestMicrophone: () async => true,
      requestCamera: () async => true,
    );
    addTearDown(controller.stop);

    expect(await controller.start(_call(self, [peer], video: true)), isTrue);
    engine.localFrame = _frame(1);
    engine.peerFrames[peer.hex] = _frame(2);
    await Future<void>.delayed(const Duration(milliseconds: 70));

    expect(controller.localVideoFrame.value?.rgba.first, 1);
    expect(controller.videoFrameFor(peer).value?.rgba.first, 2);
  });
}

VeilVideoFrame _frame(int byte) => VeilVideoFrame(
  rgba: Uint8List.fromList(List.filled(16, byte)),
  width: 2,
  height: 2,
);

class _FakeTransport implements GroupMediaChannelTransport {
  _FakeTransport(this.self);

  final NodeId self;
  final List<NodeId> opened = [];
  final List<int> closed = [];

  @override
  Future<Uint8List> localNodeId() async => self.bytes;

  @override
  Future<int> open(NodeId peer) async {
    opened.add(peer);
    return opened.length;
  }

  @override
  void close(int channel) => closed.add(channel);
}

class _FakeEngine implements GroupAudioEngine {
  final List<NodeId> added = [];
  final List<NodeId> removed = [];
  final Map<String, int> rx = {};
  int started = 0;
  int videoStarted = 0;
  int cameraStarted = 0;
  bool muted = false;
  VeilVideoFrame? localFrame;
  final Map<String, VeilVideoFrame> peerFrames = {};

  @override
  bool addPeer({required int channel, required NodeId peer}) {
    added.add(peer);
    return true;
  }

  @override
  void dispose() {}

  @override
  int peerRxPackets(NodeId peer) => rx[peer.hex] ?? 0;

  @override
  bool removePeer(NodeId peer) {
    removed.add(peer);
    return true;
  }

  @override
  void setMicMuted(bool value) => muted = value;

  @override
  bool startAudio() {
    started++;
    return true;
  }

  @override
  bool stopAudio() => true;

  @override
  bool startVideo() {
    videoStarted++;
    return true;
  }

  @override
  bool stopVideo() => true;

  @override
  bool startCamera() {
    cameraStarted++;
    return true;
  }

  @override
  bool stopCamera() => true;

  @override
  bool startScreen() => true;

  @override
  bool stopScreen() => true;

  @override
  bool pushVideoFrame(
    Uint8List y,
    Uint8List u,
    Uint8List v,
    int width,
    int height,
  ) => true;

  @override
  VeilVideoFrame? localVideoFrame() => localFrame;

  @override
  VeilVideoFrame? peerVideoFrame(NodeId peer) => peerFrames[peer.hex];
}
