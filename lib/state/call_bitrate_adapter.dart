/// Pure sender-side link-quality ladder for live call video.
///
/// Consumes the per-second engine stats sample (remote-reported outbound loss
/// and jitter from RTCP report blocks, round-trip time, and the local sender
/// queue drop counter) and walks a fixed ladder of bitrate fractions below the
/// route profile's budget. The route profile is a hard ceiling: adaptation
/// only ever spends LESS than the negotiated route allows (the padded onion
/// budget stays authoritative), so privacy decisions are never traded for
/// quality.
///
/// Pure and synchronous — no timers, no engine handles — so the policy is unit
/// testable; the media controller owns wiring it to the 1 s stats poll.
/// What the ladder has to say about video beyond its own rungs.
///
/// The ladder can only spend less; it cannot spend nothing. Once the bottom
/// rung is reached and the link is STILL bad, stepping down is no longer an
/// available move and continuing to send is not a neutral choice — measured on
/// the stand 2026-09-19, the previous bottom rung (270 kbps of a 900 kbps profile) still
/// lost 68% of outbound video, i.e. two thirds of everything sent was pushed
/// into a link that could not carry it, crowding the audio that shared it.
///
/// Advisory on purpose: the ladder states the finding, the call decides. A
/// codec policy must not silently switch off a camera the user turned on.
enum CallVideoAdvice {
  /// The link is carrying what the current rung asks of it.
  keep,

  /// The ladder is at its floor and the link is still failing. Offer to drop
  /// video; audio alone needs a fraction of the budget (measured: ~35 kbit/s
  /// against ~330 kbit/s for video+audio on the same call).
  suggestDisable,
}

class CallBitrateAdapter {
  CallBitrateAdapter({
    required this.baseBitrateKbps,
    required this.baseFps,
    int? initialLevel,
    this.supportsLowRateVideo = true,
  }) : assert(
         initialLevel == null ||
             (initialLevel >= 0 && initialLevel < ladder.length),
       ),
       _level = initialLevel ?? ladder.length - 1;

  /// Route-profile budget this call negotiated; the ladder scales below it.
  final int baseBitrateKbps;
  final int baseFps;

  /// Older native engines clamp to 30 kbit/s and integer fps. Their targets
  /// must describe the effective budget rather than cache an unapplied one.
  final bool supportsLowRateVideo;

  /// Fractions of the base bitrate budget, best-first.
  // A slow mobile link may not carry even the old 270-kbit floor. Keep one
  // further step before suggesting that the person turn the camera off.
  static const List<double> ladder = [1.0, 0.75, 0.5, 0.3, 0.05];

  /// Spend fewer video frames when audio reports persistent congestion.
  /// Small anonymous frames still occupy padded cells; shrinking their byte
  /// payload alone cannot release that part of the link's bandwidth. Healthy
  /// calls retain their full cadence, and recovery uses the same hysteresis.
  static const List<double> cadenceLadder = [1.0, 0.5, 0.25, 0.1, 0.02];

  /// Consecutive bad samples (~seconds) before stepping down.
  static const int degradeAfter = 2;

  /// Consecutive bad samples (~seconds) AT THE BOTTOM RUNG before advising
  /// that video be dropped. Deliberately much longer than [degradeAfter]: a
  /// rung change is invisible, while this one reaches the user, and a prompt
  /// that appears during a two-second burst is worse than no prompt at all.
  static const int adviseAfter = 8;

  /// Consecutive good samples (~seconds) before stepping back up. Recovery is
  /// deliberately much slower than degradation so a marginal link settles
  /// instead of oscillating.
  static const int recoverAfter = 12;

  /// A multi-second RTT means even the ordinary sparse floor can keep an
  /// ordered route queued. Reserve almost all local video bandwidth until
  /// fresh audio feedback proves recovery; retain capture and remote video.
  static const int severeRttMs = 2000;
  static const int severePlayoutMs = 1000;

  /// Conservative receive-pipeline budget. These are native buffer estimates,
  /// not a measurement of acoustic latency; RTT still guards network queues.
  static const int playoutDegradeMs = 300;
  static const int playoutRecoverMs = 200;

  /// Bufferbloat guard, relative to the call's own RTT baseline. The relay
  /// leg is TCP-like: congestion NEVER shows as loss (the transport hides
  /// it), only as queueing delay — with the old absolute 400 ms threshold a
  /// 70 ms-baseline path could accumulate +300 ms of standing queue before
  /// the ladder reacted, felt live as "delay grows the longer the call runs".
  /// Degrade once RTT stands [bloatDegradeMs] above the windowed-min
  /// baseline; count a sample as good only within [bloatRecoverMs] of it.
  static const int bloatDegradeMs = 150;
  static const int bloatRecoverMs = 60;

  /// Windowed-min RTT baseline: two ~[minWindowSamples]-sample buckets
  /// (≈2 min total at the 1 s poll). Taking the min of the current + previous
  /// bucket tracks the propagation floor while standing queues build on top
  /// of it, yet forgets a stale floor within ~2 min after a genuine route
  /// change (a plain lifetime-min would mark the new longer path "bloated"
  /// forever and pin the ladder at the bottom rung).
  static const int minWindowSamples = 60;

