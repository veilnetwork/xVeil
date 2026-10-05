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
      expect(a.audioReserve, isFalse);
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
