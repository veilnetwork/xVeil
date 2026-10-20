import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

void main() {
  final times = Expando<DateTime>();
  DateTime nextTime(CallBitrateAdapter adapter) =>
      times[adapter] = (times[adapter] ?? DateTime(2026, 10, 19)).add(
        const Duration(seconds: 1),
      );
  test('released source constraint grows from acknowledged reduced output', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 900,
      baseFps: 60,
      initialLevel: 0,
      supportsLowRateVideo: true,
    );
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    a.constrainSource(floor: true, paused: false);
    a.applyPendingTarget((_) => true);
    final floor = a.acknowledgedTarget!;
    expect(floor.maxFps, 1);
    expect(floor.maxBitrateKbps, 15);
    a.constrainSource(floor: true, paused: true);
    expect(a.applyPendingPause((_) => false), isFalse);
    expect(a.acknowledgedPause, isFalse);
    expect(a.applyPendingPause((_) => true), isTrue);
    a.constrainSource(floor: false, paused: false);
    var previous = floor;
    for (var n = 1; n <= 20; n++) {
      a.onNativeStats(
        {
          'worker_stalled': 0,
          'video_worker_stalled': 0,
          'audio_feedback_reports': 1,
          'video_feedback_reports': 1,
          'rtt_ms': 80,
          'tx_loss_pct': 0,
          'tx_jitter_ms': 10,
          'audio_rx_pkts': n * 100,
          'audio_rx_native_age_ms': 10,
          'audio_delay_ms': 60,
          'tx_drops': 0,
        },
        sampledAt: DateTime(2026, 10, 19).add(Duration(seconds: n)),
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        peerAudioDelayMs: 60,
        peerCurrentAudioDelayMs: 60,
        peerAudioSampleSequence: n,
        requirePeerAudioPlayout: true,
        expectedAudioFeedbackReports: 1,
        expectedVideoFeedbackReports: 1,
      );
      a.applyPendingTarget((_) => true);
      final current = a.acknowledgedTarget!;
      final step = (previous.maxBitrateKbps * 1.1).floor();
      expect(
        current.maxBitrateKbps,
        lessThanOrEqualTo(
          step > previous.maxBitrateKbps ? step : previous.maxBitrateKbps + 1,
        ),
      );
      expect(current.maxFps, lessThanOrEqualTo(previous.maxFps + 1));
      previous = current;
    }
    expect(previous.maxBitrateKbps, greaterThan(floor.maxBitrateKbps));
    expect(previous.maxBitrateKbps, lessThan(a.target.maxBitrateKbps));
  });

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
    bool? peerBufferGrowing,
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
      sampledAt: nextTime(a),
      videoSendExpected: video,
      sendAudioExpected: send,
      receiveAudioExpected: receive,
      requireAudioReceivePlayout: receive,
      requirePeerAudioPlayout: send,
      peerAudioDelayMs: peerDelay,
      peerCurrentAudioDelayMs: currentPeerDelay,
      peerTargetAudioDelayMs: peerTargetDelay,
      peerAudioSampleSequence: peerSequence,
      peerAudioBufferGrowing: peerBufferGrowing,
      audioInterrupted: interrupted,
      audioRecoveryObserved: recovered,
      expectedAudioFeedbackReports: audioReceivers,
      expectedVideoFeedbackReports: videoReceivers,
    );
    apply(a);
  }

  void good(CallBitrateAdapter a, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      a.onSample(
        sampledAt: nextTime(a),
        rttMs: 80,
        txJitterMs: 10,
        txLossPct: 0,
        txDrops: 0,
      );
    }
  }

  void poor(CallBitrateAdapter a, [int n = 1]) {
    for (var i = 0; i < n; i++) {
      a.onSample(
        sampledAt: nextTime(a),
        rttMs: 80,
        txJitterMs: 10,
        txLossPct: 12,
        txDrops: 0,
      );
    }
  }

  test('acknowledged native pause preserves the usable video ceiling', () {
    final a = direct(level: 4);
    apply(a);
    final floor = a.acknowledgedTarget;
    poor(a, 2);
    expect(a.audioReserve, isTrue);
    expect(a.applyPendingPause((_) => false), isFalse);
    // A library without a working pause still needs the sparse fallback.
    expect(a.target, (maxBitrateKbps: 1, maxFps: 0.02));
    expect(a.applyPendingPause((_) => true), isTrue);
    expect(a.target, floor);
    expect(
      a.applyPendingTarget((_) => throw StateError('unneeded retune')),
      isNull,
    );
    good(a, CallBitrateAdapter.recoverAfter);
    expect(a.audioReserve, isFalse);
    expect(
      a.applyPendingTarget((_) => throw StateError('unneeded retune')),
      isNull,
    );
    expect(a.applyPendingPause((_) => true), isTrue);
    expect(a.acknowledgedTarget, floor);
  });

  test(
    'late pause acknowledgement restores the floor while video is closed',
    () {
      final a = direct(level: 4);
      apply(a);
      final floor = a.acknowledgedTarget;
      poor(a, 2);
      expect(a.applyPendingPause((_) => false), isFalse);
      expect(a.applyPendingTarget((_) => true), isTrue);
      expect(a.acknowledgedTarget, (maxBitrateKbps: 1, maxFps: 0.02));
      expect(a.applyPendingPause((_) => true), isTrue);
      expect(a.applyPendingTarget((_) => true), isTrue);
      expect(a.acknowledgedTarget, floor);
      expect(a.acknowledgedPause, isTrue);
      a.invalidateAppliedState();
      expect(a.acknowledgedPause, isNull);
      expect(a.target, (maxBitrateKbps: 1, maxFps: 0.02));
    },
  );

  test('isolated short holds cannot starve acknowledged video recovery', () {
    final a = CallBitrateAdapter(
      baseBitrateKbps: 150,
      baseFps: 15,
      initialLevel: 3,
      supportsLowRateVideo: true,
    );
    a.constrainSource(floor: true, paused: false);
    a.applyPendingTarget((_) => true);
    a.applyPendingPause((_) => true);
    a.constrainSource(floor: false, paused: false);
    var previous = a.acknowledgedTarget!;
    var witness = 0;
    for (var n = 1; n <= 180; n++) {
      // The capture contains isolated reports separated by nine seconds.
      // Each briefly yields sources; no pair qualifies repeated audio damage.
      final phase = n % 9;
      if (phase == 0) witness++;
      a.onNativeStats(
        {
          ...healthy(),
          'audio_peer_concealment_report_us': witness,
          'video_tx_frames': n * 10,
        },
        sampledAt: DateTime(2026, 10, 20).add(Duration(seconds: n)),
        sourceBudgetPressured: phase <= 2 && witness > 0,
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 90,
        peerCurrentAudioDelayMs: 90,
        peerAudioSampleSequence: n,
      );
      a.applyPendingTarget((_) => true);
      final current = a.acknowledgedTarget!;
      if (phase <= 2 && witness > 0) {
        expect(current, previous, reason: 'short hold cannot spend growth');
      } else {
        expect(
          current.maxBitrateKbps,
          lessThanOrEqualTo(
            previous.maxBitrateKbps >= 150
                ? 150
                : (previous.maxBitrateKbps * 1.1).floor().clamp(
                    previous.maxBitrateKbps + 1,
                    150,
                  ),
          ),
        );
        expect(current.maxFps, lessThanOrEqualTo(previous.maxFps + 1));
      }
      previous = current;
    }
    expect(
      a.level,
      0,
      reason: 'isolated holds cannot erase all earned healthy credit',
    );
    expect(a.acknowledgedTarget, (maxBitrateKbps: 150, maxFps: 15.0));
  });

  for (final incoming in [false, true]) {
    test(
      'unconfirmed buffer rise holds earned recovery incoming=$incoming',
      () {
        final a = direct(level: 3);
        apply(a);
        var sequence = 0;
        void sample(int delay, {bool growing = false}) {
          native(
            a,
            stats: {...healthy(), 'audio_delay_ms': incoming ? delay : 50},
            peerDelay: incoming ? 50 : delay,
            currentPeerDelay: incoming ? 50 : delay,
            peerBufferGrowing: incoming ? false : growing,
            peerSequence: ++sequence,
          );
        }

        for (var n = 0; n < (incoming ? 9 : 11); n++) {
          sample(50);
        }
        final before = a.acknowledgedTarget!;
        if (incoming) {
          // The native six-sample window sees a short rise, not three seconds
          // of continuing growth. Its newest sample then drains immediately.
          sample(100);
          sample(105);
        }
        sample(110, growing: true);
        expect(a.audioBufferPressure, isFalse);
        expect(
          a.acknowledgedTarget,
          before,
          reason: 'no growth during the rise',
        );
        expect(a.level, 3);
        sample(50);
        expect(
          a.level,
          2,
          reason: 'the short rise did not erase eleven good samples',
        );
        final after = a.acknowledgedTarget!;
        expect(
          after.maxBitrateKbps,
          lessThanOrEqualTo((before.maxBitrateKbps * 1.1).floor()),
        );
        expect(after.maxFps, lessThanOrEqualTo(before.maxFps + 1));
      },
    );
  }

  test(
    'cached rising report cannot earn growth or confirm continuing damage',
    () {
      final a = direct(level: 3);
      for (var n = 1; n <= 11; n++) {
        native(
          a,
          currentPeerDelay: 60,
          peerSequence: n,
          peerBufferGrowing: false,
        );
      }
      final before = a.acknowledgedTarget;
      for (var n = 0; n < 6; n++) {
        native(
          a,
          peerDelay: 110,
          currentPeerDelay: 110,
          peerSequence: 12,
          peerBufferGrowing: true,
        );
        expect(a.acknowledgedTarget, before);
        expect(a.level, 3);
        expect(a.audioBufferPressure, isFalse);
      }
      native(
        a,
        currentPeerDelay: 60,
        peerSequence: 13,
        peerBufferGrowing: false,
      );
      expect(a.level, 2, reason: 'the hold earned no samples and erased none');
    },
  );

  test(
    'confirmed continuing growth still clears earned recovery and cuts video',
    () {
      final a = direct(level: 3);
      for (var n = 1; n <= 11; n++) {
        native(
          a,
          currentPeerDelay: 60,
          peerSequence: n,
          peerBufferGrowing: false,
        );
      }
      for (var n = 12; n <= 16; n++) {
        native(
          a,
          peerDelay: 110 + n - 12,
          currentPeerDelay: 110 + n - 12,
          peerSequence: n,
          peerBufferGrowing: true,
        );
      }
      expect(a.audioBufferPressure, isTrue);
      expect(a.level, 4);
      for (var n = 17; n < 28; n++) {
        native(
          a,
          currentPeerDelay: 60,
          peerSequence: n,
          peerBufferGrowing: false,
        );
        expect(
          a.level,
          4,
          reason: 'real pressure erased the previous recovery credit',
        );
      }
      native(
        a,
        currentPeerDelay: 60,
        peerSequence: 28,
        peerBufferGrowing: false,
      );
      expect(a.level, 3);
    },
  );

  for (final incoming in [false, true]) {
    test(
      'duration evidence keeps repeated small damage at its video rung incoming=$incoming',
      () {
        final a = direct();
        Map<String, Object> stats(int event, {int significant = 0}) => {
          ...healthy(),
          'audio_soft_loss_duration_supported': 1,
          'audio_peer_soft_loss_duration_supported': 1,
          'audio_local_soft_loss_report_us': incoming ? significant : 0,
          'audio_peer_soft_loss_report_us': incoming ? 0 : significant,
          incoming
                  ? 'audio_local_concealment_report_us'
                  : 'audio_peer_concealment_report_us':
              event,
        };
        native(a, stats: stats(100), send: !incoming);
        native(a, stats: stats(200), send: !incoming);
        expect(
          a.level,
          0,
          reason: 'two small events do not prove significant damage',
        );
        native(a, stats: stats(300, significant: 1000), send: !incoming);
        expect(
          a.level,
          2,
          reason: 'measured damage protects audio immediately',
        );
        for (var n = 0; n < 7; n++) {
          native(a, stats: stats(300, significant: 1000), send: !incoming);
          expect(
            a.level,
            2,
            reason: 'cached duration witness cannot cut again',
          );
        }
        native(
          a,
          stats: stats(300, significant: 1000),
          send: !incoming,
          interrupted: true,
        );
        expect(
          a.level,
          4,
          reason: 'duration accounting cannot mask an audio interruption',
        );
      },
    );
  }

  test(
    'partial duration diagnostics retain conservative legacy protection',
    () {
      final a = direct();
      for (final event in [100, 200]) {
        native(
          a,
          stats: {
            ...healthy(),
            'audio_peer_soft_loss_duration_supported': 1,
            'audio_peer_concealment_report_us': event,
          },
        );
      }
      expect(
        a.level,
        2,
        reason: 'missing duration witness is unknown rather than healthy',
      );
    },
  );

  test(
    'duration witnesses while receive is disabled or stalled cannot replay',
    () {
      for (final stalled in [false, true]) {
        final a = direct();
        Map<String, Object> stats(int witness, int worker) => {
          ...healthy(),
          'worker_stalled': worker,
          'audio_soft_loss_duration_supported': 1,
          'audio_peer_soft_loss_duration_supported': 1,
          'audio_local_soft_loss_report_us': witness,
          'audio_peer_soft_loss_report_us': 0,
        };
        native(a, stats: stats(1000, stalled ? 1 : 0), receive: stalled);
        native(a, stats: stats(1000, 0));
        expect(a.level, 0);
        native(a, stats: stats(2000, 0));
        expect(a.level, 2);
      }
    },
  );

  test(
    'local catch-up duration cannot be reclassified as unknown outgoing damage',
    () {
      final a = direct();
      final stats = {
        ...healthy(),
        'audio_soft_loss_duration_supported': 1,
        'audio_peer_soft_loss_duration_supported': 0,
        'audio_local_soft_loss_report_us': 0,
        'audio_peer_soft_loss_report_us': 0,
      };
      native(a, stats: stats, recovered: true);
      native(a, stats: stats, recovered: true);
      expect(a.level, 0);
      native(a, stats: {...stats, 'audio_peer_recovery_report_us': 100});
      native(a, stats: {...stats, 'audio_peer_recovery_report_us': 200});
      expect(
        a.level,
        2,
        reason: 'unknown peer damage still uses legacy protection',
      );
    },
  );

  test(
    'incoming damage remains actionable without optional packet-age diagnostics',
    () {
      for (final durationKnown in [false, true]) {
        final a = direct();
        final base = healthy()..remove('audio_rx_native_age_ms');
        for (var n = 1; n <= 2; n++) {
          a.onNativeStats(
            {
              ...base,
              if (durationKnown) ...{
                'audio_soft_loss_duration_supported': 1,
                'audio_peer_soft_loss_duration_supported': 1,
                'audio_local_soft_loss_report_us': 1000,
                'audio_peer_soft_loss_report_us': 0,
              },
            },
            sampledAt: DateTime(2026, 10, 20).add(Duration(seconds: n)),
            receiveAudioExpected: true,
            audioRecoveryObserved: true,
          );
        }
        expect(
          a.level,
          2,
          reason:
              'receiving expectation and packet-age capability are independent',
        );
      }
    },
  );

  test(
    'isolated concealment at recorded 94/62-ms buffers holds the video rung',
    () {
      final a = direct(level: 2);
      apply(a);
      final before = a.acknowledgedTarget;
      a.onNativeStats(
        {
          ...healthy(),
          'audio_delay_ms': 94,
          'audio_peer_concealment_report_us': 100,
        },
        sampledAt: DateTime(2026, 10, 19, 12),
        receiveAudioExpected: true,
        requireAudioReceivePlayout: true,
        requirePeerAudioPlayout: true,
        peerAudioDelayMs: 62,
        peerCurrentAudioDelayMs: 62,
        peerAudioSampleSequence: 1,
      );
      expect(a.level, 2);
      expect(a.audioReserve, isFalse);
      expect(a.acknowledgedTarget, before);
      expect(
        a.bufferDiagnostics['latest'],
        containsPair('soft_audio_loss_repeated', false),
      );
    },
  );

  test(
    'isolated decoded loss holds its rung, repeated fresh loss cuts once',
    () {
      final a = direct();
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 1000});
      expect(a.level, 0);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 1000});
      expect(a.level, 0);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 0});
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 900});
      expect(a.level, 0);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 2000});
      expect(a.level, 2);
    },
  );

  test('expired concealment does not combine with a new episode', () {
    final a = direct();
    final start = DateTime(2026, 10, 19);
    void report(int us, int second) => a.onNativeStats({
      ...healthy(),
      'audio_peer_concealment_report_us': us,
    }, sampledAt: start.add(Duration(seconds: second)));
    report(100, 0);
    report(100, 1);
    report(0, 2);
    report(90, 3);
    report(101, 7);
    expect(a.level, 0);
    report(102, 8);
    expect(a.level, 2);
    report(102, 9);
    expect(a.level, 2);
    a.invalidateAppliedState();
    report(200, 10);
    expect(a.level, 2, reason: 'replacement cannot join the old episode');
  });

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
      expect(a.level, 0);
      native(a, stats: {...healthy(), 'audio_peer_recovery_report_us': 3000});
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

  for (final rtt in [120, 220]) {
    test('video recovery with measured stable audio at $rtt ms RTT', () {
      final a = CallBitrateAdapter(
        baseBitrateKbps: 900,
        baseFps: 15,
        initialLevel: 2,
        supportsLowRateVideo: true,
      );
      var frames = 0;
      native(
        a,
        stats: {...healthy(), 'rtt_ms': 20, 'video_tx_frames': ++frames},
        peerSequence: 0,
      );
      for (var n = 1; n <= 75; n++) {
        native(
          a,
          stats: {...healthy(), 'rtt_ms': rtt, 'video_tx_frames': ++frames},
          peerSequence: 1 + n ~/ 5,
        );
        expect(a.audioReserve, isFalse);
      }
      if (rtt == 120) {
        expect(
          a.level,
          0,
          reason:
              'stable 120ms RTT must not pin usable audio/video at the low rung',
        );
        expect(a.acknowledgedTarget?.maxFps, 15);
      } else {
        expect(
          a.level,
          2,
          reason:
              'an RTT queue beyond the recovery margin still withholds growth',
        );
      }
    });
  }

  for (final muteAfterFirst in [false, true]) {
    test(
      'incoming concealment protects video with microphone muted=$muteAfterFirst',
      () {
        final a = direct();
        native(
          a,
          stats: {...healthy(), 'audio_local_concealment_report_us': 100},
        );
        expect(a.level, 0, reason: 'one incoming event only holds growth');
        native(
          a,
          stats: {...healthy(), 'audio_local_concealment_report_us': 100},
        );
        native(
          a,
          stats: {...healthy(), 'audio_local_concealment_report_us': 200},
          send: !muteAfterFirst,
        );
        expect(
          a.level,
          2,
          reason: 'repeated incoming damage yields local video',
        );
        for (var n = 0; n < 3; n++) {
          native(
            a,
            stats: {...healthy(), 'audio_local_concealment_report_us': 200},
            send: !muteAfterFirst,
          );
          expect(
            a.level,
            2,
            reason: 'cached event is not fresh incoming damage',
          );
        }
      },
    );
  }

  test('incoming events while receive is off or stalled cannot replay', () {
    for (final stalled in [false, true]) {
      final a = direct();
      native(
        a,
        stats: {
          ...healthy(),
          'worker_stalled': stalled ? 1 : 0,
          'audio_local_concealment_report_us': 100,
        },
        receive: stalled,
      );
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 100},
      );
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 200},
      );
      expect(a.level, 0, reason: 'resume has only one fresh receive event');
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 201},
      );
      expect(a.level, 2);
    }
  });

  test('recorded 63-to-109ms spike and brief 250ms excursions hold video', () {
    for (final peerDirection in [false, true]) {
      final a = direct();
      for (final delay in [
        63,
        63,
        77,
        99,
        99,
        109,
        99,
        90,
        73,
        73,
        73,
        250,
        73,
        73,
        73,
      ]) {
        native(
          a,
          stats: {...healthy(), 'audio_delay_ms': peerDirection ? 60 : delay},
          peerDelay: peerDirection ? delay : 60,
        );
        expect(a.level, 0);
        expect(a.audioReserve, isFalse);
      }
    }
  });

  test(
    'a growing receive buffer cuts two rungs before reaching the ceiling',
    () {
      final a = direct();
      for (final delay in [20, 40, 60, 80, 100, 120, 140, 160, 180]) {
        native(a, stats: {...healthy(), 'audio_delay_ms': delay});
        expect(a.level, 0);
      }
      native(a, stats: {...healthy(), 'audio_delay_ms': 200});
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
  test('temporary video RR gap waits for native persistence evidence', () {
    final a = direct();
    native(
      a,
      stats: {
        ...healthy(),
        'video_loss_report_us': 100,
        'video_persistent_loss_report_us': 0,
      },
    );
    expect(a.level, 0);
    native(
      a,
      stats: {
        ...healthy(),
        'video_loss_report_us': 100,
        'video_persistent_loss_report_us': 200,
      },
    );
    expect(a.level, 2);
    native(
      a,
      stats: {
        ...healthy(),
        'video_loss_report_us': 300,
        'video_persistent_loss_report_us': 200,
      },
    );
    expect(a.level, 2, reason: 'raw and cached reports cannot renew a cut');
    native(
      a,
      stats: {
        ...healthy(),
        'video_loss_report_us': 300,
        'video_persistent_loss_report_us': 0,
      },
    );
    expect(a.level, 2);
  });
  test(
    'peer concealment repeats before cutting and never fabricates network loss',
    () {
      final a = direct();
      a.onNativeStats({...healthy(), 'audio_peer_concealment_report_us': 100});
      expect(a.level, 0);
      final diagnostic = a.bufferDiagnostics['latest'] as Map;
      expect(diagnostic['audio_peer_concealment'], isTrue);
      expect(diagnostic['audio_network_loss'], isFalse);
      a.onNativeStats({...healthy(), 'audio_peer_concealment_report_us': 100});
      expect(a.level, 0);
      a.onNativeStats({
        ...healthy(),
        'audio_peer_concealment_report_us': 200,
      }, sendAudioExpected: false);
      a.onNativeStats({...healthy(), 'audio_peer_concealment_report_us': 200});
      expect(a.level, 0, reason: 'muted event was already consumed');
      a.onNativeStats({...healthy(), 'audio_peer_concealment_report_us': 300});
      expect(a.level, 0, reason: 'mute transition starts a new episode');
      a.onNativeStats({...healthy(), 'audio_peer_concealment_report_us': 400});
      expect(a.level, 2);
    },
  );

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
    for (var i = 0; i < CallBitrateAdapter.probeResumeAfter; i++) {
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
    'only repeated catch-up cuts video and then measures the sparse floor',
    () {
      final a = direct();
      native(a, recovered: true);
      expect(a.level, 0);
      native(a, recovered: true);
      expect(a.level, 2);
      for (var second = 3; second <= 8; second++) {
        native(a, recovered: true);
      }
      expect(a.level, 4);
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
    'a burst of soft audio recovery gives each reduced video rung a trial',
    () {
      final a = direct();
      native(a, recovered: true);
      native(a, recovered: true);
      expect(a.level, 2);
      for (var second = 3; second < 8; second++) {
        native(a, recovered: true);
        expect(a.level, 2, reason: 'a short burst must not cascade to one fps');
        expect(a.audioReserve, isFalse);
      }
      native(a, recovered: true);
      expect(
        a.level,
        4,
        reason: 'continued damage still reduces video further',
      );
      expect(a.audioReserve, isFalse);
      native(a, recovered: true);
      expect(a.audioReserve, isFalse);
      native(a, recovered: true);
      expect(
        a.audioReserve,
        isTrue,
        reason: 'damage at the applied floor still pauses video',
      );
    },
  );

  test(
    'opposite-direction soft events cannot double-cut the same video trial',
    () {
      final a = direct();
      native(a, recovered: true);
      native(a, recovered: true);
      expect(a.level, 2);
      native(
        a,
        send: false,
        stats: {...healthy(), 'audio_local_concealment_report_us': 100},
      );
      native(
        a,
        send: false,
        stats: {...healthy(), 'audio_local_concealment_report_us': 200},
      );
      expect(a.level, 2);
      expect(a.audioReserve, isFalse);
    },
  );

  test('hard audio loss bypasses the soft video trial immediately', () {
    final a = direct();
    native(a, recovered: true);
    native(a, recovered: true);
    expect(a.level, 2);
    native(a, stats: {...healthy(), 'audio_loss_report_us': 100});
    expect(a.level, 4);
    native(a, stats: {...healthy(), 'audio_loss_report_us': 200});
    native(a, stats: {...healthy(), 'audio_loss_report_us': 300});
    expect(a.audioReserve, isTrue);
  });

  test('a capped buffer bypasses the soft video trial', () {
    final a = direct();
    native(a, recovered: true);
    native(a, recovered: true);
    expect(a.level, 2);
    native(a, peerDelay: 300);
    native(a, peerDelay: 300);
    expect(a.level, 4);
  });
  test('healthy decoded audio retries one fps before another small trim', () {
    final a = direct(level: 4);
    var frames = 1;
    while (!a.audioReserve && frames <= 8) {
      native(
        a,
        recovered: true,
        stats: {...healthy(), 'video_tx_frames': frames++},
      );
    }
    expect(a.audioReserve, isTrue);
    // The stand showed another small trim after six healthy seconds. A
    // twelve-second hold never let this sender try its floor in that gap.
    for (var i = 0; i < 2; i++) {
      native(a, stats: {...healthy(), 'video_tx_frames': frames});
      expect(a.audioReserve, isTrue);
    }
    native(a, stats: {...healthy(), 'video_tx_frames': frames});
    expect(a.audioReserve, isFalse);
    expect(a.target.maxFps, 1.0);
    expect(a.atFloor, isTrue);
    // Resuming the floor is separate from earning a larger video budget.
    for (var i = 0; i < 11; i++) {
      native(a, stats: {...healthy(), 'video_tx_frames': ++frames});
      expect(a.atFloor, isTrue);
    }
    native(a, stats: {...healthy(), 'video_tx_frames': ++frames});
    expect(a.level, 3);
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
    for (var i = 0; i < 10; i++) {
      native(
        a,
        stats: {...healthy(), 'audio_delay_ms': 240 - i * 20},
        peerDelay: 20 + i * 20,
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
      isFalse,
      reason: 'a brief subsequent rise still needs confirmation',
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
      for (var n = 0; n < 9; n++) {
        sample(6 + n, 20 + n * 20);
      }
      expect(a.audioBufferPressure, isTrue);
      for (var i = 0; i < 5; i++) {
        sample(14, 180);
      }
      expect(a.audioBufferPressure, isTrue, reason: 'pressure is retained');
      expect(a.level, level, reason: 'one report is not several bad samples');
      expect(a.audioReserve, isFalse);
      expect(a.videoAdvice, CallVideoAdvice.keep);
      sample(15, 200);
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
    for (final delay in [20, 40, 60, 80, 100, 120, 140, 160, 180, 200]) {
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
    for (final delay in [20, 40, 60, 80, 100, 120, 140]) {
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

      for (var i = 0; i < CallBitrateAdapter.probeResumeAfter - 1; i++) {
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

      for (var i = 0; i < 4; i++) {
        tick(60);
      }
      expect(a.atFloor, isTrue);
      for (final delay in [
        20,
        40,
        60,
        80,
        100,
        120,
        140,
        160,
        180,
        200,
        220,
        240,
      ]) {
        tick(delay, growing: true);
      }
      expect(
        a.audioReserve,
        isTrue,
        reason: 'confirmed trial-only growth protects audio below the ceiling',
      );
    });
  }

  test(
    'startup counts healthy local video samples and one new peer report per rung',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0;
      void tick(int sequence) => native(
        a,
        peerSequence: sequence,
        stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
      );

      // Health is measured every second; peer reports arrive every five.
      for (var second = 0; second < 5; second++) {
        tick(10);
        expect(a.level, 4, reason: 'a cached report cannot confirm startup');
      }
      tick(11);
      expect(
        a.level,
        3,
        reason: 'one new report confirms the already measured healthy period',
      );
      final firstRung = a.target;
      for (var second = 0; second < 45; second++) {
        tick(11);
        expect(a.level, 3, reason: 'the same report cannot fund another rung');
      }
      expect(a.acknowledgedTarget, firstRung);
      tick(12);
      expect(
        a.level,
        2,
        reason: 'a new report confirms the applied first rung',
      );
    },
  );

  test(
    'a new peer report cannot skip the healthy startup observation period',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0;
      void tick(int sequence) => native(
        a,
        peerSequence: sequence,
        stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
      );
      tick(10);
      tick(11);
      expect(
        a.level,
        4,
        reason: 'a fresh report is not three healthy measurements',
      );
      tick(11);
      expect(a.level, 3, reason: 'the new report confirms the measured period');
    },
  );

  test('a marginal RTT hold preserves the measured pending video ramp', () {
    final a = direct(level: 3);
    var frames = 0, sequence = 0;
    void tick(int rtt) => native(
      a,
      peerSequence: ++sequence,
      stats: {...healthy(), 'rtt_ms': rtt, 'video_tx_frames': ++frames},
    );
    for (var second = 0; second < CallBitrateAdapter.recoverAfter; second++) {
      tick(13);
    }
    expect(a.level, 2);
    final before = a.acknowledgedTarget!;
    expect(
      before,
      isNot(a.target),
      reason: 'a measured native ramp is pending',
    );
    // Replay the observed 156 ms RTT against a 13 ms baseline. Both audio
    // buffers remain at 60 ms, without loss or receive gaps.
    for (var second = 0; second < 5; second++) {
      tick(156);
      expect(
        a.acknowledgedTarget,
        before,
        reason: 'the RTT hold earns no growth',
      );
      expect(a.level, 2);
    }
    tick(13);
    final resumed = a.acknowledgedTarget!;
    expect(
      resumed.maxBitrateKbps,
      greaterThan(before.maxBitrateKbps),
      reason: 'a cleared RTT hold needs no extra twelve-sample recovery',
    );
    expect(
      resumed.maxBitrateKbps,
      lessThanOrEqualTo((before.maxBitrateKbps * 1.1).floor()),
    );
    expect(resumed.maxFps, lessThanOrEqualTo(before.maxFps + 1));
  });

  for (final failure in [
    'congested RTT',
    'missing peer',
    'audio buffer',
    'source pressure',
    'stalled worker',
    'audio packet drop',
  ]) {
    test('RTT grace cannot bypass $failure', () {
      final a = direct(level: 3);
      var frames = 0, sequence = 0;
      void tick({bool failing = false, bool marginal = false}) {
        apply(a);
        a.onNativeStats(
          {
            ...healthy(),
            'rtt_ms': !failing
                ? (marginal ? 156 : 13)
                : failure == 'congested RTT'
                ? 170
                : 156,
            'video_tx_frames': ++frames,
            if (failing && failure == 'audio buffer') 'audio_delay_ms': 200,
            if (failing && failure == 'stalled worker') 'worker_stalled': 1,
            if (failing && failure == 'audio packet drop')
              'audio_tx_rtp_drops': 1,
          },
          sampledAt: nextTime(a),
          sourceBudgetPressured: failing && failure == 'source pressure',
          receiveAudioExpected: true,
          requireAudioReceivePlayout: true,
          requirePeerAudioPlayout: true,
          peerAudioDelayMs: failing && failure == 'missing peer' ? null : 60,
          peerAudioSampleSequence: ++sequence,
        );
        apply(a);
      }

      for (var second = 0; second < CallBitrateAdapter.recoverAfter; second++) {
        tick();
      }
      expect(a.level, 2);
      final before = a.acknowledgedTarget!;
      tick(failing: true);
      expect(
        (a.bufferDiagnostics['latest'] as Map)['rtt_growth_hold'],
        isNot(true),
      );
      // Later healthy playout during an RTT hold cannot erase a recovery
      // debt already established by this failure.
      tick(marginal: true);
      tick();
      expect(
        a.acknowledgedTarget!.maxBitrateKbps,
        lessThanOrEqualTo(before.maxBitrateKbps),
      );
      expect(a.acknowledgedTarget!.maxFps, lessThanOrEqualTo(before.maxFps));
    });
  }

  test(
    'healthy startup quickly leaves one fps and recovers through bounded steps',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0;
      for (var i = 0; i < 90; i++) {
        native(
          a,
          stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
        );
        final actual = a.targetForStart;
        if (i == 3) expect(actual.maxFps, greaterThan(1));
        if (i == 29) expect(actual.maxFps, greaterThanOrEqualTo(6));
      }
      expect(a.target, (maxBitrateKbps: 900, maxFps: 30.0));
      expect(a.targetForStart, a.target);
    },
  );

  for (final startup in [false, true]) {
    test(
      'cached peer audio cannot earn ${startup ? 'startup' : 'normal'} video growth',
      () {
        final a = CallBitrateAdapter(
          baseBitrateKbps: 900,
          baseFps: 30,
          initialLevel: startup ? null : 3,
        );
        final initialLevel = a.level;
        var frames = 0;
        void tick(int sequence) => native(
          a,
          peerSequence: sequence,
          stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
        );

        tick(10);
        for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
          tick(10);
        }
        tick(9);
        expect(
          a.level,
          initialLevel,
          reason: 'polling a cached or older report is not new audio evidence',
        );

        if (!startup) {
          tick(11);
          expect(
            a.level,
            initialLevel - 1,
            reason: 'a new report confirms the existing healthy period',
          );
          for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
            tick(11);
          }
          expect(
            a.level,
            initialLevel - 1,
            reason: 'one report cannot confirm two budget increases',
          );
          tick(12);
          expect(
            a.level,
            initialLevel - 1,
            reason: 'unapplied ramp steps do not bank another recovery rung',
          );
          for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
            tick(12);
          }
          tick(13);
          expect(
            a.level,
            initialLevel - 2,
            reason: 'a fresh report confirms healthy traffic after the ramp',
          );
          return;
        }
        final reports = CallBitrateAdapter.startupRecoverAfter;
        for (var i = 1; i < reports; i++) {
          tick(10 + i);
          // Real peer reports arrive less frequently than local stats polls.
          // Healthy cached polls must not erase the fresh-report streak either.
          if (i < reports - 1) tick(10 + i);
        }
        expect(
          a.level,
          initialLevel - 1,
          reason: 'distinct healthy reports still permit video growth',
        );
      },
    );
  }

  test(
    'a fresh peer report during a short hold confirms recovery after it drains',
    () {
      final a = direct(level: 2);
      var frames = 0;
      void tick(int sequence, {bool event = false}) => native(
        a,
        peerSequence: sequence,
        stats: {
          ...healthy(),
          'video_tx_frames': ++frames,
          'audio_soft_loss_duration_supported': 1,
          'audio_peer_soft_loss_duration_supported': 1,
          'audio_local_soft_loss_report_us': 0,
          'audio_peer_soft_loss_report_us': 0,
          'audio_peer_concealment_report_us': event ? 100 : 0,
        },
      );
      tick(10);
      for (var i = 0; i < CallBitrateAdapter.recoverAfter; i++) {
        tick(10);
      }
      expect(a.level, 2, reason: 'one cached report cannot establish recovery');
      tick(12, event: true);
      for (var i = 0; i < 2; i++) {
        tick(12);
        expect(
          a.level,
          2,
          reason: 'the original three-second hold remains effective',
        );
      }
      tick(11);
      expect(a.level, 2, reason: 'an older report cannot confirm growth');
      tick(12);
      expect(
        a.level,
        1,
        reason:
            'a current distinct report and earned healthy time survive the short hold',
      );
      for (var i = 0; i < 60; i++) {
        tick(12);
      }
      expect(
        a.level,
        1,
        reason: 'one report cannot confirm a second promotion',
      );
    },
  );

  for (final startup in [false, true]) {
    for (final restartedSequence in [false, true]) {
      test(
        '${startup ? 'startup' : 'normal'} growth remeasures a replacement engine with ${restartedSequence ? 'restarted' : 'continuing'} peer sequence',
        () {
          final a = CallBitrateAdapter(
            baseBitrateKbps: 900,
            baseFps: 30,
            initialLevel: startup ? null : 3,
          );
          final initialLevel = a.level;
          final reports = startup
              ? CallBitrateAdapter.startupRecoverAfter
              : CallBitrateAdapter.recoverAfter;
          var frames = 0;
          void tick(int sequence) => native(
            a,
            peerSequence: sequence,
            stats: {...healthy(), 'rtt_ms': 40, 'video_tx_frames': ++frames},
          );

          for (var i = 0; i < reports - 1; i++) {
            tick(100 + i);
          }
          expect(a.level, initialLevel);
          a.invalidateAppliedState();
          final first = restartedSequence ? 1 : 300;
          tick(first);
          expect(
            a.level,
            initialLevel,
            reason: 'old engine health cannot earn the new engine an upshift',
          );
          for (var i = 1; i < reports; i++) {
            tick(first + i);
          }
          expect(
            a.level,
            initialLevel - 1,
            reason: 'new engine reports establish their own healthy streak',
          );
        },
      );
    }
  }

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

  test(
    'a relative RTT warning remeasures healthy startup without retiring it',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0, sequence = 0;
      void tick(int rtt) => native(
        a,
        peerSequence: ++sequence,
        stats: {...healthy(), 'rtt_ms': rtt, 'video_tx_frames': ++frames},
      );
      tick(16);
      final floor = a.acknowledgedTarget;
      tick(200);
      expect(a.level, 4);
      expect(
        a.acknowledgedTarget,
        floor,
        reason: 'a warning earns no video growth',
      );
      // The warning must reset startup credit, then let a newly measured
      // healthy period and a new peer report earn the bounded first step.
      tick(16);
      tick(16);
      expect(a.level, 4);
      tick(16);
      expect(
        a.level,
        3,
        reason: 'RTT alone cannot permanently retire measured healthy startup',
      );
    },
  );

  for (final failure in [
    'absolute RTT',
    'loss',
    'buffer',
    'missing peer',
    'source pressure',
    'legacy peer',
  ]) {
    test('a relative RTT warning cannot bypass $failure during startup', () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0, sequence = 0;
      void tick({bool failing = false}) {
        apply(a);
        a.onNativeStats(
          {
            ...healthy(),
            'rtt_ms': !failing
                ? 16
                : failure == 'absolute RTT'
                ? 400
                : 200,
            'video_tx_frames': ++frames,
            if (failing && failure == 'loss') 'tx_loss_pct': 8,
            if (failing && failure == 'buffer') 'audio_delay_ms': 200,
          },
          sampledAt: nextTime(a),
          sourceBudgetPressured: failing && failure == 'source pressure',
          receiveAudioExpected: true,
          requireAudioReceivePlayout: true,
          requirePeerAudioPlayout: !(failing && failure == 'legacy peer'),
          peerAudioDelayMs: failing && failure == 'missing peer' ? null : 60,
          peerAudioSampleSequence: ++sequence,
        );
        apply(a);
      }

      tick();
      tick(failing: true);
      expect(
        (a.bufferDiagnostics['latest'] as Map)['relative_rtt_warning'],
        isNot(true),
      );
      for (var n = 0; n < CallBitrateAdapter.startupRecoverAfter; n++) {
        tick();
      }
      expect(
        a.level,
        4,
        reason: 'the RTT exception cannot restore fast startup after $failure',
      );
    });
  }

  test(
    'a relative RTT warning still remeasures an already pending native ramp',
    () {
      final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
      var frames = 0, sequence = 0;
      void tick(int rtt) => native(
        a,
        peerSequence: ++sequence,
        stats: {...healthy(), 'rtt_ms': rtt, 'video_tx_frames': ++frames},
      );
      for (var n = 0; n < CallBitrateAdapter.startupRecoverAfter; n++) {
        tick(16);
      }
      expect(a.level, 3);
      final before = a.acknowledgedTarget!;
      expect(before, isNot(a.target));
      tick(200);
      expect(a.acknowledgedTarget, before);
      for (var n = 0; n < CallBitrateAdapter.recoverAfter - 1; n++) {
        tick(16);
        expect(
          a.acknowledgedTarget,
          before,
          reason: 'a relative warning resets the pending-ramp credit',
        );
      }
      tick(16);
      expect(
        a.acknowledgedTarget!.maxBitrateKbps,
        greaterThan(before.maxBitrateKbps),
      );
      expect(
        a.acknowledgedTarget!.maxFps,
        lessThanOrEqualTo(before.maxFps + 1),
      );
    },
  );

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

  test(
    'fresh incoming concealment cannot count toward resuming paused video',
    () {
      final a = direct();
      poor(a, 6);
      expect(a.audioReserve, isTrue);
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 100},
      );
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 100},
      );
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 100},
      );
      expect(a.audioReserve, isTrue);
      native(
        a,
        stats: {...healthy(), 'audio_local_concealment_report_us': 100},
      );
      expect(a.audioReserve, isFalse);
    },
  );

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
    native(a, stats: {...healthy(), 'audio_delay_ms': 53, 'audio_jb_ms': 310});
    native(a, stats: {...healthy(), 'audio_delay_ms': 53, 'audio_jb_ms': 310});
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
    for (var i = 0; i < CallBitrateAdapter.probeResumeAfter; i++) {
      native(
        a,
        stats: {
          ...healthy(),
          'rtt_ms': 600,
          'tx_jitter_ms': 100,
          'tx_loss_pct': 7,
        },
      );
      expect(a.audioReserve, i < CallBitrateAdapter.probeResumeAfter - 1);
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
    for (var i = 0; i < CallBitrateAdapter.probeResumeAfter - 1; i++) {
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
    for (var i = 0; i < CallBitrateAdapter.probeResumeAfter - 1; i++) {
      native(a);
    }
    native(a, stats: {'audio_feedback_reports': 0}, peerDelay: null);
    for (var i = 0; i < CallBitrateAdapter.probeResumeAfter - 1; i++) {
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

  test('silent video recovers despite sparse-frame packet jitter', () {
    final a = direct(level: 4);
    // Recorded Mac/Android video-only RR values, with no RTP loss and low RTT.
    const jitter = [58, 111, 34, 67, 64, 52, 103, 93, 51, 26, 81, 54];
    for (final value in jitter) {
      native(
        a,
        stats: {
          ...healthy(),
          'audio_feedback_reports': 0,
          'video_feedback_rtt_ms': 11,
          'video_feedback_jitter_ms': value,
        },
        send: false,
        receive: false,
      );
    }
    expect(a.level, 3);
    expect(a.audioReserve, isFalse);
  });

  test('silent video packet jitter alone does not cut a working rung', () {
    final a = direct();
    for (var i = 0; i < 20; i++) {
      native(
        a,
        stats: {...healthy(), 'video_feedback_jitter_ms': 111},
        send: false,
        receive: false,
      );
    }
    expect(a.level, 0);
  });

  for (final failure in ['loss', 'RTT', 'missing report']) {
    test('silent video still respects $failure with high packet jitter', () {
      final a = direct(level: 4);
      for (var i = 0; i < 30; i++) {
        native(
          a,
          stats: {
            ...healthy(),
            'video_feedback_jitter_ms': 111,
            if (failure == 'loss') 'video_feedback_loss_pct': 6,
            if (failure == 'RTT') 'video_feedback_rtt_ms': 600,
            if (failure == 'missing report') 'video_feedback_reports': 0,
          },
          send: false,
          receive: false,
        );
      }
      expect(a.level, 4);
    });
  }

  for (final sending in [true, false]) {
    test(
      'one expected audio direction retains jitter recovery guard: $sending',
      () {
        final a = direct(level: 4);
        for (var i = 0; i < 30; i++) {
          native(
            a,
            stats: {
              ...healthy(),
              'tx_jitter_ms': 111,
              'video_feedback_jitter_ms': 111,
            },
            send: sending,
            receive: !sending,
          );
        }
        expect(a.level, 4);
      },
    );
  }

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
