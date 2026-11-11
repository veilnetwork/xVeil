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
  backgroundSnapshot,
  audioRoute,
  preferenceStoreFallback,
  microphonePermission,
  cameraPermission,
  networkChange,
  callAudioOutput,
  audioOutputSnapshot,
  microphoneControl,
  callSignalDecision,
  callHistoryRestore,
  callReplayRejected,
  cameraStart,
}

/// Source-owned stages; never a device ID, label or native error string.
enum CameraStartOrigin { callStart, toggle, deviceSelection, recovery }

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
  supported,
  serviceForeground,
  wakeLockHeld,
  interactive,
  powerSave,
  deviceIdle,
  batteryExempt,
  backgroundRestricted,
  audioInputLevelBand,
  audioOutputLevelBand,
  audioCaptureStartResult,
  audioPlayoutStartResult,
  speakerMuted,
  callVolumePercent,
  systemMicMuted,
  appAudioSessionState,
  outputVolumePercent,
  outputMuted,
  appOutputVolumePercent,
  appOutputMuted,
  outputIsDefault,
  outputIsCommunicationsDefault,
  outputDefaultsSame,
  audioAecEnabled,
  audioNsEnabled,
  audioAgcEnabled,
  audioTargetDelayMs,
  networkSnapshotAvailable,
  networkPresent,
  networkCapabilitiesAvailable,
  networkMetered,
  processNetworkBound,
  processNetworkIsDefault,
  networkWifi,
  networkCellular,
  networkVpn,
  networkInternet,
  networkValidated,
  networkNotSuspended,
  restrictBackgroundStatus,
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
  // Media traffic can evict the main ring before Settings opens. Retain only
  // a small phase tail, with the same enum/numeric allowlist and monotonic
  // offsets. It is process-wide, not an identifier-linked per-call history.
  static const _callStateHistoryCapacity = 12;
  final _callStates = ListQueue<Map<String, Object>>();
  final _lastEvidence = <DiagnosticEvent, Map<String, Object>>{};
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
    if (event == DiagnosticEvent.callState) {
      _callStates.add(row);
      if (_callStates.length > _callStateHistoryCapacity) {
        _callStates.removeFirst();
      }
    }
    // A busy transport can fill the ring while the person opens Settings to
    // copy the report. Keep one identifier-free terminal cause until the next
    // call ends, the journal is cleared, or this process exits.
    if (event == DiagnosticEvent.callEnded) _lastCallEnd = row;
    if (_retainedEvidence.contains(event)) _lastEvidence[event] = row;
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
        for (final entry in _audioDiscreteFields.entries)
          if (stats[entry.key] case final int number)
            if (number >= entry.value.$2 && number <= entry.value.$3)
              entry.value.$1: number,
      },
      minInterval: const Duration(seconds: 5),
    );
  }

  /// Only an OS decision category; no rationale, URI, label or OS error text.
  void recordMediaPermission({required bool video, bool? granted}) {
    record(
      video
          ? DiagnosticEvent.cameraPermission
          : DiagnosticEvent.microphonePermission,
      values: {
        DiagnosticMetric.state: granted == null ? -1 : (granted ? 1 : 0),
      },
    );
  }

  /// OS flags are boolean-only; volume and policy codes are bounded. Do not
  /// stringify, recurse or export native keys from a newer/malformed plugin.
  void recordBackgroundState(Map<Object?, Object?>? state) {
    record(
      DiagnosticEvent.backgroundSnapshot,
      values: {
        DiagnosticMetric.supported: state == null ? 0 : 1,
        DiagnosticMetric.success: 1,
        if (state != null)
          for (final entry in _backgroundFields.entries)
            if (state[entry.key] case final bool value)
              entry.value: value ? 1 : 0,
        if (state?['callVolumePercent'] case final int volume)
          if (volume >= 0 && volume <= 100)
            DiagnosticMetric.callVolumePercent: volume,
        if (state?['restrictBackgroundStatus'] case final int policy)
          if (policy >= 1 && policy <= 3)
            DiagnosticMetric.restrictBackgroundStatus: policy,
      },
    );
  }

  static const _backgroundFields = {
    'serviceForeground': DiagnosticMetric.serviceForeground,
    'wakeLockHeld': DiagnosticMetric.wakeLockHeld,
    'interactive': DiagnosticMetric.interactive,
    'powerSave': DiagnosticMetric.powerSave,
    'deviceIdle': DiagnosticMetric.deviceIdle,
    'batteryExempt': DiagnosticMetric.batteryExempt,
    'backgroundRestricted': DiagnosticMetric.backgroundRestricted,
    'systemMicMuted': DiagnosticMetric.systemMicMuted,
    'networkSnapshotAvailable': DiagnosticMetric.networkSnapshotAvailable,
    'networkPresent': DiagnosticMetric.networkPresent,
    'networkCapabilitiesAvailable':
        DiagnosticMetric.networkCapabilitiesAvailable,
    'networkMetered': DiagnosticMetric.networkMetered,
    'processNetworkBound': DiagnosticMetric.processNetworkBound,
    'processNetworkIsDefault': DiagnosticMetric.processNetworkIsDefault,
    'networkWifi': DiagnosticMetric.networkWifi,
    'networkCellular': DiagnosticMetric.networkCellular,
    'networkVpn': DiagnosticMetric.networkVpn,
    'networkInternet': DiagnosticMetric.networkInternet,
    'networkValidated': DiagnosticMetric.networkValidated,
    'networkNotSuspended': DiagnosticMetric.networkNotSuspended,
  };

  /// Only fixed protocol fields; no COM IDs, labels, paths or process IDs.
  /// Separate call/export evidence prevents a post-call empty session snapshot
  /// from overwriting the mixer state observed during the reported call.
  void recordAudioOutputState(
    Map<Object?, Object?>? state, {
    bool duringCall = false,
    bool failed = false,
  }) {
    final known = state?['schema'] == 'xveil-audio-output/1';
    final sessionState = state?['sessionState'];
    final validState =
        sessionState is int && sessionState >= 0 && sessionState <= 2;
    final single = known && validState && sessionState == 1;
    bool volumeValid(String key) =>
        state?[key] is int &&
        (state![key] as int) >= 0 &&
        (state[key] as int) <= 100;
    final complete =
        known &&
        validState &&
        state?['success'] == true &&
        (!single ||
            (volumeValid('outputVolumePercent') &&
                volumeValid('appVolumePercent') &&
                state?['outputMuted'] is bool &&
                state?['appMuted'] is bool));
    record(
      duringCall
          ? DiagnosticEvent.callAudioOutput
          : DiagnosticEvent.audioOutputSnapshot,
      values: {
        DiagnosticMetric.supported: known ? 1 : 0,
        DiagnosticMetric.success: !failed && complete ? 1 : 0,
        if (known) ...{
          for (final entry in _audioOutputBooleans.entries)
            if (single || entry.key == 'defaultOutputsSame')
              if (state?[entry.key] case final bool value)
                entry.value: value ? 1 : 0,
          for (final entry in _audioOutputNumbers.entries)
            if (single || entry.key == 'sessionState')
              if (state?[entry.key] case final int value)
                if (value >= 0 && value <= entry.value.$2)
                  entry.value.$1: value,
        },
      },
    );
  }

  static const _audioOutputBooleans = {
    'outputMuted': DiagnosticMetric.outputMuted,
    'appMuted': DiagnosticMetric.appOutputMuted,
    'usesDefaultOutput': DiagnosticMetric.outputIsDefault,
    'usesCommunicationsOutput': DiagnosticMetric.outputIsCommunicationsDefault,
    'defaultOutputsSame': DiagnosticMetric.outputDefaultsSame,
  };
  static const _audioOutputNumbers = {
    'sessionState': (DiagnosticMetric.appAudioSessionState, 2),
    'outputVolumePercent': (DiagnosticMetric.outputVolumePercent, 100),
    'appVolumePercent': (DiagnosticMetric.appOutputVolumePercent, 100),
  };

  // Read actual native configuration; absent fields in older libraries remain
  // absent. A stored intent is not evidence that processing was enabled.
  static const _audioStartFields = {
    'audio_aec_enabled': (DiagnosticMetric.audioAecEnabled, -1, 1),
    'audio_ns_enabled': (DiagnosticMetric.audioNsEnabled, -1, 1),
    'audio_agc_enabled': (DiagnosticMetric.audioAgcEnabled, -1, 1),
    'audio_capture_start_result': (
      DiagnosticMetric.audioCaptureStartResult,
      -1,
      1,
    ),
    'audio_playout_start_result': (
      DiagnosticMetric.audioPlayoutStartResult,
      -1,
      1,
    ),
  };

  static const _audioDiscreteFields = {
    ..._audioStartFields,
    // Receiver reserve, not network RTT or a user-selected send interval.
    'audio_jb_target_ms': (DiagnosticMetric.audioTargetDelayMs, -1, 60000),
    'audio_input_level_band': (DiagnosticMetric.audioInputLevelBand, -1, 5),
    'audio_output_level_band': (DiagnosticMetric.audioOutputLevelBand, -1, 5),
    'speaker_muted': (DiagnosticMetric.speakerMuted, 0, 1),
  };

  /// A failed start can end before the periodic media sample. Keep the two
  /// device outcomes immediately; never copy the rest of a native snapshot.
  void recordAudioStart({
    required bool success,
    Map<String, dynamic> stats = const {},
  }) {
    record(
      DiagnosticEvent.audioStart,
      values: {
        DiagnosticMetric.success: success ? 1 : 0,
        for (final entry in _audioStartFields.entries)
          if (stats[entry.key] case final int value)
            if (value >= entry.value.$2 && value <= entry.value.$3)
              entry.value.$1: value,
      },
    );
  }

  void recordCameraStart({
    required bool success,
    required CameraStartOrigin origin,
  }) {
    record(
      DiagnosticEvent.cameraStart,
      values: {
        DiagnosticMetric.success: success ? 1 : 0,
        DiagnosticMetric.origin: origin.index,
      },
    );
  }

  // Busy network traffic must not erase the last audio/OS/setup evidence while
  // the user navigates to export. Fixed cardinality, process-local only.
  static const _retainedEvidence = {
    DiagnosticEvent.callHistoryRestore,
    DiagnosticEvent.mediaSample,
    DiagnosticEvent.audioStart,
    DiagnosticEvent.cameraStart,
    DiagnosticEvent.audioRoute,
    DiagnosticEvent.backgroundSnapshot,
    DiagnosticEvent.backgroundService,
    DiagnosticEvent.onboardingBegin,
    DiagnosticEvent.containerOpen,
    DiagnosticEvent.onboardingSession,
    DiagnosticEvent.onboardingFailed,
    DiagnosticEvent.preferenceStoreFallback,
    DiagnosticEvent.microphonePermission,
    DiagnosticEvent.cameraPermission,
    DiagnosticEvent.networkChange,
    DiagnosticEvent.callAudioOutput,
    DiagnosticEvent.audioOutputSnapshot,
    DiagnosticEvent.microphoneControl,
  };

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
    'last_evidence': {
      for (final entry in _lastEvidence.entries)
        entry.key.name: {
          ...entry.value,
          'values': {...entry.value['values'] as Map},
        },
    },
    if (_lastCallEnd case final last?)
      'last_call_end': {
        ...last,
        'values': {...last['values'] as Map},
      },
    if (_callStates.isNotEmpty)
      'call_state_history': [
        for (final row in _callStates)
          {
            ...row,
            'values': {...row['values'] as Map},
          },
      ],
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
    _callStates.clear();
    _lastEvidence.clear();
    _dropped = 0;
    _clock.reset();
  }
}

final diagnosticJournal = DiagnosticJournal();
