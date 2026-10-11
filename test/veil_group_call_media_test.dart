import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
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
  test(
    'one interrupted audio receiver pauses group video with fresh packets',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        Map<String, dynamic> sample(int interruptions) => {
          'audio_rx_supported': 1,
          'audio_rx_native_age_supported': 1,
          'worker_stalled': 0,
          'audio_feedback_reports': 2,
          'rtt_ms': 80,
          'audio_receivers': {
            alice.hex: {
              'audio_rx_pkts': 20,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 10,
              'audio_interruption_count': 0,
            },
            bob.hex: {
              'audio_rx_pkts': 20,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 10,
              'audio_interruption_count': interruptions,
            },
          },
        };
        engine.stats = sample(0);
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last.maxBitrateKbps, 150);
        for (var i = 1; i <= 6; i++) {
          engine.stats = sample(i);
          clock.elapse(const Duration(seconds: 1));
          if (i <= 4) expect(engine.pauses.last, isFalse);
        }
        expect(engine.pauses.last, isTrue);
        expect(engine.cameraStarted, 1);
        clock.elapse(const Duration(seconds: 11));
        expect(engine.pauses.last, isTrue);
        clock.elapse(const Duration(seconds: 1));
        expect(engine.pauses.last, isFalse);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );
  test('group video tries one fps until all audio receivers are fresh', () {
    for (final initialVideo in [false, true]) {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final engine = _FakeEngine()
          ..stats = {
            'audio_rx_native_age_supported': 1,
            'worker_stalled': 0,
            'audio_feedback_reports': 1,
            'rtt_ms': 80,
            'audio_receivers': {
              peer.hex: {
                'audio_rx_pkts': 0,
                'audio_delay_ms': 100,
                'audio_rx_native_age_ms': -1,
              },
            },
          };
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        controller.start(_call(self, [peer], video: initialVideo));
        clock.flushMicrotasks();
        if (!initialVideo) {
          controller.setVideoEnabled(true);
          clock.flushMicrotasks();
          controller.setCameraEnabled(true);
          clock.flushMicrotasks();
        }
        expect(engine.videoMountPauses, [false]);
        expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
        expect(
          engine.cameraStarted,
          1,
          reason: 'preview/capture intent remains live',
        );
        clock.elapse(const Duration(seconds: 20));
        expect(engine.pauses.last, isFalse);
        engine.stats = {
          ...engine.stats,
          'audio_receivers': {
            peer.hex: {
              'audio_rx_pkts': 20,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 100,
            },
          },
        };
        clock.elapse(const Duration(seconds: 11));
        expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
        clock.elapse(const Duration(seconds: 1));
        expect(engine.pauses.last, isFalse);
        expect(engine.cameraStarted, 1);
        controller.stop();
        clock.flushMicrotasks();
      });
    }
  });

  test(
    'linked device uses its room identity for peers and media keys',
    () async {
      final identity = _id(1);
      final device = _id(7);
      final remote = _id(2);
      final sdk = _LinkedSdkTransport(identity, device);
      final engine = _FakeEngine();
      Uint8List? nativeLocalId;
      final controller = VeilGroupCallMediaController(
        VeilGroupMediaChannelTransport(sdk),
        roomMediaSecret: _room(),
        engineFactory: (id) {
          nativeLocalId = Uint8List.fromList(id);
          return engine;
        },
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      addTearDown(controller.stop);
      expect(await controller.start(_call(identity, [remote])), isTrue);
      expect(nativeLocalId, identity.bytes);
      expect(sdk.opened, [remote]);
      expect(engine.added, [remote]);
      final remoteKeys = deriveGroupCallMediaKeys(
        roomSecret: _secret(0x5a),
        localNode: remote,
        peerNode: identity,
      );
      expect(sdk.txKeys[remote.hex], remoteKeys.rxKey);
      expect(sdk.rxKeys[remote.hex], remoteKeys.txKey);
    },
  );

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
        expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
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
        expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
        engine.stats = {'audio_feedback_reports': 0};
        clock.elapse(const Duration(seconds: 30));
        expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
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
        expect(engine.targets.first, (maxBitrateKbps: 8, maxFps: 1.0));
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('one group audio outage pauses video despite another healthy peer', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      final room = _call(self, [alice, bob], video: true);
      controller.start(room);
      clock.flushMicrotasks();
      Map<String, dynamic> sample(int? aliceAge, int? bobAge) => {
        'audio_rx_supported': 1,
        'audio_rx_native_age_supported': 1,
        'worker_stalled': 0,
        'audio_feedback_reports': 2,
        'rtt_ms': 80,
        'audio_receivers': {
          alice.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': 100,
            'audio_rx_native_age_ms': aliceAge,
          },
          bob.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': 100,
            'audio_rx_native_age_ms': bobAge,
          },
        },
      };
      engine.stats = sample(100, 100);
      clock.elapse(const Duration(seconds: 48));
      expect(engine.targets.last.maxBitrateKbps, 150);
      engine.stats = sample(100, 4456); // sustained outage after floor trial
      clock.elapse(const Duration(seconds: 6));
      expect(
        engine.pauses.last,
        isTrue,
        reason: 'healthy Alice cannot mask Bob',
      );
      expect(engine.cameraStarted, 1, reason: 'pause retains capture');
      engine.stats = sample(100, null);
      clock.elapse(const Duration(seconds: 20));
      expect(
        engine.pauses.last,
        isTrue,
        reason: 'unknown Bob cannot earn recovery',
      );
      engine.stats = {'audio_feedback_reports': 2, 'rtt_ms': 80};
      clock.elapse(const Duration(seconds: 20));
      expect(
        engine.pauses.last,
        isTrue,
        reason: 'missing capability field cannot forget known native support',
      );
      engine.stats = {...sample(0, 0), 'worker_stalled': 1};
      clock.elapse(const Duration(seconds: 20));
      expect(
        engine.pauses.last,
        isTrue,
        reason: 'a stalled audio worker is unknown',
      );
      engine.stats = sample(100, 100);
      clock.elapse(const Duration(seconds: 11));
      expect(engine.pauses.last, isTrue);
      clock.elapse(const Duration(seconds: 1));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'all expected audio must be fresh for twelve samples',
      );
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('group receive priority follows remote mute, unmute and removal', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      final room = _call(self, [alice, bob], video: true);
      final muted = room.copyWith(
        participants: {
          ...room.participants,
          bob.hex: room.participants[bob.hex]!.copyWith(
            media: const CallMedia(audio: false, video: true),
          ),
        },
      );
      controller.start(muted);
      clock.flushMicrotasks();
      controller.setMicMuted(true);
      clock.flushMicrotasks();
      engine.stats = {
        'audio_rx_supported': 1,
        'audio_rx_native_age_supported': 1,
        'worker_stalled': 0,
        'audio_feedback_reports': 2,
        'rtt_ms': 80,
        'audio_receivers': {
          alice.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': 100,
            'audio_rx_native_age_ms': 100,
          },
          bob.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': 100,
            'audio_rx_native_age_ms': 13000,
          },
        },
      };
      clock.elapse(const Duration(seconds: 48));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'intentional remote mute is not a receive outage',
      );
      controller.update(room);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 6));
      expect(
        engine.pauses.last,
        isTrue,
        reason: 'local mute does not waive expected incoming audio',
      );
      controller.update(muted);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 12));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'remote mute removes Bob from required sources',
      );
      controller.update(room);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 6));
      expect(engine.pauses.last, isTrue);
      controller.update(_call(self, [alice], video: true));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 12));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'departed peers cannot keep video paused',
      );
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test(
    'known group outage remains actionable when another peer never sent audio',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
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
          'audio_rx_native_age_supported': 1,
          'worker_stalled': 0,
          'audio_feedback_reports': 2,
          'rtt_ms': 80,
          'audio_receivers': {
            alice.hex: {
              'audio_rx_pkts': 20,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 100,
            },
            bob.hex: {
              'audio_rx_pkts': 0,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': -1,
            },
          },
        };
        clock.elapse(const Duration(seconds: 48));
        expect(
          engine.pauses.last,
          isFalse,
          reason:
              'unknown audio holds the one-fps trial without claiming outage',
        );
        expect(
          engine.targets.last.maxBitrateKbps,
          lessThan(150),
          reason: 'one healthy peer cannot earn the full shared budget',
        );
        engine.stats = {
          ...engine.stats,
          'audio_receivers': {
            alice.hex: {
              'audio_rx_pkts': 20,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 1085,
            },
            bob.hex: {
              'audio_rx_pkts': 0,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': -1,
            },
          },
        };
        clock.elapse(const Duration(seconds: 2));
        expect(
          engine.pauses.last,
          isTrue,
          reason: 'known Alice outage is sufficient despite unknown Bob',
        );
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('room pauses video for severe audio delay and retries recovery', () {
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
      controller.start(_call(self, [_id(2)], video: true));
      clock.flushMicrotasks();
      engine.stats = {'audio_feedback_reports': 1, 'rtt_ms': 8500};
      clock.elapse(const Duration(seconds: 2));
      expect(engine.pauses.last, isTrue);
      expect(engine.cameraStarted, 1);
      engine.stats = {'audio_feedback_reports': 0};
      clock.elapse(const Duration(seconds: 20));
      expect(engine.pauses.last, isTrue);
      engine.acceptPause = false;
      engine.stats = {
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'tx_loss_pct': 0,
      };
      clock.elapse(const Duration(seconds: 12));
      expect(engine.pauses.last, isTrue);
      engine.acceptPause = true;
      clock.elapse(const Duration(seconds: 1));
      expect(engine.pauses.last, isFalse);
      expect(engine.cameraStarted, 1);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test(
    'low-rate native library without pause keeps an honest sparse fallback',
    () {
      fakeAsync((clock) {
        final self = _id(1);
        final engine = _FakeEngine(supportsVideoSendPause: false);
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        controller.start(_call(self, [_id(2)], video: true));
        clock.flushMicrotasks();
        engine.stats = {'audio_feedback_reports': 1, 'rtt_ms': 8500};
        clock.elapse(const Duration(seconds: 2));
        expect(engine.targets.last, (maxBitrateKbps: 1, maxFps: 0.02));
        expect(engine.pauses, isEmpty);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('older group library gets an integer startup budget', () {
    fakeAsync((clock) {
      final self = _id(1);
      final engine = _FakeEngine(supportsLowRateVideo: false);
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      controller.start(_call(self, [_id(2)], video: true));
      clock.flushMicrotasks();
      expect(engine.targets.first, (maxBitrateKbps: 30, maxFps: 1.0));
      clock.elapse(const Duration(seconds: 3));
      expect(engine.targets.length, 1);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

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

  test('clean RTCP cannot grow group video over delayed receiver audio', () {
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
      controller.start(_call(self, [_id(2), _id(3)], video: true));
      clock.flushMicrotasks();
      engine.stats = {
        'audio_feedback_reports': 2,
        'rtt_ms': 80,
        'audio_playout_peers': 2,
        'audio_playout_reports': 2,
        'audio_playout_ms': 100,
      };
      clock.elapse(const Duration(seconds: 48));
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      engine.stats = {...engine.stats, 'audio_playout_ms': 380};
      clock.elapse(const Duration(seconds: 2));
      expect(
        engine.targets.last.maxFps,
        lessThan(15),
        reason: 'clean loss/RTT cannot hide a receiver playout queue',
      );
      clock.elapse(const Duration(seconds: 6));
      expect(engine.targets.last, (maxBitrateKbps: 1, maxFps: 0.02));
      expect(engine.pauses.last, isTrue);
      engine.stats = {...engine.stats, 'audio_playout_ms': 250};
      clock.elapse(const Duration(seconds: 30));
      expect(
        engine.targets.last,
        (maxBitrateKbps: 1, maxFps: 0.02),
        reason: 'a borderline audio delay has not earned video recovery',
      );
      engine.stats = {...engine.stats, 'audio_playout_ms': 100};
      clock.elapse(const Duration(seconds: 12));
      expect(engine.pauses.last, isFalse);
      clock.elapse(const Duration(seconds: 48));
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('a new audio peer limits live video before joining its fanout', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine()
        ..stats = {
          'audio_rx_native_age_supported': 1,
          'worker_stalled': 0,
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_receivers': {
            alice.hex: {
              'audio_rx_pkts': 100,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 100,
            },
          },
        };
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      controller.start(_call(self, [alice], video: true));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 48));
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      expect(engine.pauses.last, isFalse);
      controller.update(_call(self, [alice, bob], video: true));
      clock.flushMicrotasks();
      expect(
        engine.peerAddPauses.last,
        isFalse,
        reason:
            'an unknown peer gets a sparse trial instead of an outage verdict',
      );
      expect(engine.cameraStarted, 1);
      expect(engine.peerAddTargets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      clock.elapse(const Duration(seconds: 20));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'Alice cannot earn a larger video budget for unknown Bob',
      );
      engine.stats = {
        ...engine.stats,
        'audio_feedback_reports': 2,
        'audio_receivers': {
          alice.hex: {
            'audio_rx_pkts': 200,
            'audio_delay_ms': 100,
            'audio_rx_native_age_ms': 100,
          },
          bob.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': 100,
            'audio_rx_native_age_ms': 100,
          },
        },
      };
      clock.elapse(const Duration(seconds: 11));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      clock.elapse(const Duration(seconds: 1));
      expect(engine.pauses.last, isFalse);
      expect(engine.cameraStarted, 1);
      engine.throwStats = true;
      clock.elapse(const Duration(seconds: 2));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'unknown worker health still permits the sparse trial',
      );
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      engine.throwStats = false;
      clock.elapse(const Duration(seconds: 11));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      clock.elapse(const Duration(seconds: 1));
      expect(engine.pauses.last, isFalse);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('a busy floor update pauses new fanout until the budget applies', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine()
        ..stats = {
          'audio_rx_native_age_supported': 1,
          'worker_stalled': 0,
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_receivers': {
            alice.hex: {
              'audio_rx_pkts': 100,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 100,
            },
          },
        };
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      controller.start(_call(self, [alice], video: true));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 48));
      expect(engine.targets.last.maxBitrateKbps, 150);
      engine.acceptTarget = false;
      controller.update(_call(self, [alice, bob], video: true));
      clock.flushMicrotasks();
      expect(engine.peerAddPauses.last, isTrue);
      clock.elapse(const Duration(seconds: 2));
      expect(engine.pauses.last, isTrue);
      expect(engine.targets.last.maxBitrateKbps, 150);
      engine.acceptTarget = true;
      clock.elapse(const Duration(seconds: 1));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      expect(engine.pauses.last, isFalse);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('camera off cannot grow a group video budget from audio alone', () {
    fakeAsync((clock) {
      final self = _id(1), peer = _id(2);
      final engine = _FakeEngine()
        ..stats = {'audio_feedback_reports': 1, 'rtt_ms': 80};
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      controller.start(_call(self, [peer], video: true));
      clock.flushMicrotasks();
      controller.setCameraEnabled(false);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 120));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      controller.setCameraEnabled(true);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 11));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      clock.elapse(const Duration(seconds: 1));
      expect(engine.targets.last.maxBitrateKbps, 45);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('group cannot forget capable playout when native stats fail', () {
    fakeAsync((clock) {
      final self = _id(1), peer = _id(2);
      final engine = _FakeEngine()
        ..stats = {
          'worker_stalled': 0,
          'audio_rx_native_age_supported': 1,
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_playout_peers': 1,
          'audio_playout_reports': 0,
          'audio_playout_ms': -1,
        };
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      final room = _call(self, [peer], video: true);
      final receivingMuted = room.copyWith(
        participants: {
          ...room.participants,
          peer.hex: room.participants[peer.hex]!.copyWith(
            media: const CallMedia(audio: false, video: true),
          ),
        },
      );
      controller.start(receivingMuted);
      clock.flushMicrotasks();
      expect(engine.pauses.last, isFalse);
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      engine.throwStats = true;
      clock.elapse(const Duration(seconds: 1));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'a failed sample is not explicit removal of capable peers',
      );
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      engine.throwStats = false;
      engine.stats = const {};
      clock.elapse(const Duration(seconds: 20));
      expect(engine.pauses.last, isFalse);
      engine.stats = {
        'worker_stalled': 0,
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'audio_playout_peers': 1,
        'audio_playout_reports': 1,
        'audio_playout_ms': 100,
      };
      clock.elapse(const Duration(seconds: 11));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      clock.elapse(const Duration(seconds: 1));
      expect(engine.pauses.last, isFalse);
      engine.stats = {...engine.stats, 'audio_playout_reports': 0};
      clock.elapse(const Duration(seconds: 8));
      expect(engine.pauses.last, isFalse);
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      engine.stats = {...engine.stats, 'audio_playout_peers': 0};
      clock.elapse(const Duration(seconds: 1));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'an explicit current zero really removes the requirement',
      );
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('group playout recovery requires every capable receiver', () {
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
      controller.start(_call(self, [_id(2), _id(3)], video: true));
      clock.flushMicrotasks();
      engine.stats = {
        'audio_feedback_reports': 2,
        'rtt_ms': 80,
        'audio_playout_peers': 2,
        'audio_playout_reports': 1,
        'audio_playout_ms': 100,
      };
      clock.elapse(const Duration(seconds: 60));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      expect(engine.pauses.last, isFalse);
      engine.stats = {...engine.stats, 'audio_playout_ms': 450};
      clock.elapse(const Duration(seconds: 8));
      expect(engine.targets.last, (maxBitrateKbps: 1, maxFps: 0.02));
      expect(
        engine.pauses.last,
        isTrue,
        reason:
            '450-ms audio delay cannot keep spending the sparse video floor',
      );
      engine.stats = {
        ...engine.stats,
        'audio_playout_reports': 2,
        'audio_playout_ms': 100,
      };
      clock.elapse(const Duration(seconds: 12));
      expect(engine.pauses.last, isFalse);
      clock.elapse(const Duration(seconds: 48));
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      engine.stats = {
        ...engine.stats,
        'audio_playout_reports': 0,
        'audio_playout_ms': -1,
      };
      clock.elapse(const Duration(seconds: 8));
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      expect(engine.pauses.last, isFalse);
      controller.setMicMuted(true);
      clock.flushMicrotasks();
      engine.stats = {
        ...engine.stats,
        'worker_stalled': 0,
        'audio_rx_native_age_supported': 1,
        'audio_receivers': {
          for (final id in [_id(2), _id(3)])
            id.hex: {
              'audio_rx_pkts': 100,
              'audio_rx_native_age_ms': 20,
              'audio_delay_ms': 100,
            },
        },
        'video_feedback_reports': 2,
        'video_feedback_rtt_ms': 80,
        'video_feedback_jitter_ms': 10,
      };
      clock.elapse(const Duration(seconds: 11));
      expect(engine.pauses.last, isFalse);
      clock.elapse(const Duration(seconds: 1));
      expect(engine.pauses.last, isFalse);
      clock.elapse(const Duration(seconds: 48));
      expect(
        engine.targets.last,
        (maxBitrateKbps: 150, maxFps: 15),
        reason: 'a muted sender has no outgoing audio playout to measure',
      );
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
          (maxBitrateKbps: 8, maxFps: 1.0),
          reason: 'one healthy receiver cannot speak for the silent one',
        );
        engine.stats = {...engine.stats, 'audio_feedback_reports': 2};
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.stats = {...engine.stats, 'audio_feedback_reports': 1};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 8, maxFps: 1.0),
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
          (maxBitrateKbps: 8, maxFps: 1.0),
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
          (maxBitrateKbps: 8, maxFps: 1.0),
          reason: 'unreadable native stats cannot keep full video',
        );
        engine.stats = healthy;
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.throwStats = true;
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 8, maxFps: 1.0),
          reason: 'a failed query must still apply the reduced video target',
        );
        engine.throwStats = false;
        clock.elapse(const Duration(seconds: 48));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.stats = {...engine.stats, 'worker_stalled': 1};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 8, maxFps: 1.0),
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
          'video_feedback_reports': 2,
          'video_feedback_rtt_ms': 80,
          'video_feedback_loss_pct': 0,
          'video_feedback_jitter_ms': 10,
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
        expect(
          engine.pauses.last,
          isFalse,
          reason: 'new audio gets a one-fps video trial before capture',
        );
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 8, maxFps: 1.0),
          reason:
              'video reports cannot prove that both peers hear the new audio',
        );
        engine.stats = {...engine.stats, 'audio_feedback_reports': 2};
        clock.elapse(const Duration(seconds: 12));
        expect(engine.pauses.last, isFalse);
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

  test(
    'native group RTP age drives liveness even after delayed host polling',
    () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final base = DateTime(2026, 10, 7);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => base.add(clock.elapsed),
        );
        controller.start(_call(self, [peer]));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 5));
        engine.stats = {
          'audio_rx_supported': 1,
          'audio_rx_native_age_supported': 1,
          'worker_stalled': 0,
          'audio_receivers': {
            peer.hex: {
              'audio_rx_pkts': 4,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 2500,
            },
          },
        };
        clock.elapse(const Duration(seconds: 1));
        final acceptedAt = base.add(const Duration(milliseconds: 3500));
        expect(
          controller.lastAudioRxAt(peer),
          acceptedAt,
          reason: 'a late count sample is not a fresh packet',
        );
        expect(
          controller.debugNativeStatsAt,
          base.add(const Duration(seconds: 6)),
        );
        expect(controller.debugNativeStats['audio_rx_native_age_supported'], 1);
        engine.stats = {
          ...engine.stats,
          'audio_receivers': {
            peer.hex: {
              'audio_rx_pkts': 4,
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 3500,
            },
          },
        };
        clock.elapse(const Duration(seconds: 1));
        expect(controller.lastAudioRxAt(peer), acceptedAt);
        controller.stop();
        clock.flushMicrotasks();
        expect(controller.debugNativeStats, isEmpty);
        expect(controller.debugNativeStatsAt, isNull);
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
    expect(controller.supportsAudioReceiveStats, isFalse);
    expect(controller.lastAudioRxAt(peer), isNull);
  });

  test(
    'group audio liveness is independent of video, peers and worker stalls',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final engine = _FakeEngine();
        final base = DateTime(2026, 10, 5);
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          now: () => base.add(clock.elapsed),
        );
        controller.start(_call(self, [alice, bob]));
        clock.flushMicrotasks();
        engine.rx[alice.hex] = 20; // video/RTCP ingress does not prove audio
        engine.rx[bob.hex] = 30;
        engine.stats = {
          'audio_rx_supported': 1,
          'worker_stalled': 0,
          'audio_receivers': {
            alice.hex: {'audio_rx_pkts': 4, 'audio_delay_ms': 150},
            bob.hex: {'audio_rx_pkts': 0, 'audio_delay_ms': 0},
          },
        };
        clock.elapse(const Duration(seconds: 1));
        final firstAudio = base.add(const Duration(seconds: 1));
        expect(controller.supportsAudioReceiveStats, isTrue);
        expect(controller.lastAudioRxAt(alice), firstAudio);
        expect(controller.lastAudioRxAt(bob), isNull);
        expect(controller.lastMediaRxAt(bob), firstAudio);

        engine.rx[alice.hex] = 50;
        engine.rx[bob.hex] = 60;
        clock.elapse(const Duration(seconds: 11));
        expect(controller.lastMediaRxAt(alice)!.isAfter(firstAudio), isTrue);
        expect(controller.lastAudioRxAt(alice), firstAudio);
        expect(controller.lastAudioRxAt(bob), isNull);
        engine.stats = {
          ...engine.stats,
          'worker_stalled': 1,
          'audio_receivers': {
            alice.hex: {'audio_rx_pkts': 999, 'audio_delay_ms': 100},
            bob.hex: {'audio_rx_pkts': 999, 'audio_delay_ms': 100},
          },
        };
        clock.elapse(const Duration(seconds: 1));
        engine.stats =
            const {}; // library failure cannot restore legacy fallback
        clock.elapse(const Duration(seconds: 1));
        expect(controller.supportsAudioReceiveStats, isTrue);
        expect(controller.lastAudioRxAt(alice), firstAudio);
        expect(controller.lastAudioRxAt(bob), isNull);

        engine.stats = {
          'audio_rx_supported': 1,
          'worker_stalled': 0,
          'audio_receivers': {
            alice.hex: {'audio_rx_pkts': 4, 'audio_delay_ms': 100},
            bob.hex: {'audio_rx_pkts': 2, 'audio_delay_ms': 100},
          },
        };
        clock.elapse(const Duration(seconds: 1));
        expect(controller.lastAudioRxAt(bob), base.add(clock.elapsed));
        expect(controller.lastAudioRxAt(alice), firstAudio);
        controller.invalidatePeerChannel(alice);
        clock.flushMicrotasks();
        expect(controller.lastAudioRxAt(alice), isNull);
        controller.update(_call(self, [alice]));
        clock.flushMicrotasks();
        expect(controller.lastAudioRxAt(bob), isNull);
        engine.stats = {
          'audio_rx_supported': 1,
          'worker_stalled': 0,
          'audio_receivers': {
            alice.hex: {'audio_rx_pkts': 0, 'audio_delay_ms': 100},
          },
        };
        clock.elapse(const Duration(seconds: 1));
        expect(controller.lastAudioRxAt(alice), isNull);
        controller.stop();
        clock.flushMicrotasks();
        expect(controller.supportsAudioReceiveStats, isFalse);
        expect(controller.lastAudioRxAt(alice), isNull);
      });
    },
  );

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

  test(
    'group screen source reaches existing and newly joined channels',
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
      expect(await controller.start(_call(self, [alice], video: true)), isTrue);
      expect(await controller.setScreenShareEnabled(true), isTrue);
      expect(transport.screenModes[1], isTrue);
      await controller.setCameraEnabled(true);
      expect(transport.screenModes[1], isTrue);
      await controller.update(_call(self, [alice, bob], video: true));
      expect(transport.screenModes[2], isTrue);
      expect(await controller.setScreenShareEnabled(false), isTrue);
      expect(transport.screenModes, {1: false, 2: false});
      transport.rejectScreen = true;
      expect(await controller.setScreenShareEnabled(true), isFalse);
      expect(transport.screenModes, {1: false, 2: false});
    },
  );

  for (final throws in [false, true]) {
    for (final cameraOn in [false, true]) {
      test('failed desktop screen restores camera intent '
          '(camera=$cameraOn, throws=$throws)', () async {
        final self = _id(1);
        final transport = _FakeTransport(self);
        final engine = _FakeEngine()
          ..screenStarts = false
          ..throwOnScreenStart = throws;
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        addTearDown(controller.stop);
        expect(
          await controller.start(_call(self, [_id(2)], video: true)),
          isTrue,
        );
        await controller.setCameraEnabled(cameraOn);
        final previousCameraStarts = engine.cameraStarted;
        expect(await controller.setScreenShareEnabled(true), isFalse);
        expect(transport.screenModes, {1: false});
        expect(engine.cameraStarted, previousCameraStarts + (cameraOn ? 1 : 0));
      });
    }
  }

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

