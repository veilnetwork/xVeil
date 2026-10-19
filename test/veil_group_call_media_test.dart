import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:clock/clock.dart' as test_clock;
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

Map<String, dynamic> _sourceStats(List<NodeId> peers, {int delay = 100}) => {
  'audio_rx_supported': 1,
  'audio_rx_native_age_supported': 1,
  'worker_stalled': 0,
  'audio_playout_peers': peers.length,
  'audio_playout_reports': peers.length,
  'audio_playout_ms': delay,
  'audio_tx_rtp_drops': 0,
  'audio_receivers': {
    for (final peer in peers)
      peer.hex: {
        'audio_rx_pkts': 20,
        'audio_delay_ms': 100,
        'audio_rx_native_age_ms': 10,
        'audio_interruption_count': 0,
      },
  },
};

void main() {
  test(
    'long audio packets wait for actual video yield when pause is refused',
    () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final engine = _FakeEngine(supportsAudioBudget: true)
          ..stats = {
            ..._sourceStats([peer]),
            'audio_feedback_reports': 1,
            'rtt_ms': 40,
            'audio_max_packet_ms': 60,
            'audio_loss_report_us': 0,
            'audio_config_valid': 1,
            'audio_tx_payload_pkts': 20,
            'audio_tx_packet_duration_ms': 40,
            'audio_latency_recovery_count': 0,
            'video_worker_stalled': 0,
            'video_tx_payload_pkts': 0,
            'max_fps': 1.0,
            'video_send_paused': 0,
          };
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          now: () => DateTime(2026, 10, 19).add(clock.elapsed),
        );
        controller.start(_call(self, [peer], video: true));
        clock.flushMicrotasks();
        expect(engine.videoStarted, 1);
        engine.acceptPause = false;
        for (var n = 1; n <= 12; n++) {
          engine.stats = {
            ...engine.stats,
            'audio_playout_sequence': n,
            'audio_playout_ms': 240,
            'audio_latency_recovery_count': n,
            'audio_tx_payload_pkts': n * 100,
            'audio_tx_packet_duration_ms': engine.audioBudgets.last.packetMs,
            'video_tx_payload_pkts': n * 4,
            'max_fps': engine.targets.last.maxFps,
            'video_send_paused': engine.pauses.last ? 1 : 0,
          };
          clock.elapse(const Duration(seconds: 3));
        }
        expect(engine.audioBudgets.any((b) => b.packetMs == 60), isFalse);
        expect(engine.audioBudgets.last.payloadBps, 24000);
        // Once pause really succeeds and outgoing packet counters become quiet,
        // persistent pressure may use the last-resort audio fallback.
        engine.acceptPause = true;
        var videoPackets = 48;
        for (var n = 13; n <= 20; n++) {
          if (!engine.pauses.last) videoPackets += 4;
          engine.stats = {
            ...engine.stats,
            'audio_playout_sequence': n,
            'audio_latency_recovery_count': n,
            'audio_tx_payload_pkts': n * 100,
            'audio_tx_packet_duration_ms': engine.audioBudgets.last.packetMs,
            'video_tx_payload_pkts': videoPackets,
            'video_send_paused': engine.pauses.last ? 1 : 0,
          };
          clock.elapse(const Duration(seconds: 3));
        }
        expect(engine.pauses.last, isTrue);
        expect(engine.audioBudgets.any((b) => b.packetMs == 60), isTrue);
        // Sound recovery can resume bounded video without spending bandwidth
        // on a shorter audio cadence while the transport is still queued.
        for (var n = 21; n <= 42; n++) {
          engine.stats = {
            ...engine.stats,
            'audio_playout_sequence': n,
            'audio_playout_ms': 80,
            'rtt_ms': 77,
            'audio_tx_payload_pkts': n * 100,
            'audio_tx_packet_duration_ms': engine.audioBudgets.last.packetMs,
            'max_fps': engine.targets.last.maxFps,
            'video_send_paused': engine.pauses.last ? 1 : 0,
          };
          clock.elapse(const Duration(seconds: 3));
        }
        expect(engine.audioBudgets.last.packetMs, 60);
        expect(engine.pauses.last, isFalse);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  for (final accepted in [true, false]) {
    test('group growth honors source budget only after SDK ACK=$accepted', () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final transport = _FakeTransport(self)..rejectPressure = !accepted;
        final engine = _FakeEngine()
          ..stats = {
            'worker_stalled': 0,
            'audio_feedback_reports': 1,
            'rtt_ms': 80,
            'audio_receivers': {
              peer.hex: {
                'audio_rx_pkts': 100,
                'audio_delay_ms': 100,
                'audio_rx_native_age_ms': 100,
              },
            },
          };
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          now: () => DateTime(2026, 10, 18).add(clock.elapsed),
        );
        controller.start(_call(self, [peer], video: true));
        clock.flushMicrotasks();
        clock.elapse(Duration(seconds: accepted ? 48 : 120));
        expect(transport.pressureReports.last.pressured, isTrue);
        expect(engine.targets.last.maxFps, accepted ? 1 : 15);
        if (accepted) {
          engine.stats = {
            ..._sourceStats([peer]),
            'audio_feedback_reports': 1,
            'rtt_ms': 80,
          };
          clock.elapse(const Duration(seconds: 12));
          expect(transport.pressureReports.last.pressured, isFalse);
          expect(engine.targets.last.maxFps, 1);
          clock.elapse(const Duration(seconds: 120));
          expect(engine.targets.last.maxFps, 15);
        }
        controller.stop();
        clock.flushMicrotasks();
      });
    });
  }
  for (final cold in [true, false]) {
    test(
      'group video mounts paused and applies its budget (cold=$cold)',
      () async {
        final self = _id(1), peer = _id(2);
        final engine = _FakeEngine()..acceptColdTarget = cold;
        final controller = VeilGroupCallMediaController(
          now: test_clock.clock.now,
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        expect(
          await controller.start(_call(self, [peer], video: true)),
          isTrue,
        );
        expect(engine.videoMountPauses, [true]);
        expect(engine.videoMountTargets, [
          cold ? (maxBitrateKbps: 8, maxFps: 1.0) : null,
        ]);
        expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
        expect(engine.pauses.last, isFalse);
        await controller.stop();
      },
    );
  }
  test(
    'audio-only group applies confirmed Opus budgets and resets per call',
    () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final engine = _FakeEngine(supportsAudioBudget: true)
          ..stats = {
            ..._sourceStats([peer]),
            'audio_max_packet_ms': 60,
            'audio_config_valid': 1,
            'audio_tx_payload_pkts': 0,
            'audio_tx_packet_duration_ms': 40,
            'audio_latency_recovery_count': 0,
          };
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => DateTime(2026, 10, 16).add(clock.elapsed),
        );
        controller.start(_call(self, [peer]));
        clock.flushMicrotasks();
        expect(engine.audioBudgets.single, (packetMs: 40, payloadBps: 32000));
        clock.elapse(const Duration(seconds: 2));
        engine.acceptAudioBudget = false;
        engine.stats = {...engine.stats, 'audio_latency_recovery_count': 1};
        clock.elapse(const Duration(seconds: 1));
        expect(engine.audioBudgets, hasLength(1));
        expect(
          (controller.debugNativeStats['local_audio_budget'] as Map)['pending'],
          isTrue,
        );
        engine.acceptAudioBudget = true;
        clock.elapse(const Duration(seconds: 1));
        expect(engine.audioBudgets.last, (packetMs: 40, payloadBps: 24000));
        clock.elapse(const Duration(seconds: 5));
        expect(engine.audioBudgets, hasLength(2));
        engine.stats = {
          ...engine.stats,
          // Incoming catch-up cannot lengthen our outgoing audio on its own.
          'audio_tx_payload_pkts': 20,
          'audio_latency_recovery_count': 2,
        };
        clock.elapse(const Duration(seconds: 1));
        expect(engine.audioBudgets.last, (packetMs: 40, payloadBps: 24000));
        engine.stats = {
          ...engine.stats,
          'audio_tx_payload_pkts': 40,
          'audio_loss_report_us': 100,
        };
        clock.elapse(const Duration(seconds: 1));
        expect(engine.audioBudgets.last, (packetMs: 60, payloadBps: 24000));
        controller.stop();
        clock.flushMicrotasks();
        // The factory reuses this fake; a fresh native engine has no loss
        // report left over from the previous call.
        engine.stats = {...engine.stats, 'audio_loss_report_us': 0};
        controller.start(_call(self, [peer]));
        clock.flushMicrotasks();
        expect(engine.audioBudgets.last, (packetMs: 40, payloadBps: 32000));
        clock.elapse(const Duration(seconds: 2));
        expect(engine.audioBudgets, hasLength(4));
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'failed initial audio budget closes channels before capture starts',
    () async {
      final self = _id(1), peer = _id(2);
      final transport = _FakeTransport(self);
      final engine = _FakeEngine(supportsAudioBudget: true)
        ..acceptAudioBudget = false;
      final controller = VeilGroupCallMediaController(
        now: test_clock.clock.now,
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
      );
      expect(await controller.start(_call(self, [peer])), isFalse);
      expect(engine.started, 0);
      expect(transport.closed, isNotEmpty);
      expect(controller.debugNativeStats, isEmpty);
      await controller.stop();
    },
  );

  test(
    'group decoded catch-up cuts video once and briefly yields producers',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final transport = _FakeTransport(self);
        final engine = _FakeEngine();
        Map<String, dynamic> sample(int count) => {
          ..._sourceStats([alice, bob]),
          'audio_feedback_reports': 2,
          'rtt_ms': 80,
          'audio_latency_recovery_count': count,
        };
        engine.stats = sample(0);
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          now: () => DateTime(2026, 10, 16).add(clock.elapsed),
        );
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last.maxBitrateKbps, 150);
        expect(transport.pressureReports.last.pressured, isFalse);

        // Catch-up has already restored the queue, so ordinary delay and RTP
        // counters look healthy. Its discarded audio must still reach policy.
        engine.stats = sample(1);
        clock.elapse(const Duration(seconds: 1));
        expect(engine.targets.last.maxBitrateKbps, lessThan(150));
        expect(transport.pressureReports.last.pressured, isTrue);
        final targetsAfterCatchup = engine.targets.length;
        clock.elapse(const Duration(seconds: 3));
        expect(engine.targets.length, targetsAfterCatchup);
        expect(transport.pressureReports.last.pressured, isFalse);

        controller.stop();
        clock.flushMicrotasks();
        // The next engine starts with a baseline, not a replayed catch-up.
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last.maxBitrateKbps, 150);
        engine.stats = sample(
          0,
        ); // A restarted native counter is also a baseline.
        clock.elapse(const Duration(seconds: 1));
        expect(engine.targets.last.maxBitrateKbps, 150);
        engine.stats = sample(1);
        clock.elapse(const Duration(seconds: 1));
        expect(engine.targets.last.maxBitrateKbps, lessThan(150));
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('a cached group report below the ceiling cannot cut live video', () {
    fakeAsync((clock) {
      final self = _id(1), peer = _id(2);
      final engine = _FakeEngine();
      Map<String, dynamic> report(int sequence, int delay) => {
        ..._sourceStats([peer], delay: delay),
        'audio_playout_sequence': sequence,
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
      };
      engine.stats = report(1, 100);
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        now: () => DateTime(2026, 10, 15).add(clock.elapsed),
      );
      controller.start(_call(self, [peer], video: true));
      clock.flushMicrotasks();
      // Cached healthy feedback cannot earn a higher startup budget. First
      // recover with distinct peer observations, then freeze the next report.
      clock.elapse(const Duration(seconds: 12));
      expect(engine.targets.last.maxBitrateKbps, 8);
      var sequence = 1;
      for (var i = 0; i < 120; i++) {
        engine.stats = report(++sequence, 100);
        clock.elapse(const Duration(seconds: 1));
      }
      expect(engine.targets.last.maxBitrateKbps, 150);
      engine.stats = report(++sequence, 140);
      clock.elapse(const Duration(seconds: 20));
      expect(engine.targets.last.maxBitrateKbps, 150);
      expect(engine.pauses.last, isFalse);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('cached group playout cannot fill the source growth window', () {
    fakeAsync((clock) {
      final self = _id(1), peer = _id(2);
      final transport = _FakeTransport(self);
      final engine = _FakeEngine()..stats = _sourceStats([peer]);
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        now: () => DateTime(2026, 10, 15).add(clock.elapsed),
      );
      controller.start(_call(self, [peer]));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 12));
      expect(transport.pressureReports.last.pressured, isFalse);
      engine.stats = {
        ..._sourceStats([peer], delay: 140),
        'audio_playout_sequence': 1,
      };
      clock.elapse(const Duration(seconds: 20));
      expect(transport.pressureReports.last.pressured, isFalse);
      final rising = [100, 100, 100, 125, 130, 135];
      for (var i = 0; i < rising.length; i++) {
        engine.stats = {
          ..._sourceStats([peer], delay: rising[i]),
          'audio_playout_sequence': i + 2,
        };
        clock.elapse(const Duration(seconds: 1));
        expect(
          transport.pressureReports.last.pressured,
          i == rising.length - 1,
        );
      }
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test(
    'malformed group report counts stay unknown without breaking the stats timer',
    () {
      for (final count in [null, 'invalid', double.nan, -1]) {
        fakeAsync((clock) {
          final self = _id(1), peer = _id(2);
          final transport = _FakeTransport(self);
          final engine = _FakeEngine()
            ..stats = {
              ..._sourceStats([peer]),
              'audio_playout_reports': count,
            };
          final controller = VeilGroupCallMediaController(
            transport,
            roomMediaSecret: _room(),
            engineFactory: (_) => engine,
            requestMicrophone: () async => true,
            now: () => DateTime(2026, 10, 15).add(clock.elapsed),
          );
          controller.start(_call(self, [peer]));
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 15));
          expect(transport.pressureReports, hasLength(15));
          expect(transport.pressureReports.every((r) => r.pressured), isTrue);
          engine.stats = _sourceStats([peer]);
          clock.elapse(const Duration(seconds: 12));
          expect(transport.pressureReports.last.pressured, isFalse);
          controller.stop();
          clock.flushMicrotasks();
        });
      }
    },
  );

  test(
    'new group listeners cannot spend source headroom from the old roster',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final transport = _FakeTransport(self);
        final engine = _FakeEngine()..stats = _sourceStats([alice]);
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => DateTime(2026, 10, 15).add(clock.elapsed),
        );
        controller.start(_call(self, [alice]));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 12));
        expect(transport.pressureReports.last.pressured, isFalse);
        controller.update(_call(self, [alice, bob]));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 20));
        expect(transport.pressureReports.last.pressured, isTrue);
        engine.stats = _sourceStats([alice, bob]);
        clock.elapse(const Duration(seconds: 12));
        expect(transport.pressureReports.last.pressured, isFalse);
        engine.stats = const {};
        final reports = transport.pressureReports.length;
        clock.elapse(const Duration(seconds: 10));
        expect(
          transport.pressureReports,
          hasLength(reports),
          reason: 'unknown samples cannot renew a cleared congestion lease',
        );
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'group local mute still protects incoming audio and no-audio stops reports',
    () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final transport = _FakeTransport(self);
        final engine = _FakeEngine()
          ..stats = {
            ..._sourceStats([peer]),
            'audio_receivers': {
              peer.hex: {
                'audio_rx_pkts': 20,
                'audio_delay_ms': 220,
                'audio_rx_native_age_ms': 10,
              },
            },
          };
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => DateTime(2026, 10, 15).add(clock.elapsed),
        );
        final room = _call(self, [peer]);
        controller.start(room);
        clock.flushMicrotasks();
        controller.setMicMuted(true);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 20));
        expect(transport.pressureReports.last.pressured, isTrue);
        controller.update(
          room.copyWith(
            participants: {
              ...room.participants,
              peer.hex: room.participants[peer.hex]!.copyWith(
                media: const CallMedia(audio: false),
              ),
            },
          ),
        );
        clock.flushMicrotasks();
        final count = transport.pressureReports.length;
        clock.elapse(const Duration(seconds: 5));
        expect(transport.pressureReports, hasLength(count));
        expect(controller.debugNativeStats['local_source_pressured'], isNull);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'group feedback stays bounded and a stopped epoch cannot update its successor',
    () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final pending = Completer<bool>();
        final transport = _FakeTransport(self)
          ..rejectPressure = false
          ..pendingPressure = pending;
        final engine = _FakeEngine()..stats = _sourceStats([peer]);
        final origin = DateTime(2026, 10, 15);
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => origin.add(clock.elapsed),
        );
        final room = _call(self, [peer]);
        controller.start(room);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 5));
        expect(transport.pressureReports, hasLength(1));
        expect(
          transport.pressureReports.single.at,
          origin.add(const Duration(seconds: 1)),
        );
        controller.stop();
        clock.flushMicrotasks();
        controller.start(room);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 3));
        expect(transport.pressureReports, hasLength(1));
        transport.pendingPressure = null;
        pending.complete(true);
        clock.flushMicrotasks();
        expect(
          controller.debugNativeStats['local_source_feedback_queued'],
          0,
          reason: 'same engine object in another epoch is still a new call',
        );
        clock.elapse(const Duration(seconds: 1));
        expect(transport.pressureReports, hasLength(2));
        expect(transport.pressureReports.last.at, origin.add(clock.elapsed));
        expect(controller.debugNativeStats['local_source_feedback_queued'], 1);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test(
    'unavailable group source IPC cannot break audio or accumulate reports',
    () {
      for (final mode in ['throw', 'error', 'reject']) {
        fakeAsync((clock) {
          final self = _id(1), peer = _id(2);
          final transport = _FakeTransport(self)
            ..throwPressure = mode == 'throw'
            ..failPressure = mode == 'error'
            ..rejectPressure = mode == 'reject';
          final engine = _FakeEngine()..stats = _sourceStats([peer]);
          final controller = VeilGroupCallMediaController(
            transport,
            roomMediaSecret: _room(),
            engineFactory: (_) => engine,
            requestMicrophone: () async => true,
            now: () => DateTime(2026, 10, 15).add(clock.elapsed),
          );
          controller.start(_call(self, [peer]));
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 15));
          expect(transport.pressureReports, hasLength(15));
          expect(
            controller.debugNativeStats['local_source_feedback_skipped'],
            15,
          );
          expect(
            controller.debugNativeStats['local_source_feedback_queued'],
            0,
          );
          expect(engine.started, 1);
          controller.stop();
          clock.flushMicrotasks();
        });
      }
    },
  );

  test(
    'audio-only group reports pressure and recovers only with every peer',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final transport = _FakeTransport(self);
        final engine = _FakeEngine();
        final origin = DateTime(2026, 10, 15);
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => origin.add(clock.elapsed),
        );
        Map<String, dynamic> sample({int reports = 2, int delay = 100}) => {
          'audio_rx_supported': 1,
          'audio_rx_native_age_supported': 1,
          'worker_stalled': 0,
          'audio_playout_peers': 2,
          'audio_playout_reports': reports,
          'audio_playout_ms': delay,
          'audio_tx_rtp_drops': 0,
          'audio_receivers': {
            for (final peer in [alice, bob])
              peer.hex: {
                'audio_rx_pkts': 20,
                'audio_delay_ms': 100,
                'audio_rx_native_age_ms': 10,
                'audio_interruption_count': 0,
              },
          },
        };
        engine.stats = sample();
        controller.start(_call(self, [alice, bob]));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 1));
        expect(transport.pressureReports.last.pressured, isTrue);
        expect(transport.pressureReports.last.at, origin.add(clock.elapsed));
        clock.elapse(const Duration(seconds: 11));
        expect(transport.pressureReports.last.pressured, isFalse);
        engine.stats = sample(reports: 1, delay: 220);
        clock.elapse(const Duration(seconds: 1));
        expect(
          transport.pressureReports.last.pressured,
          isTrue,
          reason: 'one known overloaded receiver suffices',
        );
        engine.stats = sample(reports: 1);
        clock.elapse(const Duration(seconds: 20));
        expect(
          transport.pressureReports.last.pressured,
          isTrue,
          reason: 'one healthy receiver cannot clear the missing peer',
        );
        engine.stats = sample();
        clock.elapse(const Duration(seconds: 11));
        expect(transport.pressureReports.last.pressured, isTrue);
        clock.elapse(const Duration(seconds: 1));
        expect(transport.pressureReports.last.pressured, isFalse);
        expect(
          engine.videoStarted,
          0,
          reason: 'audio-only calls need admission too',
        );
        controller.stop();
        clock.flushMicrotasks();
        final count = transport.pressureReports.length;
        clock.elapse(const Duration(seconds: 5));
        expect(transport.pressureReports, hasLength(count));
      });
    },
  );

  test(
    'fresh group audio interruptions reduce video and pause a failed floor trial',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          now: test_clock.clock.now,
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        Map<String, dynamic> sample(int interruptions, {int bobDelay = 100}) =>
            {
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
                  'audio_delay_ms': bobDelay,
                  'audio_rx_native_age_ms': 10,
                  'audio_interruption_count': interruptions,
                },
              },
            };
        engine.stats = sample(0);
        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last.maxBitrateKbps, 150);
        for (var i = 1; i <= 6; i++) {
          engine.stats = sample(i);
          clock.elapse(const Duration(seconds: 1));
          if (i <= 3) expect(engine.pauses.last, isFalse);
        }
        expect(
          engine.pauses.last,
          isTrue,
          reason: 'fresh audio loss also triggers protection below the ceiling',
        );
        expect(engine.targets.last.maxBitrateKbps, lessThan(150));
        expect(engine.cameraStarted, 1);
        engine.stats = sample(6);
        clock.elapse(const Duration(seconds: 2));
        expect(engine.pauses.last, isTrue);
        clock.elapse(const Duration(seconds: 1));
        expect(engine.pauses.last, isFalse);
        expect(
          engine.targets.last.maxFps,
          1,
          reason: 'measured recovery earns only the sparse probe',
        );
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
          now: test_clock.clock.now,
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
        expect(engine.videoMountPauses, [true]);
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
        now: test_clock.clock.now,
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
        now: test_clock.clock.now,
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
          now: test_clock.clock.now,
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
        clock.elapse(const Duration(seconds: 120));
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
        clock.elapse(const Duration(seconds: 120));
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

  test(
    'one group buffer ceiling pauses video despite another healthy peer',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          now: test_clock.clock.now,
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        final room = _call(self, [alice, bob], video: true);
        controller.start(room);
        clock.flushMicrotasks();
        Map<String, dynamic> sample(
          int? aliceAge,
          int? bobAge, {
          int bobDelay = 100,
        }) => {
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
              'audio_delay_ms': bobDelay,
              'audio_rx_native_age_ms': bobAge,
            },
          },
        };
        engine.stats = sample(100, 100);
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last.maxBitrateKbps, 150);
        engine.stats = sample(100, 4456, bobDelay: 220);
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
        clock.elapse(const Duration(seconds: 2));
        expect(engine.pauses.last, isTrue);
        clock.elapse(const Duration(seconds: 1));
        expect(
          engine.pauses.last,
          isFalse,
          reason: 'all expected audio must be fresh for the three-sample probe',
        );
        expect(engine.targets.last.maxFps, 1);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

  test('group receive priority follows remote mute, unmute and removal', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        now: test_clock.clock.now,
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
            'audio_delay_ms': 220,
            'audio_rx_native_age_ms': 13000,
          },
        },
      };
      clock.elapse(const Duration(seconds: 120));
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
    'known group buffer ceiling remains actionable when another peer never sent audio',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          now: test_clock.clock.now,
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
        clock.elapse(const Duration(seconds: 120));
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
              'audio_delay_ms': 220,
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
          reason:
              'known Alice buffer ceiling is sufficient despite unknown Bob',
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
        now: test_clock.clock.now,
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
          now: test_clock.clock.now,
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
        now: test_clock.clock.now,
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
        now: test_clock.clock.now,
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
        now: test_clock.clock.now,
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
      clock.elapse(const Duration(seconds: 120));
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
      clock.elapse(const Duration(seconds: 120));
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
        now: test_clock.clock.now,
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      controller.start(_call(self, [alice], video: true));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 120));
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
      final earned = engine.targets.last;
      engine.throwStats = true;
      clock.elapse(const Duration(seconds: 2));
      expect(
        engine.pauses.last,
        isFalse,
        reason: 'unknown worker health still permits the sparse trial',
      );
      expect(
        engine.targets.last,
        earned,
        reason: 'unknown health holds the earned rung without a buffer cut',
      );
      engine.throwStats = false;
      clock.elapse(const Duration(seconds: 11));
      expect(engine.targets.last, earned);
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
        now: test_clock.clock.now,
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      controller.start(_call(self, [alice], video: true));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 120));
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
        now: test_clock.clock.now,
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
      expect(engine.targets.last.maxBitrateKbps, 9);
      clock.elapse(const Duration(seconds: 7));
      expect(engine.targets.last.maxBitrateKbps, 15);
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
        now: test_clock.clock.now,
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
      final earned = engine.targets.last;
      engine.stats = {...engine.stats, 'audio_playout_reports': 0};
      clock.elapse(const Duration(seconds: 8));
      expect(engine.pauses.last, isFalse);
      expect(
        engine.targets.last,
        earned,
        reason: 'missing playout holds the rung rather than cutting video',
      );
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
        now: test_clock.clock.now,
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
      clock.elapse(const Duration(seconds: 120));
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      engine.stats = {
        ...engine.stats,
        'audio_playout_reports': 0,
        'audio_playout_ms': -1,
      };
      clock.elapse(const Duration(seconds: 8));
      expect(
        engine.targets.last,
        (maxBitrateKbps: 150, maxFps: 15),
        reason: 'expired reports alone cannot cut the earned video budget',
      );
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
      clock.elapse(const Duration(seconds: 120));
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
    'group video grows only with fresh feedback and holds an earned rung on unknown samples',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3), carol = _id(4);
        final engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          now: test_clock.clock.now,
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
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.stats = {...engine.stats, 'audio_feedback_reports': 1};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 150, maxFps: 15),
          reason:
              'missing feedback cannot cut video without measured buffer pressure',
        );
        engine.stats = {...engine.stats, 'audio_feedback_reports': 2};
        clock.elapse(const Duration(seconds: 120));
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
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last, (
          maxBitrateKbps: 150,
          maxFps: 15,
        ), reason: 'removed peers no longer block recovery');
        final healthy = engine.stats;
        engine.stats = const {};
        clock.elapse(const Duration(seconds: 8));
        expect(engine.targets.last, (
          maxBitrateKbps: 150,
          maxFps: 15,
        ), reason: 'unreadable stats hold the earned rung');
        engine.stats = healthy;
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.throwStats = true;
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 150, maxFps: 15),
          reason: 'a failed query cannot invent measured buffer pressure',
        );
        engine.throwStats = false;
        clock.elapse(const Duration(seconds: 120));
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        engine.stats = {...engine.stats, 'worker_stalled': 1};
        clock.elapse(const Duration(seconds: 8));
        expect(
          engine.targets.last,
          (maxBitrateKbps: 150, maxFps: 15),
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
          now: test_clock.clock.now,
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
        clock.elapse(const Duration(seconds: 120));
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
        now: test_clock.clock.now,
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
      now: test_clock.clock.now,
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

  test('unsupported desktop screen leaves the camera source intact', () async {
    final self = _id(1);
    final transport = _FakeTransport(self);
    final engine = _FakeEngine();
    final controller = VeilGroupCallMediaController(
      now: test_clock.clock.now,
      transport,
      roomMediaSecret: _room(),
      engineFactory: (_) => engine,
      requestMicrophone: () async => true,
      requestCamera: () async => true,
      desktopScreenCaptureSupported: false,
    );
    addTearDown(controller.stop);
    expect(await controller.start(_call(self, [_id(2)], video: true)), isTrue);
    final cameraStarts = engine.cameraStarted;
    expect(await controller.setScreenShareEnabled(true), isFalse);
    expect(transport.screenModes, isEmpty);
    expect(engine.cameraStarted, cameraStarts);
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
        now: test_clock.clock.now,
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        desktopScreenCaptureSupported: true,
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
          now: test_clock.clock.now,
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          desktopScreenCaptureSupported: true,
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
        now: test_clock.clock.now,
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
        now: test_clock.clock.now,
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
  final List<({bool pressured, DateTime at})> pressureReports = [];
  Completer<bool>? pendingPressure;
  bool failPressure = false;
  bool throwPressure = false;
  // Ordinary video-policy tests use a transport without the optional endpoint
  // admission lease. Tests of that lease explicitly enable successful ACKs.
  bool rejectPressure = true;

  @override
  Future<bool> reportLocalSourcePressure({
    required bool pressured,
    required DateTime sampledAt,
  }) {
    pressureReports.add((pressured: pressured, at: sampledAt));
    if (throwPressure) throw StateError('local IPC unavailable');
    if (failPressure) return Future.error(StateError('local IPC unavailable'));
    return pendingPressure?.future ?? Future.value(!rejectPressure);
  }

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
    this.supportsAudioBudget = false,
  });
  @override
  final bool supportsAudioBudget;
  final List<({int packetMs, int payloadBps})> audioBudgets = [];
  bool acceptAudioBudget = true;
  @override
  bool setAudioBudget({required int packetMs, required int payloadBps}) {
    if (!acceptAudioBudget) return false;
    audioBudgets.add((packetMs: packetMs, payloadBps: payloadBps));
    return true;
  }

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
  final List<({int maxBitrateKbps, double maxFps})?> videoMountTargets = [];
  bool videoActive = false;
  bool acceptColdTarget = true;
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
    if (!acceptTarget || (!videoActive && !acceptColdTarget)) return false;
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
    videoMountTargets.add(targets.isEmpty ? null : targets.last);
    videoActive = true;
    videoStarted++;
    return true;
  }

  @override
  bool stopVideo() {
    videoActive = false;
    return true;
  }

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
