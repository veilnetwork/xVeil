import 'call_audio_transient_loss.dart';
import 'call_bitrate_adapter.dart';
import 'call_rtcp_loss.dart';
import 'group_call_audio_adapter.dart';

/// Orders real group source reductions before spending audio quality on long
/// packets. This is an endpoint policy, not a bandwidth estimate or relay QoS.
class GroupCallSourcePriority {
  static const settle = Duration(seconds: 2);
  static const quietRecovery = Duration(seconds: 20);
  static const recoverySamples = 8;
  static const transientQuietRecovery = Duration(seconds: 3);
  static const transientRecoverySamples = 3;
  int _stage = 0; // Unrestricted, one-fps floor, paused.
  DateTime? _lastAt, _floorAckAt, _pauseAckAt, _quietAt, _pressureAt;
  DateTime? _peerRecoveryFirstSeenAt;
  int? _packets, _sequence, _audioTxDrops, _peerRecoveryReport;
  int _floorSamples = 0, _healthy = 0;
  int _sparseLocalSamples = 0, _sparsePeerSamples = 0;
  bool _yielded = false;
  bool _transientOnly = false;

  bool get floor => _stage > 0;
  bool get paused => _stage == 2;
  bool get yielded => _yielded;
  Map<String, Object?> get diagnostics => {
    'stage': _stage,
    'yielded': _yielded,
    'floor_samples': _floorSamples,
    'healthy_samples': _healthy,
    'transient_only': _transientOnly,
  };

  void requestYield(DateTime now, {bool transient = false}) {
    _healthy = _sparseLocalSamples = _sparsePeerSamples = 0;
    if (_stage == 0) {
      _stage = 1;
      _transientOnly = transient;
    }
    if (!transient) _transientOnly = false;
    // A short completed impairment cannot extend a genuine congestion hold,
    // shorten that hold, or escalate a sparse video trial into a long pause.
    if (!transient || _transientOnly) _pressureAt = now;
    if (!transient &&
        _stage == 1 &&
        _floorAckAt != null &&
        !now.isBefore(_floorAckAt!) &&
        now.difference(_floorAckAt!) >= settle &&
        _floorSamples >= 2) {
      _stage = 2;
      _yielded = false;
    }
  }

  void acknowledgeFloor(DateTime now) {
    // The regular video adapter may already have reached this floor before
    // the audio coordinator sees pressure. Keep that actual acknowledgement.
    if (_stage < 2) _floorAckAt ??= now;
  }

  void acknowledgePause(bool paused, DateTime now) {
    if (paused && _stage == 2) {
      _pauseAckAt ??= now;
    } else if (!paused) {
      _pauseAckAt = _quietAt = null;
      _yielded = false;
    }
  }

  /// Membership/clock changes cannot reuse the old native acknowledgements.
  /// Preserve an already required restriction while re-establishing evidence.
  void invalidate() {
    _floorAckAt = _pauseAckAt = _quietAt = null;
    _packets = _sequence = _audioTxDrops = _peerRecoveryReport = null;
    _peerRecoveryFirstSeenAt = null;
    _floorSamples = _healthy = _sparseLocalSamples = _sparsePeerSamples = 0;
    _yielded = false;
  }

