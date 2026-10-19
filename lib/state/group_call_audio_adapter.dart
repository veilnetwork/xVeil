import 'dart:collection';

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
    // Real Opus at 16 kbit/s can attenuate a sustained input for hundreds of
    // milliseconds even without transport loss. Preserve signal quality;
    // video and reliable local producers yield before this payload floor.
    (packetMs: 60, payloadBps: 24000),
  ];
  static const _shortPacketFloor = 2, _longPacketFloor = 3;
  static const pressureCooldown = Duration(seconds: 3);
  static const recoveryQuiet = Duration(seconds: 20);
  static const recoveryCooldown = Duration(seconds: 8);
  static const healthySamples = 8;
  static const _rttWindowSpan = Duration(minutes: 2);

  // Avoid filling a shared uplink before the first listener reports. Shorter
  // packets are recovered only after fresh evidence establishes headroom.
  int _level = 1;
  GroupAudioBudget? _applied;
  DateTime? _changedAt, _pressureAt, _observedAt, _lastDownAt;
  int? _sequence, _drops, _recoveries, _packets;
  int _lossUs = 0, _peerRecoveryUs = 0, _healthy = 0, _expectedPeers = 0;
  int _peerConcealmentUs = 0;
  bool _supports60Ms = false;
  bool _needsSecondaryYield = false;
  bool get needsSecondaryYield => _needsSecondaryYield;
  final _buffer = CallAudioBufferWindow();
  final _rttWindow = Queue<({DateTime at, int ms})>();

  GroupAudioBudget get target => _budgets[_level];
  GroupAudioBudget? get applied => _applied;
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
    bool secondaryYielded = true,
  }) {
    _needsSecondaryYield = false;
    final previousTime = _observedAt;
    _observedAt = now;
    if (previousTime != null && now.isBefore(previousTime)) {
      // Clock correction cannot prove healthy elapsed time or add samples.
      _changedAt = _pressureAt = now;
      _lastDownAt = now;
      _healthy = 0;
      _buffer.reset();
      _rttWindow.clear();
    }
    if (expectedPeers != _expectedPeers) {
      _expectedPeers = expectedPeers;
      _buffer.reset();
      _rttWindow.clear();
      _healthy = 0;
    }
    int? counter(Object? value) => value is int && value >= 0 ? value : null;
    final nativeFresh = stats['worker_stalled'] == 0;
    final maxPacketMs = stats['audio_max_packet_ms'];
    if (nativeFresh && stats['audio_config_valid'] == 1) {
      if (maxPacketMs == 60) _supports60Ms = true;
      if (maxPacketMs == 20 || maxPacketMs == 40) _supports60Ms = false;
    }
    if (!_supports60Ms && _level > _shortPacketFloor) {
      _level = _shortPacketFloor;
    }
    final loss = counter(stats['audio_loss_report_us']) ?? 0;
    final newLoss = loss > _lossUs;
    if (loss > _lossUs) _lossUs = loss;
    final peerRecovery = counter(stats['audio_peer_recovery_report_us']) ?? 0;
    final peerRecovered = peerRecovery > _peerRecoveryUs;
    if (peerRecovered) _peerRecoveryUs = peerRecovery;
    final peerConcealment =
        counter(stats['audio_peer_concealment_report_us']) ?? 0;
    final concealed = peerConcealment > _peerConcealmentUs;
    if (concealed) _peerConcealmentUs = peerConcealment;
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
    final transportAllowsRecovery = _transportAllowsRecovery(
      stats['rtt_ms'],
      now,
      fresh:
          nativeFresh &&
          freshPeer &&
          reports == expectedPeers &&
          counter(stats['audio_feedback_reports']) == expectedPeers,
    );
    if (!sending || expectedPeers <= 0) {
      // Consume counters while muted, so unmute cannot replay old pressure.
      _healthy = 0;
      _buffer.reset();
      return;
    }
    final peerPressure =
        freshPeer && _buffer.observe(delay, sequence: sequence);
    final pressure =
        newLoss ||
        newDrop ||
        recovered ||
        peerRecovered ||
        peerPressure ||
        concealed;
    if (pressure) {
      _pressureAt = now;
      _healthy = 0;
      // A longer packet is a last step after the applied 40-ms/24-kbit
      // floor has actually emitted packets and fresh pressure remains. Neither
      // startup/unknown feedback nor a requested-but-unapplied floor qualifies.
      final measuredFloor =
          _supports60Ms &&
          nativeFresh &&
          stats['audio_config_valid'] == 1 &&
          _applied == _budgets[_shortPacketFloor] &&
          packetsAdvanced &&
          stats['audio_tx_packet_duration_ms'] == 40;
      // The room controller must first reduce/pause actual secondary output.
      // A smaller nominal video ceiling alone does not establish that yield.
      final measuredEmergency =
          nativeFresh &&
          stats['audio_config_valid'] == 1 &&
          _applied == _budgets[_longPacketFloor] &&
          packetsAdvanced &&
          stats['audio_tx_packet_duration_ms'] == 60;
      _needsSecondaryYield =
          (measuredFloor || measuredEmergency) && !secondaryYielded;
      // Incoming decoder catch-up and a peer's already completed catch-up
      // still make secondary work yield. They do not establish current
      // outgoing congestion or fund longer packets on an otherwise healthy
      // (or unknown) listener path. Reserve that last step for real outgoing
      // loss/admission failure or a fresh growing/capped peer buffer.
      // Concealment also yields secondary output, but alone cannot fund longer
      // packets: it can result from reordering or local playout scheduling.
      final maxLevel =
          (measuredFloor &&
                  secondaryYielded &&
                  (newLoss || newDrop || peerPressure)) ||
              _level == _longPacketFloor
          ? _longPacketFloor
          : _shortPacketFloor;
      if (!pending &&
          _level < maxLevel &&
          (_lastDownAt == null ||
              now.difference(_lastDownAt!) >= pressureCooldown)) {
        _level++;
        // Decoded catch-up means audio was already queued too long. Take
        // two rungs now instead of carrying that overload through another
        // cooldown; isolated loss still takes one measured step.
        if (recovered && _level < _shortPacketFloor) _level++;
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
        peerConcealment == 0 &&
        transportAllowsRecovery &&
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

  bool _transportAllowsRecovery(
    Object? value,
    DateTime now, {
    required bool fresh,
  }) {
    // Older snapshots lack RTT; a sub-ms local route can round to zero.
    // Preserve their existing receiver-based policy without inventing an
    // estimate. Invalid advertised values cannot authorize producer growth.
    if (value == null) return _rttWindow.isEmpty;
    if (value is! int || value < 0 || value > 60000) return false;
    if (value == 0) return true;
    if (fresh) {
      while (_rttWindow.isNotEmpty &&
          now.difference(_rttWindow.first.at) >= _rttWindowSpan) {
        _rttWindow.removeFirst();
      }
      _rttWindow.addLast((at: now, ms: value));
      while (_rttWindow.length > 120) {
        _rttWindow.removeFirst();
      }
    }
    var baseline = value;
    for (final sample in _rttWindow) {
      if (sample.ms < baseline) baseline = sample.ms;
    }
    final margin = baseline ~/ 4 > 20 ? baseline ~/ 4 : 20;
    // Shorter packets multiply padded fanout traffic. A queue on the
    // measured path must clear before healthy playout can earn that growth.
    // RTT alone never reduces the current audio budget or video quality.
    return value <= baseline + margin;
  }
}
