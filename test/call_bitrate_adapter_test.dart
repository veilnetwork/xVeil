import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  final badSamplesToFloor =
      (CallBitrateAdapter.ladder.length - 1) * CallBitrateAdapter.degradeAfter;

  CallBitrateAdapter direct() =>
      CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60, initialLevel: 0);

  ({int maxBitrateKbps, double maxFps})? good(CallBitrateAdapter a) =>
      a.onSample(rttMs: 80, txJitterMs: 10, txLossPct: 0, txDrops: 0);

  ({int maxBitrateKbps, double maxFps})? lossy(CallBitrateAdapter a) =>
      a.onSample(rttMs: 80, txJitterMs: 10, txLossPct: 12, txDrops: 0);

  Map<String, Object> healthyDrops(int aggregate, {int? audio}) => {
    'worker_stalled': 0,
    'audio_feedback_reports': 1,
    'video_feedback_reports': 1,
    'video_feedback_rtt_ms': 80,
    'video_feedback_jitter_ms': 10,
    'rtt_ms': 80,
    'tx_jitter_ms': 10,
    'tx_loss_pct': 0,
    'audio_rx_pkts': 100,
    'audio_rx_native_age_ms': 10,
    'audio_delay_ms': 60,
    'tx_drops': aggregate,
    'audio_tx_rtp_drops': ?audio,
  };

  test('secondary drops allow only a sparse probe after audio recovery', () {
    final a = direct();
    a.prepareVideoSend(
      const {},
      requireAudioReceivePlayout: true,
      receiveAudioExpected: true,
      requirePeerAudioPlayout: true,
    );
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter * 2; i++) {
      a.onNativeStats(
        healthyDrops(i * 20, audio: 0),
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 60,
      );
    }
    expect(a.audioReserve, isFalse);
    expect(a.atFloor, isTrue, reason: 'aggregate losses still forbid growth');
  });

  test('audio recovery probe requires consecutive fresh measurements', () {
    final a = direct();
    a.prepareVideoSend(const {}, requirePeerAudioPlayout: true);
    void sample(Map<String, Object> stats) => a.onNativeStats(
      stats,
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 60,
    );
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      sample(healthyDrops(i * 20, audio: 0));
    }
    sample({...healthyDrops(300, audio: 0), 'audio_feedback_reports': 0});
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      sample(healthyDrops(400 + i * 20, audio: 0));
    }
    expect(a.audioReserve, isTrue);
    sample(healthyDrops(800, audio: 0));
    expect(a.audioReserve, isFalse);
    expect(a.atFloor, isTrue);
  });

  test('secondary losses still reduce video with a clean primary counter', () {
    final a = direct();
    a.onNativeStats(healthyDrops(0, audio: 0));
    for (var i = 1; i <= CallBitrateAdapter.degradeAfter; i++) {
      a.onNativeStats(healthyDrops(i, audio: 0));
    }
    expect(a.level, 1);
  });

  test('actual primary RTP failures still reduce video', () {
    final a = direct();
    a.onNativeStats(healthyDrops(100, audio: 0));
    for (var i = 1; i <= CallBitrateAdapter.degradeAfter; i++) {
      a.onNativeStats(healthyDrops(100, audio: i));
    }
    expect(a.level, 1);
  });

  test('missing or invalid primary counter retains conservative fallback', () {
    for (final audio in [null, -1]) {
      final a = direct();
      a.onNativeStats(healthyDrops(0, audio: audio));
      for (var i = 1; i <= CallBitrateAdapter.degradeAfter; i++) {
        a.onNativeStats(healthyDrops(i, audio: audio));
      }
      expect(a.level, 1);
    }
  });

  test('switching counter domains does not treat old losses as new', () {
    final a = direct();
    a.onNativeStats(healthyDrops(100, audio: 0));
    a.onNativeStats(healthyDrops(100, audio: 0), sendAudioExpected: false);
    a.onNativeStats(healthyDrops(100, audio: 0), sendAudioExpected: false);
    expect(a.level, 0);
    for (var i = 1; i <= CallBitrateAdapter.degradeAfter; i++) {
      a.onNativeStats(
        healthyDrops(100 + i, audio: 0),
        sendAudioExpected: false,
      );
    }
    expect(
      a.level,
      1,
      reason: 'video-only sending still uses aggregate losses',
    );
  });

  test('intentional silence releases an already measured audio hold', () {
    final a = direct();
    a.onSample(
      rttMs: 80,
      txJitterMs: 10,
      txLossPct: 0,
      txDrops: 0,
      audioInterrupted: true,
    );
    expect(a.audioReserve, isTrue);
    // Both endpoints explicitly muted: missing audio reports are expected.
    for (var i = 0; i < 20; i++) {
      a.onNativeStats(
        {'audio_feedback_reports': 0},
        sendAudioExpected: false,
        receiveAudioExpected: false,
        requirePeerAudioPlayout: false,
      );
    }
    expect(a.audioReserve, isFalse);
    expect(a.atFloor, isTrue, reason: 'unknown video has only earned a probe');
  });

  test('muted sender recovers a probe only after healthy incoming playout', () {
    final a = direct();
    a.onSample(
      rttMs: 80,
      txJitterMs: 0,
      txLossPct: 0,
      txDrops: 0,
      audioInterrupted: true,
    );
    void sample(int? delay, {bool interrupted = false, int videoReports = 0}) =>
        a.onNativeStats(
          {
            'worker_stalled': 0,
            'video_worker_stalled': 0,
            'audio_rx_pkts': 100,
            'audio_rx_native_age_ms': 20,
            'audio_delay_ms': ?delay,
            'video_feedback_reports': videoReports,
            'video_feedback_rtt_ms': 80,
            'video_feedback_jitter_ms': 10,
          },
          sendAudioExpected: false,
          receiveAudioExpected: true,
          requireAudioReceivePlayout: true,
          audioInterrupted: interrupted,
        );
    // Fresh packets and even video reports cannot hide buffered audio.
    for (var i = 0; i < 20; i++) {
      sample(500, videoReports: 1);
    }
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < 20; i++) {
      sample(null, videoReports: 1);
    }
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      sample(100);
    }
    sample(100, interrupted: true);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      sample(100);
    }
    expect(a.audioReserve, isTrue);
    sample(100);
    expect(a.audioReserve, isFalse);
    expect(a.atFloor, isTrue);
    for (var i = 0; i < 30; i++) {
      sample(100);
    }
    expect(a.atFloor, isTrue, reason: 'no video report has earned growth');
    for (var i = 0; i < CallBitrateAdapter.recoverAfter * 4; i++) {
      sample(100, videoReports: 1);
    }
    expect(a.level, 0);
  });

  test('video reports never stand in for expected outgoing audio', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    for (var i = 0; i < 60; i++) {
      a.onNativeStats({
        'audio_feedback_reports': 0,
        'video_feedback_reports': 1,
        'video_feedback_rtt_ms': 80,
        'video_feedback_jitter_ms': 10,
      });
    }
    expect(a.atFloor, isTrue);
  });

  test('muted room needs video reports from every receiver to grow', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 150, baseFps: 15);
    void sample(int reports) => a.onNativeStats(
      {
        'video_feedback_reports': reports,
        'video_feedback_rtt_ms': 80,
        'video_feedback_jitter_ms': 10,
      },
      sendAudioExpected: false,
      expectedVideoFeedbackReports: 2,
    );
    for (var i = 0; i < 60; i++) {
      sample(1);
    }
    expect(a.atFloor, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter * 4; i++) {
      sample(2);
    }
    expect(a.level, 0);
  });

  test(
    'decoded audio interruptions pause video despite fresh RTP and low delay',
    () {
      final a = direct();
      void sample({bool interrupted = false}) => a.onNativeStats(
        {
          'worker_stalled': 0,
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_rx_pkts': 100,
          'audio_rx_native_age_ms': 10,
        },
        receiveAudioExpected: true,
        peerAudioDelayMs: 60,
        requirePeerAudioPlayout: true,
        audioInterrupted: interrupted,
      );
      sample();
      expect(a.audioReserve, isFalse);
      sample(interrupted: true);
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; ++i) {
        sample();
      }
      expect(a.audioReserve, isTrue);
      sample(interrupted: true); // Another outage restarts recovery.
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; ++i) {
        sample();
      }
      expect(a.audioReserve, isTrue);
      sample();
      expect(a.audioReserve, isFalse);
    },
  );

  test(
    'video admission waits for expected incoming audio before its first frame',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
      a.prepareVideoSend({
        'audio_rx_pkts': 0,
        'audio_rx_native_age_ms': -1,
      }, receiveAudioExpected: true);
      expect(a.audioReserve, isTrue);
      final pauses = <bool>[];
      a.applyPendingPause((value) {
        pauses.add(value);
        return true;
      });
      expect(pauses, [true]);
      for (var i = 0; i < 20; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_rx_pkts': 0,
          'audio_rx_native_age_ms': -1,
        }, receiveAudioExpected: true);
      }
      expect(a.audioReserve, isTrue);
      // A timeout cannot erase a capability that the engine already reported.
      for (var i = 0; i < 20; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'worker_stalled': 1,
        }, receiveAudioExpected: true);
      }
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_rx_pkts': i + 1,
          'audio_rx_native_age_ms': 100,
        }, receiveAudioExpected: true);
      }
      expect(a.audioReserve, isTrue);
      a.onNativeStats({
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'audio_rx_pkts': 30,
        'audio_rx_native_age_ms': 100,
      }, receiveAudioExpected: true);
      expect(a.audioReserve, isFalse);
    },
  );

  test(
    'standing receive delay holds video before exhausting the PCM budget',
    () {
      final a = CallBitrateAdapter(
        baseBitrateKbps: 900,
        baseFps: 15,
        initialLevel: 0,
      );
      a.onSample(
        rttMs: 80,
        txJitterMs: 0,
        txLossPct: 0,
        txDrops: 0,
        requireAudioReceive: true,
        audioReceiveAgeMs: 20,
        requireAudioReceivePlayout: true,
        audioReceiveDelayMs: 180,
      );
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < 20; i++) {
        a.onSample(
          rttMs: 80,
          txJitterMs: 0,
          txLossPct: 0,
          txDrops: 0,
          requireAudioReceive: true,
          audioReceiveAgeMs: 20,
          requireAudioReceivePlayout: true,
          audioReceiveDelayMs: 140,
        );
      }
      expect(
        a.audioReserve,
        isTrue,
        reason: 'a draining buffer has not earned video recovery',
      );
    },
  );

  test('fresh peer playout pressure stops an already earned video budget', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 15,
      initialLevel: 0,
    );
    a.onSample(
      rttMs: 80,
      txJitterMs: 0,
      txLossPct: 0,
      txDrops: 0,
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 180,
    );
    expect(a.audioReserve, isTrue);
    expect(a.target, (maxBitrateKbps: 1, maxFps: 0.02));
  });

  test('video mount respects poor or unknown remote audio playout', () {
    for (final delay in <int?>[null, 450]) {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
      a.prepareVideoSend(
        {'audio_rx_pkts': 100, 'audio_rx_native_age_ms': 100},
        receiveAudioExpected: true,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: delay,
      );
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        a.onNativeStats(
          {
            'audio_feedback_reports': 1,
            'rtt_ms': 80,
            'audio_rx_pkts': 100 + i,
            'audio_rx_native_age_ms': 100,
          },
          receiveAudioExpected: true,
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: 100,
        );
      }
      expect(a.audioReserve, isFalse);
    }
  });

  test('healthy DTX and video without expected audio mount without a hold', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    a.prepareVideoSend(
      {'audio_rx_pkts': 100, 'audio_rx_native_age_ms': 400},
      receiveAudioExpected: true,
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 100,
    );
    expect(a.audioReserve, isFalse);
    a.prepareVideoSend({'audio_rx_pkts': 0, 'audio_rx_native_age_ms': -1});
    expect(a.audioReserve, isFalse);
    final legacy = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      supportsLowRateVideo: false,
    );
    legacy.prepareVideoSend({
      'audio_rx_pkts': 0,
      'audio_rx_native_age_ms': -1,
    }, receiveAudioExpected: true);
    expect(legacy.audioReserve, isFalse);
  });

  test(
    'intentional mute can release an initial hold without invented feedback',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
      a.prepareVideoSend({
        'audio_rx_pkts': 0,
        'audio_rx_native_age_ms': -1,
      }, receiveAudioExpected: true);
      expect(a.audioReserve, isTrue);
      a.onNativeStats(
        {'audio_feedback_reports': 0, 'worker_stalled': 0},
        sendAudioExpected: false,
        receiveAudioExpected: false,
      );
      expect(a.audioReserve, isFalse);
    },
  );

  test('the sparse floor stops after two measured 450-ms audio samples', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    for (var i = 0; i < CallBitrateAdapter.degradeAfter; i++) {
      a.onSample(
        rttMs: 80,
        txJitterMs: 0,
        txLossPct: 0,
        txDrops: 0,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 450,
      );
    }
    expect(a.audioReserve, isTrue);
    expect(a.target, (maxBitrateKbps: 1, maxFps: 0.02));
  });

  test('a rebuilt native engine must reapply the existing audio pause', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    a.prepareVideoSend({
      'audio_rx_pkts': 0,
      'audio_rx_native_age_ms': -1,
    }, receiveAudioExpected: true);
    final firstEngine = <bool>[];
    a.applyPendingPause((paused) {
      firstEngine.add(paused);
      return true;
    });
    expect(firstEngine, [true]);
    a.invalidateAppliedState();
    final replacement = <bool>[];
    a.applyPendingPause((paused) {
      replacement.add(paused);
      return true;
    });
    expect(replacement, [true]);
    expect(a.audioReserve, isTrue);
  });

  test('lost live audio measurements pause full video until recovery', () {
    for (final missing in [
      <String, dynamic>{},
      {'worker_stalled': 1, 'audio_rx_native_age_ms': 100},
      {'audio_rx_pkts': 0, 'audio_rx_native_age_ms': -1},
    ]) {
      final a = direct();
      final healthy = <String, dynamic>{
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'audio_rx_pkts': 100,
        'audio_rx_native_age_ms': 100,
      };
      a.onNativeStats(healthy, receiveAudioExpected: true);
      expect(a.audioReserve, isFalse);
      a.onNativeStats(missing, receiveAudioExpected: true);
      expect(
        a.audioReserve,
        isTrue,
        reason: 'a missing sample cannot keep sending full video',
      );
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        a.onNativeStats(healthy, receiveAudioExpected: true);
      }
      expect(a.audioReserve, isTrue);
      a.onNativeStats(healthy, receiveAudioExpected: true);
      expect(a.audioReserve, isFalse);
      expect(a.level, 0);
    }
  });

  test('expired capable peer playout pauses video without false advice', () {
    final a = direct();
    final healthy = <String, dynamic>{
      'audio_feedback_reports': 1,
      'rtt_ms': 80,
    };
    a.onNativeStats(
      healthy,
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 100,
    );
    expect(a.audioReserve, isFalse);
    a.onNativeStats(healthy, requirePeerAudioPlayout: true);
    expect(a.audioReserve, isTrue);
    expect(a.videoAdvice, CallVideoAdvice.keep);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      a.onNativeStats(
        healthy,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 100,
      );
    }
    expect(a.audioReserve, isTrue);
    a.onNativeStats(
      healthy,
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 100,
    );
    expect(a.audioReserve, isFalse);
  });

  test('an RTP outage pauses video before remote delay feedback arrives', () {
    final a = direct();
    a.onNativeStats({
      'audio_feedback_reports': 1,
      'rtt_ms': 1844,
      'tx_jitter_ms': 129,
      'tx_loss_pct': 3,
      'audio_rx_pkts': 100,
      'audio_rx_native_age_ms': 4456,
    }, receiveAudioExpected: true);
    expect(a.audioReserve, isTrue);
    final pauses = <bool>[];
    a.applyPendingPause((value) {
      pauses.add(value);
      return true;
    });
    expect(pauses, [true]);
    // A healthy last RTT is not proof that incoming audio returned.
    for (var i = 0; i < 20; i++) {
      a.onNativeStats({
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'audio_rx_pkts': 100,
        'audio_rx_native_age_ms': 2000,
      }, receiveAudioExpected: true);
    }
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      a.onNativeStats({
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'audio_rx_pkts': 101 + i,
        'audio_rx_native_age_ms': 100,
      }, receiveAudioExpected: true);
    }
    expect(a.audioReserve, isFalse);
  });

  test('DTX, a muted peer and legacy telemetry do not claim an RTP outage', () {
    for (final age in [0, 400, 499]) {
      final a = direct();
      for (var i = 0; i < 20; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'audio_rx_pkts': 100,
          'audio_rx_native_age_ms': age,
        }, receiveAudioExpected: true);
      }
      expect(a.audioReserve, isFalse);
    }
    final muted = direct();
    for (var i = 0; i < 20; i++) {
      muted.onNativeStats({
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'audio_rx_pkts': 100,
        'audio_rx_native_age_ms': 10000,
      }, receiveAudioExpected: false);
    }
    expect(muted.audioReserve, isFalse);
    final legacy = direct();
    legacy.onNativeStats({
      'audio_feedback_reports': 1,
      'rtt_ms': 80,
    }, receiveAudioExpected: true);
    expect(legacy.audioReserve, isFalse);
    final unknown = direct();
    unknown.onNativeStats({
      'audio_feedback_reports': 0,
      'audio_rx_pkts': 0,
      'audio_rx_native_age_ms': -1,
    }, receiveAudioExpected: true);
    expect(unknown.audioReserve, isTrue);
    expect(unknown.videoAdvice, CallVideoAdvice.keep);
  });

  test('video pause retries a busy resume and survives unknown feedback', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    final pauses = <bool>[];
    bool apply(bool paused) {
      pauses.add(paused);
      return true;
    }

    expect(a.applyPendingPause(apply), isTrue);
    for (var i = 0; i < 2; i++) {
      a.onSample(rttMs: 8500, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.applyPendingPause(apply), isTrue);
    expect(pauses, [false, true]);
    for (var i = 0; i < 20; i++) {
      a.onNativeStats({'audio_feedback_reports': 0});
      expect(a.applyPendingPause(apply), isNull);
    }
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      good(a);
    }
    expect(a.applyPendingPause((_) => false), isFalse);
    expect(a.applyPendingPause(apply), isTrue);
    expect(pauses, [false, true, false]);
    expect(a.applyPendingPause(apply), isNull);
  });

  test('new calls reserve bandwidth for audio before feedback arrives', () {
    for (final base in [900, 150]) {
      final a = CallBitrateAdapter(
        baseBitrateKbps: base,
        baseFps: base == 900 ? 60 : 15,
      );
      final initial = a.target;
      expect(initial.maxBitrateKbps, base == 900 ? 45 : 8);
      expect(initial.maxFps, base == 900 ? 1.2 : 0.3);
      for (var i = 0; i < 60; i++) {
        a.onNativeStats({'audio_feedback_reports': 0});
      }
      expect(a.target, initial);
      // Even a report with default/unknown RTT cannot earn more bandwidth.
      for (var i = 0; i < 60; i++) {
        a.onNativeStats({'audio_feedback_reports': 1, 'rtt_ms': 0});
      }
      expect(a.target, initial);
    }
  });

  test('multi-second queues release the ordinary video floor for audio', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    final ordinaryFloor = a.target;
    expect(
      a.onSample(rttMs: 8500, txJitterMs: 10, txLossPct: 0, txDrops: 0),
      isNull,
    );
    expect(a.target, ordinaryFloor);
    expect(a.onSample(rttMs: 8500, txJitterMs: 10, txLossPct: 0, txDrops: 0), (
      maxBitrateKbps: 1,
      maxFps: 0.02,
    ));
    expect(a.audioReserve, isTrue);
    // A lost/expired report is not evidence that the ordered queue drained.
    for (var i = 0; i < 60; i++) {
      a.onNativeStats({'audio_feedback_reports': 0, 'rtt_ms': 0});
    }
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      good(a);
      expect(a.audioReserve, isTrue);
    }
    expect(good(a), ordinaryFloor);
    expect(a.audioReserve, isFalse);
    expect(
      a.atFloor,
      isTrue,
      reason: 'recovery first restores only the sparse floor',
    );
  });

  test(
    'confirmed remote playout can release video but unknown playout cannot',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 150, baseFps: 15);
      for (var i = 0; i < 20; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 0,
        }, requirePeerAudioPlayout: true);
      }
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.degradeAfter; i++) {
        a.onSample(
          rttMs: 80,
          txJitterMs: 10,
          txLossPct: 0,
          txDrops: 0,
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: 1500,
        );
      }
      expect(a.audioReserve, isTrue);
      expect(a.target, (maxBitrateKbps: 1, maxFps: 0.02));
    },
  );

  test('older native cannot pretend to apply a fractional reserve', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      supportsLowRateVideo: false,
    );
    for (var i = 0; i < 20; i++) {
      a.onSample(rttMs: 8500, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.audioReserve, isFalse);
    expect(a.target, (maxBitrateKbps: 45, maxFps: 1.0));
  });

  test('one-fps routes have five genuinely distinct video budgets', () {
    for (final base in [30, 45]) {
      final adapter = CallBitrateAdapter(
        baseBitrateKbps: base,
        baseFps: 1,
        initialLevel: 0,
      );
      final targets = [adapter.target];
      for (var rung = 1; rung < CallBitrateAdapter.ladder.length; rung++) {
        lossy(adapter);
        targets.add(lossy(adapter)!);
      }
      expect(targets.map((t) => t.maxFps), [1, 0.5, 0.25, 0.1, 0.02]);
      expect(targets.map((t) => t.maxBitrateKbps).toSet().length, 5);
      expect(targets.last.maxBitrateKbps, 2);
      for (final t in targets) {
        expect(t.maxBitrateKbps, lessThanOrEqualTo(base));
        expect(t.maxFps, inInclusiveRange(0.02, 1));
      }
    }
  });

  test('older native libraries retain their effective integer budget', () {
    final adapter = CallBitrateAdapter(
      baseBitrateKbps: 30,
      baseFps: 1,
      supportsLowRateVideo: false,
    );
    expect(adapter.target, (maxBitrateKbps: 30, maxFps: 1.0));
    var calls = 0;
    expect(
      adapter.applyPendingTarget((_) {
        calls++;
        return true;
      }),
      isTrue,
    );
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      good(adapter);
    }
    expect(
      adapter.applyPendingTarget((_) {
        calls++;
        return true;
      }),
      isNull,
    );
    expect(calls, 1);
  });

  test('new video grows one rung per sustained healthy audio interval', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    final floor = a.level;
    for (var rung = floor - 1; rung >= 0; rung--) {
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        expect(good(a), isNull);
      }
      expect(good(a), isNotNull);
      expect(a.level, rung);
    }
    expect(a.target, (maxBitrateKbps: 900, maxFps: 60));
  });

  test('bad or expired audio feedback interrupts startup video growth', () {
    for (final interrupt in [
      {'audio_feedback_reports': 1, 'rtt_ms': 80, 'tx_loss_pct': 12},
      {'audio_feedback_reports': 0},
      {'audio_feedback_reports': 1, 'worker_stalled': 1},
    ]) {
      final a = CallBitrateAdapter(baseBitrateKbps: 150, baseFps: 15);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        good(a);
      }
      a.onNativeStats(interrupt);
      good(a);
      expect(a.atFloor, isTrue);
    }
  });

  test('missing feedback holds video and cannot count as recovery', () {
    final a = direct();
    lossy(a);
    lossy(a);
    expect(a.level, 1);
    for (var i = 0; i < 30; i++) {
      a.onSample(
        rttMs: 0,
        txJitterMs: 0,
        txLossPct: 0,
        txDrops: 0,
        feedbackAvailable: false,
      );
    }
    expect(a.level, 1);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      good(a);
    }
    expect(a.level, 0);
  });

  test(
    'partial room audio reports reserve bandwidth without a false prompt',
    () {
      final adapter = direct();
      for (var i = 0; i < 60; i++) {
        adapter.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'tx_loss_pct': 0,
          'tx_jitter_ms': 10,
        }, expectedAudioFeedbackReports: 2);
      }
      expect(adapter.atFloor, isTrue);
      expect(adapter.videoAdvice, CallVideoAdvice.keep);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        adapter.onNativeStats({
          'audio_feedback_reports': 2,
          'rtt_ms': 80,
          'tx_loss_pct': 0,
          'tx_jitter_ms': 10,
        }, expectedAudioFeedbackReports: 2);
      }
      expect(adapter.level, CallBitrateAdapter.ladder.length - 2);
    },
  );

  test('partial known bad audio reports still substantiate floor advice', () {
    final adapter = direct();
    for (
      var i = 0;
      i < badSamplesToFloor + CallBitrateAdapter.adviseAfter;
      i++
    ) {
      adapter.onNativeStats({
        'audio_feedback_reports': 1,
        'rtt_ms': 80,
        'tx_loss_pct': 12,
      }, expectedAudioFeedbackReports: 2);
    }
    expect(adapter.atFloor, isTrue);
    expect(adapter.videoAdvice, CallVideoAdvice.suggestDisable);
  });

  test('native defaults and expired reports cannot restore video', () {
    for (final unavailable in [
      <String, dynamic>{}, // Older library: no report freshness.
      <String, dynamic>{'audio_feedback_reports': 0},
      <String, dynamic>{'audio_feedback_reports': 1, 'worker_stalled': 1},
    ]) {
      final a = direct();
      for (var i = 0; i < CallBitrateAdapter.degradeAfter; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'tx_loss_pct': 12,
          'tx_drops': 0,
        });
      }
      expect(a.level, 1);
      for (var i = 0; i < 30; i++) {
        a.onNativeStats({'tx_drops': 0, ...unavailable});
      }
      expect(a.level, 1);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        a.onNativeStats({
          'audio_feedback_reports': 1,
          'rtt_ms': 80,
          'tx_drops': 0,
        });
      }
      expect(a.level, 0);
    }
  });

  test('native local audio drops reduce video without remote reports', () {
    final a = direct();
    for (var drops = 0; drops < 3; drops++) {
      a.onNativeStats({
        'audio_feedback_reports': 0,
        'worker_stalled': 1,
        'rtt_ms': 1000,
        'tx_drops': drops,
      });
    }
    expect(a.level, 1);
    expect(a.rttBaselineMs, isNull);
  });

  test('new local audio drops reduce video even before reports arrive', () {
    final a = direct();
    for (var drops = 0; drops < 3; drops++) {
      a.onSample(
        rttMs: 0,
        txJitterMs: 0,
        txLossPct: 0,
        txDrops: drops,
        feedbackAvailable: false,
      );
    }
    expect(a.level, 1);
  });

  test('busy native retune retries even when quality no longer changes', () {
    final a = direct();
    var nativeTarget = a.target;
    a.applyPendingTarget((target) {
      nativeTarget = target;
      return true;
    });
    lossy(a);
    lossy(a);
    expect(a.level, 1);
    expect(a.applyPendingTarget((_) => false), isFalse);
    expect(nativeTarget.maxBitrateKbps, 900);
    // No fresh report: hold the policy rung, but still apply its pending cut.
    a.onNativeStats({'audio_feedback_reports': 0});
    expect(
      a.applyPendingTarget((target) {
        nativeTarget = target;
        return true;
      }),
      isTrue,
    );
    expect(nativeTarget, (maxBitrateKbps: 675, maxFps: 30));
    expect(a.applyPendingTarget((_) => throw StateError('duplicate')), isNull);
  });

  test('a busy retune never reapplies a superseded or overridden budget', () {
    final a = direct();
    lossy(a);
    lossy(a);
    expect(a.applyPendingTarget((_) => false), isFalse);
    lossy(a);
    lossy(a);
    var nativeTarget = a.target;
    a.applyPendingTarget((target) {
      nativeTarget = target;
      return true;
    });
    expect(nativeTarget, (maxBitrateKbps: 450, maxFps: 15));
    // A successful external override invalidates the remembered native state.
    nativeTarget = (maxBitrateKbps: 900, maxFps: 60);
    a.invalidateAppliedTarget();
    a.applyPendingTarget((target) {
      nativeTarget = target;
      return true;
    });
    expect(nativeTarget, a.target);
  });

  test('stays at full budget on a healthy link', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      expect(good(a), isNull);
    }
    expect(a.level, 0);
    expect(a.target, (maxBitrateKbps: 900, maxFps: 60));
  });

  test('one bad sample does not degrade (hysteresis)', () {
    final a = direct();
    expect(lossy(a), isNull);
    expect(good(a), isNull);
    expect(a.level, 0);
  });

  test('sustained loss walks down the ladder one rung per streak', () {
    final a = direct();
    expect(lossy(a), isNull);
    final first = lossy(a);
    expect(first, isNotNull);
    expect(a.level, 1);
    expect(first!.maxBitrateKbps, 675);
    expect(first.maxFps, 30);

    expect(lossy(a), isNull);
    final second = lossy(a);
    expect(a.level, 2);
    expect(second!.maxBitrateKbps, 450);
    expect(second.maxFps, 15);
  });

  test('bottom rung limits video cadence and never goes lower', () {
    final a = direct();
    ({int maxBitrateKbps, double maxFps})? last;
    for (var i = 0; i < 20; i++) {
      last = lossy(a) ?? last;
    }
    expect(a.level, CallBitrateAdapter.ladder.length - 1);
    expect(last!.maxBitrateKbps, 45);
    expect(last.maxFps, 1.2);
    // Further bad samples keep the floor.
    for (var i = 0; i < 10; i++) {
      expect(lossy(a), isNull);
    }
    expect(a.level, CallBitrateAdapter.ladder.length - 1);
  });

  test('recovery needs a long good streak and climbs one rung at a time', () {
    final a = direct();
    lossy(a);
    lossy(a);
    expect(a.level, 1);
    // One bad sample resets the recovery clock.
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      expect(good(a), isNull);
    }
    expect(lossy(a), isNull);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      expect(good(a), isNull);
    }
    final up = good(a);
    expect(up, isNotNull);
    expect(a.level, 0);
    expect(up!.maxBitrateKbps, 900);
  });

  test('high RTT degrades, unknown RTT (0) does not', () {
    final a = direct();
    ({int maxBitrateKbps, double maxFps})? r;
    for (var i = 0; i < 3; i++) {
      r = a.onSample(rttMs: 500, txJitterMs: 5, txLossPct: 0, txDrops: 0) ?? r;
    }
    expect(a.level, 1);
    expect(r, isNotNull);

    final b = direct();
    for (var i = 0; i < 5; i++) {
      expect(
        b.onSample(rttMs: 0, txJitterMs: 5, txLossPct: 0, txDrops: 0),
        isNull,
      );
    }
    expect(b.level, 0);
  });

  test('growing local tx drops degrade; a stable counter does not', () {
    final a = direct();
    expect(
      a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 10),
      isNull, // first sample only records the baseline
    );
    expect(
      a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 11),
      isNull,
    );
    final r = a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 12);
    expect(r, isNotNull);
    expect(a.level, 1);
    // Counter stops growing → link is judged healthy again.
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      expect(
        a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 12),
        isNull,
      );
    }
    final up = a.onSample(rttMs: 50, txJitterMs: 5, txLossPct: 0, txDrops: 12);
    expect(up, isNotNull);
    expect(a.level, 0);
  });

  test('marginal samples hold the rung and restart the recovery clock', () {
    final a = direct();
    lossy(a);
    lossy(a);
    expect(a.level, 1);
    for (var i = 0; i < 100; i++) {
      // jitter 60 is neither bad (>=80) nor good (<40).
      expect(
        a.onSample(rttMs: 100, txJitterMs: 60, txLossPct: 0, txDrops: 0),
        isNull,
      );
    }
    expect(a.level, 1);
  });

  test('bufferbloat above the call baseline degrades below the 400ms rail', () {
    final a = direct();
    // Establish a ~70ms baseline (loss-free TCP-like relay leg).
    for (var i = 0; i < 10; i++) {
      a.onSample(rttMs: 70, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.level, 0);
    // Standing queue builds: rtt 230 is FAR below the absolute 400ms rail but
    // 160ms over the baseline — the TCP relay hides it as zero loss, so the
    // baseline-relative verdict is the only signal that can fire.
    a.onSample(rttMs: 230, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    a.onSample(rttMs: 230, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    expect(a.level, 1, reason: 'bloat over baseline must step down');
  });

  test('draining the queue back to the baseline recovers the rung', () {
    final a = direct();
    for (var i = 0; i < 10; i++) {
      a.onSample(rttMs: 70, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    expect(a.level, 1);
    // Queue drained: rtt back within bloatRecoverMs of the floor.
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      a.onSample(rttMs: 90, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.level, 0, reason: 'recovery near the baseline steps back up');
  });

  test('a genuine route change re-learns the baseline within two windows', () {
    final a = direct();
    // Old fast route: floor 70ms.
    for (var i = 0; i < 10; i++) {
      a.onSample(rttMs: 70, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    // Route changes to a legitimately slower path (240ms floor, healthy). The
    // stale 70ms floor first reads as bloat and may step down, but after both
    // min-filter windows roll over the 240ms floor is the new baseline and
    // sustained good samples recover the rung — the ladder must not stay
    // pinned at the bottom on a longer-but-clean path.
    for (var i = 0; i < CallBitrateAdapter.minWindowSamples * 2 + 1; i++) {
      a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.rttBaselineMs, 240);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter * 4; i++) {
      a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.level, 0, reason: 're-baselined path must fully recover');
  });

  test(
    'audio congestion releases padded video cells, then recovers slowly',
    () {
      final a = CallBitrateAdapter(
        baseBitrateKbps: 150,
        baseFps: 15,
        initialLevel: 0,
      );
      final cadence = <double>[a.target.maxFps];
      for (var rung = 1; rung < CallBitrateAdapter.ladder.length; rung++) {
        expect(lossy(a), isNull);
        cadence.add(lossy(a)!.maxFps);
      }
      expect(cadence, [15, 7.5, 3.75, 1.5, 0.3]);
      // A two-second burst must not restore full video pressure on audio.
      expect(good(a), isNull);
      expect(good(a), isNull);
      expect(a.target.maxFps, 0.3);
      for (var i = 2; i < CallBitrateAdapter.recoverAfter; i++) {
        good(a);
      }
      expect(a.target.maxFps, 1.5);
    },
  );

  test('weak video can release bandwidth below the old native floor', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 150,
      baseFps: 15,
      initialLevel: 0,
    );
    for (var i = 0; i < 30; i++) {
      lossy(a);
      expect(a.target.maxBitrateKbps, inInclusiveRange(1, 150));
    }
    expect(a.target, (maxBitrateKbps: 8, maxFps: 0.3));
  });

  test('a rebuilt encoder starts with the reduced audio-preserving budget', () {
    final a = direct();
    for (var i = 0; i < 20; i++) {
      lossy(a);
    }
    a.applyPendingTarget((_) => true);
    // A replacement has no remembered native budget, even on an unchanged
    // route. A missing new report must retain the call's previous decision.
    a.invalidateAppliedTarget();
    a.onNativeStats({'audio_feedback_reports': 0});
    var replacement = (maxBitrateKbps: 900, maxFps: 60.0);
    expect(
      a.applyPendingTarget((target) {
        replacement = target;
        return true;
      }),
      isTrue,
    );
    expect(replacement, (maxBitrateKbps: 45, maxFps: 1.2));
  });

  test(
    'a low-cadence profile retains sparse video without rounding to one fps',
    () {
      final a = CallBitrateAdapter(
        baseBitrateKbps: 150,
        baseFps: 5,
        initialLevel: 0,
      );
      for (var i = 0; i < badSamplesToFloor; i++) {
        lossy(a);
      }
      expect(a.target.maxFps, 0.1);
    },
  );

  test('anonymous profile never exceeds its route budget', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 150,
      baseFps: 15,
      initialLevel: 0,
    );
    lossy(a);
    lossy(a);
    expect(a.target.maxBitrateKbps, lessThan(150));
    for (var i = 0; i < 200; i++) {
      good(a);
    }
    expect(a.level, 0);
    expect(a.target, (maxBitrateKbps: 150, maxFps: 15));
  });

  group('when the ladder runs out of rungs', () {
    // The gap this closes, measured: at the bottom rung (270 kbps of a 900 kbps
    // profile) the stand still lost 68% of outbound video and kept sending.
    // The ladder had no way to say "there is no smaller step" — every sample
    // returned null, which is exactly what a healthy hold returns too.

    test('says nothing while rungs remain, however bad the link', () {
      final a = direct();
      // Walk all the way down, allowing each smaller budget to be sampled.
      for (var i = 0; i < badSamplesToFloor; i++) {
        lossy(a);
      }
      expect(a.level, CallBitrateAdapter.ladder.length - 1);
      expect(a.atFloor, isTrue);
      expect(
        a.videoAdvice,
        CallVideoAdvice.keep,
        reason:
            'reaching the floor is not itself advice — the floor has not '
            'been given a chance to carry the call yet',
      );
    });

    test('advises dropping video only after the floor keeps failing', () {
      final a = direct();
      for (var i = 0; i < badSamplesToFloor; i++) {
        lossy(a);
      }
      // One short burst at the floor must not raise a user-facing prompt.
      for (var i = 0; i < CallBitrateAdapter.adviseAfter - 1; i++) {
        expect(lossy(a), isNull);
        expect(a.videoAdvice, CallVideoAdvice.keep, reason: 'sample $i');
      }
      expect(lossy(a), isNull);
      expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
    });

    test('a good sample at the floor restarts the count', () {
      final a = direct();
      for (var i = 0; i < badSamplesToFloor; i++) {
        lossy(a);
      }
      for (var i = 0; i < CallBitrateAdapter.adviseAfter - 1; i++) {
        lossy(a);
      }
      good(a); // link breathes
      for (var i = 0; i < CallBitrateAdapter.adviseAfter - 1; i++) {
        expect(lossy(a), isNull);
        expect(a.videoAdvice, CallVideoAdvice.keep, reason: 'after $i');
      }
      expect(lossy(a), isNull);
      expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
    });

    test('the advice is latched, not momentary', () {
      final a = direct();
      for (
        var i = 0;
        i < badSamplesToFloor + CallBitrateAdapter.adviseAfter;
        i++
      ) {
        lossy(a);
      }
      expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
      // A handful of good samples is not yet a recovery: too few to climb a
      // rung, so a prompt the user is reaching for must not vanish.
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        good(a);
        expect(
          a.videoAdvice,
          CallVideoAdvice.suggestDisable,
          reason: 'good $i',
        );
      }
    });

    test('climbing off the floor withdraws the advice', () {
      final a = direct();
      for (
        var i = 0;
        i < badSamplesToFloor + CallBitrateAdapter.adviseAfter;
        i++
      ) {
        lossy(a);
      }
      expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        good(a);
      }
      expect(a.atFloor, isFalse);
      expect(a.videoAdvice, CallVideoAdvice.keep);
    });
  });
}
