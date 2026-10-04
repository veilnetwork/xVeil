import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/state/veil_group_call_media.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

Uint8List _secret(int byte) => Uint8List.fromList(List.filled(32, byte));

/// Room secret source for the tests that are not about the seal itself. A
/// fresh copy per resolve: the controller wipes what it is handed.
GroupCallMediaSecretResolver _room([int byte = 0x5a]) =>
    (_) async => _secret(byte);

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
        roomMediaSecret: _room(),
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

  test(
    'group video lowers cadence for audio and retries a busy video worker',
    () {
      fakeAsync((clock) {
        final self = _id(1);
        final peer = _id(2);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        bool? started;
        controller
            .start(_call(self, [peer], video: true))
            .then((ok) => started = ok);
        clock.flushMicrotasks();
        expect(started, isTrue);
        engine.stats = {'audio_feedback_reports': 0};
        clock.elapse(const Duration(seconds: 30));
        expect(engine.targets.last, (maxBitrateKbps: 30, maxFps: 1));
        engine.stats = {
          'audio_feedback_reports': 2,
          'tx_loss_pct': 0,
          'rtt_ms': 80,
        };
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.targets.clear();
        engine.stats = {'audio_feedback_reports': 2, 'tx_loss_pct': 12};
        engine.acceptTarget = false;
        clock.elapse(const Duration(seconds: 6));
        expect(engine.targets, isEmpty);
        engine.acceptTarget = true;
        clock.elapse(const Duration(seconds: 1));
        expect(engine.targets.last, (maxBitrateKbps: 45, maxFps: 2));
        engine.stats = {'audio_feedback_reports': 0};
        clock.elapse(const Duration(seconds: 30));
        expect(engine.targets.last, (maxBitrateKbps: 30, maxFps: 1));
        engine.stats = {
          'audio_feedback_reports': 2,
          'tx_loss_pct': 0,
          'rtt_ms': 80,
        };
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        controller.stop();
        clock.flushMicrotasks();
        engine.targets.clear();
        controller.start(_call(self, [peer], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 1));
        expect(engine.targets.first, (maxBitrateKbps: 30, maxFps: 1));
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('group audio-only telemetry does not retune video', () {
    fakeAsync((clock) {
      final self = _id(1);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      engine.stats = {'audio_feedback_reports': 2, 'tx_loss_pct': 20};
      bool? started;
      controller.start(_call(self, [_id(2)])).then((ok) => started = ok);
      clock.flushMicrotasks();
      expect(started, isTrue);
      clock.elapse(const Duration(seconds: 15));
      expect(engine.targets, isEmpty);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test(
    'group video requires fresh audio feedback from every connected peer',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3), carol = _id(4);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        engine.stats = {
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'tx_loss_pct': 0,
          'tx_jitter_ms': 10,
        };
        clock.elapse(const Duration(seconds: 60));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason: 'one healthy receiver cannot speak for the silent one',
        );
        engine.stats = {...engine.stats, 'audio_feedback_reports': 2};
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.stats = {...engine.stats, 'audio_feedback_reports': 1};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason: 'losing a receiver must release bandwidth for audio',
        );
        engine.stats = {...engine.stats, 'audio_feedback_reports': 2};
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));

        controller.update(_call(self, [alice, bob, carol], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason: 'the newly connected receiver has not yet reported audio',
        );
        controller.update(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (
          maxBitrateKbps: 150,
          maxFps: 15,
        ), reason: 'removed peers no longer block recovery');
        final healthy = engine.stats;
        engine.stats = const {};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason: 'unreadable native stats cannot keep full video',
        );
        engine.stats = healthy;
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.throwStats = true;
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason: 'a failed query must still apply the reduced video target',
        );
        engine.throwStats = false;
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.stats = {...engine.stats, 'worker_stalled': 1};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason:
              'cached reports from a stalled audio worker cannot grow video',
        );
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'mute during group setup suppresses capture and audio report requirements',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final engine = _FakeEngine();
        final permission = Completer<bool>();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () => permission.future,
          requestCamera: () async => true,
        );
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        controller.setMicMuted(true);
        clock.flushMicrotasks();
        permission.complete(true);
        clock.flushMicrotasks();
        expect(
          engine.audioStartMuted,
          [true],
          reason: 'the stale start snapshot must not open microphone capture',
        );
        engine.stats = {
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'tx_loss_pct': 0,
          'tx_jitter_ms': 10,
        };
        clock.elapse(const Duration(seconds: 48));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 150, maxFps: 15),
          reason: 'deliberate mute does not imply bad outgoing sound',
        );
        controller.setMicMuted(false);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 30, maxFps: 1),
          reason: 'unmute restores every-receiver audio protection',
        );
        controller.stop();
        clock.flushMicrotasks();
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        expect(
          engine.audioStartMuted.last,
          isFalse,
          reason: 'a new call does not inherit the previous capture state',
        );
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('native packet counters become per-peer media liveness', () async {
    final self = _id(1);
    final peer = _id(2);
    final engine = _FakeEngine();
    final controller = VeilGroupCallMediaController(
      _FakeTransport(self),
      roomMediaSecret: _room(),
      engineFactory: (_) => engine,
      requestMicrophone: () async => true,
      requestCamera: () async => true,
      statsInterval: const Duration(milliseconds: 1),
      now: () => DateTime(2026, 7, 13, 18),
    );
    addTearDown(controller.stop);

    await controller.start(_call(self, [peer]));
    expect(controller.lastMediaRxAt(peer), isNull);
    engine.rx[peer.hex] = 4;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.lastMediaRxAt(peer), DateTime(2026, 7, 13, 18));
  });

  test(
    'video room starts one shared video engine and becomes media-ready',
    () async {
      final self = _id(1);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
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
      roomMediaSecret: _room(),
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

  group('room media is sealed per participant pair', () {
    test('the two ends of a pair derive the same directional keys', () {
      final alice = _id(1);
      final bob = _id(2);
      final secret = _secret(0x5a);

      final fromAlice = deriveGroupCallMediaKeys(
        roomSecret: secret,
        localNode: alice,
        peerNode: bob,
      );
      final fromBob = deriveGroupCallMediaKeys(
        roomSecret: secret,
        localNode: bob,
        peerNode: alice,
      );

      expect(
        fromAlice.txKey,
        fromBob.rxKey,
        reason: 'bob must be able to open what alice sealed',
      );
      expect(fromAlice.rxKey, fromBob.txKey, reason: 'and the other way round');
      expect(fromAlice.txKey, hasLength(32));
      expect(fromAlice.txKey, isNot(fromAlice.rxKey));
      expect(fromAlice.txKey.any((byte) => byte != 0), isTrue);
    });

    test('a different room, or a different pair, is a different key', () {
      final alice = _id(1);
      final bob = _id(2);
      final carol = _id(3);
      final here = deriveGroupCallMediaKeys(
        roomSecret: _secret(0x5a),
        localNode: alice,
        peerNode: bob,
      );
      final otherRoom = deriveGroupCallMediaKeys(
        roomSecret: _secret(0x5b),
        localNode: alice,
        peerNode: bob,
      );
      final otherPeer = deriveGroupCallMediaKeys(
        roomSecret: _secret(0x5a),
        localNode: alice,
        peerNode: carol,
      );
      expect(here.txKey, isNot(otherRoom.txKey));
      expect(here.txKey, isNot(otherPeer.txKey));
    });

    test('every opened peer channel carries that pair\'s keys', () async {
      final self = _id(1);
      final alice = _id(2);
      final bob = _id(3);
      final transport = _FakeTransport(self);
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => _FakeEngine(),
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      addTearDown(controller.stop);

      expect(await controller.start(_call(self, [alice, bob])), isTrue);
      expect(transport.opened, [alice, bob]);

      for (final peer in [alice, bob]) {
        final expected = deriveGroupCallMediaKeys(
          roomSecret: _secret(0x5a),
          localNode: self,
          peerNode: peer,
        );
        expect(transport.txKeys[peer.hex], expected.txKey);
        expect(transport.rxKeys[peer.hex], expected.rxKey);
      }
      expect(
        transport.txKeys[alice.hex],
        isNot(transport.txKeys[bob.hex]),
        reason:
            'one key for the whole room would let each member open the '
            'others\' streams off the wire',
      );
    });

    test('a room whose secret is unavailable opens no peer channel', () async {
      final self = _id(1);
      final peer = _id(2);
      final transport = _FakeTransport(self);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: (_) async => null,
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      addTearDown(controller.stop);

      await controller.start(_call(self, [peer]));

      expect(
        transport.opened,
        isEmpty,
        reason: 'an unsealable room must not reach the transport at all',
      );
      expect(engine.added, isEmpty);
    });
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
  final Map<String, Uint8List> txKeys = {};
  final Map<String, Uint8List> rxKeys = {};

  @override
  Future<Uint8List> localNodeId() async => self.bytes;

  @override
  Future<int> open(
    NodeId peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
  }) async {
    opened.add(peer);
    // Copied: the caller wipes its buffers as soon as the open returns.
    txKeys[peer.hex] = Uint8List.fromList(txKey);
    rxKeys[peer.hex] = Uint8List.fromList(rxKey);
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
  final List<bool> audioStartMuted = [];
  Map<String, dynamic> stats = const {};
  bool throwStats = false;
  final List<({int maxBitrateKbps, int maxFps})> targets = [];
  bool acceptTarget = true;

  @override
  Map<String, dynamic> getStats() {
    if (throwStats) throw const FormatException('native stats unavailable');
    return stats;
  }

  @override
  bool setVideoBitrate({required int maxBitrateKbps, required int maxFps}) {
    if (!acceptTarget) return false;
    targets.add((maxBitrateKbps: maxBitrateKbps, maxFps: maxFps));
    return true;
  }

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
    audioStartMuted.add(muted);
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
  bool startScreen({String? sourceId}) => true;

  @override
  List<MediaDevice> listScreens() => const [];

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
