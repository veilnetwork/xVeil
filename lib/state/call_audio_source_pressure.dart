import 'call_bitrate_adapter.dart';
import 'call_audio_playout_reserve.dart';
import 'call_audio_buffer_window.dart';
import 'call_rtcp_loss.dart';
import 'call_audio_transient_loss.dart';
import 'call_audio_soft_loss.dart';

/// Endpoint measurements for the shared source budget, including audio-only
/// calls. The node receives only a generic, expiring pressure observation.
class CallAudioSourcePressure {
  CallAudioSourcePressure({this.singlePeerPlayout = false});

  // Use the video ladder's buffer rails and sustained recovery. A retained
  // peak is not the current source pressure.
  static const int playoutDegradeMs = CallAudioBufferWindow.ceilingMs;
  static const int playoutRecoverMs = CallBitrateAdapter.playoutRecoverMs;
  final bool singlePeerPlayout;
  bool _pressured = true;
  int _healthy = 0;
  int _measuredHealthy = 0;
  int _filledReserveSamples = 0;
  int? _filledReservePeerBaseline;
  DateTime? _lastFilledReserveSample;
  bool _hardRecoveryRequired = false;
  int _recoverySamples = CallBitrateAdapter.recoverAfter;
  int? _lastAudioDrops;
  bool? _measuredAudioPressure;
  DateTime? _growthHoldStartedAt;
  bool _filledJitterReserveConfirmed = false;

  /// Both receivers have a current stable reserve and source recovery has
  /// finished. The video adapter still needs its own decoder acknowledgments.
  bool get filledJitterReserveConfirmed => _filledJitterReserveConfirmed;

  /// Keep current admission, but earn no growth until this event's hold ends.
  /// Distinct from unknown measurements and from measured pressure.
  DateTime? get growthHoldStartedAt => _growthHoldStartedAt;

  /// Current measured state for video pixels, without the transport budget's
  /// cold/recovery latch. Unknown feedback cannot authorize source growth.
  bool? get measuredAudioPressure => _measuredAudioPressure;

  /// Keep the adapter's growth hold while a new peer sample is pending.
  /// Current healthy audio permits the older transport lease to expire.
  bool get waitingForReserveConfirmation =>
      _pressured &&
      _filledReserveSamples >= CallBitrateAdapter.probeResumeAfter;
  final _rtcpLoss = CallRtcpLoss();
  final _peerRecoveryLoss = CallRtcpLoss();
  final _peerConcealment = CallRtcpLoss();
  final _localConcealment = CallRtcpLoss();
  final _softLoss = CallAudioSoftLoss();
  final _transientLoss = CallAudioTransientLoss();
  final _receiveTransientLoss = CallAudioTransientLoss();
  final _networkAudioLoss = CallAudioTransientLoss();
  int? _audioRouteEpoch;
  bool? _lastTransientSendExpected;
  bool? _lastTransientReceiveExpected;
  final _peerBuffer = CallAudioBufferWindow();
  final _receiveBuffer = CallAudioBufferWindow();

