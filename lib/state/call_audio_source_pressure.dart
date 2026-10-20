import 'call_bitrate_adapter.dart';
import 'call_audio_buffer_window.dart';
import 'call_rtcp_loss.dart';
import 'call_audio_transient_loss.dart';
import 'call_audio_soft_loss.dart';

/// Endpoint measurements for the shared source budget, including audio-only
/// calls. The node receives only a generic, expiring pressure observation.
class CallAudioSourcePressure {
  // Use the video ladder's buffer rails and sustained recovery. A retained
  // peak is not the current source pressure.
  static const int playoutDegradeMs = CallAudioBufferWindow.ceilingMs;
  static const int playoutRecoverMs = CallBitrateAdapter.playoutRecoverMs;
  bool _pressured = true;
  int _healthy = 0;
  int _recoverySamples = CallBitrateAdapter.recoverAfter;
  int? _lastAudioDrops;
  bool? _measuredAudioPressure;

  /// Current measured state for video pixels, without the transport budget's
  /// cold/recovery latch. Unknown feedback cannot authorize source growth.
  bool? get measuredAudioPressure => _measuredAudioPressure;
  final _rtcpLoss = CallRtcpLoss();
  final _peerRecoveryLoss = CallRtcpLoss();
  final _peerConcealment = CallRtcpLoss();
  final _localConcealment = CallRtcpLoss();
  final _softLoss = CallAudioSoftLoss();
  final _transientLoss = CallAudioTransientLoss();
  final _receiveTransientLoss = CallAudioTransientLoss();
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
    final networkLoss = _rtcpLoss
        .observe(
          audioReportUs: audioLossReportUs,
          audioExpected: sendExpected,
          videoExpected: false,
        )
        .audio;
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
      _reset(preserveConcealmentWitness: true);
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
    final peerPressure = _peerBuffer.observe(
      peerNeeded ? peerDelay : null,
      sequence: peerSampleSequence,
      sampledAt: sampledAt,
      measuredGrowing: peerNeeded && hasCurrentPeerDelay
          ? peerBufferGrowing
          : null,
    );
    final receivePressure = _receiveBuffer.observe(
      receiveExpected ? receiveDelayMs : null,
      sampledAt: sampledAt,
    );
    // Competing sources honor fresh audio loss and the video buffer trigger.
    // Transport estimates or unknown feedback alone cannot cut this budget.
    final peerTarget =
        peerNeeded && valid(peerDelay) && valid(peerTargetDelayMs)
        ? peerTargetDelayMs
        : null;
    final receiveTarget =
        receiveExpected && valid(receiveDelayMs) && valid(receiveTargetDelayMs)
        ? receiveTargetDelayMs
        : null;
    if (_lastTransientSendExpected != sendExpected) {
      _transientLoss.reset();
      _lastTransientSendExpected = sendExpected;
    }
    final transient =
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
    final bad =
        newDrop ||
        networkLoss ||
        (soft.send ?? repeatedTransient) ||
        (soft.receive ?? repeatedReceiveLoss) ||
        interrupted ||
        peerPressure ||
        receivePressure ||
        (peerTarget != null && peerTarget >= playoutDegradeMs) ||
        (receiveTarget != null && receiveTarget >= playoutDegradeMs);
    final measuredHealthy =
        !bad &&
        nativeStats?['worker_stalled'] != 1 &&
        _peerBuffer.growing != true &&
        _receiveBuffer.growing != true &&
        !unknown &&
        !interrupted &&
        !newDrop &&
        (peerTarget == null || peerTarget < playoutRecoverMs) &&
        (receiveTarget == null || receiveTarget < playoutRecoverMs) &&
        (!peerNeeded || peerDelay! < playoutRecoverMs) &&
        (!receiveExpected ||
            (receiveDelayMs! < playoutRecoverMs &&
                receiveAgeMs! < CallBitrateAdapter.audioReceiveRecoverMs));
    final durationKnown =
        nativeStats != null &&
        (!(concealed || peerRecoveredSignal || soft.send == true) ||
            soft.send != null) &&
        (!(localConcealed || recovered || soft.receive == true) ||
            soft.receive != null);
    final good = measuredHealthy && !transient;
    _measuredAudioPressure = bad
        ? true
        : (measuredHealthy && (!transient || durationKnown) ? false : null);
    final measuredSmallTransient =
        measuredHealthy && durationKnown && transient;
    final shortHold =
        durationKnown &&
        (_transientLoss.holdingGrowth || _receiveTransientLoss.holdingGrowth);
    if (bad) {
      _recoverySamples = CallBitrateAdapter.recoverAfter;
      _pressured = true;
      _healthy = 0;
    } else if (transient && !durationKnown) {
      if (!_pressured) {
        // Catch-up already restored the queue. Briefly yield our producers,
        // without shortening any still-active genuine congestion recovery.
        _recoverySamples = CallBitrateAdapter.startupRecoverAfter;
        _healthy = 0;
      }
      _healthy = 0;
      _pressured = true;
    } else if (good) {
      if (++_healthy >= _recoverySamples && !shortHold) _pressured = false;
    } else if (!measuredSmallTransient) {
      _healthy = 0;
    }
    // Unknown/marginal measurements cannot authorize producer growth, but
    // must not renew a congestion lease after measured pressure has cleared.
    // A true node report contracts shared transport flight and source budgets;
    // it is stronger than the video ladder's brief growth hold. Known small
    // damage must not repeatedly halve transport credit while audio is healthy.
    // Real pressure/recovery remains latched; unknown peer counters keep the
    // conservative legacy path. Video's independent transient tracker still
    // pauses growth without reducing its target.
    return _pressured ? true : (good || measuredSmallTransient ? false : null);
  }

  void reset() => _reset();

  void _reset({bool preserveConcealmentWitness = false}) {
    _measuredAudioPressure = null;
    _pressured = true;
    _healthy = 0;
    _recoverySamples = CallBitrateAdapter.recoverAfter;
    _lastAudioDrops = null;
    _transientLoss.reset();
    _receiveTransientLoss.reset();
    _lastTransientSendExpected = null;
    _lastTransientReceiveExpected = null;
    _rtcpLoss.reset();
    _peerRecoveryLoss.reset();
    // Keep consuming this witness while both directions are muted, including
    // samples where its freshness TTL expires. Resume cannot replay it.
    if (!preserveConcealmentWitness) _peerConcealment.reset();
    if (!preserveConcealmentWitness) _localConcealment.reset();
    if (!preserveConcealmentWitness) _softLoss.reset();
    _peerBuffer.reset();
    _receiveBuffer.reset();
  }
}
