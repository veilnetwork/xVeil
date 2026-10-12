import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  CallBitrateAdapter direct({int level = 0, bool lowRate = true}) =>
      CallBitrateAdapter(
        baseBitrateKbps: 900,
        baseFps: 60,
        initialLevel: level,
        supportsLowRateVideo: lowRate,
      );

  Map<String, Object> healthy({int drops = 0, int? audioDrops = 0}) => {
    'worker_stalled': 0,
    'video_worker_stalled': 0,
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
    'tx_drops': drops,
    'audio_tx_rtp_drops': ?audioDrops,
  };

  void apply(CallBitrateAdapter a) {
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
  }

  void native(
    CallBitrateAdapter a, {
    Map<String, dynamic>? stats,
    int? peerDelay = 60,
    int? currentPeerDelay,
    int? peerSequence,
    bool interrupted = false,
    bool send = true,
    bool receive = true,
    bool video = true,
    int? audioReceivers,
    int? videoReceivers,
  }) {
    apply(a);
    a.onNativeStats(
      stats ?? healthy(),
      videoSendExpected: video,
      sendAudioExpected: send,
      receiveAudioExpected: receive,
      requireAudioReceivePlayout: receive,
      requirePeerAudioPlayout: send,
      peerAudioDelayMs: peerDelay,
      peerCurrentAudioDelayMs: currentPeerDelay,
      peerAudioSampleSequence: peerSequence,
      audioInterrupted: interrupted,
      expectedAudioFeedbackReports: audioReceivers,
      expectedVideoFeedbackReports: videoReceivers,
    );
    apply(a);
  }

  void good(CallBitrateAdapter a, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      a.onSample(rttMs: 80, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
  }

  void poor(CallBitrateAdapter a, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      a.onSample(rttMs: 80, txJitterMs: 10, txLossPct: 12, txDrops: 0);
    }
  }

  test(
    'new low latency video probes each rung without a minute of sparse frames',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0;
      for (var rung = 3; rung >= 0; rung--) {
        for (var i = 0; i < CallBitrateAdapter.startupRecoverAfter; i++) {
          native(
            a,
            stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
          );
          expect(
            a.level,
            i == CallBitrateAdapter.startupRecoverAfter - 1 ? rung : rung + 1,
          );
        }
      }
      expect(a.target, (maxBitrateKbps: 900, maxFps: 30.0));
    },
  );

  test('startup needs consecutive fresh low delay measurements', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
    var frames = 0;
    void tick({int? peer = 60}) => native(
      a,
      peerDelay: peer,
      stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
    );
    tick();
    tick();
    tick(peer: null);
    tick();
    tick();
    expect(a.level, 4);
    tick();
    expect(a.level, 3);
  });

  test('measured startup congestion retains slow recovery afterward', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
    native(
      a,
      stats: {
        ...healthy(),
        'rtt_ms': 40,
        'tx_loss_pct': 8,
        'video_tx_frames': 1,
      },
    );
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a, stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': i + 2});
    }
    expect(a.level, 4);
    native(a, stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': 20});
    expect(a.level, 3);
  });

  test(
    'higher playout latency cannot accelerate startup on a low RTT link',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        native(
          a,
          peerDelay: 140,
          stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': i + 1},
        );
      }
      expect(a.level, 4);
      native(
        a,
        peerDelay: 140,
        stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': 20},
      );
      expect(a.level, 3);
    },
  );

  test(
    'restored video policy retains slow recovery even on a healthy link',
    () {
      final a = CallBitrateAdapter(
        baseBitrateKbps: 900,
        baseFps: 30,
        initialLevel: 3,
      );
      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        native(
          a,
          stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': i + 1},
        );
      }
      expect(a.level, 3);
      native(a, stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': 20});
      expect(a.level, 2);
    },
  );

  test('decreasing cadence cannot enlarge the mean frame byte budget', () {
    for (final fps in [15, 30, 60]) {
      for (var level = 0; level < CallBitrateAdapter.ladder.length; level++) {
        final a = CallBitrateAdapter(
          baseBitrateKbps: 900,
          baseFps: fps,
          initialLevel: level,
        );
        final t = a.target;
        expect(t.maxBitrateKbps / t.maxFps, lessThanOrEqualTo(900 / fps));
        expect(t.maxFps, greaterThanOrEqualTo(1));
      }
    }
  });

  test('sparse relay cadence does not retain a 270-kbit burst budget', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 15,
      initialLevel: 3,
    );
    expect(a.target, (maxBitrateKbps: 90, maxFps: 1.5));
    final full = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 15,
      initialLevel: 0,
    );
    expect(full.target, (maxBitrateKbps: 900, maxFps: 15.0));
  });

  test('audio-only measurements cannot earn a larger video source', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
    for (var i = 0; i < 120; i++) {
      native(a, video: false);
    }
    expect(a.target, (maxBitrateKbps: 30, maxFps: 1.0));
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a);
    }
    expect(a.target, (maxBitrateKbps: 30, maxFps: 1.0));
    native(a);
    expect(a.target, (maxBitrateKbps: 90, maxFps: 3.0));
  });

  test('turning capture off breaks an unfinished recovery streak', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 30,
      initialLevel: 3,
    );
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a);
    }
    for (var i = 0; i < 30; i++) {
      native(a, video: false);
    }
    expect(a.target.maxBitrateKbps, 90);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a);
    }
    expect(a.target.maxBitrateKbps, 90);
    native(a);
    expect(a.target.maxBitrateKbps, 225);
  });

  test('capture intent and historical frames cannot prove video headroom', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
    for (final frames in [0, 10]) {
      for (var i = 0; i < 30; i++) {
        native(a, stats: {...healthy(), 'video_tx_frames': frames});
      }
      expect(a.target.maxBitrateKbps, 30);
    }
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a, stats: {...healthy(), 'video_tx_frames': 11 + i});
    }
    expect(a.target.maxBitrateKbps, 30);
    native(a, stats: {...healthy(), 'video_tx_frames': 30});
    expect(a.target.maxBitrateKbps, 90);
  });

  test('one-fps polling jitter still earns sustained video recovery', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a, stats: {...healthy(), 'video_tx_frames': 1 + i ~/ 2});
    }
    expect(a.target.maxBitrateKbps, 90);
  });

  test('healthy audio releases a protection pause while capture is off', () {
    for (final audioDrops in [null, 0]) {
      final a = direct();
      poor(a, 6);
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        native(
          a,
          video: false,
          stats: {...healthy(), 'audio_tx_rtp_drops': audioDrops},
        );
      }
      expect(a.audioReserve, isFalse);
      expect(a.target, (maxBitrateKbps: 15, maxFps: 1.0));
      for (var i = 0; i < 30; i++) {
        native(a, video: false);
      }
      expect(a.target.maxBitrateKbps, 15);
    }
  });

  test('degrades two levels, trials one fps, then pauses failing audio', () {
    final a = direct();
    poor(a);
    expect(a.target, (maxBitrateKbps: 900, maxFps: 60.0));
    poor(a);
    expect(a.target, (maxBitrateKbps: 225, maxFps: 15.0));
    expect(a.audioReserve, isFalse);
    poor(a, 2);
    expect(a.target, (maxBitrateKbps: 15, maxFps: 1.0));
    expect(a.audioReserve, isFalse, reason: 'the minimum must be tried first');
    poor(a);
    expect(a.audioReserve, isFalse);
    poor(a);
    expect(a.audioReserve, isTrue);
  });

  test('recovery resumes at one fps and grows one level at a time', () {
    final a = direct();
    poor(a, 6);
    expect(a.audioReserve, isTrue);
    good(a, CallBitrateAdapter.recoverAfter - 1);
    expect(a.audioReserve, isTrue);
    good(a);
    expect(a.target, (maxBitrateKbps: 15, maxFps: 1.0));
    expect(a.audioReserve, isFalse);
    good(a, CallBitrateAdapter.recoverAfter);
    expect(a.target, (maxBitrateKbps: 90, maxFps: 6.0));
    good(a, CallBitrateAdapter.recoverAfter);
    expect(a.target, (maxBitrateKbps: 225, maxFps: 15.0));
    good(a, CallBitrateAdapter.recoverAfter);
    expect(a.target, (maxBitrateKbps: 450, maxFps: 30.0));
    good(a, CallBitrateAdapter.recoverAfter);
    expect(a.target, (maxBitrateKbps: 900, maxFps: 60.0));
  });

  test('a short burst does not cut video or earn an improvement', () {
    final a = direct();
    poor(a);
    good(a);
    expect(a.level, 0);
    poor(a, 2);
    expect(a.level, 2);
    good(a, CallBitrateAdapter.recoverAfter - 1);
    poor(a);
    good(a, CallBitrateAdapter.recoverAfter - 1);
    expect(a.level, 2);
    good(a);
    expect(a.level, 1);
  });

  for (final base in [30, 45, 150, 900]) {
    for (final fps in [1, 15, 60]) {
      test('one-fps floor and route ceiling hold for $base kbit/$fps fps', () {
        final a = CallBitrateAdapter(baseBitrateKbps: base, baseFps: fps);
        expect(a.target.maxFps, 1.0);
        for (var i = 0; i < 60; i++) {
          a.onNativeStats({'audio_feedback_reports': 0});
          expect(a.audioReserve, isFalse);
          expect(a.target.maxFps, 1.0);
        }
        for (var i = 0; i < CallBitrateAdapter.recoverAfter * 4; i++) {
          good(a);
          expect(a.target.maxBitrateKbps, inInclusiveRange(1, base));
          expect(a.target.maxFps, inInclusiveRange(1, fps));
        }
        expect(a.target.maxFps, fps.toDouble());
        expect(a.target.maxBitrateKbps, base);
      });
    }
  }

  test('unknown startup audio permits one fps without inventing health', () {
    final a = direct();
    a.prepareVideoSend(
      const {},
      requireAudioReceivePlayout: true,
      receiveAudioExpected: true,
      requirePeerAudioPlayout: true,
    );
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 1.0);
    for (var i = 0; i < 60; i++) {
      native(a, stats: {'audio_feedback_reports': 0}, peerDelay: null);
    }
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 1.0);
    expect(a.videoAdvice, CallVideoAdvice.keep);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a);
    }
    expect(a.level, 3);
  });

  test('stale measurements lower earned video but do not claim an outage', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      native(a, stats: {'audio_feedback_reports': 0}, peerDelay: null);
    }
    expect(a.target.maxFps, 1.0);
    expect(a.audioReserve, isFalse);
    expect(a.videoAdvice, CallVideoAdvice.keep);
  });

  test('an unmeasured RTT cannot earn growth even with a report', () {
    final a = direct(level: 4);
    for (var i = 0; i < 60; i++) {
      a.onNativeStats({'audio_feedback_reports': 1, 'rtt_ms': 0});
    }
    expect(a.level, 4);
    expect(a.audioReserve, isFalse);
  });

  for (final failure in [
    'receive buffer',
    'peer buffer',
    'RTP outage',
    'interruption',
  ]) {
    test('$failure reduces video before pausing at the applied floor', () {
      final a = direct();
      void bad() => native(
        a,
        stats: {
          ...healthy(),
          if (failure == 'receive buffer') 'audio_delay_ms': 450,
          if (failure == 'RTP outage') 'audio_rx_native_age_ms': 1500,
        },
        peerDelay: failure == 'peer buffer' ? 450 : 60,
        interrupted: failure == 'interruption',
      );
      bad();
      expect(a.level, 0);
      bad();
      expect(a.level, 2);
      bad();
      bad();
      expect(a.level, 4);
      expect(a.target.maxFps, 1.0);
      expect(a.audioReserve, isFalse);
      bad();
      expect(a.audioReserve, isFalse);
      bad();
      expect(a.audioReserve, isTrue);
    });
  }

  test('buffer hysteresis tolerates 180ms but recovers below 160ms', () {
    final a = direct(level: 4);
    for (var i = 0; i < 20; i++) {
      native(a, stats: {...healthy(), 'audio_jb_ms': 180});
    }
    expect(a.audioReserve, isFalse);
    expect(a.level, 4, reason: 'a marginal buffer does not earn more video');
    native(a, stats: {...healthy(), 'audio_delay_ms': 53, 'audio_jb_ms': 210});
    native(a, stats: {...healthy(), 'audio_delay_ms': 53, 'audio_jb_ms': 210});
    expect(
      a.audioReserve,
      isTrue,
      reason: 'use the current buffer, not a filtered value',
    );
    for (var i = 0; i < 20; i++) {
      native(a, stats: {...healthy(), 'audio_jb_ms': 170});
    }
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a, stats: {...healthy(), 'audio_jb_ms': 150});
    }
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 1.0);
  });

  test('a busy native floor cannot be counted as a completed trial', () {
    final a = direct();
    apply(a);
    for (var i = 0; i < 30; i++) {
      a.onNativeStats(
        healthy(),
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 450,
      );
      a.applyPendingTarget((_) => false);
    }
    expect(a.level, 4);
    expect(a.audioReserve, isFalse);
    a.applyPendingTarget((_) => true);
    a.onNativeStats(
      healthy(),
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 450,
    );
    expect(a.audioReserve, isFalse);
    a.onNativeStats(
      healthy(),
      requirePeerAudioPlayout: true,
      peerAudioDelayMs: 450,
    );
    expect(a.audioReserve, isTrue);
  });

  test('an old peak reduces video but cannot fail a healthy floor trial', () {
    final a = direct();
    for (var i = 0; i < 20; i++) {
      native(
        a,
        stats: {...healthy(), 'video_tx_frames': i + 1},
        peerDelay: 209,
        currentPeerDelay: 100,
        peerSequence: i + 1,
      );
    }
    expect(a.atFloor, isTrue);
    expect(a.audioReserve, isFalse);
    expect(a.videoAdvice, CallVideoAdvice.keep);
    expect(a.target.maxFps, 1);
  });

  test('pretrial peer report cannot be reused to claim the floor failed', () {
    final a = direct();
    for (var i = 0; i < 10; i++) {
      native(
        a,
        stats: {...healthy(), 'video_tx_frames': i + 1},
        peerDelay: 300,
        currentPeerDelay: 300,
        peerSequence: 10,
      );
    }
    expect(a.atFloor, isTrue);
    expect(a.audioReserve, isFalse);
    for (var i = 0; i < 2; i++) {
      native(
        a,
        stats: {...healthy(), 'video_tx_frames': 11 + i},
        peerDelay: 300,
        currentPeerDelay: 300,
        peerSequence: 11,
      );
    }
    expect(
      a.audioReserve,
      isTrue,
      reason: 'fresh failure after the actual trial still pauses',
    );
  });

  test(
    'busy floor application records readiness only when the budget is accepted',
    () {
      final a = direct();
      apply(a);
      void sample(int frames, int sequence) {
        a.onNativeStats(
          {...healthy(), 'video_tx_frames': frames},
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: 300,
          peerCurrentAudioDelayMs: 300,
          peerAudioSampleSequence: sequence,
          requireAudioReceivePlayout: true,
          receiveAudioExpected: true,
        );
      }

      for (var i = 1; i <= 5; i++) {
        sample(i, i == 5 ? 11 : 10);
        a.applyPendingTarget((_) => false);
      }
      expect(a.atFloor, isTrue);
      expect(a.audioReserve, isFalse);
      expect(a.applyPendingTarget((_) => true), isTrue);
      sample(6, 11);
      sample(7, 11);
      expect(
        a.audioReserve,
        isFalse,
        reason: 'the report arrived before successful application',
      );
      sample(8, 12);
      sample(9, 12);
      expect(a.audioReserve, isTrue);
    },
  );

  test(
    'current recovery resumes sparse video while retaining peak growth guard',
    () {
      final a = direct(level: 4);
      for (var i = 0; i < 6; i++) {
        native(
          a,
          stats: {...healthy(), 'video_tx_frames': i + 1},
          peerDelay: 300,
          currentPeerDelay: 300,
          peerSequence: i + 1,
        );
      }
      expect(a.audioReserve, isTrue);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        native(
          a,
          stats: {...healthy(), 'video_tx_frames': 6},
          peerDelay: 300,
          currentPeerDelay: 100,
          peerSequence: 7 + i,
        );
      }
      expect(a.audioReserve, isFalse);
      expect(a.target.maxFps, 1);
      for (var i = 0; i < 20; i++) {
        native(
          a,
          stats: {...healthy(), 'video_tx_frames': 7 + i},
          peerDelay: 300,
          currentPeerDelay: 100,
          peerSequence: 20 + i,
        );
      }
      expect(
        a.target.maxFps,
        1,
        reason: 'recent peaks still cannot earn more bandwidth',
      );
    },
  );

  test('secondary losses alone never pause known healthy audio', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      native(a, stats: healthy(drops: i * 20));
    }
    expect(a.atFloor, isTrue);
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 1.0);
  });

  test('a floor trial requires newly sent frames, not an applied budget', () {
    final a = direct(level: 4);
    void sample(int frames) => native(
      a,
      stats: {...healthy(), 'video_tx_frames': frames},
      peerDelay: 450,
    );
    for (var i = 0; i < 20; i++) {
      sample(100);
    }
    expect(a.audioReserve, isFalse, reason: 'old frames are not a trial');
    sample(101);
    sample(101);
    expect(a.audioReserve, isFalse, reason: 'only one new frame was sent');
    sample(102);
    expect(a.audioReserve, isFalse);
    sample(102);
    expect(a.audioReserve, isTrue);

    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a, stats: {...healthy(), 'video_tx_frames': 102});
    }
    expect(a.audioReserve, isFalse);
    for (var i = 0; i < 20; i++) {
      sample(102);
    }
    expect(a.audioReserve, isFalse, reason: 'a resumed probe needs new frames');
    sample(103);
    sample(104);
    sample(104);
    expect(a.audioReserve, isTrue);
  });

  test('engine replacement invalidates the measured floor trial', () {
    final a = direct(level: 4);
    for (final frames in [10, 11, 12]) {
      native(
        a,
        stats: {...healthy(), 'video_tx_frames': frames},
        peerDelay: 450,
      );
    }
    a.invalidateAppliedState();
    for (var i = 0; i < 20; i++) {
      native(a, stats: {...healthy(), 'video_tx_frames': 12}, peerDelay: 450);
    }
    expect(a.audioReserve, isFalse);
  });

  test('recovered playout resumes a probe on a high RTT and jitter route', () {
    final a = direct(level: 4);
    native(a, interrupted: true);
    native(a, interrupted: true);
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(
        a,
        stats: {
          ...healthy(),
          'rtt_ms': 600,
          'tx_jitter_ms': 100,
          'tx_loss_pct': 7,
        },
      );
      expect(a.audioReserve, i < CallBitrateAdapter.recoverAfter - 1);
    }
    expect(a.target.maxFps, 1.0);
    for (var i = 0; i < 30; i++) {
      native(
        a,
        stats: {
          ...healthy(),
          'rtt_ms': 600,
          'tx_jitter_ms': 100,
          'tx_loss_pct': 7,
        },
      );
    }
    expect(a.atFloor, isTrue, reason: 'a probe does not grant video headroom');
    expect(a.audioReserve, isFalse);
  });

  test(
    'probe recovery still requires both measured playouts and no outages',
    () {
      for (final failure in ['peer', 'receive', 'missing', 'severe RTT']) {
        final a = direct(level: 4);
        native(a, interrupted: true);
        native(a, interrupted: true);
        for (var i = 0; i < 30; i++) {
          native(
            a,
            stats: {
              ...healthy(),
              'rtt_ms': failure == 'severe RTT' ? 2000 : 600,
              if (failure == 'receive') 'audio_delay_ms': 170,
            },
            peerDelay: failure == 'peer'
                ? 170
                : (failure == 'missing' ? null : 60),
          );
        }
        expect(a.audioReserve, isTrue, reason: failure);
      }
    },
  );

  test('healthy audio may resume a trial despite secondary losses', () {
    final a = direct(level: 4);
    native(a, interrupted: true);
    native(a, interrupted: true);
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a, stats: healthy(drops: i * 20));
    }
    expect(a.audioReserve, isTrue);
    native(a, stats: healthy(drops: 1000));
    expect(a.audioReserve, isFalse);
    expect(a.atFloor, isTrue);
  });

  test('missing measurement breaks a consecutive recovery streak', () {
    final a = direct(level: 4);
    native(a, interrupted: true);
    native(a, interrupted: true);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a);
    }
    native(a, stats: {'audio_feedback_reports': 0}, peerDelay: null);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
      native(a);
    }
    expect(a.audioReserve, isTrue);
    native(a);
    expect(a.audioReserve, isFalse);
  });

  test('local primary drops reduce and pause without remote reports', () {
    final a = direct();
    for (var i = 0; i < 8; i++) {
      native(
        a,
        stats: {'audio_feedback_reports': 0, 'audio_tx_rtp_drops': i},
        peerDelay: null,
      );
    }
    expect(a.audioReserve, isTrue);
    expect(a.rttBaselineMs, isNull);
  });

  test('missing and invalid primary counters still allow aggregate cuts', () {
    for (final audio in [null, -1]) {
      final a = direct();
      for (var i = 0; i < 3; i++) {
        a.onNativeStats(healthy(drops: i, audioDrops: audio));
      }
      expect(a.level, 2);
    }
  });

  test('switching report domains does not invent a new loss', () {
    final a = direct();
    a.onNativeStats(healthy(drops: 100));
    a.onNativeStats(healthy(drops: 100), sendAudioExpected: false);
    a.onNativeStats(healthy(drops: 100), sendAudioExpected: false);
    expect(a.level, 0);
    a.onNativeStats(healthy(drops: 101), sendAudioExpected: false);
    a.onNativeStats(healthy(drops: 102), sendAudioExpected: false);
    expect(a.level, 2);
  });

  test('video reports cannot prove expected outgoing audio healthy', () {
    final a = direct(level: 4);
    for (var i = 0; i < 60; i++) {
      a.onNativeStats({
        'audio_feedback_reports': 0,
        'video_feedback_reports': 1,
        'video_feedback_rtt_ms': 80,
      });
    }
    expect(a.level, 4);
    expect(a.audioReserve, isFalse);
  });

  test('muted sender needs actual incoming recovery, then video reports', () {
    final a = direct(level: 4);
    native(a, interrupted: true);
    native(a, interrupted: true);
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < 20; i++) {
      native(
        a,
        stats: {
          ...healthy(),
          'audio_delay_ms': 170,
          'video_feedback_reports': 0,
        },
        send: false,
      );
    }
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(
        a,
        stats: {...healthy(), 'video_feedback_reports': 0},
        send: false,
      );
    }
    expect(a.audioReserve, isFalse);
    expect(a.level, 4);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a, send: false);
    }
    expect(a.level, 3);
  });

  test(
    'both intentionally muted endpoints release an existing audio pause',
    () {
      final a = direct(level: 4);
      native(a, interrupted: true);
      native(a, interrupted: true);
      native(a, stats: {}, send: false, receive: false);
      expect(a.audioReserve, isFalse);
      expect(a.target.maxFps, 1.0);
    },
  );

  test(
    'DTX, a muted peer and legacy receive telemetry do not prove outage',
    () {
      for (final age in [400, null]) {
        final a = direct(level: 4);
        for (var i = 0; i < 60; i++) {
          a.onNativeStats({
            ...healthy(),
            'audio_rx_native_age_ms': ?age,
          }, receiveAudioExpected: age != null);
        }
        expect(a.audioReserve, isFalse);
      }
      final a = direct();
      for (var i = 0; i < 10; i++) {
        a.onNativeStats({
          ...healthy(),
          'audio_rx_native_age_ms': 10000,
        }, receiveAudioExpected: false);
      }
      expect(a.audioReserve, isFalse);
    },
  );

  test(
    'partial room reports cannot earn growth or fabricate disable advice',
    () {
      final a = direct();
      for (var i = 0; i < 60; i++) {
        native(a, audioReceivers: 2);
      }
      expect(a.level, 4);
      expect(a.audioReserve, isFalse);
      expect(a.videoAdvice, CallVideoAdvice.keep);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        native(
          a,
          stats: {...healthy(), 'audio_feedback_reports': 2},
          audioReceivers: 2,
        );
      }
      expect(a.level, 3);
    },
  );

  test('muted room needs video reports from every receiver to grow', () {
    final a = direct(level: 4);
    for (var i = 0; i < 30; i++) {
      native(a, send: false, receive: false, videoReceivers: 2);
    }
    expect(a.level, 4);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(
        a,
        stats: {...healthy(), 'video_feedback_reports': 2},
        send: false,
        receive: false,
        videoReceivers: 2,
      );
    }
    expect(a.level, 3);
  });

  test('fresh bad partial room feedback still substantiates video advice', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      native(a, stats: {...healthy(), 'tx_loss_pct': 12}, audioReceivers: 2);
    }
    expect(a.atFloor, isTrue);
    expect(a.audioReserve, isTrue);
    expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
  });

  test('RTT bloat lowers video and a changed baseline can recover', () {
    final a = direct();
    good(a, 10);
    for (var i = 0; i < 2; i++) {
      a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.level, 2);
    for (var i = 0; i < CallBitrateAdapter.minWindowSamples * 2 + 1; i++) {
      a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.rttBaselineMs, 240);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter * 4; i++) {
      a.onSample(rttMs: 240, txJitterMs: 10, txLossPct: 0, txDrops: 0);
    }
    expect(a.level, 0);
  });

  test('marginal feedback does not earn growth', () {
    final a = direct();
    poor(a, 2);
    for (var i = 0; i < 100; i++) {
      a.onSample(rttMs: 100, txJitterMs: 60, txLossPct: 0, txDrops: 0);
    }
    expect(a.level, 2);
  });

  test('busy retunes retry only the latest requested budget', () {
    final a = direct();
    var actual = a.target;
    a.applyPendingTarget((t) {
      actual = t;
      return true;
    });
    poor(a, 2);
    expect(a.applyPendingTarget((_) => false), isFalse);
    expect(actual.maxFps, 60);
    poor(a, 2);
    expect(
      a.applyPendingTarget((t) {
        actual = t;
        return true;
      }),
      isTrue,
    );
    expect(actual, (maxBitrateKbps: 15, maxFps: 1.0));
    expect(a.applyPendingTarget((_) => throw StateError('duplicate')), isNull);
    a.invalidateAppliedTarget();
    expect(a.applyPendingTarget((_) => true), isTrue);
  });

  test(
    'busy pause and resume are retried, including after engine replacement',
    () {
      final a = direct(level: 4);
      apply(a);
      poor(a, 2);
      expect(a.applyPendingPause((_) => false), isFalse);
      final applied = <bool>[];
      expect(
        a.applyPendingPause((v) {
          applied.add(v);
          return true;
        }),
        isTrue,
      );
      for (var i = 0; i < 20; i++) {
        a.onNativeStats({'audio_feedback_reports': 0});
      }
      expect(a.audioReserve, isTrue);
      a.invalidateAppliedState();
      expect(
        a.applyPendingPause((v) {
          applied.add(v);
          return true;
        }),
        isTrue,
      );
      expect(a.applyPendingTarget((_) => true), isTrue);
      good(a, CallBitrateAdapter.recoverAfter);
      expect(a.applyPendingPause((_) => false), isFalse);
      expect(
        a.applyPendingPause((v) {
          applied.add(v);
          return true;
        }),
        isTrue,
      );
      expect(applied, [true, true, false]);
    },
  );

  test('older native retains integer budgets and never pretends to pause', () {
    final a = direct(lowRate: false);
    poor(a, 30);
    expect(a.target, (maxBitrateKbps: 30, maxFps: 1.0));
    expect(a.audioReserve, isFalse);
    final b = CallBitrateAdapter(
      baseBitrateKbps: 30,
      baseFps: 1,
      supportsLowRateVideo: false,
    );
    apply(b);
    good(b, CallBitrateAdapter.recoverAfter);
    expect(b.target, (maxBitrateKbps: 30, maxFps: 1.0));
    expect(b.applyPendingTarget((_) => throw StateError('duplicate')), isNull);
  });

  test('floor advice is latched until healthy growth', () {
    final a = direct();
    poor(a, 4);
    expect(a.atFloor, isTrue);
    expect(a.videoAdvice, CallVideoAdvice.keep);
    poor(a, CallBitrateAdapter.adviseAfter + 2);
    expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
    good(a);
    expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
    good(a, CallBitrateAdapter.recoverAfter * 2);
    expect(a.level, 3);
    expect(a.videoAdvice, CallVideoAdvice.keep);
  });

  test('a good floor sample resets advice without claiming full recovery', () {
    final a = direct(level: 4);
    poor(a, CallBitrateAdapter.adviseAfter - 1);
    good(a);
    poor(a, CallBitrateAdapter.adviseAfter - 1);
    expect(a.audioReserve, isTrue);
    expect(a.videoAdvice, CallVideoAdvice.keep);
    poor(a);
    expect(a.videoAdvice, CallVideoAdvice.suggestDisable);
  });

  test(
    'a stalled worker cannot earn video growth from stale healthy fields',
    () {
      for (final muted in [false, true]) {
        final a = direct(level: 4);
        for (var i = 0; i < 30; i++) {
          native(
            a,
            stats: {
              ...healthy(),
              'worker_stalled': 1,
              'video_worker_stalled': 1,
            },
            send: !muted,
          );
        }
        expect(a.level, 4);
        expect(
          a.audioReserve,
          isFalse,
          reason: 'staleness is not measured loss',
        );
      }
    },
  );

  test('resuming a primary counter starts a new baseline after mute', () {
    final a = direct();
    a.onNativeStats(healthy());
    a.onNativeStats(healthy(), sendAudioExpected: false);
    a.onNativeStats(healthy(audioDrops: 500));
    expect(a.level, 0);
    a.onNativeStats(healthy(audioDrops: 501));
    a.onNativeStats(healthy(audioDrops: 502));
    expect(a.level, 2);
  });
}
