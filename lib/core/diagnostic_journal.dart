import 'dart:collection';

/// Opt-in release instrumentation. No raw log, network API or automatic upload.
const kDiagnosticReportEnabled = bool.fromEnvironment('XVEIL_DIAGNOSTICS');

/// Source-owned labels only: neither event nor metric accepts user strings.
enum DiagnosticEvent {
  startup,
  lifecycle,
  onboardingBegin,
  containerOpen,
  onboardingSession,
  onboardingFailed,
  transportSent,
  transportFailed,
  transportReceived,
  messageAcknowledged,
  messageRetry,
  nativeSendFailed,
  callState,
  callSignalSent,
  callSignalFailed,
  callSignalReceived,
  audioStart,
  mediaSample,
  videoDelivery,
  downloadRetry,
  downloadParked,
  downloadFailed,
  downloadReceived,
  backgroundService,
  callEnded,
  p2pBootstrapSent,
  p2pBootstrapFailed,
  p2pBootstrapReceived,
  modelInventorySent,
  modelInventoryFailed,
  modelInventoryReceived,
}

enum DiagnosticMetric {
  code,
  transport,
  direction,
  endReason,
  video,
  state,
  success,
  durationMs,
  anonymous,
  background,
  wantReply,
  attempt,
  sources,
  enabled,
  nodeUp,
  txPackets,
  rxPackets,
  audioTxPackets,
  audioPayloadBytes,
  audioPayloadPackets,
  audioPacketDurationMs,
  audioPacketizationHold,
  audioLongPacketsRequested,
  audioRxPackets,
  audioReceiveAgeMs,
  micMuted,
  audioDelayMs,
  audioRecoveryCount,
  audioDiscardedMs,
  audioRecoveryFallbackFrames,
  audioInsertedSamples,
  audioAcceleratedSamples,
  jitterMs,
  lossPercent,
  rttMs,
  txDrops,
  rxDrops,
  workerStalled,
  videoWorkerStalled,
  videoTxFps,
  videoRxFps,
  videoTxFrames,
  videoRxFrames,
  videoSendPaused,
  concealedSamples,
  audioPayloadAgeMs,
  videoDeliveryPhase,
  videoDeliverySupported,
  videoDeliveryProbeConfirmed,
  videoDeliveryQueuePressure,
  videoDeliveryKbps,
  videoProbeIntervalMs,
  origin,
}

/// Bounded process-local evidence. Monotonic offsets, never wall-clock time,
/// peer/message/content identifiers, paths, names, device labels or payloads.
/// Events survive screen changes but not process exit. Export is explicit.
class DiagnosticJournal {
  DiagnosticJournal({
    this.enabled = kDiagnosticReportEnabled,
    this.capacity = 360,
  }) : assert(capacity > 0);

  final bool enabled;
  final int capacity;
  final Stopwatch _clock = Stopwatch()..start();
  final _events = ListQueue<Map<String, Object>>();
  final _counts = <DiagnosticEvent, int>{};
  final _lastAt = <DiagnosticEvent, int>{};
  Map<String, Object>? _lastCallEnd;
  int _dropped = 0;

  void record(
    DiagnosticEvent event, {
    Map<DiagnosticMetric, num> values = const {},
    Duration minInterval = Duration.zero,
  }) {
    if (!enabled) return;
    _counts.update(event, (n) => n + 1, ifAbsent: () => 1);
    final at = _clock.elapsedMilliseconds;
    final last = _lastAt[event];
    if (last != null && at - last < minInterval.inMilliseconds) return;
    _lastAt[event] = at;
    final row = <String, Object>{
      'elapsed_ms': at,
      'event': event.name,
      'values': {
        for (final entry in values.entries)
          if (entry.value.isFinite && entry.value.abs() <= 1000000000000)
            entry.key.name: entry.value,
      },
    };
    _events.add(row);
    // A busy transport can fill the ring while the person opens Settings to
    // copy the report. Keep one identifier-free terminal cause until the next
    // call ends, the journal is cleared, or this process exits.
    if (event == DiagnosticEvent.callEnded) _lastCallEnd = row;
    if (_events.length > capacity) {
      _events.removeFirst();
      _dropped++;
    }
  }

  /// Native JSON can contain peer-keyed maps. Never copy it wholesale, recurse,
  /// stringify values or infer that an unknown numeric field is safe to export.
  void recordMediaStats(Map<String, dynamic> stats) {
    if (!enabled) return;
    record(
      DiagnosticEvent.mediaSample,
      values: {
        for (final entry in _mediaFields.entries)
          if (stats[entry.key] case final num number) entry.value: number,
      },
      minInterval: const Duration(seconds: 5),
    );
  }

