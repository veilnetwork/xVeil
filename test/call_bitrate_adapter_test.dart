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
    int? peerTargetDelay,
    int? peerSequence,
    bool interrupted = false,
    bool recovered = false,
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
      peerTargetAudioDelayMs: peerTargetDelay,
      peerAudioSampleSequence: peerSequence,
      audioInterrupted: interrupted,
      audioRecoveryObserved: recovered,
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
    'fresh peer decoded loss cuts video once with a recovered peer buffer',
    () {
      final a = direct();
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 1000});
      expect(a.level, 2);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 1000});
      expect(a.level, 2);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 0});
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 900});
      expect(a.level, 2);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 2000});
      expect(a.level, CallBitrateAdapter.ladder.length - 1);
    },
  );

  test(
    'peer decoded loss while audio sending is off cannot replay at resume',
    () {
      final a = direct();
      native(
        a,
        send: false,
        stats: {...healthy(), 'audio_peer_recovery_report_us': 1000},
      );
      expect(a.level, 0);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 1000});
      expect(a.level, 0);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 2000});
      expect(a.level, 2);
    },
  );

  test(
    'transport estimates without actual RTP loss cannot cut stable buffers',
    () {
      final a = direct();
      for (var i = 0; i < 60; i++) {
        native(
          a,
          stats: {
            ...healthy(drops: i * 20),
            'rtt_ms': 2500,
            'tx_jitter_ms': 100,
            'tx_loss_pct': 15,
            'audio_delay_ms': 150,
            'audio_rx_native_age_ms': 1500,
          },
          peerDelay: 150,
          peerSequence: i,
        );
      }
      expect(a.level, 0);
      expect(a.audioReserve, isFalse);
    },
  );

  test(
    'a growing receive buffer cuts two rungs before reaching the ceiling',
    () {
      final a = direct();
      for (final delay in [60, 70, 80, 90, 100, 110]) {
        native(a, stats: {...healthy(), 'audio_delay_ms': delay});
        expect(a.level, 0);
      }
      native(a, stats: {...healthy(), 'audio_delay_ms': 120});
      expect(a.level, 2);
      expect(a.audioReserve, isFalse);
    },
  );

  for (final lane in ['audio', 'video']) {
    test('fresh $lane network loss cuts once with healthy measured audio', () {
      final a = direct();
      native(a, stats: {...healthy(), '${lane}_loss_report_us': 100});
      expect(a.level, 2);
      for (var i = 0; i < 6; i++) {
        native(a, stats: {...healthy(), '${lane}_loss_report_us': 100});
      }
      expect(a.level, 2, reason: 'cached report cannot renew loss');
      native(a, stats: {...healthy(), '${lane}_loss_report_us': 0});
      native(a, stats: {...healthy(), '${lane}_loss_report_us': 50});
      expect(a.level, 2, reason: 'expiry/room removal cannot replay loss');
      native(a, stats: {...healthy(), '${lane}_loss_report_us': 101});
      expect(a.level, 4);
      expect(a.audioReserve, isFalse);
    });
    test('fresh $lane RTP loss cuts once despite healthy buffers', () {
      final a = direct();
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 7});
      expect(a.level, 0, reason: 'historical loss starts the baseline');
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 8});
      expect(a.level, 2);
      for (var i = 0; i < 6; i++) {
        native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 8});
      }
      expect(a.level, 2, reason: 'a cached count is not repeated loss');
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 0});
      expect(a.level, 2, reason: 'counter reset is not a new loss');
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 1});
      expect(a.level, 4);
      expect(a.audioReserve, isFalse);
    });
    test('replacement engine starts a new $lane loss baseline', () {
      final a = direct();
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 1});
      a.invalidateAppliedState();
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 10});
      expect(a.level, 0, reason: 'replacement snapshot is not a new event');
      native(a, stats: {...healthy(), '${lane}_tx_rtp_drops': 11});
      expect(a.level, 2);
    });
  }
  test('ongoing fresh audio network loss cannot earn video resume', () {
    final a = direct();
    for (var i = 0; i < 4; i++) {
      native(a, interrupted: true);
    }
    expect(a.audioReserve, isTrue);
    for (var i = 1; i <= CallBitrateAdapter.recoverAfter + 1; i++) {
      native(a, stats: {...healthy(), 'audio_loss_report_us': i});
      expect(a.audioReserve, isTrue);
    }
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a, stats: {...healthy(), 'audio_loss_report_us': 100});
    }
    expect(a.audioReserve, isTrue, reason: 'first new report resets recovery');
    native(a, stats: {...healthy(), 'audio_loss_report_us': 100});
    expect(a.audioReserve, isFalse);
  });
  test('fresh RTCP loss protects the floor with an older peer', () {
    final a = direct();
    for (var i = 1; i <= 4; i++) {
      apply(a);
      a.onNativeStats({...healthy(), 'audio_loss_report_us': i});
    }
    expect(a.level, 4);
    expect(a.audioReserve, isTrue);
  });

  test(
    'isolated catch-up cuts video without immediately failing the sparse floor',
    () {
      final a = direct();
      native(a, recovered: true);
      expect(a.level, 2);
      native(a, recovered: true);
      expect(a.level, 4);
      native(a, recovered: true);
      expect(a.audioReserve, isFalse);
      native(a);
      native(a, recovered: true);
      expect(
        a.audioReserve,
        isFalse,
        reason: 'a healthy sample breaks the streak',
      );
      native(a, recovered: true);
      expect(
        a.audioReserve,
        isTrue,
        reason: 'repeated decoded discards show the floor still harms audio',
      );
    },
  );
  test('ongoing decoded catch-up cannot resume paused video', () {
    final a = direct(level: 4);
    native(a, recovered: true);
    native(a, recovered: true);
    expect(a.audioReserve, isTrue);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter + 2; i++) {
      native(a, recovered: true);
      expect(a.audioReserve, isTrue);
    }
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      native(a);
    }
    expect(a.audioReserve, isFalse);
  });
  test(
    'fresh local discards need actual floor frames but not a new peer report',
    () {
      final a = direct(level: 4);
      for (var i = 0; i < 5; i++) {
        native(
          a,
          peerSequence: 1,
          recovered: true,
          stats: {...healthy(), 'video_tx_frames': 1},
        );
      }
      expect(a.audioReserve, isFalse);
      native(
        a,
        peerSequence: 1,
        recovered: true,
        stats: {...healthy(), 'video_tx_frames': 2},
      );
      expect(a.audioReserve, isFalse);
      native(
        a,
        peerSequence: 1,
        recovered: true,
        stats: {...healthy(), 'video_tx_frames': 3},
      );
      expect(
        a.audioReserve,
        isFalse,
        reason: 'first proven failed floor sample',
      );
      native(
        a,
        peerSequence: 1,
        recovered: true,
        stats: {...healthy(), 'video_tx_frames': 4},
      );
      expect(a.audioReserve, isTrue);
    },
  );
  test(
    'fresh audio interruptions reduce video, then protect a failing floor',
    () {
      final a = direct();
      native(a, interrupted: true);
      expect(a.level, 2);
      native(a, interrupted: true);
      expect(a.level, 4);
      native(a, interrupted: true);
      native(a, interrupted: true);
      expect(a.audioReserve, isTrue);
    },
  );
  test('RTP loss while camera is off is not a new video failure on resume', () {
    final a = direct();
    native(a, stats: {...healthy(), 'video_tx_rtp_drops': 0}, video: false);
    native(a, stats: {...healthy(), 'video_tx_rtp_drops': 10}, video: false);
    native(a, stats: {...healthy(), 'video_tx_rtp_drops': 10});
    expect(a.level, 0);
  });

  test('growth is measured independently for the two audio directions', () {
    final a = direct();
    for (var i = 0; i < 7; i++) {
      native(
        a,
        stats: {...healthy(), 'audio_delay_ms': 140 - i * 10},
        peerDelay: 60 + i * 10,
        peerSequence: i,
      );
    }
    expect(a.level, 2);
  });

  test('a recovered peer buffer cannot cut video using an older rise', () {
    final a = direct();
    final delays = [52, 52, 52, 90, 93, 73, 73];
    for (var i = 0; i < delays.length; i++) {
      native(a, peerDelay: delays[i], peerSequence: i);
    }
    expect(a.level, 0);
    expect(a.audioReserve, isFalse);
  });

  test('a draining audio sample cannot falsely fail the one-fps trial', () {
    final a = direct(level: 4);
    for (final delay in [80, 80, 88, 101, 128, 110, 130]) {
      native(
        a,
        stats: {...healthy(), 'audio_delay_ms': delay},
        peerDelay: 123,
        currentPeerDelay: 123,
        peerSequence: 1,
      );
    }
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 1.0);
    expect(
      a.audioBufferPressure,
      isTrue,
      reason: 'the subsequent fresh rise still protects audio',
    );
  });

  for (final level in [0, 4]) {
    test('cached peer growth cannot repeat a video cut at level $level', () {
      final a = direct(level: level);
      var frames = 0;
      void sample(int sequence, int delay) => native(
        a,
        stats: {...healthy(), 'video_tx_frames': ++frames},
        peerDelay: delay,
        peerSequence: sequence,
      );
      for (var i = 0; i < 6; i++) {
        sample(i, 60);
      }
      sample(6, 70);
      sample(7, 100);
      sample(8, 130);
      expect(a.audioBufferPressure, isTrue);
      for (var i = 0; i < 20; i++) {
        sample(8, 130);
      }
      expect(a.audioBufferPressure, isTrue, reason: 'pressure is retained');
      expect(a.level, level, reason: 'one report is not several bad samples');
      expect(a.audioReserve, isFalse);
      expect(a.videoAdvice, CallVideoAdvice.keep);
      sample(9, 150);
      if (level == 0) {
        expect(
          a.level,
          2,
          reason: 'a fresh growth sample still cuts two rungs',
        );
      } else {
        expect(
          a.audioReserve,
          isTrue,
          reason: 'fresh failure of the floor pauses',
        );
      }
    });
  }

  test('fresh local growth still pauses with a cached healthy peer', () {
    final a = direct(level: 4);
    for (final delay in [60, 70, 80, 90, 100, 110, 120]) {
      native(
        a,
        stats: {...healthy(), 'audio_delay_ms': delay},
        peerSequence: 1,
      );
    }
    expect(a.audioReserve, isTrue);
  });

  test('pre-floor growth cannot prove the new one-fps trial failed', () {
    final a = direct();
    var frames = 0;
    var sequence = 0;
    void tick(int delay, {bool growing = true}) {
      apply(a);
      a.onNativeStats(
        {...healthy(), 'video_tx_frames': ++frames},
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: delay,
        peerCurrentAudioDelayMs: delay,
        peerAudioSampleSequence: ++sequence,
        peerAudioBufferGrowing: growing,
      );
      apply(a);
    }

    // The peer's six-sample trend still includes the higher sending rungs.
    for (final delay in [70, 80, 90, 100]) {
      tick(delay);
    }
    expect(a.atFloor, isTrue);
    expect(a.audioReserve, isFalse);
    for (final delay in [110, 120, 120]) {
      tick(delay);
    }
    expect(
      a.audioBufferPressure,
      isTrue,
      reason: 'the old growth verdict still prevents a larger video budget',
    );
    expect(
      a.audioReserve,
      isFalse,
      reason: 'the trial needs its own window, not a higher-rung verdict',
    );
    expect(a.videoAdvice, CallVideoAdvice.keep);
    for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
      tick(120, growing: false);
    }
    expect(a.audioReserve, isFalse);
    expect(a.level, 3);
  });

  test(
    'bounded healthy audio can resume only a probe despite a growth verdict',
    () {
      final a = direct(level: 4);
      native(a, peerDelay: 300);
      native(a, peerDelay: 300);
      expect(a.audioReserve, isTrue);
      var sequence = 0;
      var frames = 0;
      void tick({required bool paused}) {
        apply(a);
        a.onNativeStats(
          {
            ...healthy(),
            'audio_delay_ms': 90,
            'video_tx_frames': paused ? frames : ++frames,
          },
          receiveAudioExpected: true,
          requireAudioReceivePlayout: true,
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: 100,
          peerCurrentAudioDelayMs: 100,
          peerAudioSampleSequence: ++sequence,
          peerAudioBufferGrowing: true,
        );
        apply(a);
      }

      for (var i = 0; i < CallBitrateAdapter.recoverAfter - 1; i++) {
        tick(paused: true);
        expect(a.audioReserve, isTrue);
      }
      tick(paused: true);
      expect(a.audioReserve, isFalse);
      expect(a.target.maxFps, 1);
      for (var i = 0; i < 30; i++) {
        tick(paused: false);
        expect(a.audioReserve, isFalse);
        expect(
          a.level,
          4,
          reason: 'the growth verdict still forbids a larger video budget',
        );
      }
    },
  );

  for (final direction in ['local', 'peer']) {
    test('new $direction growth during the floor trial still pauses video', () {
      final a = direct(level: 4);
      var frames = 0;
      var sequence = 0;
      void tick(int delay, {bool growing = false}) {
        apply(a);
        a.onNativeStats(
          {
            ...healthy(),
            'video_tx_frames': ++frames,
            'audio_delay_ms': direction == 'local' ? delay : 60,
          },
          receiveAudioExpected: true,
          requireAudioReceivePlayout: true,
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: direction == 'peer' ? delay : 60,
          peerCurrentAudioDelayMs: direction == 'peer' ? delay : 60,
          peerAudioSampleSequence: ++sequence,
          peerAudioBufferGrowing: direction == 'peer' && growing,
        );
        apply(a);
      }

      for (var i = 0; i < 8; i++) {
        tick(60);
      }
      expect(a.atFloor, isTrue);
      for (final delay in [70, 80, 90, 100, 110, 120]) {
        tick(delay, growing: true);
      }
      expect(
        a.audioReserve,
        isTrue,
        reason: 'trial-only growth must still protect audio below 200 ms',
      );
    });
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

  test('stale measurements hold earned video without claiming an outage', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      native(a, stats: {'audio_feedback_reports': 0}, peerDelay: null);
    }
    expect(a.target.maxFps, 60.0);
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

  for (final failure in ['receive buffer', 'peer buffer']) {
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

  test('an old peak cannot reduce video when the current buffer recovered', () {
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
    expect(a.level, 0);
    expect(a.audioReserve, isFalse);
    expect(a.videoAdvice, CallVideoAdvice.keep);
    expect(a.target.maxFps, 60);
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

  test('current recovery resumes and grows video despite a drained peak', () {
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
      greaterThan(1),
      reason: 'fresh healthy buffers can earn growth after a peak drains',
    );
  });

  test('secondary losses alone never pause known healthy audio', () {
    final a = direct();
    for (var i = 0; i < 60; i++) {
      native(a, stats: healthy(drops: i * 20));
    }
    expect(a.level, 0);
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 60.0);
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
    native(a, peerDelay: 300);
    native(a, peerDelay: 300);
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
        native(a, peerDelay: 300);
        native(a, peerDelay: 300);
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
    native(a, peerDelay: 300);
    native(a, peerDelay: 300);
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
    native(a, peerDelay: 300);
    native(a, peerDelay: 300);
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

  test('fresh primary drops protect audio even without buffer telemetry', () {
    final a = direct();
    for (var i = 0; i < 8; i++) {
      native(
        a,
        stats: {'audio_feedback_reports': 0, 'audio_tx_rtp_drops': i},
        peerDelay: null,
      );
    }
    expect(a.audioReserve, isTrue);
    expect(a.level, 4);
    expect(a.audioBufferPressure, isFalse);
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
    native(a, peerDelay: 300);
    native(a, peerDelay: 300);
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
      final a = direct(level: 4);
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
      native(
        a,
        stats: {...healthy(), 'tx_loss_pct': 12},
        peerDelay: 300,
        audioReceivers: 2,
      );
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
    expect(a.level, 2);
    a.onNativeStats(healthy(audioDrops: 502));
    expect(a.level, 4);
  });
  test('requested buffer withholds growth without cutting measured video', () {
    final a = direct(level: 2);
    for (var n = 0; n < 30; n++) {
      native(a, stats: {...healthy(), 'audio_jb_target_ms': 220});
    }
    expect(a.level, 2);
    final b = direct();
    for (var n = 0; n < 30; n++) {
      native(b, stats: {...healthy(), 'audio_jb_target_ms': 199});
    }
    expect(b.level, 0);
  });
  test(
    'requested peer buffer withholds growth without changing actual delay',
    () {
      final a = direct(level: 2);
      for (var n = 0; n < 30; n++) {
        native(a, peerTargetDelay: 300, peerSequence: n);
      }
      expect(a.level, 2);
      final b = direct();
      for (var n = 0; n < 30; n++) {
        native(b, peerDelay: null, peerTargetDelay: 300, peerSequence: n);
      }
      expect(b.level, 0, reason: 'a target alone cannot validate absent audio');
      final c = direct();
      for (var n = 0; n < 30; n++) {
        native(
          c,
          stats: {
            ...healthy(),
            'audio_rx_native_age_ms': 4000,
            'audio_jb_target_ms': 300,
          },
        );
      }
      expect(c.level, 0, reason: 'stale receive targets are not new pressure');
    },
  );
}
