import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraPlatform;
import 'package:xveil/state/call_slot.dart';
import 'package:xveil/state/call_service.dart'
    show CallMediaDevice, CallMediaDeviceKind;
import 'support/camera_retirement_platform.dart';
import 'package:fake_async/fake_async.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clock/clock.dart' as test_clock;
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/group_service.dart';
import 'package:xveil/state/veil_group_call_media.dart';
import 'package:xveil/state/call_audio_buffer_window.dart';
import 'package:xveil/state/call_network_activity.dart';
import 'package:xveil/state/android_call_foreground.dart';
import 'package:xveil/state/android_camera_capture.dart';
import 'package:xveil/state/android_screen_capture.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

Uint8List _secret(int byte) => Uint8List.fromList(List.filled(32, byte));

/// Room secret source for the tests that are not about the seal itself. A
/// fresh copy per resolve: the controller wipes what it is handed.
GroupCallMediaSecretResolver _room([int byte = 0x5a]) =>
    (_) async => _secret(byte);

GroupCall _call(
  NodeId self,
  List<NodeId> peers, {
  bool video = false,
  String callId = 'group-media',
  NodeId? groupId,
  NodeId? channelId,
}) {
  final now = DateTime(2026, 7, 13);
  return GroupCall(
    groupId: groupId ?? _id(9),
    channelId: channelId,
    callId: callId,
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

class _StartGate {
  _StartGate(this.stage);
  final String stage;
  final entered = Completer<void>(), ready = Completer<void>();
  bool used = false;

  Future<void> pause(String at) async {
    if (stage != at || used) return;
    used = true;
    entered.complete();
    await ready.future;
  }
}

class _CancelledStartTransport extends _FakeTransport {
  _CancelledStartTransport(super.self, this.gate);
  final _StartGate gate;

  @override
  Future<Uint8List> localNodeId() async {
    await gate.pause('identity');
    return super.localNodeId();
  }

  @override
  Future<int> open(
    NodeId peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
  }) async {
    final channel = await super.open(peer, txKey: txKey, rxKey: rxKey);
    await gate.pause('channel');
    return channel;
  }
}

class _CancelledStartEngine extends _FakeEngine {
  int disposed = 0;
  @override
  void dispose() {
    disposed++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stage in [
    'permission',
    'identity',
    'activity',
    'foreground',
    'secret',
    'channel',
  ]) {
    for (final action in ['keep', 'stop', 'replace', 'queued-stop-replace']) {
      test('group start cancellation at $stage with $action', () async {
        final self = _id(1), peers = [_id(2), _id(3)];
        final gate = _StartGate(stage);
        final transport = _CancelledStartTransport(self, gate);
        final engines = <_CancelledStartEngine>[];
        final grants = <bool>[], foreground = <bool>[];
        final secrets = <Uint8List>[];
        AndroidCallForegroundService.debugReset();
        AndroidCallForegroundService.debugInvokeOverride = (active) async {
          foreground.add(active);
          if (active) await gate.pause('foreground');
          return true;
        };
        final activity = CallNetworkActivity(
          setActive: (active) async {
            grants.add(active);
            if (active) await gate.pause('activity');
            return active;
          },
        );
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: (_) async {
            await gate.pause('secret');
            final secret = _secret(0x5a);
            secrets.add(secret);
            return secret;
          },
          engineFactory: (_) {
            final engine = _CancelledStartEngine();
            engines.add(engine);
            return engine;
          },
          requestMicrophone: () async {
            await gate.pause('permission');
            return true;
          },
          networkActivity: activity,
        );
        final starting = controller.start(_call(self, peers));
        Future<void>? stopping;
        Future<bool>? replacement;
        Future<bool>? superseded;
        try {
          await gate.entered.future.timeout(const Duration(seconds: 5));
          final retired = List<_CancelledStartEngine>.of(engines);
          if (action == 'stop') stopping = controller.stop();
          if (action == 'replace') {
            await controller.setMicMuted(true);
            replacement = controller.start(_call(self, peers));
          }
          if (action == 'queued-stop-replace') {
            await controller.setMicMuted(true);
            superseded = controller.start(_call(self, peers));
            stopping = controller.stop();
            replacement = controller.start(_call(self, peers));
          }
          gate.ready.complete();
          final result = await starting;
          if (superseded != null) expect(await superseded, isFalse);
          await stopping;
          if (replacement != null) expect(await replacement, isTrue);
          if (action == 'replace') {
            expect(
              engines.last.audioStartMuted,
              [true],
              reason: 'same-call replacement must retain a live mute choice',
            );
          }
          if (action == 'queued-stop-replace') {
            expect(
              engines.last.audioStartMuted,
              [false],
              reason: 'an explicit stop ends the previous call mute lifetime',
            );
          }
          expect(
            {
              'startResult': result,
              'audioStarts': engines.fold<int>(
                0,
                (n, engine) => n + engine.started,
              ),
            },
            {
              'startResult': action == 'keep',
              'audioStarts': action == 'stop' ? 0 : 1,
            },
            reason: 'a retired start must not capture or publish success',
          );
          if (action != 'keep') {
            for (final engine in retired) {
              expect(engine.started, 0);
              expect(engine.added, isEmpty);
              expect(engine.disposed, 1);
            }
          }
          final expectedOpens = action == 'keep'
              ? peers.length
              : (stage == 'channel' ? 1 : 0) +
                    (replacement != null ? peers.length : 0);
          expect(
            transport.opened,
            hasLength(expectedOpens),
            reason: 'cancellation cannot open more peer channels',
          );
          if (stage == 'channel' && action != 'keep') {
            expect(
              transport.closed.where((channel) => channel == 1),
              hasLength(1),
              reason: 'the late admitted channel is reclaimed once',
            );
          }
          expect(
            secrets.every((secret) => secret.every((byte) => byte == 0)),
            isTrue,
          );
          if (action == 'stop') {
            expect(AndroidCallForegroundService.isActive, isFalse);
            expect(grants.isEmpty || !grants.last, isTrue);
          } else {
            expect(AndroidCallForegroundService.isActive, isTrue);
            expect(grants.last, isTrue);
          }
        } finally {
          if (!gate.ready.isCompleted) gate.ready.complete();
          try {
            await starting;
            await stopping;
            await replacement;
            await superseded;
          } finally {
            await controller.stop();
            AndroidCallForegroundService.debugReset();
          }
        }
      });
    }
  }

  test('group capture waits for stored processing choice', () async {
    final self = _id(1), peer = _id(2);
    final ready = Completer<void>();
    final transport = _StartingGroupTransport(self);
    final engine = _FakeEngine();
    var creates = 0;
    final controller = VeilGroupCallMediaController(
      transport,
      roomMediaSecret: _room(),
      audioProcessingReady: ready.future,
      engineFactory: (_) {
        creates++;
        return engine;
      },
      requestMicrophone: () async => true,
      networkActivity: CallNetworkActivity(setActive: (_) async => true),
    );
    final start = controller.start(_call(self, [peer]));
    try {
      await transport.starting.future;
      await Future<void>.delayed(Duration.zero);
      expect(creates, 0);
      controller.setNoiseSuppression(false);
      ready.complete();
      expect(await start, isTrue);
      expect(engine.noiseSuppression, [false]);
    } finally {
      if (!ready.isCompleted) ready.complete();
      await start;
      await controller.stop();
    }
  });
  test(
    'group noise choice survives live changes and replacement without accepting a refusal',
    () async {
      final self = _id(1), peer = _id(2);
      final engines = [_FakeEngine(), _FakeEngine()];
      var creates = 0;
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engines[creates++],
        requestMicrophone: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => true),
      );
      try {
        expect(controller.setNoiseSuppression(false), isTrue);
        expect(await controller.start(_call(self, [peer])), isTrue);
        expect(engines[0].noiseSuppression, [false]);
        expect(controller.setNoiseSuppression(true), isTrue);
        engines[0].rejectNoiseSuppression = true;
        expect(controller.setNoiseSuppression(false), isFalse);
        expect(await controller.start(_call(self, [peer])), isTrue);
        expect(engines[1].noiseSuppression, [true]);
      } finally {
        await controller.stop();
      }
    },
  );

  test(
    'one group concealment cannot bypass video debouncing at the audio floor',
    () {
      fakeAsync((clock) {
        final self = _id(1), alice = _id(2), bob = _id(3);
        final transport = _FakeTransport(self);
        final engine = _FakeEngine(supportsAudioBudget: true);
        final controller = VeilGroupCallMediaController(
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          now: () => DateTime(2026, 10, 20).add(clock.elapsed),
        );
        var tick = 0;
        void sample({int recovery = 0, int concealment = 0, int loss = 0}) {
          tick++;
          engine.stats = {
            ..._sourceStats([alice, bob]),
            'audio_config_valid': 1,
            'audio_max_packet_ms': 60,
            'audio_feedback_reports': 2,
            'video_feedback_reports': 2,
            'video_feedback_rtt_ms': 80,
            'video_feedback_jitter_ms': 10,
            'rtt_ms': 80,
            'audio_playout_sequence': tick,
            'audio_tx_payload_pkts': tick * 25,
            'audio_tx_packet_duration_ms': engine.audioBudgets.last.packetMs,
            'audio_latency_recovery_count': recovery,
            'audio_peer_concealment_report_us': concealment,
            'audio_loss_report_us': loss,
            'video_worker_stalled': 0,
            'video_tx_payload_pkts': tick * 30,
            'max_fps': engine.targets.last.maxFps,
            'video_send_paused': engine.pauses.last ? 1 : 0,
          };
          clock.elapse(const Duration(seconds: 1));
        }

        controller.start(_call(self, [alice, bob], video: true));
        clock.flushMicrotasks();
        for (var n = 0; n < 120; n++) {
          sample();
        }
        expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
        sample(recovery: 1);
        expect(engine.audioBudgets.last, (packetMs: 40, payloadBps: 24000));
        for (var n = 0; n < 7; n++) {
          sample(recovery: 1);
        }
        final earned = engine.targets.last;
        expect(earned, (maxBitrateKbps: 150, maxFps: 15));
        sample(recovery: 1, concealment: 100);
        expect(transport.pressureReports.last.pressured, isTrue);
        expect(
          engine.targets.last,
          earned,
          reason:
              'one soft event yields background work without forcing one fps',
        );
        sample(recovery: 1, concealment: 100);
        expect(
          engine.targets.last,
          earned,
          reason: 'cached event cannot reduce video',
        );
        sample(recovery: 1, concealment: 100, loss: 100);
        expect(
          engine.targets.last.maxFps,
          1,
          reason:
              'fresh outgoing loss still forces video to yield before longer audio',
        );
        expect(engine.audioBudgets.last.packetMs, 40);
        controller.stop();
        clock.flushMicrotasks();
      });
    },
  );

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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
            'audio_playout_ms': CallAudioBufferWindow.ceilingMs,
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
      final networkCalls = <bool>[];
      final network = CallNetworkActivity(
        setActive: (active) async {
          networkCalls.add(active);
          return active;
        },
      );
      final self = _id(1), peer = _id(2);
      final transport = _FakeTransport(self);
      final engine = _FakeEngine(supportsAudioBudget: true)
        ..acceptAudioBudget = false;
      final controller = VeilGroupCallMediaController(
        networkActivity: network,
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
      expect(networkCalls, [true, false]);
      await controller.stop();
      expect(networkCalls, [true, false]);
    },
  );

  test(
    'group activity follows successful media and releases on start exceptions',
    () async {
      for (final fail in [false, true]) {
        final calls = <bool>[];
        final network = CallNetworkActivity(
          setActive: (active) async {
            calls.add(active);
            return active;
          },
        );
        final self = _id(1), peer = _id(2);
        final engine = _FakeEngine()..throwOnAudioStart = fail;
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          networkActivity: network,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
        );
        if (fail) {
          await expectLater(
            controller.start(_call(self, [peer])),
            throwsStateError,
          );
          expect(calls, [true, false]);
        } else {
          expect(await controller.start(_call(self, [peer])), isTrue);
          expect(calls, [true]);
        }
        await controller.stop();
        expect(calls, [true, false]);
      }
    },
  );

  test(
    'isolated group decoded catch-up holds video while briefly yielding producers',
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        expect(engine.targets.last.maxBitrateKbps, 150);
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
        expect(engine.targets.last.maxBitrateKbps, 150);
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
      // Brief growth below the ceiling only holds further growth. It takes
      // three seconds of continuing evidence to restrict competing sources.
      final rising = [100, 100, 100, 150, 200, 250, 280, 290, 295];
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
            networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          expect(
            engine.audioSourcePressure.last,
            isNull,
            reason: 'unknown measurements are not transport floor pressure',
          );
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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

  test('group incoming concealment yields local video with a muted mic', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final transport = _FakeTransport(self);
      final engine = _FakeEngine()
        ..stats = {
          ..._sourceStats([alice, bob]),
          'video_feedback_reports': 2,
          'video_feedback_rtt_ms': 80,
          'video_feedback_jitter_ms': 10,
        };
      final controller = VeilGroupCallMediaController(
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        now: () => DateTime(2026, 10, 20).add(clock.elapsed),
      );
      controller.start(_call(self, [alice, bob], video: true));
      clock.flushMicrotasks();
      controller.setMicMuted(true);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 120));
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      expect(transport.pressureReports.last.pressured, isFalse);
      engine.stats = {
        ...engine.stats,
        'audio_local_concealment_report_us': 100,
      };
      clock.elapse(const Duration(seconds: 1));
      expect(transport.pressureReports.last.pressured, isTrue);
      expect(engine.targets.last, (maxBitrateKbps: 150, maxFps: 15));
      clock.elapse(const Duration(seconds: 1));
      engine.stats = {
        ...engine.stats,
        'audio_local_concealment_report_us': 200,
      };
      clock.elapse(const Duration(seconds: 1));
      final reduced = engine.targets.last;
      expect(reduced.maxFps, lessThan(15));
      expect(reduced.maxBitrateKbps, lessThan(150));
      clock.elapse(const Duration(seconds: 3));
      expect(
        engine.targets.last,
        reduced,
        reason: 'cached report cannot cut again',
      );
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test(
    'known group damage carries one hold event to native and SDK independently',
    () {
      fakeAsync((clock) {
        final self = _id(1), peer = _id(2);
        final transport = _FakeTransport(self)..rejectPressure = false;
        final engine = _FakeEngine()
          ..stats = {
            ..._sourceStats([peer]),
            'audio_soft_loss_duration_supported': 1,
            'audio_peer_soft_loss_duration_supported': 1,
            'audio_local_soft_loss_report_us': 0,
            'audio_peer_soft_loss_report_us': 0,
            'audio_latency_recovery_count': 0,
          };
        final origin = DateTime(2026, 10, 20);
        final controller = VeilGroupCallMediaController(
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => origin.add(clock.elapsed),
        );
        controller.start(_call(self, [peer]));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 15));
        expect(transport.pressureReports.last.pressured, isFalse);
        final pending = Completer<bool>();
        transport.pendingPressure = pending;
        engine.stats = {...engine.stats, 'audio_latency_recovery_count': 1};
        clock.elapse(const Duration(seconds: 1));
        final event = origin.add(const Duration(seconds: 16));
        expect(transport.pressureReports.last.pressured, isFalse);
        expect(transport.growthHoldReports.last, (at: event, event: event));
        expect(engine.audioSourcePressure.last, isFalse);
        clock.elapse(const Duration(seconds: 2));
        expect(
          engine.audioGrowthHolds,
          hasLength(3),
          reason: 'native hold must not wait for SDK admission ACK',
        );
        expect(engine.audioGrowthHolds.every((r) => r.event == event), isTrue);
        expect(
          engine.audioGrowthHolds.last.at,
          origin.add(const Duration(seconds: 18)),
        );
        transport.pendingPressure = null;
        pending.complete(true);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 1));
        expect(
          engine.audioGrowthHolds,
          hasLength(3),
          reason: 'polls cannot renew the hold',
        );
        expect(transport.pressureReports.last.pressured, isFalse);
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        expect(engine.audioSourcePressure.last, isFalse);
        expect(
          engine.audioSourcePressure.where((value) => value == false).length,
          greaterThanOrEqualTo(5),
          reason: 'native feedback must not wait for SDK admission ACK',
        );
        expect(
          transport.pressureReports.single.at,
          origin.add(const Duration(seconds: 1)),
        );
        controller.stop();
        clock.flushMicrotasks();
        final replacementPending = Completer<bool>();
        transport.pendingPressure = replacementPending;
        controller.start(room);
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 3));
        expect(transport.pressureReports, hasLength(2));
        pending.complete(true);
        clock.flushMicrotasks();
        expect(
          controller.debugNativeStats['local_source_feedback_queued'],
          0,
          reason: 'same engine object in another epoch is still a new call',
        );
        clock.elapse(const Duration(seconds: 1));
        expect(transport.pressureReports, hasLength(2));

        transport.pendingPressure = null;
        replacementPending.complete(true);
        clock.flushMicrotasks();
        expect(controller.debugNativeStats['local_source_feedback_queued'], 1);
        clock.elapse(const Duration(seconds: 1));
        expect(transport.pressureReports, hasLength(3));
        expect(transport.pressureReports.last.at, origin.add(clock.elapsed));
        expect(controller.debugNativeStats['local_source_feedback_queued'], 2);
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
            networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          now: () => origin.add(clock.elapsed),
        );
        Map<String, dynamic> sample({
          int reports = 2,
          int delay = 100,
          int? pressure,
        }) => {
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
                'audio_pressure_delay_ms': ?pressure,
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
        engine.stats = sample(
          reports: 1,
          delay: CallAudioBufferWindow.ceilingMs,
        );
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
        engine.stats = sample(pressure: CallAudioBufferWindow.ceilingMs);
        clock.elapse(const Duration(seconds: 1));
        expect(
          transport.pressureReports.last.pressured,
          isTrue,
          reason: 'a small local queue cannot hide old audio from upstream',
        );
        engine.stats = sample();
        clock.elapse(const Duration(seconds: 12));
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        engine.stats = sample(
          100,
          4456,
          bobDelay: CallAudioBufferWindow.ceilingMs,
        );
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

  test('room subtracts only each receiver’s own filled jitter reserve', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
        now: test_clock.clock.now,
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      Map<String, dynamic> sample(
        int bobDelay, {
        int aliceDelay = 520,
        int? alicePressure,
      }) => {
        'audio_rx_native_age_supported': 1,
        'worker_stalled': 0,
        'audio_feedback_reports': 2,
        'rtt_ms': 80,
        'audio_receivers': {
          alice.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': aliceDelay,
            'audio_pressure_delay_ms': ?alicePressure,
            'audio_jb_target_ms': 500,
            'audio_rx_native_age_ms': 100,
          },
          bob.hex: {
            'audio_rx_pkts': 20,
            'audio_delay_ms': bobDelay,
            'audio_jb_target_ms': 40,
            'audio_rx_native_age_ms': 100,
          },
        },
      };
      engine.stats = sample(100);
      controller.start(_call(self, [alice, bob], video: true));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 6));
      expect(engine.pauses.last, isFalse);

      engine.stats = sample(CallAudioBufferWindow.ceilingMs);
      clock.elapse(const Duration(seconds: 4));
      expect(engine.pauses.last, isTrue);

      engine.stats = sample(100);
      clock.elapse(const Duration(seconds: 12));
      expect(engine.pauses.last, isFalse);
      engine.stats = sample(100, aliceDelay: 100, alicePressure: 520);
      clock.elapse(const Duration(seconds: 4));
      expect(engine.pauses.last, isTrue);
      controller.stop();
      clock.flushMicrotasks();
    });
  });

  test('group receive priority follows remote mute, unmute and removal', () {
    fakeAsync((clock) {
      final self = _id(1), alice = _id(2), bob = _id(3);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
            'audio_delay_ms': CallAudioBufferWindow.ceilingMs,
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
              'audio_delay_ms': 100,
              'audio_rx_native_age_ms': 100,
            },
            bob.hex: {
              'audio_rx_pkts': 15,
              'audio_delay_ms': 720,
              'audio_rx_native_age_ms': -1,
            },
          },
        };
        clock.elapse(const Duration(seconds: 4));
        expect(
          engine.pauses.last,
          isFalse,
          reason: 'padding counters cannot qualify an unknown receiver buffer',
        );
        engine.stats = {
          ...engine.stats,
          'audio_receivers': {
            alice.hex: {
              'audio_rx_pkts': 20,
              'audio_delay_ms': CallAudioBufferWindow.ceilingMs,
              'audio_rx_native_age_ms': 1085,
            },
            bob.hex: {
              'audio_rx_pkts': 15,
              'audio_delay_ms': 720,
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
      expect(engine.pauses.last, isTrue);
      engine.stats = {...engine.stats, 'audio_playout_ms': 250};
      clock.elapse(const Duration(seconds: 30));
      expect(
        engine.targets.last,
        (maxBitrateKbps: 8, maxFps: 1.0),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
      expect(engine.targets.last, (maxBitrateKbps: 8, maxFps: 1.0));
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
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

  for (final stage in ['permission', 'identity']) {
    for (final cameraOn in [false, true]) {
      test('initial group camera intent at $stage stays $cameraOn', () async {
        final self = _id(1), groups = _CameraIntentGroups(_id(1));
        final gate = _StartGate(stage), engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          _CancelledStartTransport(self, gate),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async {
            await gate.pause('permission');
            return true;
          },
          requestCamera: () async => true,
        );
        final service = GroupCallService(groups, media: controller)..start();
        addTearDown(() async {
          if (!gate.ready.isCompleted) gate.ready.complete();
          await service.dispose();
          await groups.close();
        });
        final active = service.changes.firstWhere(
          (call) => call?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            _id(9),
            const CallMedia(audio: true, video: true),
          ),
          isTrue,
        );
        await gate.entered.future;
        await service.setCameraEnabled(false);
        if (cameraOn) await service.setCameraEnabled(true);
        gate.ready.complete();
        await active;
        expect(service.current?.cameraOn, cameraOn);
        expect(engine.cameraStarted, cameraOn ? 1 : 0);
      });
    }
  }

  for (final change in ['stop', 'replacement']) {
    test(
      'pending group video permission cannot mount after $change',
      () async {
        final self = _id(1),
            permission = Completer<bool>(),
            entered = Completer<void>();
        final engines = <_FakeEngine>[];
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) {
            final engine = _FakeEngine();
            engines.add(engine);
            return engine;
          },
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async => true,
          requestCamera: () async {
            entered.complete();
            return permission.future;
          },
        );
        addTearDown(() async {
          if (!permission.isCompleted) permission.complete(false);
          await controller.stop();
        });
        expect(await controller.start(_call(self, const [])), isTrue);
        final upgrading = controller.setVideoEnabled(true);
        await entered.future;
        try {
          await controller.stop();
          if (change == 'replacement') {
            expect(await controller.start(_call(self, const [])), isTrue);
          }
          permission.complete(true);
          expect(await upgrading, isFalse);
          expect(engines.every((engine) => engine.videoStarted == 0), isTrue);
        } finally {
          if (!permission.isCompleted) permission.complete(false);
          await upgrading;
        }
      },
      skip: !Platform.isMacOS && !Platform.isIOS,
    );
  }

  for (final action in ['keep', 'stop', 'replace', 'repair']) {
    test('queued group roster observes session retirement: $action', () async {
      final self = _id(1), first = _id(2), second = _id(3);
      final gate = _StartGate('channel');
      final transport = _CancelledStartTransport(self, gate);
      final engines = <_FakeEngine>[];
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) {
          final engine = _FakeEngine();
          engines.add(engine);
          return engine;
        },
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      addTearDown(() async {
        if (!gate.ready.isCompleted) gate.ready.complete();
        await controller.stop();
      });
      final original = _call(self, const []);
      expect(await controller.start(original), isTrue);
      final updating = controller.update(_call(self, [first]));
      await gate.entered.future;
      // Real roster commands can accumulate behind a slow peer-channel open.
      final queued = controller.update(_call(self, [second], video: true));
      final stopping = action == 'stop' || action == 'replace'
          ? controller.stop()
          : null;
      final starting = action == 'replace' || action == 'repair'
          ? controller.start(
              action == 'repair'
                  ? original
                  : _call(self, const [], callId: 'next-roster-room'),
            )
          : null;
      try {
        gate.ready.complete();
        await updating;
        await queued;
        await stopping;
        if (starting != null) expect(await starting, isTrue);
        expect(
          transport.opened,
          action == 'keep' ? [first, second] : [first],
          reason: 'a retired roster cannot open another outgoing media channel',
        );
        expect(
          engines.first.added,
          action == 'keep' ? [first, second] : isEmpty,
        );
        expect(engines.first.videoStarted, action == 'keep' ? 1 : 0);
        if (starting != null) expect(engines.last.added, isEmpty);
      } finally {
        if (!gate.ready.isCompleted) gate.ready.complete();
        await updating;
        await queued;
        await stopping;
        await starting;
      }
    });
  }

  test(
    'group leave retires roster commands accumulated by incoming joins',
    () async {
      final self = _id(1), first = _id(2), second = _id(3), group = _id(9);
      final groups = _CameraIntentGroups(self);
      final gate = _StartGate('channel');
      final transport = _CancelledStartTransport(self, gate);
      final engine = _FakeEngine();
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
        requestMicrophone: () async => true,
        requestCamera: () async => true,
      );
      final service = GroupCallService(groups, media: controller)..start();
      addTearDown(() async {
        if (!gate.ready.isCompleted) gate.ready.complete();
        await service.dispose();
        await groups.close();
      });
      final active = service.changes.firstWhere(
        (call) => call?.status == GroupCallStatus.active,
      );
      expect(
        await service.startCall(group, const CallMedia(audio: true)),
        isTrue,
      );
      await active;
      void incomingJoin(NodeId author) {
        groups._incoming.add(
          GroupCallSignal(
            groupId: group,
            callId: service.current!.callId,
            author: author,
            membershipEpoch: 1,
            type: GroupCallSignalType.join,
            sentAtMs: DateTime.now().millisecondsSinceEpoch,
            nonce: 'synthetic-queued-roster',
            signature: Uint8List(64),
            authorPubKey: Uint8List(32),
            media: const CallMedia(audio: true),
          ),
        );
      }

      incomingJoin(first);
      await gate.entered.future;
      incomingJoin(second);
      await pumpEventQueue();
      expect(service.current?.participants.keys, contains(second.hex));
      await service.leave();
      expect(service.current?.status, GroupCallStatus.ended);
      try {
        gate.ready.complete();
        await pumpEventQueue();
        expect(
          transport.opened,
          [first],
          reason: 'queued joins cannot reopen media after the person leaves',
        );
        expect(engine.added, isEmpty);
        expect(controller.audioRunning, isFalse);
      } finally {
        if (!gate.ready.isCompleted) gate.ready.complete();
      }
    },
  );

  test('current group roster may queue behind its own initial start', () async {
    final self = _id(1), peer = _id(2), gate = _StartGate('identity');
    final transport = _CancelledStartTransport(self, gate);
    final engine = _FakeEngine();
    final controller = VeilGroupCallMediaController(
      transport,
      roomMediaSecret: _room(),
      engineFactory: (_) => engine,
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
      requestMicrophone: () async => true,
      requestCamera: () async => true,
    );
    addTearDown(() async {
      if (!gate.ready.isCompleted) gate.ready.complete();
      await controller.stop();
    });
    final starting = controller.start(_call(self, const []));
    await gate.entered.future;
    final updating = controller.update(_call(self, [peer], video: true));
    try {
      gate.ready.complete();
      expect(await starting, isTrue);
      await updating;
      expect(transport.opened, [peer]);
      expect(engine.added, [peer]);
      expect(engine.videoStarted, 1);
    } finally {
      if (!gate.ready.isCompleted) gate.ready.complete();
      await starting;
      await updating;
    }
  });

  for (final replace in [false, true]) {
    test(
      'queued group video mount is revoked at stop replace=$replace',
      () async {
        final self = _id(1), gate = _StartGate('channel');
        final engines = <_FakeEngine>[];
        final controller = VeilGroupCallMediaController(
          _CancelledStartTransport(self, gate),
          roomMediaSecret: _room(),
          engineFactory: (_) {
            final e = _FakeEngine();
            engines.add(e);
            return e;
          },
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        addTearDown(() async {
          if (!gate.ready.isCompleted) gate.ready.complete();
          await controller.stop();
        });
        expect(await controller.start(_call(self, const [])), isTrue);
        final updating = controller.update(_call(self, [_id(2)]));
        await gate.entered.future;
        final upgrading = controller.setVideoEnabled(true);
        await pumpEventQueue(); // drain the immediate permission reply into the held operation lane
        final stopping = controller.stop();
        final replacement = replace
            ? controller.start(_call(self, const [], callId: 'next-room'))
            : null;
        gate.ready.complete();
        await updating;
        expect(await upgrading, isFalse);
        await stopping;
        if (replacement != null) expect(await replacement, isTrue);
        expect(engines.every((e) => e.videoStarted == 0), isTrue);
      },
    );
  }

  for (final mode in ['same call', 'new call', 'failed start']) {
    test(
      'group camera intent survives $mode without borrowing another call',
      () async {
        final self = _id(1), engine = _FakeEngine();
        if (mode == 'failed start') engine.videoReady = false;
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        addTearDown(controller.stop);
        final original = _call(self, const [], video: true);
        expect(await controller.start(original), mode != 'failed start');
        await controller.setCameraEnabled(false);
        final before = engine.cameraStarted;
        engine.videoReady = true;
        if (mode == 'new call') await controller.stop();
        final retry = mode == 'new call'
            ? _call(self, const [], video: true, callId: 'another-room')
            : original;
        expect(await controller.start(retry), isTrue);
        expect(engine.cameraStarted, before + (mode == 'new call' ? 1 : 0));
      },
    );
  }

  for (final mode in ['same call', 'new call', 'stop then new']) {
    test(
      'queued group start preserves the correct camera owner: $mode',
      () async {
        final self = _id(1),
            gate = _StartGate('permission'),
            engine = _FakeEngine();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async {
            await gate.pause('permission');
            return true;
          },
          requestCamera: () async => true,
        );
        addTearDown(() async {
          if (!gate.ready.isCompleted) gate.ready.complete();
          await controller.stop();
        });
        final original = _call(self, const [], video: true);
        final starting = controller.start(original);
        await gate.entered.future;
        controller.updateCameraIntent(false);
        final superseded = mode == 'stop then new'
            ? controller.start(original)
            : null;
        final stopping = mode == 'stop then new' ? controller.stop() : null;
        final next = controller.start(
          mode == 'same call'
              ? original
              : _call(self, const [], video: true, callId: 'queued-room'),
        );
        gate.ready.complete();
        expect(await starting, isFalse);
        if (superseded != null) expect(await superseded, isFalse);
        await stopping;
        expect(await next, isTrue);
        expect(engine.cameraStarted, mode == 'same call' ? 0 : 1);
      },
    );
  }

  for (final scope in ['group', 'channel']) {
    for (final capture in ['camera', 'microphone']) {
      test(
        'reused call id in another $scope cannot borrow $capture intent',
        () async {
          final self = _id(1), engine = _FakeEngine();
          final controller = VeilGroupCallMediaController(
            _FakeTransport(self),
            roomMediaSecret: _room(),
            engineFactory: (_) => engine,
            networkActivity: CallNetworkActivity(setActive: (_) async => false),
            requestMicrophone: () async => true,
            requestCamera: () async => true,
          );
          addTearDown(controller.stop);
          expect(
            await controller.start(
              _call(self, const [], video: capture == 'camera'),
            ),
            isTrue,
          );
          final before = engine.cameraStarted;
          final next = _call(
            self,
            const [],
            video: capture == 'camera',
            groupId: scope == 'group' ? _id(8) : null,
            channelId: scope == 'channel' ? _id(7) : null,
          ).copyWith(cameraOn: false, micOn: capture != 'microphone');
          expect(await controller.start(next), isTrue);
          if (capture == 'camera') {
            expect(engine.cameraStarted, before);
          } else {
            expect(engine.audioStartMuted.last, isTrue);
          }
        },
      );
    }
  }

  for (final muted in [false, true]) {
    test(
      'queued group microphone intent stays with its engine muted=$muted',
      () async {
        final self = _id(1), gate = _StartGate('channel');
        final engines = <_FakeEngine>[];
        final controller = VeilGroupCallMediaController(
          _CancelledStartTransport(self, gate),
          roomMediaSecret: _room(),
          engineFactory: (_) {
            final engine = _FakeEngine();
            engines.add(engine);
            return engine;
          },
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async => true,
          requestCamera: () async => true,
        );
        addTearDown(() async {
          if (!gate.ready.isCompleted) gate.ready.complete();
          await controller.stop();
        });
        expect(
          await controller.start(_call(self, const []).copyWith(micOn: false)),
          isTrue,
        );
        final old = engines.single;
        expect(old.muted, isTrue);
        final updating = controller.update(_call(self, [_id(2)]));
        await gate.entered.future;
        final stopping = controller.stop();
        final starting = controller.start(
          _call(self, const [], callId: 'queued-mic-room'),
        );
        await controller.setMicMuted(muted);
        try {
          expect(
            old.muted,
            isTrue,
            reason: 'a new room cannot unmute the retiring engine',
          );
          gate.ready.complete();
          await updating;
          await stopping;
          expect(await starting, isTrue);
          expect(engines.last.audioStartMuted.single, muted);
        } finally {
          if (!gate.ready.isCompleted) gate.ready.complete();
          await updating;
          await stopping;
          await starting;
        }
      },
    );
  }

  for (final phase in [
    'initial',
    'toggle',
    'upgrade',
    'share-failure',
    'handback',
  ]) {
    for (final throws in [false, true]) {
      test(
        'group camera refusal is reflected in FSM: $phase throws=$throws',
        () async {
          final self = _id(1), groups = _CameraOutcomeGroups(_id(1));
          final engine = _CameraOutcomeEngine();
          if (phase == 'initial') engine.rejectCamera = true;
          engine.throwOnCamera = throws;
          final controller = VeilGroupCallMediaController(
            _FakeTransport(self),
            roomMediaSecret: _room(),
            engineFactory: (_) => engine,
            networkActivity: CallNetworkActivity(setActive: (_) async => false),
            requestMicrophone: () async => true,
            requestCamera: () async => true,
            desktopScreenCaptureSupported: true,
          );
          final service = GroupCallService(groups, media: controller)..start();
          addTearDown(() async {
            await service.dispose();
            await groups.close();
          });
          final active = service.changes.firstWhere(
            (call) => call?.status == GroupCallStatus.active,
          );
          expect(
            await service.startCall(
              _id(9),
              CallMedia(audio: true, video: phase != 'upgrade'),
            ),
            isTrue,
          );
          await active;
          await pumpEventQueue();
          if (phase != 'initial') {
            if (phase == 'toggle') await service.setCameraEnabled(false);
            if (phase == 'handback') await service.setScreenShareEnabled(true);
            engine.rejectCamera = true;
            if (phase == 'share-failure') {
              engine.screenStarts = false;
              await service.setScreenShareEnabled(true);
            } else if (phase == 'handback') {
              await service.setScreenShareEnabled(false);
            } else {
              await service.setCameraEnabled(true);
            }
            await pumpEventQueue();
          }
          expect(engine.cameraActive, isFalse);
          expect(service.current?.status, GroupCallStatus.active);
          expect(controller.audioRunning, isTrue);
          expect(controller.videoRunning, isTrue);
          expect(
            service.current?.cameraOn,
            isFalse,
            reason: 'a refused camera must not remain advertised as capturing',
          );
          expect(service.current?.screenOn, isFalse);
          expect(groups.sent.last.media?.video, isFalse);
          // Retry uses the same live room and engine after capture recovers.
          engine.rejectCamera = false;
          await service.setCameraEnabled(true);
          await pumpEventQueue();
          expect(engine.cameraActive, isTrue);
          expect(service.current?.cameraOn, isTrue);
          expect(groups.sent.last.media?.video, isTrue);
        },
      );
    }
  }

  for (final ending in [
    'leave',
    'dispose',
    'reentrant',
    'late-grant',
    'stop-error',
    'accepted',
  ]) {
    test('group initial screen consent can be cancelled: $ending', () async {
      final channel = MethodChannel('xveil/group_screen_consent_$ending');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeStart = Completer<bool>(), startEntered = Completer<void>();
      final stopGate = Completer<void>();
      final captures = <AndroidScreenCapture>[];
      var stopCalls = 0, forceCleanup = false;
      Object? session;
      Future<void>? disposing;
      late _GroupProjectionStand stand;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          session = (call.arguments as Map)['session'];
          expect(session, isA<String>());
          startEntered.complete();
          return nativeStart.future;
        }
        if (call.method == 'stop') {
          expect(call.arguments, {'session': session});
          stopCalls++;
          if (!nativeStart.isCompleted && ending != 'late-grant') {
            nativeStart.complete(false);
          }
          if (ending == 'reentrant' && stopCalls == 1) {
            disposing = stand.service.dispose();
          }
          await stopGate.future;
          if (!forceCleanup && ending == 'stop-error') {
            throw PlatformException(code: 'synthetic_stop_refused');
          }
        }
        return null;
      });
      stand = _GroupProjectionStand((stopped) {
        final capture = AndroidScreenCapture(
          stopped,
          channel: channel,
          isAndroid: true,
        );
        captures.add(capture);
        return capture;
      });
      var activeSeen = false;
      final changes = stand.service.changes.listen((call) {
        if (call?.status == GroupCallStatus.active) activeSeen = true;
      });
      try {
        expect(
          await stand.service.startCall(
            _id(9),
            const CallMedia(audio: true, video: true, screen: true),
          ),
          isTrue,
        );
        await startEntered.future;
        expect(stand.service.current?.status, GroupCallStatus.connecting);
        expect(stand.engine.started, 1);
        if (ending == 'accepted') {
          final active = stand.service.changes.firstWhere(
            (c) => c?.status == GroupCallStatus.active,
          );
          nativeStart.complete(true);
          await active;
        }
        if (ending == 'dispose') {
          disposing = stand.service.dispose();
        } else {
          await stand.service.leave();
        }
        await pumpEventQueue();
        expect(
          stopCalls,
          1,
          reason: 'stop must reach native before the pending start reply',
        );
        expect(stand.engine.audioStops, greaterThan(0));
        expect(stand.engine.disposals, 0);
        final competing = stand.slot.acquire(CallSlotOwner.direct);
        if (competing != null) stand.slot.release(competing);
        expect(competing, isNull, reason: 'native stop has not answered');
        if (ending == 'late-grant') nativeStart.complete(true);
        stopGate.complete();
        await disposing;
        await pumpEventQueue();
        expect(stand.engine.disposals, 1);
        expect(stand.slot.owner, isNull);
        expect(activeSeen, ending == 'accepted');
        expect(
          stopCalls,
          1,
          reason: 'joined cleanup does not send another native stop',
        );
      } finally {
        forceCleanup = true;
        if (!nativeStart.isCompleted) nativeStart.complete(false);
        if (!stopGate.isCompleted) stopGate.complete();
        if (disposing == null) {
          await stand.close();
        } else {
          await disposing;
          await stand.groups.close();
        }
        for (final capture in captures) {
          await capture.stop();
        }
        await changes.cancel();
        messenger.setMockMethodCallHandler(channel, null);
        await pumpEventQueue();
      }
    });
  }

  for (final ending in ['off', 'reentrant', 'dispose', 'failure', 'attached']) {
    test('group screen retirement holds slot: $ending', () async {
      final screen = _HeldGroupScreen()..result.complete(true);
      final stand = _GroupProjectionStand((_) => screen);
      Future<void>? command, disposing;
      Object? error;
      try {
        await stand.start();
        await stand.service.setScreenShareEnabled(true);
        expect(stand.service.current?.screenOn, isTrue);
        if (ending == 'reentrant') {
          screen.onStop = () {
            disposing = stand.service.dispose();
          };
        }
        if (ending != 'attached') {
          command = stand.service
              .setScreenShareEnabled(false)
              .then<void>(
                (_) {},
                onError: (Object e, StackTrace _) {
                  error = e;
                },
              );
          await screen.stopping.future;
        }
        await stand.service.leave();
        if (ending == 'dispose') disposing = stand.service.dispose();
        await screen.stopping.future;
        await pumpEventQueue();
        final competing = stand.slot.acquire(CallSlotOwner.direct);
        if (competing != null) stand.slot.release(competing);
        expect(
          competing,
          isNull,
          reason: 'the known stop reply still owns the slot',
        );
        expect(stand.engine.disposals, 0);
        expect(stand.engine.audioStops, greaterThan(0));
        if (ending == 'failure') {
          screen.release.completeError(
            StateError('synthetic screen stop failure'),
          );
        } else {
          screen.release.complete();
        }
        await command;
        await disposing;
        await pumpEventQueue();
        expect(error, ending == 'failure' ? isA<StateError>() : isNull);
        expect(stand.slot.owner, isNull);
        expect(stand.engine.disposals, 1);
      } finally {
        if (!screen.release.isCompleted) screen.release.complete();
        await command;
        if (disposing == null) {
          await stand.close();
        } else {
          await disposing;
          await stand.groups.close();
        }
        await pumpEventQueue();
      }
    });
  }

  test(
    'group screen retirement joins the real Android bridge stop reply',
    () async {
      const channel = MethodChannel('xveil/group_screen_stop_lease');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final entered = Completer<void>(), release = Completer<void>();
      final captures = <AndroidScreenCapture>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return true;
        if (call.method == 'stop') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        return null;
      });
      final stand = _GroupProjectionStand((stopped) {
        final capture = AndroidScreenCapture(
          stopped,
          channel: channel,
          isAndroid: true,
        );
        captures.add(capture);
        return capture;
      });
      Future<void>? off;
      try {
        await stand.start();
        await stand.service.setScreenShareEnabled(true);
        expect(stand.service.current?.screenOn, isTrue);
        off = stand.service.setScreenShareEnabled(false);
        await entered.future;
        await stand.service.leave();
        await pumpEventQueue();
        final competing = stand.slot.acquire(CallSlotOwner.direct);
        if (competing != null) stand.slot.release(competing);
        expect(competing, isNull);
        expect(stand.engine.disposals, 0);
        release.complete();
        await off;
        await pumpEventQueue();
        expect(stand.slot.owner, isNull);
        expect(stand.engine.disposals, 1);
      } finally {
        if (!release.isCompleted) release.complete();
        await off;
        await stand.close();
        for (final capture in captures) {
          await capture.stop();
        }
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  for (final outcome in ['refused', 'throws']) {
    test(
      'group screen failed start retains its close reply: $outcome',
      () async {
        final screen = _HeldGroupScreen();
        final stand = _GroupProjectionStand((_) => screen);
        Future<void>? sharing;
        Object? error;
        try {
          await stand.start();
          sharing = stand.service
              .setScreenShareEnabled(true)
              .then<void>(
                (_) {},
                onError: (Object e, StackTrace _) {
                  error = e;
                },
              );
          await screen.entered.future;
          if (outcome == 'throws') {
            screen.result.completeError(
              StateError('synthetic screen start failure'),
            );
          } else {
            screen.result.complete(false);
          }
          await pumpEventQueue();
          expect(
            screen.stops,
            1,
            reason: 'failed startup must retire its source',
          );
          await stand.service.leave();
          await pumpEventQueue();
          final competing = stand.slot.acquire(CallSlotOwner.direct);
          if (competing != null) stand.slot.release(competing);
          expect(
            competing,
            isNull,
            reason: 'failed-start cleanup still owns its reply',
          );
          expect(stand.engine.disposals, 0);
          screen.release.complete();
          await sharing;
          await pumpEventQueue();
          expect(error, outcome == 'throws' ? isA<StateError>() : isNull);
          expect(stand.slot.owner, isNull);
          expect(stand.engine.disposals, 1);
        } finally {
          if (!screen.result.isCompleted) screen.result.complete(false);
          if (!screen.release.isCompleted) screen.release.complete();
          await sharing;
          await stand.close();
        }
      },
    );
  }

  test('group screen start exception does not admit a phantom retry', () async {
    final screens = <_PendingGroupScreen>[];
    final stand = _GroupProjectionStand((_) {
      final screen = _PendingGroupScreen();
      if (screens.isNotEmpty) screen.result.complete(true);
      screens.add(screen);
      return screen;
    });
    Future<void>? sharing;
    Object? error;
    try {
      await stand.start();
      sharing = stand.service
          .setScreenShareEnabled(true)
          .then<void>(
            (_) {},
            onError: (Object e, StackTrace _) {
              error = e;
            },
          );
      await pumpEventQueue();
      expect(screens, hasLength(1));
      screens.first.result.completeError(
        StateError('synthetic screen start failure'),
      );
      await sharing;
      expect(error, isA<StateError>());
      expect(stand.service.current?.screenOn, isFalse);
      await stand.service.setScreenShareEnabled(true);
      expect(screens, hasLength(2), reason: 'retry must start a new source');
      expect(screens.first.stops, greaterThan(0));
      expect(stand.service.current?.screenOn, isTrue);
      final before = stand.engine.videoPushed;
      screens.last.frame();
      expect(stand.engine.videoPushed, before + 1);
      screens.first.frame();
      expect(stand.engine.videoPushed, before + 1);
    } finally {
      for (final screen in screens) {
        if (!screen.result.isCompleted) screen.result.complete(false);
      }
      await sharing;
      await stand.close();
    }
  });

  for (final recover in [false, true]) {
    test('group screen failed native start cleanup recover=$recover', () async {
      final channel = MethodChannel('xveil/group_screen_retry_$recover');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final captures = <AndroidScreenCapture>[];
      var starts = 0, stops = 0, forceCleanup = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          starts++;
          if (starts == 1) {
            throw PlatformException(code: 'synthetic_start_lost');
          }
          return true;
        }
        if (call.method == 'stop') {
          stops++;
          if (!forceCleanup && (stops == 1 || !recover)) {
            throw PlatformException(code: 'synthetic_stop_refused');
          }
        }
        return null;
      });
      final stand = _GroupProjectionStand((stopped) {
        final capture = AndroidScreenCapture(
          stopped,
          channel: channel,
          isAndroid: true,
        );
        captures.add(capture);
        return capture;
      });
      try {
        await stand.start();
        await stand.service.setScreenShareEnabled(true);
        expect(stand.service.current?.screenOn, isFalse);
        expect(starts, 1);
        await stand.service.setScreenShareEnabled(true);
        expect(stand.service.current?.screenOn, recover);
        expect(starts, recover ? 2 : 1);
      } finally {
        forceCleanup = true;
        await stand.close();
        for (final capture in captures) {
          await capture.stop();
        }
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }

  for (final ending in ['leave', 'replacement']) {
    test(
      'group pending screen handoff rejects $ending before lifecycle cleanup',
      () async {
        final self = _id(1),
            groups = _CameraOutcomeGroups(_id(1)),
            slot = CallSlot();
        final transport = _BlockedGroupPeerOpen(self),
            camera = _HeldGroupCamera();
        final engines = <_HeldGroupEngine>[];
        var cameras = 0, screens = 0;
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) {
            final engine = _HeldGroupEngine();
            engines.add(engine);
            return engine;
          },
          androidCapture: true,
          cameraCaptureFactory: () => cameras++ == 0 ? camera : _IntentCamera(),
          screenCaptureFactory: (_) {
            screens++;
            return _IntentScreen()..result.complete(true);
          },
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
        );
        final service = GroupCallService(
          groups,
          media: controller,
          callSlot: slot,
        )..start();
        Future<void>? updating, sharing;
        Future<bool>? replacement;
        try {
          final active = service.changes.firstWhere(
            (c) => c?.status == GroupCallStatus.active,
          );
          expect(
            await service.startCall(
              _id(9),
              const CallMedia(audio: true, video: true),
            ),
            isTrue,
          );
          final call = (await active)!;
          await camera.opened.future;
          updating = controller.update(
            _call(self, [_id(2)], video: true, callId: call.callId),
          );
          await transport.entered.future;
          sharing = service.setScreenShareEnabled(true);
          await camera.stopping.future;
          if (ending == 'leave') {
            await service.leave();
          } else {
            replacement = controller.start(call);
          }
          camera.release.complete();
          await sharing;
          expect(
            screens,
            0,
            reason: 'a retired request cannot start a projection',
          );
          expect(engines.first.disposals, 0);
          expect(slot.owner, CallSlotOwner.group);
          transport.release.complete();
          await updating;
          if (replacement != null) expect(await replacement, isTrue);
        } finally {
          if (!camera.release.isCompleted) camera.release.complete();
          if (!transport.release.isCompleted) transport.release.complete();
          await updating;
          await sharing;
          await replacement;
          await service.dispose();
          await groups.close();
          await pumpEventQueue();
          expect(slot.owner, isNull);
        }
      },
    );
  }

  for (final scenario in [
    'next-camera',
    'next-camera-share',
    'next-screen-success',
    'next-screen-refused',
    'next-screen-throws',
    'current-success',
    'current-refused',
    'current-throws',
  ]) {
    test('group pending screen reply stays with source: $scenario', () async {
      final groups = _CameraOutcomeGroups(_id(1)), slot = CallSlot();
      final engines = <_HeldGroupEngine>[], screens = <_PendingGroupScreen>[];
      var cameras = 0;
      final controller = VeilGroupCallMediaController(
        _FakeTransport(_id(1)),
        roomMediaSecret: _room(),
        engineFactory: (_) {
          final engine = _HeldGroupEngine();
          engines.add(engine);
          return engine;
        },
        androidCapture: true,
        cameraCaptureFactory: () {
          cameras++;
          return _IntentCamera();
        },
        screenCaptureFactory: (_) {
          final screen = _PendingGroupScreen();
          if (screens.isNotEmpty) screen.result.complete(true);
          screens.add(screen);
          return screen;
        },
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
      final service = GroupCallService(
        groups,
        media: controller,
        callSlot: slot,
      )..start();
      Future<void>? sharing, successorSharing;
      Object? shareError;
      Future<void> start({bool screen = false}) async {
        final active = service.changes.firstWhere(
          (c) => c?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            _id(9),
            CallMedia(audio: true, video: true, screen: screen),
          ),
          isTrue,
        );
        await active;
        await pumpEventQueue();
      }

      try {
        await start();
        expect(cameras, 1);
        sharing = service
            .setScreenShareEnabled(true)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace _) {
                shareError = error;
              },
            );
        await pumpEventQueue();
        expect(screens, hasLength(1));
        await screens.first.entered.future;
        final successor = scenario.startsWith('next-');
        if (successor) {
          await service.leave();
          await pumpEventQueue();
          expect(slot.owner, isNull);
          expect(engines.first.disposals, 1);
          await start(screen: scenario.startsWith('next-screen-'));
          if (scenario == 'next-camera-share') {
            successorSharing = service.setScreenShareEnabled(true);
            await pumpEventQueue();
            expect(
              screens,
              hasLength(2),
              reason: 'the old request cannot answer a new screen enable',
            );
          }
        }
        if (scenario.endsWith('throws')) {
          screens.first.result.completeError(
            StateError('synthetic screen start failure'),
          );
        } else {
          screens.first.result.complete(!scenario.endsWith('refused'));
        }
        await sharing;
        await successorSharing;
        await pumpEventQueue();
        expect(
          shareError,
          scenario.endsWith('throws') ? isA<StateError>() : isNull,
        );
        expect(service.current?.status, GroupCallStatus.active);
        if (scenario == 'next-camera') {
          expect(
            cameras,
            2,
            reason: 'the retired start cannot gate successor capture',
          );
        } else if (successor) {
          expect(screens, hasLength(2));
          expect(
            screens.last.stops,
            0,
            reason: 'old cleanup cannot stop the new projection',
          );
          final before = engines.last.videoPushed;
          screens.last.frame();
          expect(engines.last.videoPushed, before + 1);
          expect(service.current?.screenOn, isTrue);
        } else {
          expect(service.current?.screenOn, scenario.endsWith('success'));
          if (scenario.endsWith('refused')) expect(cameras, 2);
        }
        final before = engines.last.videoPushed;
        if (successor) {
          screens.first.frame();
          expect(engines.last.videoPushed, before);
        }
      } finally {
        for (final screen in screens) {
          if (!screen.result.isCompleted) screen.result.complete(false);
        }
        await sharing;
        await successorSharing;
        await service.dispose();
        await groups.close();
        await pumpEventQueue();
        expect(slot.owner, isNull);
      }
    });
  }

  test(
    'group pending screen frames stop at leave before lifecycle cleanup',
    () async {
      final self = _id(1), groups = _CameraOutcomeGroups(_id(1));
      final transport = _BlockedGroupPeerOpen(self),
          engine = _HeldGroupEngine();
      final screen = _PendingGroupScreen();
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        androidCapture: true,
        cameraCaptureFactory: () => _IntentCamera(),
        screenCaptureFactory: (_) => screen,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
      final service = GroupCallService(groups, media: controller)..start();
      Future<void>? updating, sharing;
      try {
        final active = service.changes.firstWhere(
          (c) => c?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            _id(9),
            const CallMedia(audio: true, video: true),
          ),
          isTrue,
        );
        final call = (await active)!;
        updating = controller.update(
          _call(self, [_id(2)], video: true, callId: call.callId),
        );
        await transport.entered.future;
        sharing = service.setScreenShareEnabled(true);
        await screen.entered.future;
        final before = engine.videoPushed;
        screen.frame();
        expect(engine.videoPushed, before + 1);
        await service.leave();
        screen.frame();
        expect(
          engine.videoPushed,
          before + 1,
          reason: 'ended-room frames cannot wait for lane cleanup',
        );
        expect(engine.disposals, 0);
      } finally {
        if (!screen.result.isCompleted) screen.result.complete(false);
        if (!transport.release.isCompleted) transport.release.complete();
        await sharing;
        await updating;
        await service.dispose();
        await groups.close();
        await pumpEventQueue();
      }
    },
  );

  for (final change in [
    'current',
    'hangup',
    'next-call',
    'same-call-engine',
    'new-selection',
    'profile',
    'share-ended',
  ]) {
    test(
      'group screen selection discovery respects $change owner',
      () async {
        final stand = _GroupScreenStand();
        final list = Completer<List<CallMediaDevice>>();
        Future<bool>? selecting;
        try {
          await stand.start();
          stand.controller.nextList = list;
          selecting = stand.service.selectScreen('window-2');
          await stand.controller.listEntered.future;
          if (change == 'hangup' || change == 'next-call') {
            await stand.service.leave();
            await pumpEventQueue();
            expect(stand.engines.first.disposed, isTrue);
            if (change == 'next-call') await stand.start();
          } else if (change == 'same-call-engine') {
            expect(
              await stand.controller.start(stand.service.current!),
              isTrue,
            );
            expect(stand.engines.first.disposed, isTrue);
          } else if (change == 'share-ended') {
            await stand.service.setScreenShareEnabled(false);
            expect(stand.service.current?.screenOn, isFalse);
          } else if (change == 'profile') {
            SharedPreferences.setMockInitialValues({'fixture': 'replacement'});
          }
          if ([
            'next-call',
            'same-call-engine',
            'new-selection',
          ].contains(change)) {
            expect(await stand.service.selectScreen('display-3'), isTrue);
            expect(stand.engines.last.activeScreen, 'display-3');
          }
          final before = [
            for (final e in stand.engines)
              {'starts': List.of(e.screenChoices), 'stops': e.screenStopped},
          ];
          list.complete(_GroupScreenController.screens);
          expect(
            await selecting,
            change == 'current' || change == 'share-ended',
          );
          if (change == 'current') {
            expect(stand.engines.last.activeScreen, 'window-2');
          } else {
            expect([
              for (final e in stand.engines)
                {'starts': e.screenChoices, 'stops': e.screenStopped},
            ], before);
          }
          expect([for (final e in stand.engines) ...e.retiredCalls], isEmpty);
          if (change == 'share-ended') {
            await stand.service.setScreenShareEnabled(true);
            expect(stand.engines.last.activeScreen, 'window-2');
          }
        } finally {
          if (!list.isCompleted) list.complete(_GroupScreenController.screens);
          await selecting;
          await stand.close();
          SharedPreferences.setMockInitialValues({});
        }
      },
      skip: !Platform.isMacOS ? 'macOS group screen selection' : false,
    );
  }

  for (final refusal in [
    'stop',
    'stop-throws',
    'new',
    'new-throws',
    'both',
    'restore-throws',
  ]) {
    test(
      'group screen selection preserves actual source on $refusal refusal',
      () async {
        final stand = _GroupScreenStand();
        try {
          await stand.start();
          final engine = stand.engines.single;
          engine.screenChoices.clear();
          engine.acceptStop = refusal != 'stop';
          engine.throwStop = refusal == 'stop-throws';
          if (refusal == 'new-throws') engine.throwing.add('window-2');
          if (['new', 'both', 'restore-throws'].contains(refusal)) {
            engine.refused.add('window-2');
          }
          if (refusal == 'both') engine.refused.add('display-1');
          if (refusal == 'restore-throws') engine.throwing.add('display-1');
          expect(await stand.service.selectScreen('window-2'), isFalse);
          await pumpEventQueue();
          final stopped = refusal == 'both' || refusal == 'restore-throws';
          expect(stand.service.current?.status, GroupCallStatus.active);
          expect(stand.service.current?.screenOn, !stopped);
          expect(stand.service.current?.cameraOn, isFalse);
          expect(engine.activeScreen, stopped ? null : 'display-1');
          expect(
            engine.screenChoices,
            refusal.startsWith('stop') ? isEmpty : ['window-2', 'display-1'],
          );
          expect(engine.disposed, isFalse);
          if (stopped) {
            expect(
              stand.groups.sent
                  .lastWhere((s) => s.type == GroupCallSignalType.renegotiate)
                  .media
                  ?.screen,
              isFalse,
            );
          }
        } finally {
          await stand.close();
        }
      },
      skip: !Platform.isMacOS ? 'macOS group screen selection' : false,
    );
  }

  test(
    'group screen selection stop callback cannot restart an ended call',
    () async {
      final stand = _GroupScreenStand();
      Future<void>? leaving;
      try {
        await stand.start();
        final engine = stand.engines.single;
        engine.screenChoices.clear();
        engine.onScreenStop = () {
          leaving = stand.service.leave();
        };
        expect(await stand.service.selectScreen('window-2'), isFalse);
        await leaving;
        await pumpEventQueue();
        expect(stand.service.current?.status, GroupCallStatus.ended);
        expect(engine.screenChoices, isEmpty);
        expect(engine.retiredCalls, isEmpty);
      } finally {
        await leaving;
        await stand.close();
      }
    },
    skip: !Platform.isMacOS ? 'macOS group screen selection' : false,
  );

  for (final rebuild in [false, true]) {
    test(
      'group screen selection stop event ignores recovery rebuild=$rebuild',
      () async {
        final stand = _GroupScreenStand();
        var delayedStops = 0;
        final delayed = stand.controller.screenShareStopped.listen(
          (_) => delayedStops++,
        )..pause();
        try {
          await stand.start();
          stand.engines.last.refused.addAll(['display-1', 'window-2']);
          expect(await stand.service.selectScreen('window-2'), isFalse);
          await pumpEventQueue();
          expect(stand.service.current?.screenOn, isFalse);
          stand.engines.last.refused.clear();
          await stand.service.setScreenShareEnabled(true);
          if (rebuild) {
            expect(
              await stand.controller.start(stand.service.current!),
              isTrue,
            );
          }
          expect(stand.service.current?.screenOn, isTrue);
          expect(stand.engines.last.activeScreen, 'display-1');
          delayed.resume();
          await pumpEventQueue();
          expect(delayedStops, 0);
          expect(stand.service.current?.screenOn, isTrue);
          expect(stand.engines.last.activeScreen, 'display-1');
        } finally {
          await delayed.cancel();
          await stand.close();
        }
      },
      skip: !Platform.isMacOS ? 'macOS group screen selection' : false,
    );
  }

  test(
    'group screen stop observer retains current Android source ownership',
    () async {
      final callbacks = <void Function()>[];
      final controller = VeilGroupCallMediaController(
        _FakeTransport(_id(1)),
        roomMediaSecret: _room(),
        engineFactory: (_) => _FakeEngine(),
        androidCapture: true,
        screenCaptureFactory: (stopped) {
          callbacks.add(stopped);
          return _IntentScreen()..result.complete(true);
        },
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
      var observed = 0, delayed = 0;
      final listener = controller.screenShareStopped.listen((_) => observed++);
      final paused = controller.screenShareStopped.listen((_) => delayed++)
        ..pause();
      try {
        expect(
          await controller.start(
            _call(_id(1), [], video: true).copyWith(cameraOn: false),
          ),
          isTrue,
        );
        expect(await controller.setScreenShareEnabled(true), isTrue);
        callbacks.single();
        await pumpEventQueue();
        expect(
          observed,
          1,
          reason: 'the current source stop still reaches observers',
        );
        expect(controller.audioRunning, isTrue);
        expect(await controller.setScreenShareEnabled(true), isTrue);
        expect(callbacks, hasLength(2));
        paused.resume();
        callbacks.first();
        await pumpEventQueue();
        expect(
          delayed,
          0,
          reason: 'a retained stop no longer describes the recovered source',
        );
        expect(
          observed,
          1,
          reason: 'an old source cannot stop its replacement',
        );
      } finally {
        await listener.cancel();
        await paused.cancel();
        await controller.stop();
        await pumpEventQueue();
      }
    },
  );

  for (final outcome in [
    'success',
    'refused',
    'throws',
    'reentrant',
    'queued-repair',
  ]) {
    test(
      'group stop requests audio before pending peer open: $outcome',
      () async {
        final self = _id(1), engine = _RequestStopEngine(outcome);
        final transport = _BlockedGroupPeerOpen(self);
        final controller = VeilGroupCallMediaController(
          transport,
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
        );
        final initial = _call(self, []);
        Future<void>? updating, stopping, nestedStop;
        Future<bool>? repair;
        try {
          expect(await controller.start(initial), isTrue);
          expect(engine.started, 1);
          updating = controller.update(_call(self, [_id(2)]));
          await transport.entered.future;
          if (outcome == 'queued-repair') repair = controller.start(initial);
          if (outcome == 'reentrant') {
            engine.onAudioStop = () {
              nestedStop = controller.stop();
            };
          }
          var stopped = false;
          stopping = controller.stop().then((_) {
            stopped = true;
          });
          await pumpEventQueue();
          expect(
            engine.audioStops,
            1,
            reason: 'audio stop must not wait on the lifecycle lane',
          );
          expect(
            stopped,
            isFalse,
            reason: 'accepted channel creation is still owned',
          );
          expect(engine.disposals, 0);
          transport.release.complete();
          await updating;
          await stopping;
          await nestedStop;
          if (repair != null) expect(await repair, isFalse);
          expect(
            engine.audioStops,
            outcome == 'refused' || outcome == 'throws' ? 2 : 1,
          );
          expect(engine.disposals, 1);
          expect(engine.added, isEmpty);
          expect(transport.closed, [
            1,
          ], reason: 'late accepted channel is reclaimed');
        } finally {
          if (!transport.release.isCompleted) transport.release.complete();
          await updating;
          await stopping;
          await nestedStop;
          await repair;
          await controller.stop();
          await pumpEventQueue();
        }
      },
    );
  }

  for (final ending in ['leave', 'dispose']) {
    test('group $ending stops audio while peer open retains slot', () async {
      final self = _id(1), groups = _CameraOutcomeGroups(_id(1));
      final engine = _HeldGroupEngine(), slot = CallSlot();
      final transport = _BlockedGroupPeerOpen(self);
      final controller = VeilGroupCallMediaController(
        transport,
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
      final service = GroupCallService(
        groups,
        media: controller,
        callSlot: slot,
      )..start();
      Future<void>? updating, disposing;
      try {
        final active = service.changes.firstWhere(
          (call) => call?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(_id(9), const CallMedia(audio: true)),
          isTrue,
        );
        final call = (await active)!;
        expect(engine.started, 1);
        updating = controller.update(
          _call(self, [_id(2)], callId: call.callId),
        );
        await transport.entered.future;
        if (ending == 'leave') {
          await service.leave();
          expect(service.current?.status, GroupCallStatus.ended);
        } else {
          disposing = service.dispose();
        }
        await pumpEventQueue();
        expect(engine.audioStops, 1);
        expect(engine.disposals, 0);
        final competing = slot.acquire(CallSlotOwner.direct);
        if (competing != null) slot.release(competing);
        expect(competing, isNull);
        transport.release.complete();
        await updating;
        await pumpEventQueue();
        expect(slot.owner, isNull);
        expect(engine.audioStops, 1);
        expect(engine.disposals, 1);
        expect(engine.added, isEmpty);
        expect(transport.closed, [1]);
      } finally {
        if (!transport.release.isCompleted) transport.release.complete();
        await updating;
        if (disposing != null) {
          await disposing;
        } else {
          await service.dispose();
        }
        await groups.close();
        await pumpEventQueue();
      }
    });
  }

  for (final operation in ['off', 'screen', 'attached']) {
    for (final ending in ['ordinary', 'reentrant', 'dispose', 'failure']) {
      test('group camera stop holds slot: $operation/$ending', () async {
        final groups = _CameraOutcomeGroups(_id(1)), slot = CallSlot();
        final engine = _HeldGroupEngine(), camera = _HeldGroupCamera();
        var screens = 0;
        final controller = VeilGroupCallMediaController(
          _FakeTransport(_id(1)),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          androidCapture: true,
          cameraCaptureFactory: () => camera,
          screenCaptureFactory: (_) {
            screens++;
            return _IntentScreen()..result.complete(false);
          },
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
        );
        final service = GroupCallService(
          groups,
          media: controller,
          callSlot: slot,
        )..start();
        Future<void>? command, disposing;
        Object? commandError;
        try {
          final active = service.changes.firstWhere(
            (c) => c?.status == GroupCallStatus.active,
          );
          expect(
            await service.startCall(
              _id(9),
              const CallMedia(audio: true, video: true),
            ),
            isTrue,
          );
          await active;
          await camera.opened.future;
          await pumpEventQueue();
          expect(slot.owner, CallSlotOwner.group);
          if (ending == 'reentrant') {
            camera.onStop = () {
              disposing = service.dispose();
            };
          }
          final changing = operation == 'off'
              ? service.setCameraEnabled(false)
              : operation == 'screen'
              ? service.setScreenShareEnabled(true)
              : Future<void>.value();
          command = changing.then<void>(
            (_) {},
            onError: (Object error, StackTrace _) {
              commandError = error;
            },
          );
          if (operation != 'attached') await camera.stopping.future;
          await service.leave();
          await camera.stopping.future;
          if (ending == 'dispose') disposing = service.dispose();
          await pumpEventQueue();
          expect(
            engine.audioStops,
            greaterThan(0),
            reason: 'leave must stop audio before the camera close reply',
          );
          final pushed = engine.videoPushed;
          camera.frame();
          expect(
            engine.videoPushed,
            pushed,
            reason: 'retiring source cannot feed the ended room',
          );
          if (ending != 'failure') {
            final competing = slot.acquire(CallSlotOwner.direct);
            if (competing != null) slot.release(competing);
            expect(
              competing,
              isNull,
              reason: 'pending camera stop still owns the group lease',
            );
          }
          if (ending == 'failure') {
            camera.release.completeError(
              StateError('synthetic group stop refusal'),
            );
          } else {
            camera.release.complete();
          }
          await command;
          await disposing;
          await pumpEventQueue();
          expect(
            commandError,
            ending == 'failure' && operation == 'screen'
                ? isA<StateError>()
                : isNull,
          );
          expect(slot.owner, isNull);
          expect(engine.disposals, 1);
          expect(
            screens,
            0,
            reason: 'old handoff must not open a screen after leave',
          );
        } finally {
          if (!camera.release.isCompleted) camera.release.complete();
          await command;
          await disposing;
          await service.dispose();
          await groups.close();
          await pumpEventQueue();
          expect(slot.owner, isNull);
        }
      });
    }
  }

  for (final reentrant in [false, true]) {
    test('group startup camera cleanup holds slot: $reentrant', () async {
      final groups = _CameraOutcomeGroups(_id(1)),
          slot = CallSlot(),
          engine = _HeldGroupEngine();
      final camera = _HeldGroupCamera(
        opening: Completer<bool>(),
        failStart: true,
      );
      // Keep startup pending until the room is active, then fail its source port.
      final controller = VeilGroupCallMediaController(
        _FakeTransport(_id(1)),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        androidCapture: true,
        cameraCaptureFactory: () => camera,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
      final service = GroupCallService(
        groups,
        media: controller,
        callSlot: slot,
      )..start();
      Future<void>? disposing;
      try {
        final active = service.changes.firstWhere(
          (c) => c?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            _id(9),
            const CallMedia(audio: true, video: true),
          ),
          isTrue,
        );
        await active;
        await camera.opened.future;
        if (reentrant) {
          camera.onStop = () {
            disposing = service.dispose();
          };
        }
        camera.opening!.complete(true);
        await camera.stopping.future;
        await service.leave();
        await pumpEventQueue();
        expect(engine.audioStops, greaterThan(0));
        final competing = slot.acquire(CallSlotOwner.direct);
        if (competing != null) slot.release(competing);
        expect(
          competing,
          isNull,
          reason: 'startup cleanup still waits for its source stop',
        );
        camera.release.complete();
        await disposing;
        await pumpEventQueue();
        expect(slot.owner, isNull);
        expect(engine.disposals, 1);
      } finally {
        if (!camera.opening!.isCompleted) camera.opening!.complete(true);
        if (!camera.release.isCompleted) camera.release.complete();
        await disposing;
        await service.dispose();
        await groups.close();
        await pumpEventQueue();
        expect(slot.owner, isNull);
      }
    });
  }

  for (final operation in ['off', 'screen', 'attached']) {
    test('group platform camera stop holds slot: $operation', () async {
      final previous = CameraPlatform.instance;
      final platform = RetirementCameraPlatform()
        ..disposeGate = Completer<void>();
      CameraPlatform.instance = platform;
      final groups = _CameraOutcomeGroups(_id(1)),
          engine = _HeldGroupEngine(),
          slot = CallSlot();
      final exited = Completer<void>();
      final camera = _ObservedGroupPlugin(exited);
      final controller = VeilGroupCallMediaController(
        _FakeTransport(_id(1)),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        androidCapture: true,
        cameraCaptureFactory: () => camera,
        screenCaptureFactory: (_) => _IntentScreen()..result.complete(false),
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
      final service = GroupCallService(
        groups,
        media: controller,
        callSlot: slot,
      )..start();
      Future<void>? command;
      Object? commandError;
      try {
        final active = service.changes.firstWhere(
          (c) => c?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            _id(9),
            const CallMedia(audio: true, video: true),
          ),
          isTrue,
        );
        await active;
        expect(await camera.opened.future, isTrue);
        await pumpEventQueue();
        expect(
          androidCallCameraPreviewController.value?.value.isStreamingImages,
          isTrue,
        );
        final changing = operation == 'off'
            ? service.setCameraEnabled(false)
            : operation == 'screen'
            ? service.setScreenShareEnabled(true)
            : Future<void>.value();
        command = changing.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            commandError = error;
          },
        );
        if (operation != 'attached') await platform.disposeEntered.future;
        await service.leave();
        await platform.disposeEntered.future;
        await pumpEventQueue();
        expect(
          engine.audioStops,
          greaterThan(0),
          reason: 'audio must not wait for CameraPlatform.dispose',
        );
        final competing = slot.acquire(CallSlotOwner.direct);
        if (competing != null) slot.release(competing);
        expect(
          competing,
          isNull,
          reason: 'real plugin adapter still owns camera/worker retirement',
        );
        platform.disposeGate!.complete();
        await command;
        await pumpEventQueue();
        expect(commandError, isNull);
        expect(slot.owner, isNull);
        expect(engine.disposals, 1);
        expect(exited.isCompleted, isTrue);
      } finally {
        if (!platform.disposeGate!.isCompleted) {
          platform.disposeGate!.complete();
        }
        await command;
        await service.dispose();
        await camera.stop();
        await groups.close();
        await pumpEventQueue();
        CameraPlatform.instance = previous;
        expect(platform.errors, isEmpty);
        expect(androidCallCameraPreviewController.value, isNull);
        expect(slot.owner, isNull);
      }
    });
  }

  for (final failedReply in [false, true]) {
    test(
      'group old cleanup cannot hold newer audio engine: fail=$failedReply',
      () async {
        final old = _HeldGroupEngine(), next = _HeldGroupEngine();
        final camera = _RetryGroupCamera();
        var engines = 0;
        final controller = VeilGroupCallMediaController(
          _FakeTransport(_id(1)),
          roomMediaSecret: _room(),
          engineFactory: (_) => engines++ == 0 ? old : next,
          androidCapture: true,
          cameraCaptureFactory: () => camera,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
        );
        Future<void>? stopping;
        try {
          expect(
            await controller.start(
              _call(_id(1), [], video: true, callId: 'old-capture'),
            ),
            isTrue,
          );
          await camera.opened.future;
          // The existing best-effort policy can finish after a returned error;
          // the old startup continuation later makes its own cleanup attempt.
          await controller.stop();
          expect(old.disposals, 1);
          expect(
            await controller.start(_call(_id(1), [], callId: 'new-audio')),
            isTrue,
          );
          camera.opening.complete(false);
          await camera.retrying.future;
          var stopped = false;
          stopping = controller.stop().then((_) {
            stopped = true;
          });
          await pumpEventQueue();
          expect(
            stopped,
            isTrue,
            reason: 'another engine must not join old cleanup',
          );
          expect(next.audioStops, 1);
          expect(next.disposals, 1);
          if (failedReply) {
            camera.release.completeError(
              StateError('synthetic retry close failure'),
            );
          } else {
            camera.release.complete();
          }
          await stopping;
          await pumpEventQueue();
        } finally {
          if (!camera.opening.isCompleted) camera.opening.complete(false);
          if (!camera.release.isCompleted) camera.release.complete();
          await stopping;
          await controller.stop();
          await pumpEventQueue();
        }
      },
    );
  }

  for (final capture in [0, 1, -1, null, '0']) {
    test(
      'group observes explicit capture termination: ${capture.runtimeType}:$capture',
      () {
        diagnosticJournal.clear();
        addTearDown(diagnosticJournal.clear);
        fakeAsync((clock) {
          final groups = _CameraOutcomeGroups(_id(1));
          final engine = _CameraOutcomeEngine();
          final controller = VeilGroupCallMediaController(
            _FakeTransport(_id(1)),
            roomMediaSecret: _room(),
            engineFactory: (_) => engine,
            networkActivity: CallNetworkActivity(setActive: (_) async => false),
            requestMicrophone: () async => true,
            requestCamera: () async => true,
            now: test_clock.clock.now,
          );
          final service = GroupCallService(groups, media: controller)..start();
          service.startCall(_id(9), const CallMedia(audio: true, video: true));
          clock.flushMicrotasks();
          expect(service.current?.status, GroupCallStatus.active);
          expect(engine.cameraActive, isTrue);
          expect(service.current?.cameraOn, isTrue);
          final signals = groups.sent.length;
          // An explicit native capturer state, independent of encoded-frame
          // counts or network progress. Missing/legacy/malformed is unknown.
          if (capture == 0) engine.cameraActive = false;
          engine.stats = {
            'camera_capturing': ?capture,
            'camera_driver_text': 'PRIVATE_GROUP_TERMINATION_CANARY',
          };
          clock.elapse(const Duration(seconds: 1));
          expect(service.current?.cameraOn, capture != 0);
          expect(controller.startedWithoutCamera, capture == 0);
          expect(service.current?.status, GroupCallStatus.active);
          expect(controller.audioRunning, isTrue);
          expect(controller.videoRunning, isTrue);
          if (capture == 0) {
            expect(groups.sent.length, signals + 1);
            expect(groups.sent.last.media?.video, isFalse);
            if (kDiagnosticReportEnabled) {
              final report = diagnosticJournal.toJson();
              final evidence = report['last_evidence'] as Map;
              expect((evidence['cameraStopped'] as Map)['values'], {
                'cameraCapturing': 0,
              });
              final encoded = jsonEncode(report);
              expect(
                encoded,
                isNot(contains('PRIVATE_GROUP_TERMINATION_CANARY')),
              );
              expect(encoded, isNot(contains(service.current!.callId)));
              expect(encoded, isNot(contains(_id(9).hex)));
            }
            clock.elapse(const Duration(seconds: 2));
            expect(
              groups.sent.length,
              signals + 1,
              reason: 'one terminal observation produces one posture change',
            );
            engine.stats = {'camera_capturing': 1};
            service.setCameraEnabled(true);
            clock.flushMicrotasks();
            expect(engine.cameraStarted, 2);
            expect(service.current?.cameraOn, isTrue);
            expect(groups.sent.last.media?.video, isTrue);
          } else {
            expect(groups.sent.length, signals);
          }
          service.dispose();
          clock.flushMicrotasks();
          groups.close();
          clock.flushMicrotasks();
        });
      },
    );
  }

  for (final source in ['off', 'screen', 'android', 'stopped']) {
    test('group capture termination respects source ownership: $source', () {
      fakeAsync((clock) {
        final engine = _CameraOutcomeEngine();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(_id(1)),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          desktopScreenCaptureSupported: true,
          androidCapture: source == 'android',
          cameraCaptureFactory: () => _IntentCamera(),
          now: test_clock.clock.now,
        );
        final failures = <GroupCallCameraFailure>[];
        final subscription = controller.cameraUnavailable.listen(failures.add);
        controller.start(_call(_id(1), [], video: true));
        clock.flushMicrotasks();
        expect(controller.videoRunning, isTrue);
        if (source == 'off') controller.setCameraEnabled(false);
        bool? shareStarted;
        if (source == 'screen') {
          controller
              .setScreenShareEnabled(true)
              .then((value) => shareStarted = value);
        }
        if (source == 'stopped') controller.stop();
        clock.flushMicrotasks();
        if (source == 'screen') expect(shareStarted, isTrue);
        engine.stats = {'camera_capturing': 0};
        clock.elapse(const Duration(seconds: 2));
        expect(failures, isEmpty);
        expect(controller.startedWithoutCamera, isFalse);
        controller.stop();
        clock.flushMicrotasks();
        subscription.cancel();
        clock.flushMicrotasks();
      });
    });
  }

  for (final outcome in ['refused', 'throws', 'off', 'replacement']) {
    test('Android group camera outcome is owned: $outcome', () async {
      final self = _id(1), groups = _CameraOutcomeGroups(_id(1));
      final camera = _IntentCamera()..result = Completer<bool>();
      var creations = 0;
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => _FakeEngine(),
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        androidCapture: true,
        cameraCaptureFactory: () => creations++ == 0 ? camera : _IntentCamera(),
      );
      final service = GroupCallService(groups, media: controller)..start();
      addTearDown(() async {
        if (!camera.result!.isCompleted) camera.result!.complete(false);
        await service.dispose();
        await groups.close();
      });
      Future<void> startRoom(NodeId id) async {
        final active = service.changes.firstWhere(
          (call) => call?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            id,
            const CallMedia(audio: true, video: true),
          ),
          isTrue,
        );
        await active;
      }

      await startRoom(_id(9));
      expect(creations, 1);
      if (outcome == 'off') await service.setCameraEnabled(false);
      if (outcome == 'replacement') {
        await service.leave();
        await pumpEventQueue();
        await startRoom(_id(8));
      }
      if (outcome == 'throws') {
        camera.result!.completeError(
          StateError('synthetic camera source failure'),
        );
      } else {
        camera.result!.complete(false);
      }
      await pumpEventQueue();
      expect(service.current?.status, GroupCallStatus.active);
      expect(controller.audioRunning, isTrue);
      expect(controller.videoRunning, isTrue);
      expect(service.current?.cameraOn, outcome == 'replacement');
      expect(camera.stops, greaterThan(0));
      if (outcome == 'refused' || outcome == 'throws') {
        expect(groups.sent.last.media?.video, isFalse);
        await service.setCameraEnabled(true);
        await pumpEventQueue();
        expect(creations, 2);
        expect(service.current?.cameraOn, isTrue);
      }
    });
  }

  for (final evidence in [
    'current',
    'other-group',
    'other-channel',
    'other-call',
    'recovered',
    'disposed',
  ]) {
    test('group camera failure event keeps its owner: $evidence', () async {
      final groups = _CameraOutcomeGroups(_id(1));
      final media = _CameraOutcomeMedia();
      final service = GroupCallService(groups, media: media)..start();
      addTearDown(() async {
        await service.dispose();
        await media.failures.close();
        await groups.close();
      });
      final active = service.changes.firstWhere(
        (call) => call?.status == GroupCallStatus.active,
      );
      expect(
        await service.startCall(
          _id(9),
          const CallMedia(audio: true, video: true),
        ),
        isTrue,
      );
      await active;
      final call = service.current!;
      media.failed = evidence != 'recovered';
      if (evidence == 'disposed') await service.dispose();
      media.failures.add(
        GroupCallCameraFailure(
          groupId: evidence == 'other-group' ? _id(8) : call.groupId,
          channelId: evidence == 'other-channel' ? _id(7) : call.channelId,
          callId: evidence == 'other-call'
              ? 'previous-camera-call'
              : call.callId,
        ),
      );
      await pumpEventQueue();
      if (evidence == 'disposed') {
        expect(service.current, isNull);
      } else {
        expect(service.current?.status, GroupCallStatus.active);
        expect(service.current?.cameraOn, evidence != 'current');
        if (evidence == 'current') {
          expect(groups.sent.last.media?.video, isFalse);
        }
      }
    });
  }

  test('late failed group camera command cannot undo a newer ON', () async {
    final groups = _CameraOutcomeGroups(_id(1));
    final media = _CameraOutcomeMedia();
    final gate = Completer<void>(), entered = Completer<void>();
    var attempts = 0;
    media.cameraOperation = (on) async {
      if (on && attempts++ == 0) {
        entered.complete();
        await gate.future;
      }
    };
    final service = GroupCallService(groups, media: media)..start();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await service.dispose();
      await media.failures.close();
      await groups.close();
    });
    final active = service.changes.firstWhere(
      (call) => call?.status == GroupCallStatus.active,
    );
    expect(
      await service.startCall(
        _id(9),
        const CallMedia(audio: true, video: true),
      ),
      isTrue,
    );
    await active;
    await service.setCameraEnabled(false);
    final first = service.setCameraEnabled(true);
    await entered.future;
    await service.setCameraEnabled(false);
    await service.setCameraEnabled(true);
    gate.completeError(StateError('synthetic retired camera command'));
    await first;
    expect(service.current?.status, GroupCallStatus.active);
    expect(service.current?.cameraOn, isTrue);
    expect(groups.sent.last.media?.video, isTrue);
  });

  test('group camera report keeps only numeric capture evidence', () async {
    diagnosticJournal.clear();
    addTearDown(diagnosticJournal.clear);
    final self = _id(1), groups = _CameraOutcomeGroups(_id(1));
    final engine = _CameraOutcomeEngine()..rejectCamera = true;
    engine.stats = {
      'camera_capture_status': 6,
      'camera_capture_hresult': -1,
      'camera_capture_reads': 0,
      'camera_capture_samples': 0,
      'camera_capture_frames': 0,
      'camera_capture_dropped': 0,
      'camera_driver_path': 'PRIVATE_GROUP_CAMERA_CANARY',
    };
    final controller = VeilGroupCallMediaController(
      _FakeTransport(self),
      roomMediaSecret: _room(),
      engineFactory: (_) => engine,
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
      requestMicrophone: () async => true,
      requestCamera: () async => true,
    );
    final service = GroupCallService(groups, media: controller)..start();
    addTearDown(() async {
      await service.dispose();
      await groups.close();
    });
    final active = service.changes.firstWhere(
      (call) => call?.status == GroupCallStatus.active,
    );
    expect(
      await service.startCall(
        _id(9),
        const CallMedia(audio: true, video: true),
      ),
      isTrue,
    );
    await active;
    await pumpEventQueue();
    expect(service.current?.cameraOn, isFalse);
    if (kDiagnosticReportEnabled) {
      final report = diagnosticJournal.toJson();
      final evidence = report['last_evidence'] as Map;
      expect((evidence['cameraStart'] as Map)['values'], {
        'success': 0,
        'origin': CameraStartOrigin.callStart.index,
        'cameraCaptureStatus': 6,
        'cameraCaptureHresult': -1,
        'cameraCaptureReads': 0,
        'cameraCaptureSamples': 0,
        'cameraCaptureFrames': 0,
        'cameraCaptureDropped': 0,
      });
      final encoded = jsonEncode(report);
      expect(encoded, isNot(contains('PRIVATE_GROUP_CAMERA_CANARY')));
      expect(encoded, isNot(contains(service.current!.callId)));
      expect(encoded, isNot(contains(_id(9).hex)));
    }
  });

  group('camera intent travels from group FSM to the capture controller', () {
    for (final cameraOn in [false, true]) {
      for (final throws in [false, true]) {
        test('share failure honors camera=$cameraOn throws=$throws', () async {
          final self = _id(1), groupId = _id(9);
          final groups = _CameraIntentGroups(self);
          final engine = _FakeEngine();
          final controller = VeilGroupCallMediaController(
            _FakeTransport(self),
            networkActivity: CallNetworkActivity(setActive: (_) async => false),
            roomMediaSecret: _room(),
            engineFactory: (_) => engine,
            requestMicrophone: () async => true,
            requestCamera: () async => true,
            desktopScreenCaptureSupported: true,
          );
          final service = GroupCallService(groups, media: controller)..start();
          addTearDown(() async {
            await service.dispose();
            await groups.close();
          });
          final active = service.changes.firstWhere(
            (call) => call?.status == GroupCallStatus.active,
          );
          expect(
            await service.startCall(
              groupId,
              const CallMedia(audio: true, video: true),
            ),
            isTrue,
          );
          await active;
          expect(engine.cameraStarted, 1);
          await service.setScreenShareEnabled(true);
          expect(service.current?.screenOn, isTrue);
          final sourceBeforeToggle = (
            engine.cameraStarted,
            engine.cameraStopped,
            engine.screenStarted,
            engine.screenStopped,
          );
          await service.setCameraEnabled(!cameraOn);
          await service.setCameraEnabled(cameraOn);
          expect(service.current?.cameraOn, cameraOn);
          expect(service.current?.screenOn, isTrue);
          expect(
            (
              engine.cameraStarted,
              engine.cameraStopped,
              engine.screenStarted,
              engine.screenStopped,
            ),
            sourceBeforeToggle,
            reason:
                'remembering camera intent must not interrupt the screen source',
          );
          await service.setScreenShareEnabled(false);
          expect(service.current?.screenOn, isFalse);
          final beforeFailure = engine.cameraStarted;
          engine.screenStarts = false;
          engine.throwOnScreenStart = throws;
          await service.setScreenShareEnabled(true);
          expect(service.current?.screenOn, isFalse);
          expect(service.current?.cameraOn, cameraOn);
          expect(
            engine.cameraStarted,
            beforeFailure + (cameraOn ? 1 : 0),
            reason:
                'failed screen capture must not reopen a camera disabled while sharing',
          );
          engine.screenStarts = true;
          engine.throwOnScreenStart = false;
          final beforeRecovery = engine.cameraStarted;
          await service.setScreenShareEnabled(true);
          expect(service.current?.screenOn, isTrue);
          expect(engine.cameraStarted, beforeRecovery);
          await service.setScreenShareEnabled(false);
          expect(service.current?.screenOn, isFalse);
          expect(engine.cameraStarted, beforeRecovery + (cameraOn ? 1 : 0));
        });
      }
    }
  });

  for (final cameraOn in [false, true]) {
    test(
      'Android failed share restores only current camera=$cameraOn',
      () async {
        final self = _id(1), groups = _CameraIntentGroups(_id(1));
        final engine = _FakeEngine();
        final cameras = <_IntentCamera>[];
        final screen = _IntentScreen();
        final controller = VeilGroupCallMediaController(
          _FakeTransport(self),
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
          roomMediaSecret: _room(),
          engineFactory: (_) => engine,
          requestMicrophone: () async => true,
          requestCamera: () async => true,
          androidCapture: true,
          cameraCaptureFactory: () {
            final camera = _IntentCamera();
            cameras.add(camera);
            return camera;
          },
          screenCaptureFactory: (_) => screen,
        );
        final service = GroupCallService(groups, media: controller)..start();
        addTearDown(() async {
          if (!screen.result.isCompleted) screen.result.complete(false);
          await service.dispose();
          await groups.close();
        });
        final active = service.changes.firstWhere(
          (call) => call?.status == GroupCallStatus.active,
        );
        expect(
          await service.startCall(
            _id(9),
            const CallMedia(audio: true, video: true),
          ),
          isTrue,
        );
        await active;
        expect(cameras, hasLength(1));
        final sharing = service.setScreenShareEnabled(true);
        await screen.entered.future;
        try {
          await service.setCameraEnabled(false);
          if (cameraOn) await service.setCameraEnabled(true);
          expect(service.current?.cameraOn, cameraOn);
          screen.result.complete(false);
          await sharing;
          expect(service.current?.screenOn, isFalse);
          expect(
            cameras,
            hasLength(cameraOn ? 2 : 1),
            reason:
                'a denied Android screen must not recreate a camera after OFF',
          );
          if (cameraOn) {
            final before = engine.videoPushed;
            cameras.last.frame();
            expect(engine.videoPushed, before + 1);
          }
        } finally {
          if (!screen.result.isCompleted) screen.result.complete(false);
          await sharing;
        }
      },
    );
  }

  test('Android screen ownership refuses retired camera callbacks', () async {
    final self = _id(1), engine = _FakeEngine();
    final camera = _IntentCamera(), screen = _IntentScreen();
    final controller = VeilGroupCallMediaController(
      _FakeTransport(self),
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
      roomMediaSecret: _room(),
      engineFactory: (_) => engine,
      requestMicrophone: () async => true,
      requestCamera: () async => true,
      androidCapture: true,
      cameraCaptureFactory: () => camera,
      screenCaptureFactory: (_) => screen,
    );
    addTearDown(() async {
      if (!screen.result.isCompleted) screen.result.complete(false);
      await controller.stop();
    });
    expect(await controller.start(_call(self, const [], video: true)), isTrue);
    camera.frame();
    final before = engine.videoPushed;
    expect(before, 1);
    final sharing = controller.setScreenShareEnabled(true);
    await screen.entered.future;
    screen.result.complete(true);
    expect(await sharing, isTrue);
    camera.frame();
    expect(
      engine.videoPushed,
      before,
      reason: 'retired camera cannot feed the screen-owned source',
    );
    screen.frame();
    expect(
      engine.videoPushed,
      before + 1,
      reason: 'owned screen frames must still flow',
    );
  });

  for (final change in ['off', 'stop', 'replacement']) {
    test('late Android camera start is retired after $change', () async {
      final self = _id(1), engine = _FakeEngine();
      final result = Completer<bool>();
      final cameras = <_IntentCamera>[];
      final controller = VeilGroupCallMediaController(
        _FakeTransport(self),
        roomMediaSecret: _room(),
        engineFactory: (_) => engine,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        androidCapture: true,
        cameraCaptureFactory: () {
          final camera = _IntentCamera();
          if (cameras.isEmpty) camera.result = result;
          cameras.add(camera);
          return camera;
        },
      );
      addTearDown(() async {
        if (!result.isCompleted) result.complete(false);
        await pumpEventQueue();
        await controller.stop();
      });
      expect(
        await controller.start(_call(self, const [], video: true)),
        isTrue,
      );
      final old = cameras.single;
      if (change == 'off') {
        await controller.setCameraEnabled(false);
      } else {
        await controller.stop();
      }
      expect(old.stops, 1);
      if (change == 'replacement') {
        expect(
          await controller.start(_call(self, const [], video: true)),
          isTrue,
        );
        expect(cameras, hasLength(2));
      }
      result.complete(true);
      await pumpEventQueue();
      expect(
        old.stops,
        2,
        reason: 'a late successful orphan must be reclaimed',
      );
      final before = engine.videoPushed;
      old.frame();
      expect(engine.videoPushed, before);
      if (change == 'replacement') {
        cameras.last.frame();
        expect(
          engine.videoPushed,
          before + 1,
          reason: 'old cleanup must not retire the replacement source',
        );
      }
    });
  }

  test('refused Android camera start is cleaned up', () async {
    final camera = _IntentCamera()
      ..result = (Completer<bool>()..complete(false));
    final controller = VeilGroupCallMediaController(
      _FakeTransport(_id(1)),
      roomMediaSecret: _room(),
      engineFactory: (_) => _FakeEngine(),
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
      requestMicrophone: () async => true,
      requestCamera: () async => true,
      androidCapture: true,
      cameraCaptureFactory: () => camera,
    );
    addTearDown(controller.stop);
    expect(
      await controller.start(_call(_id(1), const [], video: true)),
      isTrue,
    );
    await pumpEventQueue();
    expect(camera.stops, 1);
  });

  test('unsupported desktop screen leaves the camera source intact', () async {
    final self = _id(1);
    final transport = _FakeTransport(self);
    final engine = _FakeEngine();
    final controller = VeilGroupCallMediaController(
      networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
          networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
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
    bool primaryOnlyPreparation = false,
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

class _StartingGroupTransport extends _FakeTransport {
  _StartingGroupTransport(super.self);
  final starting = Completer<void>();
  @override
  Future<Uint8List> localNodeId() async {
    starting.complete();
    return self.bytes;
  }
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
  final List<({DateTime at, DateTime event})> growthHoldReports = [];
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
    DateTime? growthHoldStartedAt,
  }) {
    pressureReports.add((pressured: pressured, at: sampledAt));
    if (growthHoldStartedAt != null) {
      growthHoldReports.add((at: sampledAt, event: growthHoldStartedAt));
    }
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
  @override
  bool get supportsNoiseSuppression => true;
  final noiseSuppression = <bool>[];
  bool rejectNoiseSuppression = false;
  @override
  bool setNoiseSuppression(bool enabled) {
    if (rejectNoiseSuppression) return false;
    noiseSuppression.add(enabled);
    return true;
  }

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
  final List<bool?> audioSourcePressure = [];
  final List<({DateTime at, DateTime event})> audioGrowthHolds = [];
  @override
  bool setAudioSourcePressure(
    bool? pressured, {
    DateTime? sampledAt,
    DateTime? growthHoldStartedAt,
  }) {
    audioSourcePressure.add(pressured);
    if (growthHoldStartedAt != null && sampledAt != null) {
      audioGrowthHolds.add((at: sampledAt, event: growthHoldStartedAt));
    }
    return true;
  }

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
  bool videoReady = true;
  final List<bool?> videoMountPauses = [];
  final List<({int maxBitrateKbps, double maxFps})?> videoMountTargets = [];
  bool videoActive = false;
  bool acceptColdTarget = true;
  int cameraStarted = 0;
  int cameraStopped = 0;
  int screenStarted = 0;
  int screenStopped = 0;
  int videoPushed = 0;
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

  bool throwOnAudioStart = false;

  @override
  bool startAudio() {
    if (throwOnAudioStart) throw StateError('capture failed');
    audioStartMuted.add(muted);
    started++;
    return true;
  }

  @override
  bool stopAudio() => true;

  @override
  bool startVideo() {
    if (!videoReady) return false;
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
  bool stopCamera() {
    cameraStopped++;
    return true;
  }

  bool screenStarts = true;
  bool throwOnScreenStart = false;

  @override
  bool startScreen({String? sourceId}) {
    screenStarted++;
    if (throwOnScreenStart) throw StateError('capture unavailable');
    return screenStarts;
  }

  @override
  List<MediaDevice> listScreens() => const [];

  @override
  bool stopScreen() {
    screenStopped++;
    return true;
  }

  @override
  bool pushVideoFrame(
    Uint8List y,
    Uint8List u,
    Uint8List v,
    int width,
    int height,
  ) {
    videoPushed++;
    return true;
  }

  @override
  VeilVideoFrame? localVideoFrame() => localFrame;

  @override
  VeilVideoFrame? peerVideoFrame(NodeId peer) => peerFrames[peer.hex];
}

// The real FSM and media controller share one synthetic room. Membership and
// broadcasts are controlled here; no signature, network or hardware is claimed.
class _CameraIntentGroups implements GroupService {
  _CameraIntentGroups(this.selfId);
  @override
  final NodeId selfId;
  @override
  final changes = GroupChangeSignal();
  final _incoming = StreamController<GroupCallSignal>.broadcast();
  @override
  Stream<GroupCallSignal> get groupCallIncoming => _incoming.stream;
  @override
  Future<GroupState?> stateOf(NodeId groupId) async =>
      GroupState.genesis(selfId);
  @override
  Future<({int? channelEpoch, Set<NodeId> recipients})?>
  currentVoiceChannelAdmission(NodeId groupId, NodeId? channelId) async =>
      (channelEpoch: null, recipients: {selfId});
  @override
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    NodeId? channelId,
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) async => GroupCallSignal(
    groupId: groupId,
    channelId: channelId,
    callId: callId,
    author: selfId,
    membershipEpoch: 1,
    type: type,
    sentAtMs: DateTime.now().millisecondsSinceEpoch,
    nonce: 'synthetic-camera-intent',
    signature: Uint8List(64),
    authorPubKey: Uint8List(32),
    media: media,
    reason: reason,
  );
  Future<void> close() async {
    await _incoming.close();
    changes.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockedGroupPeerOpen extends _FakeTransport {
  _BlockedGroupPeerOpen(super.self);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<int> open(
    NodeId peer, {
    required Uint8List txKey,
    required Uint8List rxKey,
  }) async {
    final channel = await super.open(peer, txKey: txKey, rxKey: rxKey);
    entered.complete();
    await release.future;
    return channel;
  }
}

class _GroupScreenStand {
  final groups = _CameraOutcomeGroups(_id(1));
  final engines = <_GroupScreenEngine>[];
  late final controller = _GroupScreenController((_) {
    final engine = _GroupScreenEngine();
    engines.add(engine);
    return engine;
  });
  late final service = GroupCallService(groups, media: controller)..start();

  Future<void> start() async {
    final active = service.changes.firstWhere(
      (call) => call?.status == GroupCallStatus.active,
    );
    expect(
      await service.startCall(
        _id(9),
        const CallMedia(audio: true, video: true),
      ),
      isTrue,
    );
    await active;
    await service.setCameraEnabled(false);
    expect(await service.selectScreen('display-1'), isTrue);
    await service.setScreenShareEnabled(true);
    expect(service.current?.screenOn, isTrue);
    expect(engines.last.activeScreen, 'display-1');
  }

  Future<void> close() async {
    await service.dispose();
    await groups.close();
    await pumpEventQueue();
  }
}

class _GroupScreenController extends VeilGroupCallMediaController {
  _GroupScreenController(GroupAudioEngineFactory factory)
    : super(
        _FakeTransport(_id(1)),
        roomMediaSecret: _room(),
        engineFactory: factory,
        requestMicrophone: () async => true,
        requestCamera: () async => true,
        desktopScreenCaptureSupported: true,
        networkActivity: CallNetworkActivity(setActive: (_) async => false),
      );
  Completer<List<CallMediaDevice>>? nextList;
  final listEntered = Completer<void>();
  static const screens = [
    CallMediaDevice(
      id: 'display-1',
      label: 'A display',
      kind: CallMediaDeviceKind.screen,
    ),
    CallMediaDevice(
      id: 'window-2',
      label: 'A window',
      kind: CallMediaDeviceKind.window,
    ),
    CallMediaDevice(
      id: 'display-3',
      label: 'Another display',
      kind: CallMediaDeviceKind.screen,
    ),
  ];
  @override
  Future<List<CallMediaDevice>> listScreens() {
    final held = nextList;
    nextList = null;
    if (held == null) return Future.value(screens);
    listEntered.complete();
    return held.future;
  }
}

class _GroupScreenEngine extends _HeldGroupEngine {
  final screenChoices = <String?>[], retiredCalls = <String>[];
  final refused = <String>{}, throwing = <String>{};
  bool disposed = false, acceptStop = true, throwStop = false;
  void Function()? onScreenStop;
  String? activeScreen;
  @override
  bool startScreen({String? sourceId}) {
    screenChoices.add(sourceId);
    if (disposed) {
      retiredCalls.add('start');
      throw StateError('retired synthetic engine');
    }
    if (throwing.contains(sourceId)) {
      throw StateError('synthetic source failure');
    }
    if (refused.contains(sourceId)) return false;
    activeScreen = sourceId;
    return super.startScreen(sourceId: sourceId);
  }

  @override
  bool stopScreen() {
    super.stopScreen();
    if (disposed) {
      retiredCalls.add('stop');
      throw StateError('retired synthetic engine');
    }
    if (throwStop) throw StateError('synthetic stop failure');
    if (!acceptStop) return false;
    activeScreen = null;
    final callback = onScreenStop;
    onScreenStop = null;
    callback?.call();
    return true;
  }

  @override
  void dispose() {
    disposed = true;
    activeScreen = null;
    super.dispose();
  }
}

class _RequestStopEngine extends _HeldGroupEngine {
  _RequestStopEngine(this.outcome);
  final String outcome;
  void Function()? onAudioStop;
  @override
  bool stopAudio() {
    final result = super.stopAudio();
    final callback = onAudioStop;
    onAudioStop = null;
    callback?.call();
    if (audioStops == 1 && outcome == 'throws') {
      throw StateError('synthetic audio stop failure');
    }
    if (audioStops == 1 && outcome == 'refused') return false;
    return result;
  }
}

class _HeldGroupEngine extends _FakeEngine {
  int audioStops = 0, disposals = 0;
  @override
  bool stopAudio() {
    audioStops++;
    return super.stopAudio();
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

class _HeldGroupCamera extends _IntentCamera {
  _HeldGroupCamera({this.opening, this.failStart = false});
  final Completer<bool>? opening;
  final bool failStart;
  final opened = Completer<void>(),
      stopping = Completer<void>(),
      release = Completer<void>();
  Future<void>? _closing;
  void Function()? onStop;
  @override
  Future<bool> start(I420FrameSink sink) async {
    await super.start(sink);
    opened.complete();
    final ok = opening == null ? true : await opening!.future;
    if (failStart) throw StateError('synthetic group startup cleanup failure');
    return ok;
  }

  @override
  Future<void> stop() {
    final pending = _closing;
    if (pending != null) return pending;
    stops++;
    _closing = release.future;
    stopping.complete();
    final callback = onStop;
    onStop = null;
    callback?.call();
    return release.future;
  }
}

class _RetryGroupCamera extends _IntentCamera {
  final opening = Completer<bool>(), opened = Completer<void>();
  final retrying = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> start(I420FrameSink sink) async {
    await super.start(sink);
    opened.complete();
    return opening.future;
  }

  @override
  Future<void> stop() {
    stops++;
    if (stops == 1) {
      return Future.error(StateError('synthetic first close failure'));
    }
    if (!retrying.isCompleted) retrying.complete();
    return release.future;
  }
}

class _ObservedGroupPlugin extends AndroidCameraCapture {
  _ObservedGroupPlugin(Completer<void> exited)
    : super(onWorkerExit: exited.complete);
  final opened = Completer<bool>();
  @override
  Future<bool> start(I420FrameSink sink) async {
    final ok = await super.start(sink);
    opened.complete(ok);
    return ok;
  }
}

class _IntentCamera extends AndroidCameraCapture {
  I420FrameSink? _sink;
  Completer<bool>? result;
  int stops = 0;
  @override
  Future<bool> start(I420FrameSink sink) async {
    _sink = sink;
    return result?.future ?? true;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  // Deliberately retain a callable sink as an adversarial late-callback probe.
  void frame() => _sink?.call(Uint8List(4), Uint8List(1), Uint8List(1), 2, 2);
}

class _GroupProjectionStand {
  _GroupProjectionStand(this.screenFactory);
  final AndroidScreenCaptureFactory screenFactory;
  final groups = _CameraOutcomeGroups(_id(1)), slot = CallSlot();
  final engine = _HeldGroupEngine();
  late final controller = VeilGroupCallMediaController(
    _FakeTransport(_id(1)),
    roomMediaSecret: _room(),
    engineFactory: (_) => engine,
    androidCapture: true,
    cameraCaptureFactory: () => _IntentCamera(),
    screenCaptureFactory: screenFactory,
    requestMicrophone: () async => true,
    requestCamera: () async => true,
    networkActivity: CallNetworkActivity(setActive: (_) async => false),
  );
  late final service = GroupCallService(
    groups,
    media: controller,
    callSlot: slot,
  )..start();
  Future<void> start() async {
    final active = service.changes.firstWhere(
      (c) => c?.status == GroupCallStatus.active,
    );
    expect(
      await service.startCall(
        _id(9),
        const CallMedia(audio: true, video: true),
      ),
      isTrue,
    );
    await active;
    await pumpEventQueue();
  }

  Future<void> close() async {
    await service.dispose();
    await groups.close();
    await pumpEventQueue();
  }
}

class _HeldGroupScreen extends _PendingGroupScreen {
  final stopping = Completer<void>(), release = Completer<void>();
  Future<void>? _closing;
  void Function()? onStop;
  @override
  Future<void> stop() {
    if (_closing != null) return _closing!;
    stops++;
    _closing = release.future;
    stopping.complete();
    final callback = onStop;
    onStop = null;
    callback?.call();
    return release.future;
  }
}

class _PendingGroupScreen extends _IntentScreen {
  int stops = 0;
  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
  }
}

class _IntentScreen implements AndroidScreenCaptureSource {
  final entered = Completer<void>(), result = Completer<bool>();
  I420FrameSink? _sink;
  @override
  Future<bool> start(I420FrameSink sink) async {
    _sink = sink;
    entered.complete();
    return result.future;
  }

  @override
  Future<void> stop() async {}
  @override
  bool rebindFrameSink(I420FrameSink? sink) {
    _sink = sink;
    return true;
  }

  void frame() => _sink?.call(Uint8List(4), Uint8List(1), Uint8List(1), 2, 2);
}

class _CameraOutcomeEngine extends _FakeEngine {
  bool rejectCamera = false;
  bool throwOnCamera = false;
  bool cameraActive = false;
  @override
  bool startCamera() {
    super.startCamera();
    if (rejectCamera) {
      cameraActive = false;
      if (throwOnCamera) throw StateError('synthetic camera start refusal');
      return false;
    }
    cameraActive = true;
    return true;
  }

  @override
  bool stopCamera() {
    cameraActive = false;
    return super.stopCamera();
  }
}

class _CameraOutcomeGroups extends _CameraIntentGroups {
  _CameraOutcomeGroups(super.selfId);
  final sent = <GroupCallSignal>[];
  @override
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    NodeId? channelId,
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) async {
    final signal = await super.broadcastGroupCallSignal(
      groupId,
      channelId: channelId,
      callId: callId,
      type: type,
      media: media,
      reason: reason,
    );
    if (signal != null) sent.add(signal);
    return signal;
  }
}

class _CameraOutcomeMedia extends GroupCallMediaController {
  final failures = StreamController<GroupCallCameraFailure>.broadcast();
  bool failed = false;
  Future<void> Function(bool)? cameraOperation;
  @override
  Stream<GroupCallCameraFailure> get cameraUnavailable => failures.stream;
  @override
  bool get startedWithoutCamera => failed;
  @override
  Future<bool> start(GroupCall call) async => true;
  @override
  Future<void> update(GroupCall call) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setCameraEnabled(bool enabled) async =>
      cameraOperation?.call(enabled);
}