  // An unmeasured link has not earned a full video budget. Start with a
  // small, sparse frame stream and climb only after sustained healthy audio.
  // initialLevel can restore an already measured policy; new calls omit it.
  int _level;
  int _badStreak = 0;
  int _floorBadStreak = 0;
  CallVideoAdvice _advice = CallVideoAdvice.keep;
  int _goodStreak = 0;
  int _severeStreak = 0;
  bool _audioReserve = false;
  int? _lastTxDrops;
  int? _curWindowMin;
  int? _prevWindowMin;
  int _windowFill = 0;
  ({int maxBitrateKbps, double maxFps})? _appliedTarget;

  /// Try the current video budget. A busy native worker leaves it pending;
  /// the next poll retries the latest budget, never a superseded one.
  /// Null means the current target was already applied.
  bool? applyPendingTarget(
    bool Function(({int maxBitrateKbps, double maxFps}) target) apply,
  ) {
    final desired = target;
    if (_appliedTarget == desired) return null;
    if (!apply(desired)) return false;
    _appliedTarget = desired;
    return true;
  }

  bool? _appliedPause;

  /// Pause immediately under severe audio pressure. A busy resume stays
  /// pending; unknown feedback never resumes video by itself.
  bool? applyPendingPause(bool Function(bool paused) apply) {
    final desired = audioReserve;
    if (_appliedPause == desired) return null;
    if (!apply(desired)) return false;
    _appliedPause = desired;
    return true;
  }

  /// A diagnostic override changed native state outside this policy.
  void invalidateAppliedTarget() => _appliedTarget = null;

  /// Current RTT baseline (windowed min), or null before any RTT sample.
  int? get rttBaselineMs => switch ((_curWindowMin, _prevWindowMin)) {
    (null, null) => null,
    (final int c, null) => c,
    (null, final int p) => p,
    (final int c, final int p) => c < p ? c : p,
  };

  void _feedBaseline(int rttMs) {
    _curWindowMin = _curWindowMin == null || rttMs < _curWindowMin!
        ? rttMs
        : _curWindowMin;
    if (++_windowFill >= minWindowSamples) {
      _prevWindowMin = _curWindowMin;
      _curWindowMin = null;
      _windowFill = 0;
    }
  }

  /// Current rung (0 = full route budget).
  int get level => _level;

  /// Whether the ladder has run out of rungs on a link that is still failing.
  ///
  /// Latched rather than momentary: it is raised after [adviseAfter] bad
  /// samples at the floor and cleared only when the ladder actually climbs
  /// back off the floor. A value that flickered with each sample would drive a
  /// prompt that appears and vanishes while the user reaches for it.
  CallVideoAdvice get videoAdvice => _advice;

  /// True while the ladder is on its last rung and cannot spend less.
  bool get atFloor => _level == ladder.length - 1;

  bool get audioReserve => _audioReserve;

  /// Target for the current rung.
  ({int maxBitrateKbps, double maxFps}) get target => _audioReserve
      ? (maxBitrateKbps: 1, maxFps: 0.02)
      : (
          maxBitrateKbps: (baseBitrateKbps * ladder[_level]).round().clamp(
            supportsLowRateVideo
                ? 1
                : (baseBitrateKbps < 30 ? baseBitrateKbps : 30),
            baseBitrateKbps,
          ),
          maxFps: supportsLowRateVideo
              ? (baseFps * cadenceLadder[_level]).clamp(
                  0.02,
                  baseFps.toDouble(),
                )
              : (baseFps * cadenceLadder[_level])
                    .round()
                    .clamp(1, 60)
                    .toDouble(),
        );

  /// Native zero defaults, expired reports and older libraries without report
  /// freshness are unknown quality. Local drops still justify reducing video.
  /// A room supplies its connected receiver count: incomplete audio feedback
  /// gives bandwidth back and cannot earn recovery; known bad reports still
  /// substantiate congestion even when other receivers have not reported.
  ({int maxBitrateKbps, double maxFps})? onNativeStats(
    Map<String, dynamic> stats, {
    int? peerAudioDelayMs,
    bool requirePeerAudioPlayout = false,
    int? expectedAudioFeedbackReports,
  }) {
    final requiredReports =
        expectedAudioFeedbackReports != null && expectedAudioFeedbackReports > 0
        ? expectedAudioFeedbackReports
        : 1;
    final reports = ((stats['audio_feedback_reports'] as num?) ?? 0);
    final anyFeedbackAvailable = stats['worker_stalled'] != 1 && reports > 0;
    final feedbackAvailable =
        anyFeedbackAvailable && reports >= requiredReports;
    return onSample(
      rttMs: anyFeedbackAvailable ? (stats['rtt_ms'] as num?)?.toInt() ?? 0 : 0,
      txJitterMs: anyFeedbackAvailable
          ? (stats['tx_jitter_ms'] as num?)?.toInt() ?? 0
          : 0,
      txLossPct: anyFeedbackAvailable
          ? (stats['tx_loss_pct'] as num?)?.toInt() ?? 0
          : 0,
      txDrops: (stats['tx_drops'] as num?)?.toInt() ?? 0,
      feedbackAvailable: feedbackAvailable,
      peerAudioDelayMs: peerAudioDelayMs,
      requirePeerAudioPlayout: requirePeerAudioPlayout,
      missingAudioReceiverFeedback:
          expectedAudioFeedbackReports != null &&
          expectedAudioFeedbackReports > 0 &&
          !feedbackAvailable,
    );
  }