  /// Null means no source or no verdict: stop refreshing the node lease.
  /// Freshness of peer and receive measurements is enforced by their trackers.
  bool? observe({
    DateTime? sampledAt,
    required bool sendExpected,
    required bool receiveExpected,
    required bool requirePeerPlayout,
    required int? peerDelayMs,
    int? peerCurrentDelayMs,
    int? peerTargetDelayMs,
    int? peerSampleSequence,
    bool? peerBufferGrowing,
    required int? receiveDelayMs,
    int? receiveTargetDelayMs,
    required int? receiveAgeMs,
    required bool interrupted,
    required int? audioTxDrops,
    Object? audioLossReportUs,
    Object? peerAudioRecoveryReportUs,
    Object? peerAudioConcealmentReportUs,
    Object? localAudioConcealmentReportUs,
    bool recovered = false,
    bool? peerRecoveryObserved,
    Map<String, dynamic>? nativeStats,
  }) {
    final rtcpLoss = _rtcpLoss.observe(
      audioReportUs: audioLossReportUs,
      previousAudioReportUs: nativeStats?['audio_previous_loss_report_us'],
      audioExpected: sendExpected,
      videoExpected: false,
    );
    final networkLoss = rtcpLoss.audio;
    final peerRecovered = _peerRecoveryLoss
        .observe(
          audioReportUs: peerAudioRecoveryReportUs,
          audioExpected: sendExpected,
          videoExpected: false,
        )
        .audio;
    final peerRecoveredSignal = peerRecoveryObserved ?? peerRecovered;
    final concealed = _peerConcealment
        .observe(
          audioReportUs: peerAudioConcealmentReportUs,
          audioExpected: sendExpected,
          videoExpected: false,
        )
        .audio;
    final localConcealed = _localConcealment
        .observe(
          audioReportUs: localAudioConcealmentReportUs,
          audioExpected: receiveExpected,
          videoExpected: false,
        )
        .audio;
    final soft = _softLoss.observe(
      nativeStats,
      sending: sendExpected,
      receiving:
          receiveExpected &&
          (nativeStats == null || nativeStats['worker_stalled'] == 0),
    );
    final drops = audioTxDrops != null && audioTxDrops >= 0
        ? audioTxDrops
        : null;
    final newDrop =
        sendExpected &&
        drops != null &&
        _lastAudioDrops != null &&
        drops > _lastAudioDrops!;
    _lastAudioDrops = sendExpected ? drops : null;
    if (!sendExpected && !receiveExpected) {
      _reset(preserveReportWitnesses: true);
      // No audio to protect: stop the transport lease, but allow video to
      // recover through its own normal controller and fresh encode evidence.
      _measuredAudioPressure = false;
      return null;
    }
    bool valid(int? n) => n != null && n >= 0 && n <= 60000;
    // A current sample belongs to the same fresh, authenticated report as its
    // peak. It cannot make an absent/invalid report healthy or exceed the peak.
    // Older peers retain their peak-only behavior.
    final hasCurrentPeerDelay =
        valid(peerDelayMs) &&
        valid(peerCurrentDelayMs) &&
        peerCurrentDelayMs! <= peerDelayMs!;
    final peerDelay = hasCurrentPeerDelay ? peerCurrentDelayMs : peerDelayMs;
    final peerNeeded = sendExpected && requirePeerPlayout;
    final unknown =
        (peerNeeded && !valid(peerDelay)) ||
        (receiveExpected && (!valid(receiveDelayMs) || !valid(receiveAgeMs)));
    final peerTarget =
        peerNeeded && valid(peerDelay) && valid(peerTargetDelayMs)
        ? peerTargetDelayMs
        : null;
    final receiveTarget =
        receiveExpected && valid(receiveDelayMs) && valid(receiveTargetDelayMs)
        ? receiveTargetDelayMs
        : null;
    final peerCredit = hasCurrentPeerDelay
        ? CallAudioPlayoutReserve.creditMs(peerDelay, peerTarget)
        : 0;
    final receiveCredit = CallAudioPlayoutReserve.creditMs(
      receiveDelayMs,
      receiveTarget,
    );
    final peerPressureDelay = CallAudioPlayoutReserve.pressureDelayMs(
      peerDelay,
      peerCredit,
    );
    final receivePressureDelay = CallAudioPlayoutReserve.pressureDelayMs(
      receiveDelayMs,
      receiveCredit,
    );
    final routeEpoch = nativeStats?['audio_rtt_route_epoch'];
    final hasRouteEpoch = routeEpoch is int && routeEpoch >= 0;
    final routeChanged = hasRouteEpoch && routeEpoch != _audioRouteEpoch;
    if (routeChanged) {
      _transientLoss.reset();
      _receiveTransientLoss.reset();
      _networkAudioLoss.reset();
      _peerBuffer.reset(keepSequence: true);
      _receiveBuffer.reset();
      _audioRouteEpoch = routeEpoch;
    }
    final peerPressure = _peerBuffer.observe(
      peerNeeded ? peerDelay : null,
      sequence: peerSampleSequence,
      sampledAt: sampledAt,
      targetDelayMs: hasCurrentPeerDelay ? peerTarget : null,
      measuredGrowing: peerNeeded && hasCurrentPeerDelay
          ? peerBufferGrowing
          : null,
    );
    final receivePressure = _receiveBuffer.observe(
      receiveExpected ? receiveDelayMs : null,
      sampledAt: sampledAt,
      targetDelayMs: receiveTarget,
    );
    if (_lastTransientSendExpected != sendExpected) {
      _transientLoss.reset();
      _networkAudioLoss.reset();
      _lastTransientSendExpected = sendExpected;
    }
    final softTransient =
        concealed ||
        recovered ||
        peerRecoveredSignal ||
        localConcealed ||
        soft.send == true ||
        soft.receive == true;
    final repeatedTransient = _transientLoss.observe(
      concealed || peerRecoveredSignal,
      sampledAt: sampledAt,
    );
    if (_lastTransientReceiveExpected != receiveExpected) {
      _receiveTransientLoss.reset();
      _lastTransientReceiveExpected = receiveExpected;
    }
    final repeatedReceiveLoss = _receiveTransientLoss.observe(
      localConcealed || (receiveExpected && recovered),
      sampledAt: sampledAt,
    );
    final repeatFromPolls = _networkAudioLoss.observe(
      singlePeerPlayout && networkLoss,
      sampledAt: sampledAt,
    );
    final repeatedNetworkLoss = rtcpLoss.repeatedAudio ?? repeatFromPolls;
    // Leave room for the requested reserve while it is filling. The request
    // alone does not prove an underrun or a growing measured queue, so it
    // cannot require hard-failure recovery once playout has settled.
    final reserveUnfilled =
        (peerTarget != null &&
            peerTarget >= playoutDegradeMs &&
            peerCredit == 0) ||
        (receiveTarget != null &&
            receiveTarget >= playoutDegradeMs &&
            receiveCredit == 0);
    final hardPlayoutFailure =
        newDrop || interrupted || peerPressure || receivePressure;
    final playoutStable =
        !hardPlayoutFailure &&
        nativeStats?['worker_stalled'] != 1 &&
        _peerBuffer.growing != true &&
        _receiveBuffer.growing != true &&
        !unknown &&
        CallAudioPlayoutReserve.targetAllowsGrowth(
          peerTarget,
          peerCredit,
          recoverMs: playoutRecoverMs,
        ) &&
        CallAudioPlayoutReserve.targetAllowsGrowth(
          receiveTarget,
          receiveCredit,
          recoverMs: playoutRecoverMs,
        ) &&
        (!receiveExpected ||
            receiveAgeMs! < CallBitrateAdapter.audioReceiveRecoverMs);
    final playoutHealthy =
        playoutStable &&
        (!peerNeeded ||
            (peerPressureDelay != null &&
                peerPressureDelay < playoutRecoverMs)) &&
        (!receiveExpected ||
            (receivePressureDelay != null &&
                receivePressureDelay < playoutRecoverMs));
    final rttMs = nativeStats?['rtt_ms'];
    // An authenticated current report in a direct call can confirm that a
    // small loss already played through. Preserve the existing source credit.
    final isolatedNetworkLoss =
        singlePeerPlayout &&
        networkLoss &&
        !repeatedNetworkLoss &&
        CallRtcpLoss.isSmallAudioLoss(
          nativeStats?['audio_loss_report_fraction'],
        ) &&
        rttMs is num &&
        rttMs > 0 &&
        rttMs < CallBitrateAdapter.severeRttMs &&
        peerNeeded &&
        hasCurrentPeerDelay &&
        peerSampleSequence != null &&
        peerSampleSequence > 0 &&
        playoutHealthy;
    final hardBad = hardPlayoutFailure || (networkLoss && !isolatedNetworkLoss);
    final bad =
        hardBad ||
        reserveUnfilled ||
        (soft.send ?? repeatedTransient) ||
        (soft.receive ?? repeatedReceiveLoss);
    final fullyMeasured =
        nativeStats?['worker_stalled'] == 0 &&
        (!sendExpected || soft.send != null) &&
        (!receiveExpected || soft.receive != null);
    // A filled adaptive reserve can retain an arrival burst above NetEq's
    // target. For the transport trial, bound excess above that target while
    // also bounding the raw delay by the ceiling, arrival tolerance and two
    // 10-ms render blocks for paced batch arrival. This needs current
    // measurements from both ends of the same direct call.
    const maximumFilledDelayMs =
        CallAudioPlayoutReserve.maximumTargetMs +
        CallAudioPlayoutReserve.arrivalToleranceMs +
        20;
    const maximumPressureWithReserveMs =
        playoutRecoverMs + CallAudioPlayoutReserve.nominalTargetMs;
    final steadyReserve =
        playoutStable &&
        singlePeerPlayout &&
        peerNeeded &&
        receiveExpected &&
        fullyMeasured &&
        sampledAt != null &&
        hasRouteEpoch &&
        !routeChanged &&
        rttMs is num &&
        rttMs > 0 &&
        rttMs < CallBitrateAdapter.severeRttMs &&
        peerCredit > 0 &&
        receiveCredit > 0 &&
        peerBufferGrowing == false &&
        peerSampleSequence != null &&
        peerSampleSequence > 0 &&
        peerDelay! <= maximumFilledDelayMs &&
        receiveDelayMs! <= maximumFilledDelayMs &&
        peerPressureDelay! < maximumPressureWithReserveMs &&
        receivePressureDelay! < maximumPressureWithReserveMs;
    final measuredHealthy = playoutHealthy && !bad;
    final transient = softTransient || isolatedNetworkLoss;
    final durationKnown =
        nativeStats != null &&
        (!(concealed || peerRecoveredSignal || soft.send == true) ||
            soft.send != null) &&
        (!(localConcealed || recovered || soft.receive == true) ||
            soft.receive != null);
    final good = (measuredHealthy || (steadyReserve && !bad)) && !transient;
    _measuredAudioPressure = bad
        ? true
        : (measuredHealthy && (!transient || durationKnown) ? false : null);
    final measuredSmallTransient =
        measuredHealthy && durationKnown && transient;
    final shortHold =
        durationKnown &&
        (_transientLoss.holdingGrowth ||
            _receiveTransientLoss.holdingGrowth ||
            _networkAudioLoss.holdingGrowth);
    _growthHoldStartedAt = null;
    if (measuredHealthy && durationKnown && shortHold) {
      for (final tracker in [
        _transientLoss,
        _receiveTransientLoss,
        _networkAudioLoss,
      ]) {
        final event = tracker.holdingGrowth ? tracker.lastEventAt : null;
        if (event != null &&
            (_growthHoldStartedAt == null ||
                event.isAfter(_growthHoldStartedAt!))) {
          _growthHoldStartedAt = event;
        }
      }
    }
    // Once both receivers have filled their measured jitter reserves, an old
    // underrun no longer warrants renewing source pressure for twelve ticks.
    // Require continuous local measurements and a second authenticated peer
    // snapshot on the same route. The transport still admits only its bounded
    // trial and ramps DATA gradually after the last pressure lease expires.
    final filledReserve =
        (_hardRecoveryRequired || !playoutHealthy) &&
        steadyReserve &&
        good &&
        !shortHold;
    if (filledReserve) {
      final previous = _lastFilledReserveSample;
      if (previous != null &&
          (!sampledAt.isAfter(previous) ||
              sampledAt.difference(previous) >
                  CallAudioBufferWindow.sampleLifetime)) {
        _filledReserveSamples = 0;
        _filledReservePeerBaseline = null;
      }
      _filledReserveSamples++;
      _filledReservePeerBaseline ??= peerSampleSequence;
      _lastFilledReserveSample = sampledAt;
    } else {
      _filledReserveSamples = 0;
      _filledReservePeerBaseline = null;
      _lastFilledReserveSample = null;
    }
    if (bad) {
      _hardRecoveryRequired |= hardBad;
      _recoverySamples = CallBitrateAdapter.recoverAfter;
      _pressured = true;
      _healthy = 0;
      _measuredHealthy = 0;
    } else if (transient && !durationKnown) {
      if (!_pressured) {
        // Catch-up already restored the queue. Briefly yield our producers,
        // without shortening any still-active genuine congestion recovery.
        _recoverySamples = CallBitrateAdapter.startupRecoverAfter;
        _healthy = 0;
      }
      _healthy = 0;
      _measuredHealthy = 0;
      _pressured = true;
    } else if (good) {
      ++_healthy;
      if (playoutHealthy && fullyMeasured) {
        if (_measuredHealthy < CallBitrateAdapter.probeResumeAfter) {
          ++_measuredHealthy;
        }
      } else {
        _measuredHealthy = 0;
      }
      // Starting or recovering from a measured short soft impairment need
      // not advertise another twelve seconds of congestion after audio is
      // healthy. Earn a bounded source trial from three complete observations;
      // hard failures retain the full recovery unless the resumed receivers
      // independently confirm the measured adaptive reserves above.
      final measuredRecovery =
          (!_hardRecoveryRequired &&
              _measuredHealthy >= CallBitrateAdapter.probeResumeAfter) ||
          (filledReserve &&
              _filledReserveSamples >= CallBitrateAdapter.probeResumeAfter &&
              peerSampleSequence > _filledReservePeerBaseline!);
      if (((playoutHealthy && _healthy >= _recoverySamples) ||
              measuredRecovery) &&
          !shortHold) {
        _pressured = false;
        _hardRecoveryRequired = false;
      }
    } else if (!measuredSmallTransient) {
      _healthy = 0;
      _measuredHealthy = 0;
    }
    // Unknown/marginal measurements cannot authorize producer growth, but
    // must not renew a congestion lease after measured pressure has cleared.
    // A true node report contracts shared transport flight and source budgets;
    // it is stronger than the video ladder's brief growth hold. Known small
    // damage must not repeatedly halve transport credit while audio is healthy.
    // A filled steady reserve can stop extending the old lease before the
    // second peer measurement arrives. The local video growth hold continues
    // and the node earns no fresh healthy credit until confirmation.
    _filledJitterReserveConfirmed =
        !_pressured && steadyReserve && good && !shortHold;
    if (waitingForReserveConfirmation) return null;
    return _pressured ? true : (good || measuredSmallTransient ? false : null);
  }

  void reset() => _reset();

  void _reset({bool preserveReportWitnesses = false}) {
    _measuredAudioPressure = null;
    _filledJitterReserveConfirmed = false;
    _growthHoldStartedAt = null;
    _pressured = true;
    _healthy = 0;
    _measuredHealthy = 0;
    _filledReserveSamples = 0;
    _filledReservePeerBaseline = null;
    _lastFilledReserveSample = null;
    _hardRecoveryRequired = false;
    _recoverySamples = CallBitrateAdapter.recoverAfter;
    _lastAudioDrops = null;
    _transientLoss.reset();
    _receiveTransientLoss.reset();
    _networkAudioLoss.reset();
    _audioRouteEpoch = null;
    _lastTransientSendExpected = null;
    _lastTransientReceiveExpected = null;
    _peerRecoveryLoss.reset();
    // Keep consuming this witness while both directions are muted, including
    // samples where its freshness TTL expires. Resume cannot replay it.
    if (!preserveReportWitnesses) {
      _rtcpLoss.reset();
      _peerConcealment.reset();
      _localConcealment.reset();
      _softLoss.reset();
    }
    _peerBuffer.reset();
    _receiveBuffer.reset();
  }
}