  /// Returns whether the paused source can try its floor if the current
  /// audio budget evaluation finds no new hard pressure.
  bool observe(
    Map<String, dynamic> stats,
    DateTime now, {
    required bool videoExpected,
    required int? appliedAudioMs,
    required int expectedPeers,
    required bool audioSending,
    bool sparseAudioRecovery = false,
  }) {
    final previousAt = _lastAt;
    if (previousAt != null && now.isBefore(previousAt)) {
      invalidate();
      if (_stage > 0) _pressureAt = now;
    }
    final fresh = previousAt == null || now.isAfter(previousAt);
    _lastAt = now;
    if (!videoExpected || !audioSending) {
      _stage = 0;
      _transientOnly = false;
      _pressureAt = null;
      invalidate();
      _yielded = true; // No owned secondary sender competes with this audio.
      return false;
    }
    // Audio cadence alone is not pressure. Late video uses the regular
    // adapter's bounded startup trial; only measured audio failure requests
    // an additional restriction. Recovery need not shorten audio packets.
    if (!fresh) return false;
    int? count(String key) {
      final value = stats[key];
      return value is int && value >= 0 ? value : null;
    }

    final packets =
        count('video_tx_payload_pkts') ?? count('video_tx_rtp_attempts');
    final nativeFresh = stats['video_worker_stalled'] == 0;
    final fps = stats['max_fps'];
    if (nativeFresh &&
        packets != null &&
        _packets != null &&
        packets < _packets!) {
      invalidate();
    }
    if (_stage < 2 &&
        _floorAckAt != null &&
        !now.isBefore(_floorAckAt!) &&
        nativeFresh &&
        packets != null &&
        fps is num &&
        fps.isFinite &&
        fps > 0 &&
        fps <= 1) {
      // A configured one-fps ceiling and a cached counter are not emitted
      // video. Count distinct native progress samples under the applied floor.
      if (_packets != null && packets > _packets!) _floorSamples++;
    } else {
      _floorSamples = 0;
      if (nativeFresh && fps is num && fps > 1) _floorAckAt = null;
    }
    if (_stage == 2 &&
        _pauseAckAt != null &&
        !now.isBefore(_pauseAckAt!) &&
        nativeFresh &&
        stats['video_send_paused'] == 1 &&
        packets != null &&
        packets == _packets) {
      _quietAt ??= now;
      _yielded = now.difference(_quietAt!) >= settle;
    } else {
      _quietAt = null;
      _yielded = false;
    }
    _packets = packets;
    final sequence = count('audio_playout_sequence');
    final freshPeer =
        sequence != null && (_sequence == null || sequence > _sequence!);
    if (freshPeer) _sequence = sequence;
    final drops = count('audio_tx_rtp_drops');
    final stableDrops = drops != null && drops == _audioTxDrops;
    _audioTxDrops = drops;
    final delay = GroupCallAudioAdapter.peerPressureDelayMs(stats);
    final audioFresh = stats['worker_stalled'] == 0;
    final peerRecovery = stats['audio_peer_recovery_report_us'];
    if (audioFresh) {
      final report = count('audio_peer_recovery_report_us');
      if (report != _peerRecoveryReport) {
        _peerRecoveryReport = report;
        _peerRecoveryFirstSeenAt = report != null && report > 0 ? now : null;
      }
    }
    final complete =
        audioFresh &&
        stats['audio_config_valid'] == 1 &&
        appliedAudioMs != null &&
        (appliedAudioMs == 20 ||
            appliedAudioMs == 40 ||
            appliedAudioMs == 60) &&
        stats['audio_tx_packet_duration_ms'] == appliedAudioMs &&
        expectedPeers > 0 &&
        stats['audio_playout_reports'] == expectedPeers &&
        stats['audio_feedback_reports'] == expectedPeers &&
        delay != null &&
        (delay < CallBitrateAdapter.playoutRecoverMs || sparseAudioRecovery);
    if (!complete) {
      _healthy = _sparseLocalSamples = _sparsePeerSamples = 0;
      return false;
    }
    if (_stage == 0) return false;
    final loss = stats['audio_loss_report_us'];
    final recoveryCleared = peerRecovery == null || peerRecovery == 0;
    if (loss == 0 && (_transientOnly || recoveryCleared)) {
      if (freshPeer) _healthy++;
    } else {
      _healthy = 0;
    }
    // RTCP may be sparse even while local audio is sampled every second.
    // Keep distinct peer confirmations separate from clean local samples.
    // A local catch-up or a changed drop counter needs new local evidence.
    const eventWindow = CallAudioTransientLoss.repeatWindow;
    final lossAge = CallRtcpLoss.audioLossAge(stats);
    final recoverySeenAt = _peerRecoveryFirstSeenAt;
    // RTCP keeps a loss or catch-up witness long after a decoder recovers.
    // For the sparse trial, count current zero-loss reports after a full
    // damage window. Catch-up time is counted from our first observation.
    final oldLoss =
        loss is int && loss > 0 && lossAge != null && lossAge >= eventWindow;
    final oldRecovery =
        recoverySeenAt != null && now.difference(recoverySeenAt) >= eventWindow;
    if (paused &&
        _yielded &&
        stats['tx_loss_pct'] == 0 &&
        (loss == 0 || oldLoss) &&
        (recoveryCleared || oldRecovery)) {
      if (freshPeer) _sparsePeerSamples++;
      _sparseLocalSamples = sparseAudioRecovery && stableDrops
          ? _sparseLocalSamples + 1
          : 0;
    } else {
      _sparseLocalSamples = _sparsePeerSamples = 0;
    }
    final quiet = _transientOnly ? transientQuietRecovery : quietRecovery;
    final pressureAt = _pressureAt;
    if (!freshPeer ||
        pressureAt == null ||
        now.difference(pressureAt) < quiet) {
      return false;
    }
    final samples = _transientOnly ? transientRecoverySamples : recoverySamples;
    if (_healthy >= samples) {
      _stage = 0;
      _transientOnly = false;
      _pressureAt = null;
      invalidate();
      return false;
    }
    return _sparsePeerSamples >= CallBitrateAdapter.probeResumeAfter &&
        _sparseLocalSamples >= CallBitrateAdapter.probeResumeAfter;
  }

  void retryFloor(DateTime now) {
    assert(paused);
    // Keep the source restriction and the peer streak needed for higher
    // quality. New congestion must establish actual output under this floor.
    _stage = 1;
    _floorAckAt = null;
    _floorSamples = _sparseLocalSamples = _sparsePeerSamples = 0;
    acknowledgePause(false, now);
  }
}
