import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/state/call_audio_receive_activity.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';
import 'package:xveil/state/call_peer_audio_playout.dart';
import 'package:xveil/state/call_peer_audio_recovery.dart';

void main() {
  Map<String, dynamic> report(int stamp, int origin, int ms) => {
    'audio_peer_recovery_report_us': stamp,
    'audio_peer_recovery_origin': origin,
    'audio_peer_recovery_discarded_ms': ms,
  };
  bool observe(
    CallPeerAudioRecovery r,
    Map<String, dynamic> stats, {
    CallAudioRecoveryIdentity? health,
    bool recovered = false,
    bool expected = true,
  }) => r.observe(
    stats: stats,
    healthIdentity: health,
    healthRecovered: recovered,
    expected: expected,
  );

  for (final healthFirst in [false, true]) {
    test('same decoded loss counts once, healthFirst=$healthFirst', () {
      final r = CallPeerAudioRecovery();
      final health = (origin: 7, discardedMs: 20);
      expect(
        observe(
          r,
          healthFirst ? {} : report(100, 7, 20),
          health: healthFirst ? health : null,
          recovered: healthFirst,
        ),
        isTrue,
      );
      expect(
        observe(r, report(100, 7, 20), health: health, recovered: !healthFirst),
        isFalse,
      );
      expect(observe(r, report(100, 7, 20)), isFalse);
      // A genuinely new loss must not disappear behind deduplication.
      expect(observe(r, report(200, 7, 40)), isTrue);
      expect(
        observe(
          r,
          report(200, 7, 40),
          health: (origin: 7, discardedMs: 40),
          recovered: true,
        ),
        isFalse,
      );
    });
  }

  test('new decoder has its own counter; retired decoder cannot replay', () {
    final r = CallPeerAudioRecovery();
    expect(observe(r, report(100, 7, 500)), isTrue);
    expect(observe(r, report(200, 8, 10)), isTrue);
    expect(
      observe(
        r,
        report(300, 7, 1000),
        health: (origin: 7, discardedMs: 1000),
        recovered: true,
      ),
      isFalse,
    );
    expect(observe(r, report(400, 8, 20)), isTrue);
  });

  test('mute consumes both paths without replaying them after unmute', () {
    final r = CallPeerAudioRecovery();
    expect(
      observe(
        r,
        report(100, 7, 20),
        health: (origin: 7, discardedMs: 20),
        recovered: true,
        expected: false,
      ),
      isFalse,
    );
    expect(
      observe(
        r,
        report(100, 7, 20),
        health: (origin: 7, discardedMs: 20),
        recovered: true,
      ),
      isFalse,
    );
    expect(observe(r, report(200, 7, 40)), isTrue);
  });

  test('stale native counter cannot become a new health loss later', () {
    final r = CallPeerAudioRecovery();
    expect(observe(r, report(0, 7, 20)), isFalse);
    expect(
      observe(
        r,
        report(0, 7, 20),
        health: (origin: 7, discardedMs: 20),
        recovered: true,
      ),
      isFalse,
    );
    expect(observe(r, report(100, 7, 40)), isTrue);
  });

  test('health baseline does not consume a future fresh native witness', () {
    final r = CallPeerAudioRecovery();
    expect(observe(r, {}, health: (origin: 7, discardedMs: 20)), isFalse);
    expect(observe(r, report(100, 7, 20)), isTrue);
  });

  test(
    'delayed pending health event keeps its identity across unknown samples',
    () {
      final peer = CallPeerAudioPlayout();
      final now = DateTime(2026);
      peer.observe(
        const CallAudioPlayoutFeedback(
          sequence: 1,
          delayMs: 80,
          interruptionCount: 0,
          recoveryCount: 0,
          recoveryOrigin: 7,
          recoveryDiscardedMs: 0,
        ),
        now,
      );
      peer.observe(
        const CallAudioPlayoutFeedback(
          sequence: 2,
          delayMs: 80,
          interruptionCount: 1,
          recoveryCount: 1,
          recoveryOrigin: 7,
          recoveryDiscardedMs: 20,
        ),
        now,
      );
      peer.observe(const CallAudioPlayoutFeedback(sequence: 3), now);
      final later = now.add(const Duration(seconds: 20));
      expect(peer.delayMs(later), isNull);
      final recovery = CallPeerAudioRecovery();
      expect(observe(recovery, report(100, 7, 20)), isTrue);
      expect(
        observe(
          recovery,
          report(100, 7, 20),
          health: peer.recoveryIdentity(later),
          recovered: peer.takeRecovery(),
        ),
        isFalse,
      );
    },
  );

  test('legacy witnesses remain usable without canonical identities', () {
    final r = CallPeerAudioRecovery();
    expect(observe(r, {'audio_peer_recovery_report_us': 100}), isTrue);
    expect(observe(r, {'audio_peer_recovery_report_us': 100}), isFalse);
    expect(observe(r, {}, recovered: true), isTrue);
  });

  test('wire validates identity pair and preserves legacy feedback', () {
    expect(CallAudioPlayoutFeedback.fromJson({'n': 1}), isNotNull);
    for (final bad in [
      {'ro': 1},
      {'rd': 10},
      {'ro': 0, 'rd': 10},
      {'ro': 1, 'rd': -1},
      {'ro': '1', 'rd': 10},
      {'ro': 9007199254740992, 'rd': 10},
    ]) {
      expect(CallAudioPlayoutFeedback.fromJson({'n': 1, ...bad}), isNull);
    }
  });

  test(
    'health uses the decoder identity when aggregate counters race a sample',
    () {
      final peer = CallPeerAudioPlayout();
      final now = DateTime(2026);
      void sample(int sequence, int count, int ms) => peer.observe(
        CallAudioPlayoutFeedback(
          sequence: sequence,
          delayMs: 80,
          interruptionCount: count,
          recoveryCount: count,
          recoveryOrigin: 7,
          recoveryDiscardedMs: ms,
        ),
        now,
      );
      sample(1, 0, 0);
      sample(2, 1, 0); // Aggregate counter advanced after the stream snapshot.
      expect(peer.takeRecovery(), isFalse);
      sample(3, 1, 20); // The actual event identity follows on the next sample.
      expect(peer.takeRecovery(), isTrue);
      sample(4, 1, 20);
      expect(peer.takeRecovery(), isFalse);
    },
  );

  test(
    'real receive/health/RTCP paths cannot falsely fail the sparse floor',
    () {
      final now = DateTime(2026);
      final receiver = CallAudioReceiveActivity();
      final peer = CallPeerAudioPlayout();
      final recovery = CallPeerAudioRecovery();
      final adapter = CallBitrateAdapter(
        baseBitrateKbps: 160,
        baseFps: 50,
        initialLevel: 4,
        supportsLowRateVideo: true,
      );
      Map<String, dynamic> healthy(int frame) => {
        'worker_stalled': 0,
        'video_worker_stalled': 0,
        'audio_feedback_reports': 1,
        'video_feedback_reports': 1,
        'rtt_ms': 200,
        'tx_jitter_ms': 5,
        'tx_loss_pct': 0,
        'audio_rx_pkts': frame * 50,
        'audio_rx_native_age_ms': 10,
        'audio_delay_ms': 80,
        'tx_drops': 0,
        'audio_tx_rtp_drops': 0,
        'video_tx_rtp_drops': 0,
        'video_tx_frames': frame,
      };
      void health(int tick, int count, int ms) {
        final at = now.add(Duration(seconds: tick));
        receiver.observe({
          ...healthy(tick),
          'audio_interruption_count': 0,
          'audio_latency_recovery_count': count,
          'audio_receiver_recovery_origin': 7,
          'audio_receiver_recovery_discarded_ms': ms,
        }, at);
        final wire = receiver.outgoingPlayoutFeedback(at).toJson();
        peer.observe(CallAudioPlayoutFeedback.fromJson(wire)!, at);
      }

      void poll(int tick, int stamp, int ms) {
        final at = now.add(Duration(seconds: tick));
        final stats = {...healthy(tick), ...report(stamp, 7, ms)};
        final fresh = recovery.observe(
          stats: stats,
          healthIdentity: peer.recoveryIdentity(at),
          healthRecovered: peer.takeRecovery(),
          expected: true,
        );
        adapter.applyPendingTarget((_) => true);
        adapter.applyPendingPause((_) => true);
        adapter.onNativeStats(
          stats,
          videoSendExpected: true,
          sendAudioExpected: true,
          receiveAudioExpected: true,
          requireAudioReceivePlayout: true,
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: 90,
          peerCurrentAudioDelayMs: 80,
          peerTargetAudioDelayMs: 60,
          peerAudioSampleSequence: tick,
          peerRecoveryObserved: fresh,
        );
      }

      health(1, 0, 0);
      for (var i = 1; i <= 5; ++i) {
        poll(i, 0, 0);
      }
      poll(6, 100, 20); // RTCP arrives first.
      health(7, 1, 20); // Same event later arrives over authenticated health.
      poll(7, 100, 20);
      expect(
        adapter.audioReserve,
        isFalse,
        reason: 'one real event cannot satisfy the two-loss floor gate',
      );
      poll(8, 200, 40); // A genuinely separate new event.
      poll(9, 300, 60); // Repeated real loss still protects audio.
      expect(adapter.audioReserve, isTrue);
    },
  );
}