class _LinkedSdkTransport implements VeilFlutterTransport {
  _LinkedSdkTransport(this.identity, this.device);

  final NodeId identity;
  final NodeId device;
  final List<NodeId> opened = [];
  final Map<String, Uint8List> txKeys = {};
  final Map<String, Uint8List> rxKeys = {};

  @override
  Future<NodeId> nodeId() async => device;

  @override
  Future<NodeId> peerFacingNodeId({
    Duration timeout = const Duration(seconds: 2),
  }) async => identity;

  @override
  Future<int> openMediaChannel(
    Uint8List dstNode, {
    required Uint8List txKey,
    required Uint8List rxKey,
    bool direct = false,
    bool relay = false,
  }) async {
    final peer = NodeId(dstNode);
    opened.add(peer);
    txKeys[peer.hex] = Uint8List.fromList(txKey);
    rxKeys[peer.hex] = Uint8List.fromList(rxKey);
    return opened.length;
  }

  @override
  void closeMediaChannel(int channel) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTransport implements GroupMediaChannelTransport {
  _FakeTransport(this.self);

  final NodeId self;
  final List<NodeId> opened = [];
  final List<int> closed = [];
  final Map<int, bool> screenModes = {};
  bool rejectScreen = false;
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
  int setScreenSharing(int channel, bool on) {
    if (on && rejectScreen) return -1;
    screenModes[channel] = on;
    return 0;
  }

  @override
  void close(int channel) => closed.add(channel);
}

class _FakeEngine implements GroupAudioEngine {
  _FakeEngine({
    this.supportsLowRateVideo = true,
    this.supportsVideoSendPause = true,
  });
  @override
  final bool supportsLowRateVideo;
  @override
  final bool supportsVideoSendPause;
  final List<bool> pauses = [];
  bool acceptPause = true;
  @override
  bool setVideoSendPaused(bool paused) {
    if (!acceptPause) return false;
    pauses.add(paused);
    return true;
  }

