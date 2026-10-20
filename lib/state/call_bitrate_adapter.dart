import 'call_audio_receive_activity.dart';
import 'call_audio_buffer_window.dart';
import 'call_rtcp_loss.dart';
import 'call_audio_transient_loss.dart';
import 'call_audio_soft_loss.dart';

/// Pure sender-side link-quality ladder for live call video.
///
/// Uses current audio buffer trends and fresh media loss to cut video.
/// Transport estimates still gate improvement and serve as a fallback without
/// playout telemetry.
/// Walks a fixed ladder of bitrate fractions below the
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
       _level = initialLevel ?? ladder.length - 1,
       _startupRecovery = initialLevel == null;

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

  /// Give a reduced rung time to affect delivery before another short
  /// concealment/catch-up event can cut it again. Hard loss and sustained
  /// buffer pressure bypass this interval; damage at the applied floor still
  /// protects audio immediately through the independent pause path.
  static const softVideoTrial = Duration(seconds: 6);

  /// Healthy measured audio can retry the one-fps floor after three samples.
  /// A larger video budget still needs [recoverAfter] healthy samples. Small
  /// intermittent decoded trims must not restart a twelve-second camera hold.
  static const int probeResumeAfter = 3;

  /// A new low-latency call can probe one rung after three measured healthy
  /// video samples. Waiting twelve samples per rung kept healthy P2P video
  /// sparse for nearly a minute. Any measured failure retires this shortcut.
  static const int startupRecoverAfter = 3;

  /// A multi-second RTT means even the ordinary sparse floor can keep an
  /// ordered route queued. Reserve almost all local video bandwidth until
  /// fresh audio feedback proves recovery; retain capture and remote video.
  static const int severeRttMs = 2000;
  // Opus DTX still supplies comfort-noise packets about every 400 ms. A
  // measured one-second RTP hole is already an audio outage, even when the
  // last RTCP RTT/receiver buffer estimate remains small.
  static const int audioReceivePauseMs = 1000;
  static const int audioReceiveRecoverMs = 500;

  /// Native buffer delay is not acoustic latency. Reduce video only on a
  /// rising window or at this ceiling; stable lower buffers hold their rung.
  /// End-to-end quality is verified separately with decoded PCM measurements.
  static const int playoutDegradeMs = CallAudioBufferWindow.ceilingMs;
  static const int playoutRecoverMs = 160;

  /// Bufferbloat guard, relative to the call's own RTT baseline. The relay
  /// leg is TCP-like: congestion NEVER shows as loss (the transport hides
  /// it), only as queueing delay — with the old absolute 400 ms threshold a
  /// 70 ms-baseline path could accumulate +300 ms of standing queue before
  /// the ladder reacted, felt live as "delay grows the longer the call runs".
  /// Degrade once RTT stands [bloatDegradeMs] above the windowed-min
  /// baseline; count a sample as good only within [bloatRecoverMs] of it.
  static const int bloatDegradeMs = 150;
  // With current playout measured independently, an otherwise healthy 120ms
  // path must not keep a reduced camera pinned behind a rare 20ms RTT minimum.
  // Keep a margin below degradation and retain the bounded acknowledged ramp.
  static const int bloatRecoverMs = 120;

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
  bool _startupRecovery;
  int _startupGoodStreak = 0;
  int _audioRecoveryStreak = 0;
  int _severeStreak = 0;
  bool _audioReserve = false;
  bool _sourceFloor = false, _sourcePause = false;

  /// An owning source coordinator may require secondary work to yield before
  /// changing audio. Native ACKs still flow through the usual budget/pause
  /// methods: releasing this constraint cannot restore an unacknowledged rung.
  void constrainSource({required bool floor, required bool paused}) {
    _sourceFloor = floor || paused;
    _sourcePause = paused;
  }

  bool _supportsNativeReceiveAge = false;
  int _mutedRecoveryStreak = 0;
  int? _lastTxDrops;
  int? _lastAudioTxDrops;
  int? _lastVideoTxDrops;
  final _rtcpLoss = CallRtcpLoss();
  final _peerRecoveryLoss = CallRtcpLoss();
  final _peerConcealment = CallRtcpLoss();
  final _localConcealment = CallRtcpLoss();
  final _softLoss = CallAudioSoftLoss();
  final _transientLoss = CallAudioTransientLoss();
  final _receiveTransientLoss = CallAudioTransientLoss();
  bool? _lastTransientSendExpected;
  bool? _lastTransientReceiveExpected;
  DateTime? _lastVideoCutAt;
  int? _lastVideoTxFrames;
  int _videoIdleSamples = 0;
  int? _floorTrialLastFrames;
  int _floorTrialFrames = 0;
  int? _lastPeerSampleSequence;
  int? _recoveryPeerBaseline;
  int? _floorPeerSampleSequence;
  int? _curWindowMin;
  int? _prevWindowMin;
  int _windowFill = 0;
  int? _lastRttRouteEpoch;
  final _receiveBuffer = CallAudioBufferWindow();
  final _peerBuffer = CallAudioBufferWindow();
  // The global trend can still describe a higher rung after its budget was
  // cut. Pausing the one-fps trial needs growth in a fresh trial-only window.
  final _floorReceiveBuffer = CallAudioBufferWindow();
  final _floorPeerBuffer = CallAudioBufferWindow();
  bool _bufferPressure = false;
  bool get audioBufferPressure => _bufferPressure;
  int _bufferObservationSequence = 0;
  Map<String, Object?>? _bufferInputs;
  final List<Map<String, Object?>> _bufferHistory = [];

  /// The exact last policy inputs, unlike a later native stats snapshot.
  /// Kept local to diagnostics; no fields enter peer feedback or relay traffic.
  Map<String, Object?>? _bufferSnapshot() {
    final inputs = _bufferInputs;
    if (inputs == null) return null;
    return Map<String, Object?>.unmodifiable({
      ...inputs,
      'rtt_route_epoch': _lastRttRouteEpoch,
      'rtt_baseline_ms_after': rttBaselineMs,
      'level_after': _level,
      'bad_streak_after': _badStreak,
      'good_streak_after': _goodStreak,
      'growth_pause_transient': _growthSampleTransient,
      'ramp_recovery_needed': _rampNeedsRecovery,
      'ramp_recovery_samples_after': _rampRecoverySamples,
      'audio_recovery_streak_after': _audioRecoveryStreak,
      'severe_streak_after': _severeStreak,
      'paused_after': _audioReserve,
    });
  }

  ({int maxBitrateKbps, double maxFps})? _appliedTarget;
  ({int maxBitrateKbps, double maxFps})? _restartTarget;
  bool _growthAllowed = false;
  bool _growthSampleHealthy = false, _rampNeedsRecovery = false;
  bool _growthSampleTransient = false;
  int _rampRecoverySamples = 0;
  int _lastGrowthObservation = -1;
  DateTime? _growthSampleAt, _lastGrowthAt;

  /// Budget to restore on a newly mounted stream. An earned nominal rung can
  /// still be above the last acknowledged ramp step; recreating a stream must
  /// not jump across those unmeasured steps.
  ({int maxBitrateKbps, double maxFps}) get targetForStart {
    final previous = _appliedTarget ?? _restartTarget;
    final desired = target;
    if (previous == null) return desired;
    return (
      maxBitrateKbps: previous.maxBitrateKbps < desired.maxBitrateKbps
          ? previous.maxBitrateKbps
          : desired.maxBitrateKbps,
      maxFps: previous.maxFps < desired.maxFps
          ? previous.maxFps
          : desired.maxFps,
    );
  }

  Map<String, Object?> get bufferDiagnostics => {
    'latest': _bufferHistory.isEmpty ? null : _bufferHistory.last,
    'recent': List<Map<String, Object?>>.unmodifiable(_bufferHistory),
    'applied_video_kbps': _appliedTarget?.maxBitrateKbps,
    'applied_video_fps': _appliedTarget?.maxFps,
  };

  void _recordBufferDecision() {
    final snapshot = _bufferSnapshot();
    if (snapshot == null ||
        (_bufferHistory.isNotEmpty &&
            _bufferHistory.last['observation'] == snapshot['observation'])) {
      return;
    }
    _bufferHistory.add(snapshot);
    if (_bufferHistory.length > 16) _bufferHistory.removeAt(0);
  }

  /// Apply reductions immediately and ramp increases against fresh healthy
  /// observations. A busy native worker spends no growth step. Null means
  /// there is no admissible change now; a larger nominal rung can stay pending.
  bool? applyPendingTarget(
    bool Function(({int maxBitrateKbps, double maxFps}) target) apply,
  ) {
    final desired = target;
    if (_appliedTarget == desired) return null;
    final previous = _appliedTarget;
    var proposed = desired;
    var grows = false;
    var floorProbe = false;
    if (previous == null) {
      proposed = targetForStart;
      // Remember the cold request even if the worker is busy. Healthy audio
      // while no video budget is acknowledged cannot earn larger rungs.
      _restartTarget ??= proposed;
    } else {
      if (!_growthSampleHealthy &&
          !_growthSampleTransient &&
          (desired.maxBitrateKbps > previous.maxBitrateKbps ||
              desired.maxFps > previous.maxFps)) {
        _rampNeedsRecovery = true;
        _rampRecoverySamples = 0;
      }
      // The measured one-fps recovery trial has its own audio admission gate.
      // Fund it immediately rather than spending many polls below a usable
      // codec/header allocation after the protective pause.
      floorProbe =
          atFloor &&
          (!_audioReserve || _appliedPause == true) &&
          previous.maxFps < 1;
      final sampleAt = _growthSampleAt;
      var timeReady = true;
      final lastAt = _lastGrowthAt;
      if (sampleAt != null && lastAt != null) {
        if (sampleAt.isBefore(lastAt)) {
          // A wall-clock correction grants no step and cannot latch growth
          // against the old clock for minutes. Establish a new local interval.
          _lastGrowthAt = sampleAt;
          timeReady = false;
        } else {
          // Tolerate jitter around the caller's one-second stats timer.
          timeReady =
              sampleAt.difference(lastAt) >= const Duration(milliseconds: 950);
        }
      }
      final mayGrow =
          floorProbe ||
          (timeReady &&
              _growthAllowed &&
              _lastGrowthObservation != _bufferObservationSequence);
      final cadenceFactor = (previous.maxFps + 1) / previous.maxFps;
      final factor = cadenceFactor < 1.1 ? cadenceFactor : 1.1;
      final kbpsStep = previous.maxBitrateKbps >= baseBitrateKbps
          ? baseBitrateKbps
          : (previous.maxBitrateKbps * factor).floor().clamp(
              previous.maxBitrateKbps + 1,
              baseBitrateKbps,
            );
      final fpsStep = (previous.maxFps + 1).clamp(1, baseFps).toDouble();
      final upKbps = floorProbe ? desired.maxBitrateKbps : kbpsStep;
      final upFps = floorProbe ? desired.maxFps : fpsStep;
      proposed = (
        maxBitrateKbps: desired.maxBitrateKbps <= previous.maxBitrateKbps
            ? desired.maxBitrateKbps
            : mayGrow
            ? desired.maxBitrateKbps.clamp(1, upKbps)
            : previous.maxBitrateKbps,
        maxFps: desired.maxFps <= previous.maxFps
            ? desired.maxFps
            : mayGrow
            ? desired.maxFps.clamp(0.02, upFps)
            : previous.maxFps,
      );
      if (proposed == previous) return null;
      grows =
          proposed.maxBitrateKbps > previous.maxBitrateKbps ||
          proposed.maxFps > previous.maxFps;
    }
    if (!apply(proposed)) return false;
    if (floorProbe) {
      // This separately admitted trial starts a fresh, measured floor. Its
      // ordinary recovery period must not be preceded by an old ramp hold.
      _rampNeedsRecovery = false;
      _rampRecoverySamples = 0;
    }
    if (grows) {
      _lastGrowthObservation = _bufferObservationSequence;
      _lastGrowthAt = _growthSampleAt;
    }
    if (atFloor && !_audioReserve && proposed == desired) {
      // A report that preceded this trial cannot prove it failed.
      _floorPeerSampleSequence = _lastPeerSampleSequence;
      _floorReceiveBuffer.reset();
      _floorPeerBuffer.reset();
    }
    _appliedTarget = proposed;
    _restartTarget = null;
    return true;
  }

  bool? _appliedPause;
  ({int maxBitrateKbps, double maxFps})? get acknowledgedTarget =>
      _appliedTarget;
  bool? get acknowledgedPause => _appliedPause;

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
  void invalidateAppliedTarget() {
    _appliedTarget = null;
    _restartTarget = null;
    _growthAllowed = false;
    _growthSampleHealthy = false;
    _growthSampleTransient = false;
  }

  /// A replacement engine has no memory of either the bitrate or the pause
  /// applied to its predecessor. Keep the policy, reapply both native controls.
  void invalidateAppliedState() {
    _restartTarget = targetForStart;
    _appliedTarget = null;
    _growthAllowed = false;
    _growthSampleHealthy = false;
    _growthSampleTransient = false;
    _rampRecoverySamples = 0;
    _lastGrowthObservation = -1;
    _appliedPause = null;
    _lastRttRouteEpoch = null;
    // Native counters belong to the replaced engine. Its first snapshot is
    // a new baseline, even if it already exceeds the predecessor's count.
    _lastAudioTxDrops = null;
    _lastVideoTxDrops = null;
    _rtcpLoss.reset();
    _peerRecoveryLoss.reset();
    _peerConcealment.reset();
    _localConcealment.reset();
    _softLoss.reset();
    _transientLoss.reset();
    _receiveTransientLoss.reset();
    _lastTransientSendExpected = null;
    _lastTransientReceiveExpected = null;
    _lastVideoCutAt = null;
    _floorTrialLastFrames = null;
    _floorTrialFrames = 0;
    _floorPeerSampleSequence = null;
    // A rebuilt engine may restart native report numbering; encrypted peer
    // health may instead continue its call-wide sequence. Neither can inherit
    // the old engine's partially earned producer growth.
    _lastPeerSampleSequence = null;
    _recoveryPeerBaseline = null;
    _goodStreak = 0;
    _startupGoodStreak = 0;
    _receiveBuffer.reset();
    _peerBuffer.reset();
    _floorReceiveBuffer.reset();
    _floorPeerBuffer.reset();
    _bufferPressure = false;
    _bufferInputs = null;
    _bufferHistory.clear();
  }

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

  // The native shim advances this local epoch only after rebinding to a
  // confirmed route. It reports unknown RTT until RR/SR echoes refer to a
  // sender report generated after that handover. Old libraries omit epochs.
  bool _observeRttRoute(Map<String, dynamic> stats, bool audio) {
    final key = audio ? 'audio_rtt_route_epoch' : 'video_rtt_route_epoch';
    if (!stats.containsKey(key)) return true;
    final epoch = stats[key];
    if (epoch is! int || epoch < 0) return false;
    final previous = _lastRttRouteEpoch;
    if (previous != null && epoch < previous) return false;
    if (epoch != previous) {
      _lastRttRouteEpoch = epoch;
      _curWindowMin = null;
      _prevWindowMin = null;
      _windowFill = 0;
      _goodStreak = 0;
      _startupGoodStreak = 0;
      _audioRecoveryStreak = 0;
      if (previous != null || epoch > 0) _startupRecovery = false;
    }
    return true;
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

  bool get audioReserve => _audioReserve || _sourcePause;

  /// Begin with a one-frame/second trial when expected audio is not yet known
  /// to be healthy. Unknown feedback cannot earn a larger video budget.
  void prepareVideoSend(
    Map<String, dynamic> stats, {
    bool sendAudioExpected = true,
    bool requireAudioReceivePlayout = false,
    int? audioReceiveDelayMs,
    bool audioInterrupted = false,
    int? peerAudioDelayMs,
    bool requirePeerAudioPlayout = false,
    bool receiveAudioExpected = false,
    ({bool expected, int? ageMs})? audioReceiveQuality,
  }) {
    if (!supportsLowRateVideo) return;
    if (!sendAudioExpected &&
        !(receiveAudioExpected || (audioReceiveQuality?.expected ?? false))) {
      _releaseAudioHold();
      return;
    }
    final receive = _receiveQuality(
      stats,
      receiveAudioExpected,
      audioReceiveQuality,
    );
    final receiveUnproven =
        receive.expected &&
        (receive.ageMs == null ||
            receive.ageMs! < 0 ||
            receive.ageMs! >= audioReceiveRecoverMs);
    final playoutUnproven =
        requirePeerAudioPlayout &&
        (peerAudioDelayMs == null || peerAudioDelayMs >= playoutRecoverMs);
    final receiveDelay = audioReceiveDelayMs ?? _nativeReceiveDelay(stats);
    final receivePlayoutUnproven =
        requireAudioReceivePlayout &&
        (receiveAudioExpected || (audioReceiveQuality?.expected ?? false)) &&
        (receiveDelay == null || receiveDelay >= playoutRecoverMs);
    if (receiveUnproven ||
        playoutUnproven ||
        receivePlayoutUnproven ||
        audioInterrupted) {
      _level = ladder.length - 1;
      _goodStreak = 0;
      _startupGoodStreak = 0;
      _audioRecoveryStreak = 0;
    }
  }

  ({bool expected, int? ageMs}) _receiveQuality(
    Map<String, dynamic> stats,
    bool receiveAudioExpected,
    ({bool expected, int? ageMs})? audioReceiveQuality,
  ) {
    if (stats.containsKey('audio_rx_native_age_ms')) {
      _supportsNativeReceiveAge = true;
    }
    return audioReceiveQuality ??
        (
          expected: receiveAudioExpected && _supportsNativeReceiveAge,
          ageMs:
              ((stats['audio_rx_pkts'] as num?) ?? 0) > 0 &&
                  (stats['worker_stalled'] as num?) != 1
              ? (stats['audio_rx_native_age_ms'] as num?)?.toInt()
              : null,
        );
  }

  /// Target for the current rung.
  ({int maxBitrateKbps, double maxFps}) get target {
    // The acknowledged native gate already stops both capture admission and
    // queued video RTP. Retain the usable floor ceiling while it is closed:
    // capping GCC at 1 kbit/s also collapses its pacer, so resumed keyframe
    // fragments can emerge seconds apart and expire before assembly.
    // An absent/failed pause still needs the old sparse fallback.
    if (_audioReserve && _appliedPause != true) {
      return (maxBitrateKbps: 1, maxFps: 0.02);
    }
    var fps = supportsLowRateVideo
        ? (_level == ladder.length - 1 ? 1.0 : baseFps * cadenceLadder[_level])
              .clamp(1.0, baseFps.toDouble())
        : (baseFps * cadenceLadder[_level]).round().clamp(1, 60).toDouble();
    if (_sourceFloor && fps > 1) fps = 1;
    final rungKbps = (baseBitrateKbps * ladder[_level]).round();
    // A slower cadence must not grant each encoded frame more bytes. The
    // previous 30%-bitrate / 10%-cadence rung tripled the bytes per frame,
    // producing uplink bursts precisely while audio needed less contention.
    final cadenceKbps = (baseBitrateKbps * fps / baseFps).round();
    final cappedKbps = rungKbps < cadenceKbps ? rungKbps : cadenceKbps;
    return (
      maxBitrateKbps: cappedKbps.clamp(
        supportsLowRateVideo
            ? 1
            : (baseBitrateKbps < 30 ? baseBitrateKbps : 30),
        baseBitrateKbps,
      ),
      maxFps: fps,
    );
  }

  /// Native zero defaults, expired reports and older libraries without report
  /// freshness are unknown quality. Without playout telemetry local drops
  /// still govern the legacy ladder; unknown audio never earns improvement.
  /// A room supplies its connected receiver count: incomplete audio feedback
  /// gives bandwidth back and cannot earn recovery; known bad reports still
  /// substantiate congestion even when other receivers have not reported.
  ({int maxBitrateKbps, double maxFps})? onNativeStats(
    Map<String, dynamic> stats, {
    DateTime? sampledAt,
    bool sourceBudgetPressured = false,
    bool videoSendExpected = true,
    bool sendAudioExpected = true,
    bool requireAudioReceivePlayout = false,
    int? audioReceiveDelayMs,
    int? audioReceiveTargetDelayMs,
    bool audioInterrupted = false,
    int? peerAudioDelayMs,
    int? peerCurrentAudioDelayMs,
    int? peerTargetAudioDelayMs,
    int? peerAudioSampleSequence,
    bool? peerAudioBufferGrowing,
    bool requirePeerAudioPlayout = false,
    int? expectedAudioFeedbackReports,
    int? expectedVideoFeedbackReports,
    bool audioRecoveryObserved = false,
    bool? peerRecoveryObserved,
    bool receiveAudioExpected = false,
    // A room supplies the worst expected receiver, retaining unknown when
    // another receiver is missing. A healthy peer cannot mask a silent one.
    ({bool expected, int? ageMs})? audioReceiveQuality,
  }) {
    _growthAllowed = false;
    _growthSampleHealthy = false;
    _growthSampleTransient = false;
    _growthSampleAt = sampledAt;
    // Require a distinct peer report during this earned recovery period,
    // without requiring its arrival to coincide with the promotion poll.
    // Short holds preserve this period; failures and unapplied ramps restart
    // it through the same zero healthy streak as before.
    if (_goodStreak == 0) {
      _recoveryPeerBaseline = peerAudioSampleSequence;
    }
    final routeRttUsable = _observeRttRoute(stats, sendAudioExpected);
    final networkLoss = _rtcpLoss.observe(
      audioReportUs: stats['audio_loss_report_us'],
      videoReportUs: stats.containsKey('video_persistent_loss_report_us')
          ? stats['video_persistent_loss_report_us']
          : stats['video_loss_report_us'],
      audioExpected: sendAudioExpected,
      videoExpected: videoSendExpected,
    );
    final peerRecovered = _peerRecoveryLoss
        .observe(
          audioReportUs: stats['audio_peer_recovery_report_us'],
          audioExpected: sendAudioExpected,
          videoExpected: false,
        )
        .audio;
    final concealed = _peerConcealment
        .observe(
          audioReportUs: stats['audio_peer_concealment_report_us'],
          audioExpected: sendAudioExpected,
          videoExpected: false,
        )
        .audio;
    final localConcealed = _localConcealment
        .observe(
          audioReportUs: stats['audio_local_concealment_report_us'],
          audioExpected:
              (audioReceiveQuality?.expected ?? receiveAudioExpected) &&
              stats['worker_stalled'] == 0,
          videoExpected: false,
        )
        .audio;
    final softLoss = _softLoss.observe(
      stats,
      sending: sendAudioExpected,
      receiving:
          (audioReceiveQuality?.expected ?? receiveAudioExpected) &&
          stats['worker_stalled'] == 0,
    );
    final videoDrops = stats['video_tx_rtp_drops'];
    final validVideoDrops = videoDrops is int && videoDrops >= 0;
    final videoLoss =
        validVideoDrops &&
        videoSendExpected &&
        _lastVideoTxDrops != null &&
        videoDrops > _lastVideoTxDrops!;
    if (validVideoDrops) _lastVideoTxDrops = videoDrops;
    final expectedReports = sendAudioExpected
        ? expectedAudioFeedbackReports
        : expectedVideoFeedbackReports;
    final requiredReports = expectedReports != null && expectedReports > 0
        ? expectedReports
        : 1;
    final reports =
        ((stats[sendAudioExpected
                ? 'audio_feedback_reports'
                : 'video_feedback_reports']
            as num?) ??
        0);
    final anyFeedbackAvailable =
        stats[sendAudioExpected ? 'worker_stalled' : 'video_worker_stalled'] !=
            1 &&
        reports > 0;
    final feedbackAvailable =
        anyFeedbackAvailable && reports >= requiredReports;
    final receive = _receiveQuality(
      stats,
      receiveAudioExpected,
      audioReceiveQuality,
    );
    final receiveRequested =
        receiveAudioExpected || (audioReceiveQuality?.expected ?? false);
    final receiveDelay = audioReceiveDelayMs ?? _nativeReceiveDelay(stats);
    final receiveTarget =
        audioReceiveTargetDelayMs ??
        CallAudioReceiveActivity.nativeTargetDelay(stats);
    // With the local mic muted, no outbound audio report can establish
    // recovery. Healthy incoming audio can earn a sparse video probe; growing
    // beyond that floor still needs fresh video reports from every receiver.
    if (!sendAudioExpected) {
      final incomingHealthy =
          !receiveRequested ||
          (receive.expected &&
              receive.ageMs != null &&
              receive.ageMs! >= 0 &&
              receive.ageMs! < audioReceiveRecoverMs &&
              (!requireAudioReceivePlayout ||
                  (receiveDelay != null && receiveDelay < playoutRecoverMs)));
      final drops = (stats['tx_drops'] as num?)?.toInt() ?? 0;
      final newDrops = _lastTxDrops != null && drops > _lastTxDrops!;
      if (!networkLoss.video &&
          !videoLoss &&
          (!receiveRequested ||
              (incomingHealthy && !audioInterrupted && !newDrops))) {
        _mutedRecoveryStreak++;
        if (_audioReserve &&
            (!receiveRequested || _mutedRecoveryStreak >= recoverAfter)) {
          _releaseAudioHold();
          return target;
        }
      } else {
        _mutedRecoveryStreak = 0;
      }
    } else {
      _mutedRecoveryStreak = 0;
    }
    final videoProgress = _videoCanEarnRecovery(stats, videoSendExpected);
    final floorTrialMeasured = _observeFloorTrial(stats, videoSendExpected);
    final videoFrames = stats['video_tx_frames'];
    final outcome = onSample(
      sampledAt: sampledAt,
      sourceBudgetPressured: sourceBudgetPressured,
      videoSendExpected: videoProgress,
      measuredVideoProgress:
          videoProgress && videoFrames is num && videoFrames > 0,
      sendAudioExpected: sendAudioExpected,
      receiveAudioExpected: receiveRequested,
      rttMs: anyFeedbackAvailable && routeRttUsable
          ? (stats[sendAudioExpected ? 'rtt_ms' : 'video_feedback_rtt_ms']
                        as num?)
                    ?.toInt() ??
                0
          : 0,
      txJitterMs: anyFeedbackAvailable
          ? (stats[sendAudioExpected
                            ? 'tx_jitter_ms'
                            : 'video_feedback_jitter_ms']
                        as num?)
                    ?.toInt() ??
                0
          : 0,
      txLossPct: anyFeedbackAvailable
          ? (stats[sendAudioExpected
                            ? 'tx_loss_pct'
                            : 'video_feedback_loss_pct']
                        as num?)
                    ?.toInt() ??
                0
          : 0,
      txDrops: (stats['tx_drops'] as num?)?.toInt() ?? 0,
      audioTxDrops:
          sendAudioExpected &&
              stats['audio_tx_rtp_drops'] is int &&
              (stats['audio_tx_rtp_drops'] as int) >= 0
          ? stats['audio_tx_rtp_drops'] as int
          : null,
      feedbackAvailable: feedbackAvailable,
      anyAudioFeedbackAvailable: anyFeedbackAvailable,
      peerAudioDelayMs: peerAudioDelayMs,
      peerCurrentAudioDelayMs: peerCurrentAudioDelayMs,
      peerTargetAudioDelayMs: peerTargetAudioDelayMs,
      peerAudioSampleSequence: peerAudioSampleSequence,
      peerAudioBufferGrowing: peerAudioBufferGrowing,
      requirePeerAudioPlayout: requirePeerAudioPlayout && sendAudioExpected,
      requireAudioReceive: receive.expected,
      audioReceiveAgeMs: receive.ageMs,
      requireAudioReceivePlayout:
          requireAudioReceivePlayout && receiveRequested,
      audioReceiveDelayMs: receiveDelay,
      audioReceiveTargetDelayMs: receiveTarget,
      missingAudioReceiverFeedback: !feedbackAvailable,
      audioInterrupted: audioInterrupted,
      videoLossObserved: videoLoss,
      audioNetworkLossObserved: networkLoss.audio,
      audioConcealmentObserved: concealed,
      audioReceiveConcealmentObserved: localConcealed,
      audioSendSoftLossSignificant: softLoss.send,
      audioReceiveSoftLossSignificant: softLoss.receive,
      videoNetworkLossObserved: networkLoss.video,
      audioRecoveryObserved: peerRecoveryObserved ?? peerRecovered,
      audioReceiveRecoveryObserved: audioRecoveryObserved,
      videoFloorApplied:
          _appliedTarget == target &&
          _appliedPause != true &&
          floorTrialMeasured,
    );
    _recordBufferDecision();
    return outcome;
  }

  /// Applying a one-fps budget is not evidence that the encoder sent it.
  /// Count only new frames under that applied budget, never frames from the
  /// previous rung or engine. Older engines retain the settings-based trial.
  bool _observeFloorTrial(Map<String, dynamic> stats, bool expected) {
    if (!stats.containsKey('video_tx_frames')) return expected;
    final value = stats['video_tx_frames'];
    final count = value is num && value.isFinite && value >= 0
        ? value.toInt()
        : null;
    final previous = _floorTrialLastFrames;
    _floorTrialLastFrames = count;
    if (!expected ||
        !atFloor ||
        _audioReserve ||
        _appliedTarget != target ||
        _appliedPause == true ||
        stats['video_worker_stalled'] == 1 ||
        count == null ||
        previous == null ||
        count < previous) {
      _floorTrialFrames = 0;
      return false;
    }
    _floorTrialFrames += count - previous;
    return _floorTrialFrames >= 2;
  }

  bool _videoCanEarnRecovery(Map<String, dynamic> stats, bool expected) {
    if (!expected) {
      _lastVideoTxFrames = null;
      _videoIdleSamples = 0;
      return false;
    }
    if (stats['video_worker_stalled'] == 1) return false;
    // Older engines without this counter retain intent-based adaptation.
    if (!stats.containsKey('video_tx_frames')) return true;
    final frames = stats['video_tx_frames'];
    if (frames is! num || !frames.isFinite || frames < 0) return false;
    final count = frames.toInt();
    _videoIdleSamples = count > (_lastVideoTxFrames ?? 0)
        ? 0
        : _videoIdleSamples + 1;
    _lastVideoTxFrames = count;
    // A one-fps trial can straddle a stats poll. Two quiet samples tolerate
    // that jitter; no frames or a stalled capture cannot earn a larger budget.
    return count > 0 && _videoIdleSamples < 3;
  }

  /// Feed one stats sample; returns the new target when the rung changed and
  /// null otherwise. `rttMs` of 0 means "unknown yet" and is not judged.
  ({int maxBitrateKbps, double maxFps})? onSample({
    DateTime? sampledAt,
    bool sourceBudgetPressured = false,
    bool measuredVideoProgress = false,
    bool videoSendExpected = true,
    bool sendAudioExpected = true,
    bool receiveAudioExpected = false,
    bool requireAudioReceivePlayout = false,
    int? audioReceiveDelayMs,
    int? audioReceiveTargetDelayMs,
    bool audioInterrupted = false,
    bool videoLossObserved = false,
    bool audioNetworkLossObserved = false,
    bool audioConcealmentObserved = false,
    bool audioReceiveConcealmentObserved = false,
    bool? audioSendSoftLossSignificant,
    bool? audioReceiveSoftLossSignificant,
    bool videoNetworkLossObserved = false,
    bool audioRecoveryObserved = false,
    bool audioReceiveRecoveryObserved = false,
    required int rttMs,
    required int txJitterMs,
    required int txLossPct,
    required int txDrops,
    int? audioTxDrops,
    bool feedbackAvailable = true,
    bool? anyAudioFeedbackAvailable,
    int? peerAudioDelayMs,
    int? peerCurrentAudioDelayMs,
    int? peerTargetAudioDelayMs,
    int? peerAudioSampleSequence,
    bool? peerAudioBufferGrowing,
    bool requirePeerAudioPlayout = false,
    bool missingAudioReceiverFeedback = false,
    bool requireAudioReceive = false,
    int? audioReceiveAgeMs,
    bool videoFloorApplied = true,
  }) {
    _growthAllowed = false;
    _growthSampleHealthy = false;
    _growthSampleTransient = false;
    _growthSampleAt = sampledAt;
    final freshPeerSample =
        peerAudioSampleSequence == null ||
        (_lastPeerSampleSequence == null ||
            peerAudioSampleSequence > _lastPeerSampleSequence!);
    if (peerAudioSampleSequence != null && peerAudioSampleSequence >= 0) {
      if (freshPeerSample) _lastPeerSampleSequence = peerAudioSampleSequence;
      if (atFloor && !_audioReserve && _appliedTarget == target) {
        _floorPeerSampleSequence ??= peerAudioSampleSequence;
      }
    }
    final recoveryPeerConfirmed =
        !requirePeerAudioPlayout ||
        peerAudioSampleSequence == null ||
        (_recoveryPeerBaseline != null &&
            peerAudioSampleSequence > _recoveryPeerBaseline! &&
            peerAudioSampleSequence == _lastPeerSampleSequence);
    final hasCurrentPeerDelay =
        peerAudioDelayMs != null &&
        peerAudioDelayMs >= 0 &&
        peerAudioDelayMs <= 60000 &&
        peerCurrentAudioDelayMs != null &&
        peerCurrentAudioDelayMs >= 0 &&
        peerCurrentAudioDelayMs <= peerAudioDelayMs;
    final currentPeerDelay = hasCurrentPeerDelay
        ? peerCurrentAudioDelayMs
        : peerAudioDelayMs;
    int? validTargetDelay(int? value, int? measured) =>
        measured != null &&
            measured >= 0 &&
            measured <= 60000 &&
            value != null &&
            value >= 0 &&
            value <= 60000
        ? value
        : null;
    final receiveTarget = requireAudioReceivePlayout
        ? validTargetDelay(audioReceiveTargetDelayMs, audioReceiveDelayMs)
        : null;
    final peerTarget = requirePeerAudioPlayout
        ? validTargetDelay(peerTargetAudioDelayMs, currentPeerDelay)
        : null;
    final targetsRecovered =
        (receiveTarget == null || receiveTarget < playoutRecoverMs) &&
        (peerTarget == null || peerTarget < playoutRecoverMs);
    // Requested targets may withhold producer growth, but are not measured
    // buffer occupancy. A target alone cannot substantiate a video reduction.
    final receiveBufferPressure = _receiveBuffer.observe(
      requireAudioReceivePlayout ? audioReceiveDelayMs : null,
      sampledAt: sampledAt,
    );
    final peerBufferPressure = _peerBuffer.observe(
      requirePeerAudioPlayout ? currentPeerDelay : null,
      sequence: peerAudioSampleSequence,
      sampledAt: sampledAt,
      measuredGrowing: requirePeerAudioPlayout && hasCurrentPeerDelay
          ? peerAudioBufferGrowing
          : null,
    );
    final usePlayout = requirePeerAudioPlayout || requireAudioReceivePlayout;
    final bufferPressure = receiveBufferPressure || peerBufferPressure;
    // A cached remote growth verdict holds pressure, but is not another bad
    // measurement. Otherwise a five-second report cuts several rungs or pauses
    // the floor on consecutive one-second polls without new peer evidence.
    // Fresh local samples and the hard ceiling retain prompt protection.
    final pressureSampleCanAdvance =
        !usePlayout ||
        receiveBufferPressure ||
        (currentPeerDelay != null && currentPeerDelay >= playoutDegradeMs) ||
        freshPeerSample;
    _bufferPressure = bufferPressure;
    _bufferInputs = {
      'source_budget_pressured': sourceBudgetPressured,
      'observation': ++_bufferObservationSequence,
      'level_before': _level,
      'receive_required': requireAudioReceivePlayout,
      'receive_ms': audioReceiveDelayMs,
      'receive_target_ms': receiveTarget,
      'receive_window_ms': _receiveBuffer.diagnosticSamples,
      'receive_pressure': receiveBufferPressure,
      'peer_required': requirePeerAudioPlayout,
      'peer_peak_ms': peerAudioDelayMs,
      'peer_current_ms': currentPeerDelay,
      'peer_target_ms': peerTarget,
      'peer_sequence': peerAudioSampleSequence,
      'peer_fresh': freshPeerSample,
      'recovery_peer_baseline': _recoveryPeerBaseline,
      'recovery_peer_confirmed': recoveryPeerConfirmed,
      'peer_growing': peerAudioBufferGrowing,
      'peer_window_ms': _peerBuffer.diagnosticSamples,
      'peer_pressure': peerBufferPressure,
      'pressure_can_advance': pressureSampleCanAdvance,
      'targets_recovered': targetsRecovered,
      'feedback_available': feedbackAvailable,
      'rtt_ms': rttMs,
      'tx_jitter_ms': txJitterMs,
      'tx_loss_pct': txLossPct,
    };

    final peerTrialMeasured =
        peerAudioSampleSequence == null ||
        _floorPeerSampleSequence == null ||
        peerAudioSampleSequence > _floorPeerSampleSequence!;
    final measuredFloor = atFloor && !_audioReserve && videoFloorApplied;
    final floorReceivePressure = _floorReceiveBuffer.observe(
      measuredFloor && requireAudioReceivePlayout ? audioReceiveDelayMs : null,
      sampledAt: sampledAt,
    );
    final floorPeerPressure = _floorPeerBuffer.observe(
      measuredFloor && peerTrialMeasured && requirePeerAudioPlayout
          ? currentPeerDelay
          : null,
      sequence: peerAudioSampleSequence,
      sampledAt: sampledAt,
    );
    // Keep the original full trend for cuts and growth admission. For a
    // below-ceiling pause, additionally prove that the applied floor itself
    // failed: a peer's measured verdict may still include the previous rung.
    // The window's hard ceiling remains immediate, even before six samples.
    final floorBufferFailure =
        (receiveBufferPressure &&
            (floorReceivePressure ||
                (audioReceiveDelayMs != null &&
                    audioReceiveDelayMs >= playoutDegradeMs))) ||
        (peerBufferPressure &&
            peerTrialMeasured &&
            (floorPeerPressure ||
                (currentPeerDelay != null &&
                    currentPeerDelay >= playoutDegradeMs)));
    final newDrops = _lastTxDrops != null && txDrops > _lastTxDrops!;
    _lastTxDrops = txDrops;
    final newAudioDrops =
        audioTxDrops != null &&
        _lastAudioTxDrops != null &&
        audioTxDrops > _lastAudioTxDrops!;
    _lastAudioTxDrops = audioTxDrops;
    // Concealment or completed catch-up at a recovered buffer can be a single
    // short impairment. Hold growth briefly; require another fresh event in
    // the time window before cutting video. Actual interruption, RTP loss and
    // growing/capped buffers retain their independent protection paths.
    if (_lastTransientSendExpected != sendAudioExpected) {
      _transientLoss.reset();
      _lastTransientSendExpected = sendAudioExpected;
    }
    final repeatedTransientLoss = _transientLoss.observe(
      audioConcealmentObserved ||
          audioRecoveryObserved ||
          audioSendSoftLossSignificant == true,
      sampledAt: sampledAt,
    );
    final receiveExpected =
        receiveAudioExpected ||
        requireAudioReceive ||
        requireAudioReceivePlayout;
    if (_lastTransientReceiveExpected != receiveExpected) {
      _receiveTransientLoss.reset();
      _lastTransientReceiveExpected = receiveExpected;
    }
    final repeatedReceiveLoss = _receiveTransientLoss.observe(
      receiveExpected &&
          (audioReceiveConcealmentObserved ||
              audioReceiveRecoveryObserved ||
              audioReceiveSoftLossSignificant == true),
      sampledAt: sampledAt,
    );
    final transientGrowthHeld =
        _transientLoss.holdingGrowth || _receiveTransientLoss.holdingGrowth;
    final qualifiedSendLoss = audioSendSoftLossSignificant == null
        ? repeatedTransientLoss
        : sendAudioExpected && audioSendSoftLossSignificant;
    final qualifiedReceiveLoss =
        receiveExpected &&
        (audioReceiveSoftLossSignificant ?? repeatedReceiveLoss);
    final freshAudioLoss =
        newAudioDrops ||
        audioInterrupted ||
        audioNetworkLossObserved ||
        qualifiedSendLoss ||
        qualifiedReceiveLoss;
    final freshMediaLoss =
        freshAudioLoss || videoLossObserved || videoNetworkLossObserved;
    final lossSampleAt = sampledAt ?? DateTime.now();
    if (_lastVideoCutAt != null && lossSampleAt.isBefore(_lastVideoCutAt!)) {
      _lastVideoCutAt = null;
    }
    final softCutReady =
        _lastVideoCutAt == null ||
        lossSampleAt.difference(_lastVideoCutAt!) >= softVideoTrial;
    final hardMediaLoss =
        newAudioDrops ||
        audioInterrupted ||
        audioNetworkLossObserved ||
        videoLossObserved ||
        videoNetworkLossObserved;
    final repeatedSoftLoss = qualifiedSendLoss || qualifiedReceiveLoss;
    final videoStepLoss = hardMediaLoss || (repeatedSoftLoss && softCutReady);
    _bufferInputs?.addAll({
      'audio_rtp_drop': newAudioDrops,
      'video_rtp_drop': videoLossObserved,
      'audio_interruption': audioInterrupted,
      'audio_network_loss': audioNetworkLossObserved,
      'audio_peer_concealment': audioConcealmentObserved,
      'audio_local_concealment': audioReceiveConcealmentObserved,
      'video_network_loss': videoNetworkLossObserved,
      'audio_latency_recovery':
          audioRecoveryObserved || audioReceiveRecoveryObserved,
      'audio_receiver_latency_recovery': audioReceiveRecoveryObserved,
      'soft_audio_loss_repeated': repeatedTransientLoss || repeatedReceiveLoss,
      'soft_audio_send_significant': audioSendSoftLossSignificant,
      'soft_audio_receive_significant': audioReceiveSoftLossSignificant,
      'soft_audio_growth_held': transientGrowthHeld,
      'soft_audio_cut_held':
          repeatedSoftLoss && !softCutReady && !hardMediaLoss,
    });

    final receiveOutage =
        (requireAudioReceive &&
            audioReceiveAgeMs != null &&
            audioReceiveAgeMs >= audioReceivePauseMs) ||
        (requireAudioReceivePlayout &&
            audioReceiveDelayMs != null &&
            audioReceiveDelayMs >= playoutDegradeMs);
    final receiveGood =
        !requireAudioReceive ||
        (audioReceiveAgeMs != null &&
            audioReceiveAgeMs >= 0 &&
            audioReceiveAgeMs < audioReceiveRecoverMs);
    final peerPlayoutOutage =
        requirePeerAudioPlayout &&
        peerBufferPressure &&
        (!atFloor || peerTrialMeasured);
    // Missing measurements block growth; they do not prove buffer pressure.
    final audioUnproven =
        (requireAudioReceivePlayout && audioReceiveDelayMs == null) ||
        (requireAudioReceive &&
            (audioReceiveAgeMs == null || audioReceiveAgeMs < 0)) ||
        (requirePeerAudioPlayout && peerAudioDelayMs == null);
    // Missing/stale reports cannot earn growth or declare buffer pressure.
    final playoutBad = bufferPressure;
    final playoutGood =
        !requirePeerAudioPlayout ||
        (currentPeerDelay != null && currentPeerDelay < playoutRecoverMs);
    if (!feedbackAvailable &&
        !freshMediaLoss &&
        !newDrops &&
        !newAudioDrops &&
        !playoutBad &&
        !missingAudioReceiverFeedback &&
        !receiveOutage &&
        !audioInterrupted &&
        !audioUnproven) {
      _badStreak = 0;
      _floorBadStreak = 0;
      _goodStreak = 0;
      _startupGoodStreak = 0;
      _audioRecoveryStreak = 0;
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

    // With both microphones intentionally off, this is video RTP packet
    // jitter, not an audio playout measurement. Sparse VP8 frames produced
    // 50–110 ms jitter on a loss-free 11 ms path, cutting the camera to one
    // fps and preventing its recovery. Let video delivery/loss, RTT and the
    // acknowledged source ramp establish headroom in that mode. Any expected
    // audio direction retains the existing jitter guard.
    final audioExpected =
        sendAudioExpected ||
        receiveAudioExpected ||
        requireAudioReceive ||
        requireAudioReceivePlayout ||
        requirePeerAudioPlayout;
    final jitterBad = audioExpected && txJitterMs >= 80;
    final jitterGood = !audioExpected || txJitterMs < 40;

    final networkBad =
        txLossPct >= 5 || jitterBad || rttBad || newDrops || newAudioDrops;
    // With measured playout support, RTT/loss/gaps may withhold growth but
    // a growing/capped buffer or fresh media loss can reduce video.
    // Video-only and legacy calls retain their transport-based ladder.
    final bad = (usePlayout ? bufferPressure : networkBad) || videoStepLoss;
    final recoveredAudio =
        targetsRecovered &&
        feedbackAvailable &&
        rttMs > 0 &&
        txLossPct <= 1 &&
        jitterGood &&
        rttGood &&
        !freshAudioLoss &&
        _receiveBuffer.growing != true &&
        _peerBuffer.growing != true &&
        !bufferPressure &&
        !missingAudioReceiverFeedback &&
        !audioUnproven &&
        playoutGood &&
        !audioInterrupted &&
        receiveGood &&
        (!requireAudioReceivePlayout ||
            (audioReceiveDelayMs != null &&
                audioReceiveDelayMs < playoutRecoverMs));
    final audioGood = recoveredAudio && !transientGrowthHeld;
    // A completed isolated impairment pauses growth without erasing earned
    // healthy credit or imposing another twelve-second ramp restart. Actual
    // loss, buffer pressure and unknown/marginal measurements still reset it.
    _growthSampleTransient =
        recoveredAudio &&
        transientGrowthHeld &&
        !newDrops &&
        !freshMediaLoss &&
        videoSendExpected;
    // Audio alone cannot prove there is headroom for a larger video source.
    // Keep the measured rung while capture is off; healthy audio may still
    // release a protection pause, so an enabled sender can try its sparse floor.
    final good = audioGood && !newDrops && !freshMediaLoss && videoSendExpected;
    if (networkBad || receiveOutage || peerPlayoutOutage || freshMediaLoss) {
      _startupRecovery = false;
      _startupGoodStreak = 0;
    }
    final startupGood =
        (receiveTarget == null || receiveTarget < 100) &&
        (peerTarget == null || peerTarget < 100) &&
        _startupRecovery &&
        good &&
        measuredVideoProgress &&
        rttMs > 0 &&
        rttMs <= 60 &&
        txLossPct == 0 &&
        txJitterMs < 20 &&
        requireAudioReceivePlayout &&
        audioReceiveDelayMs != null &&
        audioReceiveDelayMs < 100 &&
        requirePeerAudioPlayout &&
        currentPeerDelay != null &&
        currentPeerDelay < 100;
    // Local polling is faster than peer playout reports. A cached healthy
    // report can keep a measured rung, but cannot establish more headroom.
    // Fast startup requires distinct samples. Ordinary recovery retains its
    // healthy observation period below and needs a distinct current report
    // during that period. Its arrival may coincide with a short growth hold;
    // the first healthy poll after the hold can then confirm the upshift.
    final freshGrowthEvidence = !requirePeerAudioPlayout || freshPeerSample;
    if (!startupGood) {
      _startupGoodStreak = 0;
    } else if (freshGrowthEvidence) {
      _startupGoodStreak++;
    }
    // A healthy measured playout can earn the one-fps probe even on a route
    // whose RTT/jitter does not permit a larger video budget. Those network
    // estimates still govern growth; they must not latch a video pause after
    // both receivers recovered. A growth verdict below the recovery rails
    // must not hold already paused video indefinitely: release only the
    // sparse floor, whose own trial window can establish a new failure.
    // Larger budgets still require !bufferPressure through audioGood.
    // Without actual playout measurements retain the older network-based
    // recovery, including freshness/report checks.
    final measuredPlayoutHealthy =
        (requirePeerAudioPlayout || requireAudioReceivePlayout) &&
        feedbackAvailable &&
        !audioUnproven &&
        !audioInterrupted &&
        !freshAudioLoss &&
        !audioConcealmentObserved &&
        !audioReceiveConcealmentObserved &&
        !audioReceiveRecoveryObserved &&
        !audioRecoveryObserved &&
        (!requirePeerAudioPlayout ||
            (currentPeerDelay != null &&
                currentPeerDelay < playoutRecoverMs)) &&
        receiveGood &&
        (!requireAudioReceivePlayout ||
            (audioReceiveDelayMs != null &&
                audioReceiveDelayMs < playoutRecoverMs)) &&
        rttMs < severeRttMs;
    if (_audioReserve &&
        !freshAudioLoss &&
        !videoLossObserved &&
        !videoNetworkLossObserved &&
        (measuredPlayoutHealthy || audioGood) &&
        (audioTxDrops != null || !newDrops)) {
      _audioRecoveryStreak++;
      final resumeAfter = measuredPlayoutHealthy
          ? probeResumeAfter
          : recoverAfter;
      if (_audioRecoveryStreak >= resumeAfter) {
        _releaseAudioHold();
        return target;
      }
    } else {
      _audioRecoveryStreak = 0;
    }

    final measuredAudioFailure =
        freshAudioLoss ||
        (usePlayout
            ? floorBufferFailure
            : receiveOutage ||
                  peerPlayoutOutage ||
                  (!measuredPlayoutHealthy &&
                      sendAudioExpected &&
                      (anyAudioFeedbackAvailable ?? feedbackAvailable) &&
                      (txLossPct >= 5 ||
                          txJitterMs >= 80 ||
                          rttMs >= severeRttMs)));
    if (atFloor && videoFloorApplied && measuredAudioFailure) {
      if (pressureSampleCanAdvance || freshAudioLoss) _severeStreak++;
    } else {
      _severeStreak = 0;
    }
    if (supportsLowRateVideo &&
        (sendAudioExpected ||
            requireAudioReceive ||
            requireAudioReceivePlayout) &&
        !_audioReserve &&
        _severeStreak >= degradeAfter) {
      _audioReserve = true;
      _goodStreak = 0;
      _audioRecoveryStreak = 0;
      return target;
    }

    if (videoStepLoss && _level < ladder.length - 1) {
      // A new RTP admission failure, peer loss report or audio interruption is
      // source congestion evidence. Consume its event once; a retained count,
      // estimated loss percentage or intentionally skipped camera frame is
      // not another failure on the next one-second poll.
      _goodStreak = 0;
      _badStreak = 0;
      _floorBadStreak = 0;
      _level = (_level + 2).clamp(0, ladder.length - 1);
      _lastVideoCutAt = lossSampleAt;
      return target;
    }
    if (bad) {
      _goodStreak = 0;
      if (!pressureSampleCanAdvance && !freshMediaLoss) return null;
      _badStreak++;
      if (_badStreak >= degradeAfter && _level < ladder.length - 1) {
        _badStreak = 0;
        _level = (_level + 2).clamp(0, ladder.length - 1);
        _lastVideoCutAt = lossSampleAt;
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
        if (usePlayout ? floorBufferFailure : networkBad) {
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
    if (sourceBudgetPressured) {
      // The shared endpoint budget still yields bandwidth to audio. Raising
      // video here only creates local drops, NACKs and another quality cut.
      // Earn new growth evidence after that hold clears; the sparse floor
      // and prompt audio protection above retain their existing behavior.
      if (!_growthSampleTransient) _goodStreak = 0;
      _startupGoodStreak = 0;
      return null;
    }
    if (!good) {
      // Marginal sample: hold the rung, restart the recovery clock.
      if (!_growthSampleTransient) _goodStreak = 0;
      return null;
    }
    _growthSampleHealthy = true;
    if (_rampNeedsRecovery) {
      if (_appliedTarget != null &&
          _appliedTarget != target &&
          ++_rampRecoverySamples < recoverAfter) {
        return null;
      }
      _rampNeedsRecovery = false;
      _rampRecoverySamples = 0;
    }
    _growthAllowed = true;
    // A recovery rung is earned by the traffic that actually ran, not by an
    // unapplied request. Continue its ramp before banking another promotion.
    if ((_appliedTarget != null || _restartTarget != null) &&
        _appliedTarget != target) {
      _goodStreak = 0;
      _startupGoodStreak = 0;
      return null;
    }
    _goodStreak++;
    if (_audioReserve && _goodStreak >= recoverAfter) {
      _audioReserve = false;
      _severeStreak = 0;
      _goodStreak = 0;
      return target;
    }
    if (((recoveryPeerConfirmed && _goodStreak >= recoverAfter) ||
            (freshGrowthEvidence &&
                _startupGoodStreak >= startupRecoverAfter)) &&
        _level > 0) {
      _goodStreak = 0;
      _startupGoodStreak = 0;
      _level--;
      if (_level == 0) _startupRecovery = false;
      // Climbing off the floor is the only thing that withdraws the advice:
      // the link has demonstrably carried more than the floor asked of it.
      _advice = CallVideoAdvice.keep;
      return target;
    }
    return null;
  }

  void _releaseAudioHold() {
    if (_audioReserve) {
      _level = ladder.length - 1;
      _startupRecovery = false;
    }
    _audioReserve = false;
    _goodStreak = 0;
    _startupGoodStreak = 0;
    _audioRecoveryStreak = 0;
    _severeStreak = 0;
    _mutedRecoveryStreak = 0;
    // The retained floor budget needs no new retune on resume. Start its
    // measurement window here even when applyPendingTarget is a no-op.
    _floorPeerSampleSequence = _lastPeerSampleSequence;
    _floorReceiveBuffer.reset();
    _floorPeerBuffer.reset();
  }

  int? _nativeReceiveDelay(Map<String, dynamic> stats) {
    return CallAudioReceiveActivity.nativePlayoutDelay(stats);
  }
}
