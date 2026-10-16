import 'call_audio_buffer_window.dart';
import 'call_bitrate_adapter.dart';

typedef GroupAudioBudget = ({int packetMs, int payloadBps});

/// Endpoint Opus control from actual receiver/loss/decoded recovery evidence.
/// No synthetic bandwidth estimate is supplied to WebRTC or the network.
class GroupCallAudioAdapter {
  static const _budgets = <GroupAudioBudget>[
    (packetMs: 20, payloadBps: 32000),
    (packetMs: 40, payloadBps: 32000),
    (packetMs: 40, payloadBps: 24000),
    (packetMs: 40, payloadBps: 16000),
    (packetMs: 60, payloadBps: 16000),
  ];
  static const pressureCooldown = Duration(seconds: 3);
  static const recoveryQuiet = Duration(seconds: 20);
  static const recoveryCooldown = Duration(seconds: 8);
  static const healthySamples = 8;

  // Avoid filling a shared uplink before the first listener reports. Shorter
  // packets are recovered only after fresh evidence establishes headroom.
  int _level = 1;
  GroupAudioBudget? _applied;
  DateTime? _changedAt, _pressureAt, _observedAt, _lastDownAt;
  int? _sequence, _drops, _recoveries, _packets;
  int _lossUs = 0, _peerRecoveryUs = 0, _healthy = 0, _expectedPeers = 0;
  bool _supports60Ms = false;
  final _buffer = CallAudioBufferWindow();

  GroupAudioBudget get target => _budgets[_level];
  int get level => _level;
  bool get pending => _applied != target;

  bool? applyPending(bool Function(GroupAudioBudget) apply, DateTime now) {
    if (!pending) return null;
    if (!apply(target)) return false;
    if (_applied != null && _level > _budgets.indexOf(_applied!)) {
      _lastDownAt = now;
    }
    _applied = target;
    _changedAt = now;
    _healthy = 0;
    return true;
  }

  void observe(
    Map<String, dynamic> stats,
    DateTime now, {
    required int expectedPeers,
    required bool sending,
    required bool receiving,
  }) {
    final previousTime = _observedAt;
    _observedAt = now;
    if (previousTime != null && now.isBefore(previousTime)) {
      // Clock correction cannot prove healthy elapsed time or add samples.
      _changedAt = _pressureAt = now;
      _lastDownAt = now;
      _healthy = 0;
      _buffer.reset();
    }
    if (expectedPeers != _expectedPeers) {
      _expectedPeers = expectedPeers;
      _buffer.reset();
      _healthy = 0;
    }
    int? counter(Object? value) => value is int && value >= 0 ? value : null;
    final nativeFresh = stats['worker_stalled'] == 0;
    final maxPacketMs = stats['audio_max_packet_ms'];
    if (nativeFresh && stats['audio_config_valid'] == 1) {
      if (maxPacketMs == 60) _supports60Ms = true;
      if (maxPacketMs == 20 || maxPacketMs == 40) _supports60Ms = false;
    }
    if (!_supports60Ms && _level > 3) _level = 3;
    final loss = counter(stats['audio_loss_report_us']) ?? 0;
    final newLoss = loss > _lossUs;
    if (loss > _lossUs) _lossUs = loss;
    final peerRecovery = counter(stats['audio_peer_recovery_report_us']) ?? 0;
    final peerRecovered = peerRecovery > _peerRecoveryUs;
    if (peerRecovered) _peerRecoveryUs = peerRecovery;
    var newDrop = false, recovered = false, packetsAdvanced = false;
    if (nativeFresh) {
      final packets = counter(stats['audio_tx_payload_pkts']);
      packetsAdvanced =
          packets != null && _packets != null && packets > _packets!;
      _packets = packets;
      final drops = counter(stats['audio_tx_rtp_drops']);
      final recoveries = counter(stats['audio_latency_recovery_count']);
      if (drops != null) {
        newDrop = _drops != null && drops > _drops!;
        _drops = drops;
      }
      if (recoveries != null) {
        recovered =
            receiving && _recoveries != null && recoveries > _recoveries!;
        _recoveries = recoveries;
      }
    }
    final sequence = counter(stats['audio_playout_sequence']);
    final reports = counter(stats['audio_playout_reports']);
    final delay = counter(stats['audio_playout_ms']);
    final peerValid =
        sequence != null &&
        reports != null &&
        reports > 0 &&
        delay != null &&
        delay <= 60000;
    final freshPeer = peerValid && (_sequence == null || sequence > _sequence!);
    if (freshPeer) _sequence = sequence;
    if (!sending || expectedPeers <= 0) {
      // Consume counters while muted, so unmute cannot replay old pressure.
      _healthy = 0;
      _buffer.reset();
      return;
    }
    final peerPressure =
        freshPeer && _buffer.observe(delay, sequence: sequence);
    final pressure =
        newLoss || newDrop || recovered || peerRecovered || peerPressure;
    if (pressure) {
      _pressureAt = now;
      _healthy = 0;
      // A longer packet is a last step after the applied 40-ms/16-kbit
      // floor has actually emitted packets and fresh pressure remains. Neither
      // startup/unknown feedback nor a requested-but-unapplied floor qualifies.
      final measuredFloor =
          _supports60Ms &&
          nativeFresh &&
          stats['audio_config_valid'] == 1 &&
          _applied == _budgets[3] &&
          packetsAdvanced &&
          stats['audio_tx_packet_duration_ms'] == 40;
      final maxLevel = measuredFloor || _level == 4 ? 4 : 3;
      if (!pending &&
          _level < maxLevel &&
          (_lastDownAt == null ||
              now.difference(_lastDownAt!) >= pressureCooldown)) {
        _level++;
        // Decoded catch-up means audio was already queued too long. Take
        // two rungs now instead of carrying that overload through another
        // cooldown; isolated loss still takes one measured step.
        if (recovered && _level < 3) _level++;
      }
      return;
    }
    // One good listener, a cached peak, or a stale native snapshot cannot
    // establish room-wide headroom. Loss timestamps remain nonzero while the
    // native authenticated loss observation is still within its freshness TTL.
    final complete =
        nativeFresh &&
        stats['audio_config_valid'] == 1 &&
        peerValid &&
        reports == expectedPeers &&
        counter(stats['audio_feedback_reports']) == expectedPeers &&
        loss == 0 &&
        peerRecovery == 0 &&
        delay < CallBitrateAdapter.playoutRecoverMs;
    if (!complete) {
      _healthy = 0;
      return;
    }
    if (!freshPeer || pending) return;
    if (_pressureAt != null && now.difference(_pressureAt!) < recoveryQuiet) {
      _healthy = 0;
      return;
    }
    _healthy++;
    if (_level > 0 &&
        _healthy >= healthySamples &&
        (_changedAt == null ||
            now.difference(_changedAt!) >= recoveryCooldown)) {
      _level--;
      _healthy = 0;
    }
  }
}
