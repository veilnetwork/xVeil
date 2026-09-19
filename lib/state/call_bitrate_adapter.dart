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
/// the stand 2026-09-19, the bottom rung (270 kbps of a 900 kbps profile) still
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
  CallBitrateAdapter({required this.baseBitrateKbps, required this.baseFps});

  /// Route-profile budget this call negotiated; the ladder scales below it.
  final int baseBitrateKbps;
  final int baseFps;

  /// Fractions of the base bitrate budget, best-first. Frame cadence remains
  /// at the route profile's ceiling: libwebrtc already fits each frame to the
  /// target bitrate, while lowering FPS here creates visible source-side holds
  /// even when the sender queue is empty and no packet was dropped.
  static const List<double> ladder = [1.0, 0.75, 0.5, 0.3];

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

  int _level = 0;
  int _badStreak = 0;
  int _floorBadStreak = 0;
  CallVideoAdvice _advice = CallVideoAdvice.keep;
  int _goodStreak = 0;
  int? _lastTxDrops;
  int? _curWindowMin;
  int? _prevWindowMin;
  int _windowFill = 0;

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

  /// Target for the current rung.
  ({int maxBitrateKbps, int maxFps}) get target => (
    maxBitrateKbps: (baseBitrateKbps * ladder[_level]).round(),
    maxFps: baseFps,
  );

  /// Feed one stats sample; returns the new target when the rung changed and
  /// null otherwise. `rttMs` of 0 means "unknown yet" and is not judged.
  ({int maxBitrateKbps, int maxFps})? onSample({
    required int rttMs,
    required int txJitterMs,
    required int txLossPct,
    required int txDrops,
  }) {
    final newDrops = _lastTxDrops != null && txDrops > _lastTxDrops!;
    _lastTxDrops = txDrops;

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

    final bad = txLossPct >= 5 || txJitterMs >= 80 || rttBad || newDrops;
    final good = txLossPct <= 1 && txJitterMs < 40 && rttGood && !newDrops;

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
      if (atFloor && ++_floorBadStreak >= adviseAfter) {
        _advice = CallVideoAdvice.suggestDisable;
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
