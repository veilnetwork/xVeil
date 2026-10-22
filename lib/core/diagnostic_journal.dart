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
  downloadRetry,
  downloadParked,
  downloadFailed,
  downloadReceived,
  backgroundService,
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
    _events.add({
      'elapsed_ms': at,
      'event': event.name,
      'values': {
        for (final entry in values.entries)
          if (entry.value.isFinite && entry.value.abs() <= 1000000000000)
            entry.key.name: entry.value,
      },
    });
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
    'enabled': enabled,
    'retention': 'memory-until-process-exit',
    'dropped_events': _dropped,
    'counts': {
      for (final entry in _counts.entries) entry.key.name: entry.value,
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
    _dropped = 0;
    _clock.reset();
  }
}

final diagnosticJournal = DiagnosticJournal();
