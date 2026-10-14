import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_receive_activity.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';
import 'package:xveil/state/call_peer_audio_playout.dart';

void main() {
  final start = DateTime.utc(2026, 10, 5);
  const healthyNetwork = {
    'worker_stalled': 0,
    'audio_feedback_reports': 1,
    'rtt_ms': 80,
    'tx_loss_pct': 0,
    'tx_jitter_ms': 10,
    'tx_drops': 0,
  };

  test(
    'receiver reports its native six-sample trend at the unchanged heartbeat',
    () {
      final rx = CallAudioReceiveActivity();
      void sample(int second, int delay) => rx.observe({
        'audio_rx_pkts': 100 + second,
        'audio_rx_native_age_ms': 0,
        'worker_stalled': 0,
        'audio_delay_ms': delay,
      }, start.add(Duration(seconds: second)));
      final delays = [60, 60, 60, 80, 90, 100];
      for (var i = 0; i < delays.length; i++) {
        sample(i, delays[i]);
        if (i < 5) {
          expect(
            rx
                .outgoingPlayoutFeedback(start.add(Duration(seconds: i)))
                .toJson()['g'],
            isNull,
          );
        }
      }
      expect(
        rx
            .outgoingPlayoutFeedback(start.add(const Duration(seconds: 5)))
            .toJson()['g'],
        isTrue,
        reason:
            'two heartbeat samples must carry six actual receiver measurements',
      );
      for (var i = 6; i <= 8; i++) {
        sample(i, 100);
      }
      expect(
        rx
            .outgoingPlayoutFeedback(start.add(const Duration(seconds: 8)))
            .toJson()['g'],
        isFalse,
      );
      sample(15, 100);
      expect(
        rx
            .outgoingPlayoutFeedback(start.add(const Duration(seconds: 15)))
            .toJson()['g'],
        isNull,
        reason: 'a sampling gap cannot qualify the old native window',
      );
    },
  );

  test('native trend roundtrips only with an explicit current snapshot', () {
    for (final growing in [true, false]) {
      final report = CallAudioPlayoutFeedback.fromJson({
        'n': 6,
        'd': 120,
        'cd': 100,
        'g': growing,
      });
      expect(report, isNotNull);
      expect(report!.toJson()['g'], growing);
    }
    for (final raw in [
      {'n': 6, 'd': 120, 'g': true},
      {'n': 6, 'd': 120, 'cd': 100, 'g': 1},
      {'n': 6, 'd': 120, 'cd': 100, 'g': 'false'},
    ]) {
      expect(CallAudioPlayoutFeedback.fromJson(raw), isNull);
    }
    expect(
      CallAudioPlayoutFeedback.fromJson({
        'n': 6,
        'd': 120,
      })!.toJson().containsKey('g'),
      isFalse,
    );
  });

  test('native trend shares receipt expiry, replay and repair rules', () {
    final peer = CallPeerAudioPlayout();
    peer.observe(
      const CallAudioPlayoutFeedback(
        sequence: 6,
        delayMs: 120,
        currentDelayMs: 100,
        bufferGrowing: true,
      ),
      start,
    );
    peer.observe(
      const CallAudioPlayoutFeedback(
        sequence: 5,
        delayMs: 60,
        currentDelayMs: 60,
        bufferGrowing: false,
      ),
      start.add(const Duration(seconds: 10)),
    );
    expect(peer.bufferGrowing(start.add(const Duration(seconds: 11))), isTrue);
    expect(peer.bufferGrowing(start.add(const Duration(seconds: 13))), isNull);
    peer.invalidateMeasurement();
    expect(peer.bufferGrowing(start), isNull);
    peer.observe(
      const CallAudioPlayoutFeedback(
        sequence: 6,
        delayMs: 120,
        currentDelayMs: 100,
        bufferGrowing: true,
      ),
      start,
    );
    expect(
      peer.bufferGrowing(start),
      isNull,
      reason: 'repair cannot revive an old sequence',
    );
    peer.observe(
      const CallAudioPlayoutFeedback(
        sequence: 7,
        delayMs: 120,
        currentDelayMs: 100,
        bufferGrowing: false,
      ),
      start,
    );
    expect(peer.bufferGrowing(start), isFalse);
    peer.observe(
      const CallAudioPlayoutFeedback(sequence: 8, delayMs: 100),
      start,
    );
    expect(
      peer.bufferGrowing(start),
      isNull,
      reason: 'legacy has no native trend',
    );
  });

  test(
    'unmeasurable, repeated-time and repaired snapshots cannot retain a native trend',
    () {
      Map<String, Object?> stats(int delay) => {
        'audio_rx_pkts': 100,
        'audio_rx_native_age_ms': 0,
        'worker_stalled': 0,
        'audio_delay_ms': delay,
      };
      for (final kind in [
        'worker',
        'age',
        'delay',
        'same-time',
        'backwards',
        'repair',
      ]) {
        final rx = CallAudioReceiveActivity();
        for (var n = 0; n < 6; n++) {
          rx.observe(stats(60 + n * 10), start.add(Duration(seconds: n)));
        }
        expect(
          rx
              .outgoingPlayoutFeedback(start.add(const Duration(seconds: 5)))
              .toJson()['g'],
          isTrue,
        );
        var now = start.add(const Duration(seconds: 6));
        switch (kind) {
          case 'worker':
            rx.observe({...stats(100), 'worker_stalled': 1}, now);
          case 'age':
            rx.observe({...stats(100), 'audio_rx_native_age_ms': 4000}, now);
          case 'delay':
            rx.observe({...stats(100), 'audio_delay_ms': null}, now);
          case 'same-time':
            now = start.add(const Duration(seconds: 5));
            rx.observe(stats(100), now);
          case 'backwards':
            now = start.add(const Duration(seconds: 4));
            rx.observe(stats(100), now);
          case 'repair':
            rx.reset();
            rx.observe(stats(100), now);
        }
        expect(
          rx.outgoingPlayoutFeedback(now).toJson()['g'],
          isNull,
          reason: kind,
        );
      }
    },
  );

  test('two five-second native-window reports can reduce outgoing video', () {
    final rx = CallAudioReceiveActivity();
    final peer = CallPeerAudioPlayout();
    final adapter = CallBitrateAdapter(
      baseBitrateKbps: 900,
      initialLevel: 0,
      baseFps: 15,
      supportsLowRateVideo: true,
    );
    for (var n = 0; n <= 10; n++) {
      final now = start.add(Duration(seconds: n));
      rx.observe({
        'audio_rx_pkts': 100 + n,
        'audio_rx_native_age_ms': 0,
        'worker_stalled': 0,
        'audio_delay_ms': 60 + n * 8,
      }, now);
      if (n % 5 == 0) {
        final wire = CallSignal(
          callId: 'native-window',
          type: CallSignalType.health,
          audioPlayout: rx.outgoingPlayoutFeedback(now),
        ).encode();
        peer.observe(CallSignal.tryDecode(wire)!.audioPlayout!, now);
      }
      adapter.onSample(
        rttMs: 80,
        txJitterMs: 10,
        txLossPct: 0,
        txDrops: 0,
        peerAudioDelayMs: peer.delayMs(now),
        peerCurrentAudioDelayMs: peer.currentDelayMs(now),
        peerAudioSampleSequence: peer.sampleSequence,
        peerAudioBufferGrowing: peer.bufferGrowing(now),
        requirePeerAudioPlayout: true,
      );
      adapter.applyPendingTarget((_) => true);
      if (n < 10) {
        expect(
          adapter.level,
          0,
          reason: 'cached report is not another failure',
        );
      }
    }
    expect(
      adapter.level,
      2,
      reason:
          'two actual growing receiver windows, rather than six heartbeat values',
    );
  });

  test(
    'current playout is distinct from peak and shares its replay lifetime',
    () {
      final peer = CallPeerAudioPlayout();
      const report = CallAudioPlayoutFeedback(
        sequence: 8,
        delayMs: 209,
        currentDelayMs: 100,
        interruptionCount: 3,
      );
      final decoded = CallAudioPlayoutFeedback.fromJson(report.toJson())!;
      expect(decoded.currentDelayMs, 100);
      peer.observe(decoded, start);
      expect(peer.delayMs(start), 209);
      expect(peer.currentDelayMs(start), 100);
      expect(peer.sampleSequence, 8);
      peer.observe(
        const CallAudioPlayoutFeedback(
          sequence: 7,
          delayMs: 60,
          currentDelayMs: 60,
        ),
        start.add(const Duration(seconds: 10)),
      );
      expect(
        peer.currentDelayMs(start.add(const Duration(seconds: 13))),
        isNull,
      );
      peer.observe(
        const CallAudioPlayoutFeedback(sequence: 9, delayMs: 300),
        start,
      );
      expect(
        peer.currentDelayMs(start),
        300,
        reason: 'legacy feedback stays conservative',
      );
      peer.invalidateMeasurement();
      expect(peer.currentDelayMs(start), isNull);
      for (final invalid in [null, -1, 60001, 1.5, 210]) {
        if (invalid == null) {
          expect(CallAudioPlayoutFeedback.fromJson({'n': 1, 'cd': 10}), isNull);
        } else {
          expect(
            CallAudioPlayoutFeedback.fromJson({
              'n': 1,
              'd': 209,
              'cd': invalid,
            }),
            isNull,
          );
        }
      }
    },
  );

  test(
    'remote interruptions cannot be replayed or erased by older feedback',
    () {
      final peer = CallPeerAudioPlayout();
      void report(int sequence, int count) => peer.observe(
        CallAudioPlayoutFeedback(
          sequence: sequence,
          delayMs: 60,
          interruptionCount: count,
        ),
        start,
      );
      report(1, 30);
      expect(peer.takeInterruption(), isFalse);
      report(2, 31);
      report(3, 31); // A newer good sample cannot erase the pending outage.
      expect(peer.takeInterruption(), isTrue);
      expect(peer.takeInterruption(), isFalse);
      report(2, 100);
      expect(peer.takeInterruption(), isFalse);
      peer.invalidateMeasurement();
      report(4, 32);
      expect(peer.takeInterruption(), isTrue);
      final decoded = CallSignal.tryDecode(
        const CallSignal(
          callId: 'quality',
          type: CallSignalType.health,
          audioPlayout: CallAudioPlayoutFeedback(
            sequence: 5,
            delayMs: 60,
            interruptionCount: 33,
          ),
        ).encode(),
      )!;
      expect(decoded.audioPlayout!.interruptionCount, 33);
      expect(CallAudioPlayoutFeedback.fromJson({'n': 1, 'i': -1}), isNull);
      expect(CallAudioPlayoutFeedback.fromJson({'n': 1, 'i': 1.5}), isNull);
    },
  );

  test(
    'playout feedback survives stamping, fanout copying and wire decode',
    () {
      const signal = CallSignal(
        callId: 'audio-quality',
        type: CallSignalType.health,
        audioPlayout: CallAudioPlayoutFeedback(sequence: 17, delayMs: 540),
      );
      final back = CallSignal.tryDecode(
        signal.copyWith(sentAtMs: 100, onBehalfOf: 'sibling').encode(),
      )!;
      expect(back.audioPlayout!.sequence, 17);
      expect(back.audioPlayout!.delayMs, 540);
      expect(back.protocolVersion, kCallSignalProtocolVersion);
      expect(
        back.protocolVersion,
        greaterThanOrEqualTo(kCallAudioPlayoutFeedbackMinVersion),
      );
      final unknown = CallSignal.tryDecode(
        const CallSignal(
          callId: 'quality',
          type: CallSignalType.health,
          audioPlayout: CallAudioPlayoutFeedback(sequence: 18),
        ).encode(),
      )!;
      expect(unknown.audioPlayout!.delayMs, isNull);
      expect(
        CallSignal.tryDecode('{"c":"legacy","k":8,"v":4}')!.audioPlayout,
        isNull,
      );
    },
  );

  test(
    'malformed optional feedback does not discard a valid health signal',
    () {
      for (final raw in [
        true,
        {'n': -1},
        {'n': 1.5},
        {'n': '3'},
        {'n': 9007199254740992},
        {'n': 3, 'd': -1},
        {'n': 3, 'd': 60001},
        {'n': 3, 'd': 1.5},
        {'n': 3, 'd': 'healthy'},
      ]) {
        final signal = CallSignal.tryDecode(
          jsonEncode({'c': 'quality', 'k': 8, 'ap': raw}),
        );
        expect(signal, isNotNull);
        expect(signal!.audioPlayout, isNull);
      }
    },
  );

  test(
    'only recent accepted audio and a valid worker yield playout estimates',
    () {
      final rx = CallAudioReceiveActivity();
      rx.observe({
        'audio_rx_pkts': 10,
        'worker_stalled': 0,
        'audio_delay_ms': 540,
      }, start);
      expect(rx.playoutFeedback(start).delayMs, 540);
      expect(
        rx.playoutFeedback(start.add(const Duration(seconds: 4))).delayMs,
        isNull,
        reason: 'old native snapshot',
      );
      rx.observe({
        'audio_rx_pkts': 10,
        'worker_stalled': 0,
        'rx_pkts': 900,
        'audio_delay_ms': 0,
      }, start.add(const Duration(seconds: 4)));
      expect(
        rx.playoutFeedback(start.add(const Duration(seconds: 4))).delayMs,
        isNull,
        reason: 'video and RTCP cannot prove fresh audio',
      );
      rx.observe({
        'audio_rx_pkts': 11,
        'worker_stalled': 1,
        'audio_delay_ms': 0,
      }, start.add(const Duration(seconds: 5)));
      expect(
        rx.playoutFeedback(start.add(const Duration(seconds: 5))).delayMs,
        isNull,
        reason: 'timed-out worker defaults',
      );
      rx.observe({'audio_rx_pkts': 12, 'audio_delay_ms': 0}, start);
      expect(
        rx.playoutFeedback(start).delayMs,
        isNull,
        reason: 'legacy snapshot lacks successful worker evidence',
      );
    },
  );

  test(
    'receive repair invalidates delay but never reuses a sample sequence',
    () {
      final rx = CallAudioReceiveActivity();
      rx.observe({
        'audio_rx_pkts': 999,
        'worker_stalled': 0,
        'audio_delay_ms': 120,
      }, start);
      final before = rx.playoutFeedback(start);
      rx.reset();
      final reset = rx.playoutFeedback(start);
      expect(reset.sequence, greaterThan(before.sequence));
      expect(reset.delayMs, isNull);
      rx.observe({
        'audio_rx_pkts': 1,
        'worker_stalled': 0,
        'audio_delay_ms': 140,
      }, start);
      expect(rx.playoutFeedback(start).sequence, greaterThan(reset.sequence));
      expect(rx.playoutFeedback(start).delayMs, 140);
    },
  );

  test(
    'old and replayed healthy frames cannot refresh or replace bad audio',
    () {
      final peer = CallPeerAudioPlayout();
      const healthy = CallAudioPlayoutFeedback(sequence: 5, delayMs: 100);
      peer.observe(healthy, start);
      peer.observe(healthy, start.add(const Duration(seconds: 10)));
      expect(peer.delayMs(start.add(const Duration(seconds: 13))), isNull);
      peer.observe(
        const CallAudioPlayoutFeedback(sequence: 6, delayMs: 540),
        start,
      );
      peer.observe(healthy, start);
      expect(peer.delayMs(start), 540);
      peer.observe(const CallAudioPlayoutFeedback(sequence: 7), start);
      peer.observe(
        const CallAudioPlayoutFeedback(sequence: 6, delayMs: 100),
        start,
      );
      expect(peer.delayMs(start), isNull);
      peer.invalidateMeasurement();
      peer.observe(
        const CallAudioPlayoutFeedback(sequence: 7, delayMs: 100),
        start,
      );
      expect(peer.delayMs(start), isNull);
      peer.observe(
        const CallAudioPlayoutFeedback(sequence: 8, delayMs: 100),
        start,
      );
      expect(peer.delayMs(start), 100);
    },
  );

  test(
    'slow receiver audio reduces actual video target despite clean RTCP',
    () {
      for (final base in [900, 150]) {
        final adapter = CallBitrateAdapter(
          baseBitrateKbps: base,
          baseFps: base == 900 ? 60 : 15,
          initialLevel: 0,
        );
        var native = adapter.target;
        for (var i = 0; i < 10; i++) {
          adapter.onNativeStats(
            healthyNetwork,
            peerAudioDelayMs: 540,
            requirePeerAudioPlayout: true,
          );
          adapter.applyPendingTarget((target) {
            native = target;
            return true;
          });
        }
        expect(adapter.atFloor, isTrue);
        expect(adapter.audioReserve, isTrue);
        expect(native.maxFps, 0.02);
        expect(native.maxBitrateKbps, 1);
        for (var i = 0; i < 12; i++) {
          adapter.onNativeStats(
            healthyNetwork,
            peerAudioDelayMs: 170,
            requirePeerAudioPlayout: true,
          );
        }
        expect(
          adapter.atFloor,
          isTrue,
          reason: 'marginal audio cannot grow video',
        );
        for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
          adapter.onNativeStats(
            healthyNetwork,
            peerAudioDelayMs: 80,
            requirePeerAudioPlayout: true,
          );
        }
        expect(adapter.audioReserve, isFalse);
        expect(adapter.atFloor, isTrue);
        for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
          adapter.onNativeStats(
            healthyNetwork,
            peerAudioDelayMs: 80,
            requirePeerAudioPlayout: true,
          );
        }
        expect(adapter.level, CallBitrateAdapter.ladder.length - 2);
      }
    },
  );

  test('stale playout holds earned video and never earns recovery', () {
    final adapter = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      initialLevel: 3,
    );
    final peer = CallPeerAudioPlayout();
    peer.observe(
      const CallAudioPlayoutFeedback(sequence: 1, delayMs: 80),
      start,
    );
    for (var i = 0; i < 30; i++) {
      final now = start.add(Duration(seconds: 13 + i));
      peer.observe(
        const CallAudioPlayoutFeedback(sequence: 1, delayMs: 80),
        now,
      );
      adapter.onNativeStats(
        healthyNetwork,
        peerAudioDelayMs: peer.delayMs(now),
        requirePeerAudioPlayout: true,
      );
    }
    expect(adapter.level, 3);
    expect(
      adapter.videoAdvice,
      CallVideoAdvice.keep,
      reason: 'unknown quality alone must not generate a failing-link prompt',
    );
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      adapter.onNativeStats(
        healthyNetwork,
        peerAudioDelayMs: 80,
        requirePeerAudioPlayout: true,
      );
    }
    adapter.onNativeStats(healthyNetwork, requirePeerAudioPlayout: true);
    adapter.onNativeStats(
      healthyNetwork,
      peerAudioDelayMs: 80,
      requirePeerAudioPlayout: true,
    );
    expect(adapter.level, 3, reason: 'unknown breaks recovery streak');
  });

  test('bad playout trials the one-fps floor before pausing without RTCP', () {
    final adapter = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      initialLevel: 0,
    );
    for (var i = 0; i < 6; i++) {
      adapter.applyPendingTarget((_) => true);
      adapter.onNativeStats(
        {'audio_feedback_reports': 0},
        peerAudioDelayMs: 540,
        requirePeerAudioPlayout: true,
      );
      if (i == 3) {
        expect(adapter.target.maxFps, 1);
        expect(adapter.audioReserve, isFalse);
      }
    }
    bool? nativePause;
    adapter.applyPendingPause((paused) {
      nativePause = paused;
      return true;
    });
    expect(nativePause, isTrue);
    expect(adapter.target.maxBitrateKbps, 1);
    for (var i = 0; i < 30; i++) {
      adapter.onNativeStats(
        {'audio_feedback_reports': 0},
        peerAudioDelayMs: 80,
        requirePeerAudioPlayout: true,
      );
    }
    expect(
      adapter.audioReserve,
      isTrue,
      reason: 'playout alone cannot prove healthy network',
    );
    expect(
      adapter.applyPendingPause((paused) {
        nativePause = paused;
        return true;
      }),
      isNull,
    );
    expect(nativePause, isTrue);
  });

  test('legacy peers and a deliberately muted sender retain RTCP behavior', () {
    for (final delay in [null, 540]) {
      final adapter = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        adapter.onNativeStats(healthyNetwork, peerAudioDelayMs: delay);
      }
      expect(adapter.level, CallBitrateAdapter.ladder.length - 2);
    }
  });
}