  final List<NodeId> added = [];
  final List<bool?> peerAddPauses = [];
  final List<({int maxBitrateKbps, double maxFps})?> peerAddTargets = [];
  final List<NodeId> removed = [];
  final Map<String, int> rx = {};
  int started = 0;
  int videoStarted = 0;
  final List<bool?> videoMountPauses = [];
  int cameraStarted = 0;
  bool muted = false;
  final List<bool> audioStartMuted = [];
  Map<String, dynamic> stats = const {};
  bool throwStats = false;
  final List<({int maxBitrateKbps, double maxFps})> targets = [];
  bool acceptTarget = true;

  @override
  Map<String, dynamic> getStats() {
    if (throwStats) throw const FormatException('native stats unavailable');
    return stats;
  }

  @override
  bool setVideoBitrate({required int maxBitrateKbps, required num maxFps}) {
    if (!acceptTarget) return false;
    targets.add((maxBitrateKbps: maxBitrateKbps, maxFps: maxFps.toDouble()));
    return true;
  }

  VeilVideoFrame? localFrame;
  final Map<String, VeilVideoFrame> peerFrames = {};

  @override
  bool addPeer({required int channel, required NodeId peer}) {
    peerAddPauses.add(pauses.isEmpty ? null : pauses.last);
    peerAddTargets.add(targets.isEmpty ? null : targets.last);
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
    videoMountPauses.add(pauses.isEmpty ? null : pauses.last);
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

  bool screenStarts = true;
  bool throwOnScreenStart = false;

  @override
  bool startScreen({String? sourceId}) {
    if (throwOnScreenStart) throw StateError('capture unavailable');
    return screenStarts;
  }

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