  /// Feed one stats sample; returns the new target when the rung changed and
  /// null otherwise. `rttMs` of 0 means "unknown yet" and is not judged.
  ({int maxBitrateKbps, double maxFps})? onSample({
    required int rttMs,
    required int txJitterMs,
    required int txLossPct,
    required int txDrops,
    bool feedbackAvailable = true,
    int? peerAudioDelayMs,
    bool requirePeerAudioPlayout = false,
    bool missingAudioReceiverFeedback = false,
  }) {
    final newDrops = _lastTxDrops != null && txDrops > _lastTxDrops!;
    _lastTxDrops = txDrops;
    // Missing/stale reports are not healthy samples. Actual new local audio
    // drops still justify reducing video while waiting for remote feedback.
    final playoutBad =
        requirePeerAudioPlayout &&
        (peerAudioDelayMs == null || peerAudioDelayMs >= playoutDegradeMs);
    final playoutGood =
        !requirePeerAudioPlayout ||
        (peerAudioDelayMs != null && peerAudioDelayMs < playoutRecoverMs);
    if (!feedbackAvailable &&
        !newDrops &&
        !playoutBad &&
        !missingAudioReceiverFeedback) {
      _badStreak = 0;
      _floorBadStreak = 0;
      _goodStreak = 0;
      _severeStreak = 0;
      return null;
    }

    if (rttMs > 0) _feedBaseline(rttMs);
    final baseline = rttBaselineMs;
    // Bufferbloat verdicts are relative to the call's own floor; the absolute
    // 400/250 ms rails remain as the outer bound for paths whose floor is
    // itself already high.
    final rttBad =
        rttMs > 0 &&
        (rttMs >= 400 ||
            (baseline != null && rttMs >= baseline + bloatDegradeMs));
    final rttGood =
        rttMs == 0 ||
        (rttMs < 250 &&
            (baseline == null || rttMs <= baseline + bloatRecoverMs));

    final networkBad = txLossPct >= 5 || txJitterMs >= 80 || rttBad || newDrops;
    final bad = networkBad || playoutBad || missingAudioReceiverFeedback;
    final good =
        feedbackAvailable &&
        rttMs > 0 &&
        txLossPct <= 1 &&
        txJitterMs < 40 &&
        rttGood &&
        !newDrops &&
        playoutGood;

    final severe =
        rttMs >= severeRttMs ||
        (requirePeerAudioPlayout &&
            peerAudioDelayMs != null &&
            peerAudioDelayMs >= severePlayoutMs);
    _severeStreak = atFloor && severe ? _severeStreak + 1 : 0;
    if (supportsLowRateVideo &&
        !_audioReserve &&
        _severeStreak >= degradeAfter) {
      _audioReserve = true;
      _goodStreak = 0;
      return target;
    }

    if (bad) {
      _goodStreak = 0;
      _badStreak++;
      if (_badStreak >= degradeAfter && _level < ladder.length - 1) {
        _badStreak = 0;
        _level++;
        // A rung was still available, so the floor streak restarts: the new
        // rung has not been given its chance yet.
        _floorBadStreak = 0;
        return target;
      }
      // Out of rungs. THIS is the state the ladder had no way to report, and
      // the one the link was actually in while it kept sending.
      if (atFloor) {
        // Unknown playout reserves bandwidth but cannot substantiate a
        // user-facing claim that the link fails to carry video.
        if (networkBad || (playoutBad && peerAudioDelayMs != null)) {
          if (++_floorBadStreak >= adviseAfter) {
            _advice = CallVideoAdvice.suggestDisable;
          }
        } else {
          _floorBadStreak = 0;
        }
      }
      return null;
    }
    _badStreak = 0;
    _floorBadStreak = 0;
    if (!good) {
      // Marginal sample: hold the rung, restart the recovery clock.
      _goodStreak = 0;
      return null;
    }
    _goodStreak++;
    if (_audioReserve && _goodStreak >= recoverAfter) {
      _audioReserve = false;
      _severeStreak = 0;
      _goodStreak = 0;
      return target;
    }
    if (_goodStreak >= recoverAfter && _level > 0) {
      _goodStreak = 0;
      _level--;
      // Climbing off the floor is the only thing that withdraws the advice:
      // the link has demonstrably carried more than the floor asked of it.
      _advice = CallVideoAdvice.keep;
      return target;
    }
    return null;
  }
}