  /// Source-controller state, sampled after applying the current observation.
  /// Phase codes: startup=0, drain=1, cruise=2, probe=3. No history, peer maps
  /// or native clocks are copied. Unknown fields and malformed values stay out.
  void recordVideoDelivery(Map<String, Object?> snapshot) {
    if (!enabled) return;
    final phase = switch (snapshot['phase']) {
      'startup' => 0,
      'drain' => 1,
      'cruise' => 2,
      'probe' => 3,
      _ => null,
    };
    final kbps = snapshot['delivery_kbps'];
    final interval = snapshot['probe_interval_ms'];
    record(
      DiagnosticEvent.videoDelivery,
      values: {
        DiagnosticMetric.videoDeliveryPhase: ?phase,
        for (final entry in _videoDeliveryBooleans.entries)
          if (snapshot[entry.key] case final bool flag)
            entry.value: flag ? 1 : 0,
        if (kbps is num && kbps.isFinite && kbps >= 0 && kbps <= 1000000)
          DiagnosticMetric.videoDeliveryKbps: kbps,
        if (interval is int && interval >= 950 && interval <= 3000)
          DiagnosticMetric.videoProbeIntervalMs: interval,
      },
      minInterval: const Duration(seconds: 5),
    );
  }

  static const _videoDeliveryBooleans = {
    'supported': DiagnosticMetric.videoDeliverySupported,
    'probe_confirmed': DiagnosticMetric.videoDeliveryProbeConfirmed,
    'queue_pressure': DiagnosticMetric.videoDeliveryQueuePressure,
  };

  static const _mediaFields = {
    'tx_pkts': DiagnosticMetric.txPackets,
    'rx_pkts': DiagnosticMetric.rxPackets,
    'audio_tx_pkts': DiagnosticMetric.audioTxPackets,
    'audio_tx_payload_bytes': DiagnosticMetric.audioPayloadBytes,
    'audio_tx_payload_pkts': DiagnosticMetric.audioPayloadPackets,
    'audio_tx_packet_duration_ms': DiagnosticMetric.audioPacketDurationMs,
    'audio_packetization_video_hold': DiagnosticMetric.audioPacketizationHold,
    'audio_packetization_long_requested':
        DiagnosticMetric.audioLongPacketsRequested,
    'audio_rx_pkts': DiagnosticMetric.audioRxPackets,
    'audio_rx_native_age_ms': DiagnosticMetric.audioReceiveAgeMs,
    'mic_muted': DiagnosticMetric.micMuted,
    'audio_delay_ms': DiagnosticMetric.audioDelayMs,
    'audio_latency_recovery_count': DiagnosticMetric.audioRecoveryCount,
    'audio_latency_discarded_ms': DiagnosticMetric.audioDiscardedMs,
    'audio_latency_fallback_frames':
        DiagnosticMetric.audioRecoveryFallbackFrames,
    'audio_inserted_samples_for_deceleration':
        DiagnosticMetric.audioInsertedSamples,
    'audio_removed_samples_for_acceleration':
        DiagnosticMetric.audioAcceleratedSamples,
    'jitter_ms': DiagnosticMetric.jitterMs,
    'loss_pct': DiagnosticMetric.lossPercent,
    'rtt_ms': DiagnosticMetric.rttMs,
    'tx_drops': DiagnosticMetric.txDrops,
    'rx_drops': DiagnosticMetric.rxDrops,
    'worker_stalled': DiagnosticMetric.workerStalled,
    'video_worker_stalled': DiagnosticMetric.videoWorkerStalled,
    'video_tx_fps': DiagnosticMetric.videoTxFps,
    'video_rx_deliver_fps': DiagnosticMetric.videoRxFps,
    'video_tx_frames': DiagnosticMetric.videoTxFrames,
    'video_rx_deliver_frames': DiagnosticMetric.videoRxFrames,
    'video_send_paused': DiagnosticMetric.videoSendPaused,
    'audio_concealed_samples': DiagnosticMetric.concealedSamples,
    'audio_tx_payload_age_ms': DiagnosticMetric.audioPayloadAgeMs,
  };

  Map<String, Object> toJson() => {
    'schema': 'xveil-diagnostics/1',
    // Unlike the schema (also used by ordinary error reports), this constant
    // exists in AOT only when the release instrumentation was compiled in.
    if (kDiagnosticReportEnabled) 'build_mode': 'xveil-diagnostics-enabled/1',
    'enabled': enabled,
    'retention': 'memory-until-process-exit',
    'dropped_events': _dropped,
    'counts': {
      for (final entry in _counts.entries) entry.key.name: entry.value,
    },
    if (_lastCallEnd case final last?)
      'last_call_end': {
        ...last,
        'values': {...last['values'] as Map},
      },
    // Export snapshots; callers cannot mutate the journal through the report.
    'events': [
      for (final e in _events)
        {
          ...e,
          'values': {...e['values'] as Map},
        },
    ],
  };

  void clear() {
    _events.clear();
    _counts.clear();
    _lastAt.clear();
    _lastCallEnd = null;
    _dropped = 0;
    _clock.reset();
  }
}

final diagnosticJournal = DiagnosticJournal();
