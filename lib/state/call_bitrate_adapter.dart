import 'call_audio_receive_activity.dart';
import 'call_audio_buffer_window.dart';

/// Pure sender-side link-quality ladder for live call video.
///
/// Uses current audio buffer trends to cut video. Transport estimates still
/// gate improvement and serve as a fallback without playout telemetry.
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
  bool _startupRecovery;
  int _startupGoodStreak = 0;
  int _audioRecoveryStreak = 0;
  int _severeStreak = 0;
  bool _audioReserve = false;
  bool _supportsNativeReceiveAge = false;
  int _mutedRecoveryStreak = 0;
  int? _lastTxDrops;
  int? _lastAudioTxDrops;
  int? _lastVideoTxFrames;
  int _videoIdleSamples = 0;
  int? _floorTrialLastFrames;
  int _floorTrialFrames = 0;
  int? _lastPeerSampleSequence;
  int? _floorPeerSampleSequence;
  int? _curWindowMin;
  int? _prevWindowMin;
  int _windowFill = 0;
  final _receiveBuffer = CallAudioBufferWindow();
  final _peerBuffer = CallAudioBufferWindow();
  bool _bufferPressure = false;
  bool get audioBufferPressure => _bufferPressure;
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
    if (atFloor && !_audioReserve) {
      // A report that preceded this trial cannot prove it failed.
      _floorPeerSampleSequence = _lastPeerSampleSequence;
    }
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

  /// A replacement engine has no memory of either the bitrate or the pause
  /// applied to its predecessor. Keep the policy, reapply both native controls.
  void invalidateAppliedState() {
    _appliedTarget = null;
    _appliedPause = null;
    _floorTrialLastFrames = null;
    _floorTrialFrames = 0;
    _floorPeerSampleSequence = null;
    _receiveBuffer.reset();
    _peerBuffer.reset();
    _bufferPressure = false;
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
    if (_audioReserve) return (maxBitrateKbps: 1, maxFps: 0.02);
    final fps = supportsLowRateVideo
        ? (_level == ladder.length - 1 ? 1.0 : baseFps * cadenceLadder[_level])
              .clamp(1.0, baseFps.toDouble())
        : (baseFps * cadenceLadder[_level]).round().clamp(1, 60).toDouble();
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
    bool videoSendExpected = true,
    bool sendAudioExpected = true,
    bool requireAudioReceivePlayout = false,
    int? audioReceiveDelayMs,
    bool audioInterrupted = false,
    int? peerAudioDelayMs,
    int? peerCurrentAudioDelayMs,
    int? peerAudioSampleSequence,
    bool requirePeerAudioPlayout = false,
    int? expectedAudioFeedbackReports,
    int? expectedVideoFeedbackReports,
    bool receiveAudioExpected = false,
    // A room supplies the worst expected receiver, retaining unknown when
    // another receiver is missing. A healthy peer cannot mask a silent one.
    ({bool expected, int? ageMs})? audioReceiveQuality,
  }) {
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
      if (!receiveRequested ||
          (incomingHealthy && !audioInterrupted && !newDrops)) {
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
    return onSample(
      videoSendExpected: videoProgress,
      measuredVideoProgress:
          videoProgress && videoFrames is num && videoFrames > 0,
      sendAudioExpected: sendAudioExpected,
      rttMs: anyFeedbackAvailable
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
      peerAudioSampleSequence: peerAudioSampleSequence,
      requirePeerAudioPlayout: requirePeerAudioPlayout && sendAudioExpected,
      requireAudioReceive: receive.expected,
      audioReceiveAgeMs: receive.ageMs,
      requireAudioReceivePlayout:
          requireAudioReceivePlayout && receiveRequested,
      audioReceiveDelayMs: receiveDelay,
      missingAudioReceiverFeedback: !feedbackAvailable,
      audioInterrupted: audioInterrupted,
      videoFloorApplied:
          _appliedTarget == target &&
          _appliedPause != true &&
          floorTrialMeasured,
    );
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
    bool measuredVideoProgress = false,
    bool videoSendExpected = true,
    bool sendAudioExpected = true,
    bool requireAudioReceivePlayout = false,
    int? audioReceiveDelayMs,
    bool audioInterrupted = false,
    required int rttMs,
    required int txJitterMs,
    required int txLossPct,
    required int txDrops,
    int? audioTxDrops,
    bool feedbackAvailable = true,
    bool? anyAudioFeedbackAvailable,
    int? peerAudioDelayMs,
    int? peerCurrentAudioDelayMs,
    int? peerAudioSampleSequence,
    bool requirePeerAudioPlayout = false,
    bool missingAudioReceiverFeedback = false,
    bool requireAudioReceive = false,
    int? audioReceiveAgeMs,
    bool videoFloorApplied = true,
  }) {
    if (peerAudioSampleSequence != null && peerAudioSampleSequence >= 0) {
      _lastPeerSampleSequence = peerAudioSampleSequence;
      if (atFloor && !_audioReserve && _appliedTarget == target) {
        _floorPeerSampleSequence ??= peerAudioSampleSequence;
      }
    }
    final currentPeerDelay =
        peerAudioDelayMs != null &&
            peerAudioDelayMs >= 0 &&
            peerAudioDelayMs <= 60000 &&
            peerCurrentAudioDelayMs != null &&
            peerCurrentAudioDelayMs >= 0 &&
            peerCurrentAudioDelayMs <= peerAudioDelayMs
        ? peerCurrentAudioDelayMs
        : peerAudioDelayMs;
    final receiveBufferPressure = _receiveBuffer.observe(
      requireAudioReceivePlayout ? audioReceiveDelayMs : null,
    );
    final peerBufferPressure = _peerBuffer.observe(
      requirePeerAudioPlayout ? currentPeerDelay : null,
      sequence: peerAudioSampleSequence,
    );
    final usePlayout = requirePeerAudioPlayout || requireAudioReceivePlayout;
    final bufferPressure = receiveBufferPressure || peerBufferPressure;
    _bufferPressure = bufferPressure;
    final peerTrialMeasured =
        peerAudioSampleSequence == null ||
        _floorPeerSampleSequence == null ||
        peerAudioSampleSequence > _floorPeerSampleSequence!;
    final newDrops = _lastTxDrops != null && txDrops > _lastTxDrops!;
    _lastTxDrops = txDrops;
    final newAudioDrops =
        audioTxDrops != null &&
        _lastAudioTxDrops != null &&
        audioTxDrops > _lastAudioTxDrops!;
    _lastAudioTxDrops = audioTxDrops;
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

    final networkBad =
        txLossPct >= 5 ||
        txJitterMs >= 80 ||
        rttBad ||
        newDrops ||
        newAudioDrops;
    // With measured playout support, RTT/loss/gaps may withhold growth but
    // only a growing/capped buffer can reduce the current video budget.
    // Video-only and legacy calls retain their transport-based ladder.
    final bad = usePlayout ? bufferPressure : networkBad;
    final audioGood =
        feedbackAvailable &&
        rttMs > 0 &&
        txLossPct <= 1 &&
        txJitterMs < 40 &&
        rttGood &&
        !newAudioDrops &&
        !bufferPressure &&
        !missingAudioReceiverFeedback &&
        !audioUnproven &&
        playoutGood &&
        !audioInterrupted &&
        receiveGood &&
        (!requireAudioReceivePlayout ||
            (audioReceiveDelayMs != null &&
                audioReceiveDelayMs < playoutRecoverMs));
    // Audio alone cannot prove there is headroom for a larger video source.
    // Keep the measured rung while capture is off; healthy audio may still
    // release a protection pause, so an enabled sender can try its sparse floor.
    final good = audioGood && !newDrops && videoSendExpected;
    if (networkBad || receiveOutage || peerPlayoutOutage || audioInterrupted) {
      _startupRecovery = false;
      _startupGoodStreak = 0;
    }
    final startupGood =
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
    _startupGoodStreak = startupGood ? _startupGoodStreak + 1 : 0;
    // A healthy measured playout can earn the one-fps probe even on a route
    // whose RTT/jitter does not permit a larger video budget. Those network
    // estimates still govern growth; they must not latch a video pause after
    // both receivers recovered. Without actual playout measurements retain
    // the older network-based recovery, including freshness/report checks.
    final measuredPlayoutHealthy =
        (requirePeerAudioPlayout || requireAudioReceivePlayout) &&
        feedbackAvailable &&
        !audioUnproven &&
        !audioInterrupted &&
        !newAudioDrops &&
        !bufferPressure &&
        (!requirePeerAudioPlayout ||
            (currentPeerDelay != null &&
                currentPeerDelay < playoutRecoverMs)) &&
        receiveGood &&
        (!requireAudioReceivePlayout ||
            (audioReceiveDelayMs != null &&
                audioReceiveDelayMs < playoutRecoverMs)) &&
        rttMs < severeRttMs;
    if (_audioReserve &&
        (measuredPlayoutHealthy || audioGood) &&
        (audioTxDrops != null || !newDrops)) {
      _audioRecoveryStreak++;
      if (_audioRecoveryStreak >= recoverAfter) {
        _releaseAudioHold();
        return target;
      }
    } else {
      _audioRecoveryStreak = 0;
    }

    final measuredAudioFailure = usePlayout
        ? receiveBufferPressure || peerPlayoutOutage
        : receiveOutage ||
              peerPlayoutOutage ||
              audioInterrupted ||
              newAudioDrops ||
              (!measuredPlayoutHealthy &&
                  sendAudioExpected &&
                  (anyAudioFeedbackAvailable ?? feedbackAvailable) &&
                  (txLossPct >= 5 || txJitterMs >= 80 || rttMs >= severeRttMs));
    _severeStreak = atFloor && videoFloorApplied && measuredAudioFailure
        ? _severeStreak + 1
        : 0;
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

    if (bad) {
      _goodStreak = 0;
      _badStreak++;
      if (_badStreak >= degradeAfter && _level < ladder.length - 1) {
        _badStreak = 0;
        _level = (_level + 2).clamp(0, ladder.length - 1);
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
        if (usePlayout ? bufferPressure : networkBad) {
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
    if ((_goodStreak >= recoverAfter ||
            _startupGoodStreak >= startupRecoverAfter) &&
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
  }

  int? _nativeReceiveDelay(Map<String, dynamic> stats) {
    return CallAudioReceiveActivity.nativePlayoutDelay(stats);
  }
}
