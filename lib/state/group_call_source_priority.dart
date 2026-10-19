/// Orders real group source reductions before spending audio quality on long
/// packets. This is an endpoint policy, not a bandwidth estimate or relay QoS.
class GroupCallSourcePriority {
  static const settle = Duration(seconds: 2);
  static const quietRecovery = Duration(seconds: 20);
  static const recoverySamples = 8;
  int _stage = 0; // Unrestricted, one-fps floor, paused.
  DateTime? _lastAt, _floorAckAt, _pauseAckAt, _quietAt, _pressureAt;
  int? _packets, _sequence;
  int _floorSamples = 0, _healthy = 0;
  bool _yielded = false;

  bool get floor => _stage > 0;
  bool get paused => _stage == 2;
  bool get yielded => _yielded;
  Map<String, Object?> get diagnostics => {
    'stage': _stage,
    'yielded': _yielded,
    'floor_samples': _floorSamples,
    'healthy_samples': _healthy,
  };

  void requestYield(DateTime now) {
    _pressureAt = now;
    _healthy = 0;
    if (_stage == 0) _stage = 1;
    if (_stage == 1 &&
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
    _packets = _sequence = null;
    _floorSamples = _healthy = 0;
    _yielded = false;
  }

  void observe(
    Map<String, dynamic> stats,
    DateTime now, {
    required bool videoExpected,
    required int? appliedAudioMs,
    required int expectedPeers,
    required bool audioSending,
  }) {
    final previousAt = _lastAt;
    if (previousAt != null && now.isBefore(previousAt)) invalidate();
    final fresh = previousAt == null || now.isAfter(previousAt);
    _lastAt = now;
    if (!videoExpected || !audioSending) {
      _stage = 0;
      invalidate();
      _yielded = true; // No owned secondary sender competes with this audio.
      return;
    }
    // Audio cadence alone is not pressure. Late video uses the regular
    // adapter's bounded startup trial; only measured audio failure requests
    // an additional restriction. Recovery need not shorten audio packets.
    if (!fresh) return;
    int? count(String key) {
      final value = stats[key];
      return value is int && value >= 0 ? value : null;
    }

    final packets =
        count('video_tx_payload_pkts') ?? count('video_tx_rtp_attempts');
    final nativeFresh = stats['video_worker_stalled'] == 0;
    final fps = stats['max_fps'];
    if (_stage < 2 &&
        _floorAckAt != null &&
        nativeFresh &&
        packets != null &&
        fps is num &&
        fps.isFinite &&
        fps > 0 &&
        fps <= 1) {
      _floorSamples++;
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
    final healthy =
        stats['worker_stalled'] == 0 &&
        stats['audio_config_valid'] == 1 &&
        appliedAudioMs != null &&
        (appliedAudioMs == 20 ||
            appliedAudioMs == 40 ||
            appliedAudioMs == 60) &&
        stats['audio_tx_packet_duration_ms'] == appliedAudioMs &&
        expectedPeers > 0 &&
        stats['audio_playout_reports'] == expectedPeers &&
        stats['audio_feedback_reports'] == expectedPeers &&
        stats['audio_loss_report_us'] == 0 &&
        (stats['audio_peer_recovery_report_us'] == null ||
            stats['audio_peer_recovery_report_us'] == 0) &&
        stats['audio_playout_ms'] is int &&
        (stats['audio_playout_ms'] as int) >= 0 &&
        (stats['audio_playout_ms'] as int) < 160;
    if (!healthy) {
      _healthy = 0;
    } else if (freshPeer && _stage > 0) {
      _healthy++;
      if (_healthy >= recoverySamples &&
          _pressureAt != null &&
          now.difference(_pressureAt!) >= quietRecovery) {
        _stage = 0;
        invalidate();
      }
    }
  }
}
