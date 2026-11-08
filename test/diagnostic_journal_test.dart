import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';

class _PrivateValue {
  @override
  String toString() => throw StateError('must never stringify private data');
}

void main() {
  test('call phases survive busy media events until the report is copied', () {
    final journal = DiagnosticJournal(enabled: true, capacity: 2);
    for (final phase in [1, 2, 3]) {
      journal.record(
        DiagnosticEvent.callState,
        values: {DiagnosticMetric.state: phase, DiagnosticMetric.direction: 0},
      );
    }
    for (var i = 0; i < 50; i++) {
      journal.record(DiagnosticEvent.transportSent);
    }
    final report = journal.toJson();
    final evidence = [
      ...report['events'] as List,
      ...?report['call_state_history'] as List?,
    ];
    final phases = evidence
        .where((row) => (row as Map)['event'] == 'callState')
        .map((row) => ((row as Map)['values'] as Map)['state']);
    expect(
      phases,
      [1, 2, 3],
      reason:
          'a later Settings export must distinguish waiting for an answer from active media',
    );
  });

  test('retained call state history is bounded and exported as copies', () {
    final journal = DiagnosticJournal(enabled: true, capacity: 1);
    for (var i = 0; i < 50; i++) {
      journal.record(
        DiagnosticEvent.callState,
        values: {DiagnosticMetric.state: i % 4},
      );
    }
    final history = journal.toJson()['call_state_history'] as List;
    expect(history, hasLength(12));
    expect(history.map((e) => ((e as Map)['values'] as Map)['state']), [
      for (var i = 38; i < 50; i++) i % 4,
    ]);
    ((history.first as Map)['values'] as Map)['state'] = 999;
    history.clear();
    final again = journal.toJson()['call_state_history'] as List;
    expect(again, hasLength(12));
    expect(((again.first as Map)['values'] as Map)['state'], 2);
    expect(journal.toJson()['events'] as List, hasLength(1));
  });

  test('clearing or disabling diagnostics leaves no retained call history', () {
    final disabled = DiagnosticJournal(enabled: false);
    disabled.record(DiagnosticEvent.callState);
    expect(disabled.toJson().containsKey('call_state_history'), isFalse);
    final journal = DiagnosticJournal(enabled: true);
    journal.record(DiagnosticEvent.callState);
    journal.clear();
    expect(journal.toJson().containsKey('call_state_history'), isFalse);
    expect(journal.toJson()['counts'], isEmpty);
  });

  test('handover evidence retains only coarse state and outcome', () {
    final journal = DiagnosticJournal(enabled: true, capacity: 1);
    journal.record(
      DiagnosticEvent.networkChange,
      values: {
        DiagnosticMetric.state: 2,
        DiagnosticMetric.success: 1,
        DiagnosticMetric.durationMs: 7,
      },
    );
    journal.record(DiagnosticEvent.transportSent);
    final evidence = journal.toJson()['last_evidence'] as Map;
    expect((evidence['networkChange'] as Map)['values'], {
      'state': 2,
      'success': 1,
      'durationMs': 7,
    });
  });

  test('permission evidence keeps only pending/denied/granted categories', () {
    final journal = DiagnosticJournal(enabled: true, capacity: 1);
    journal.recordMediaPermission(video: false);
    final pending = (journal.toJson()['events'] as List).single as Map;
    expect(pending['values'], {'state': -1});
    journal.recordMediaPermission(video: false, granted: true);
    journal.recordMediaPermission(video: true, granted: false);
    journal.record(DiagnosticEvent.transportSent);
    final evidence = journal.toJson()['last_evidence'] as Map;
    expect((evidence['microphonePermission'] as Map)['values'], {'state': 1});
    expect((evidence['cameraPermission'] as Map)['values'], {'state': 0});
  });

  test(
    'receiver reserve exports only a bounded integer, without raw fields',
    () {
      for (final value in <Object?>[
        -1,
        0,
        260,
        400,
        60000,
        -2,
        60001,
        260.0,
        true,
        'private-target',
      ]) {
        final journal = DiagnosticJournal(enabled: true);
        journal.recordMediaStats({
          'audio_jb_target_ms': value,
          'device': 'private-device',
        });
        final row = (journal.toJson()['events'] as List).single as Map;
        expect(
          row['values'],
          value is int && value >= -1 && value <= 60000
              ? {'audioTargetDelayMs': value}
              : isEmpty,
        );
        expect(jsonEncode(journal.toJson()), isNot(contains('private-')));
      }
    },
  );

  test('disabled permission instrumentation retains nothing', () {
    final journal = DiagnosticJournal(enabled: false);
    journal.recordMediaPermission(video: false, granted: true);
    journal.recordMediaPermission(video: true, granted: false);
    expect(journal.toJson()['events'], isEmpty);
    expect(journal.toJson()['last_evidence'], isEmpty);
  });
  test(
    'APM evidence uses bounded native states, never preference defaults',
    () {
      for (final fixture in <(Map<String, dynamic>, Map<String, int>)>[
        (
          {
            'audio_aec_enabled': 1,
            'audio_ns_enabled': 0,
            'audio_agc_enabled': 1,
          },
          {'audioAecEnabled': 1, 'audioNsEnabled': 0, 'audioAgcEnabled': 1},
        ),
        (
          {
            'audio_aec_enabled': -1,
            'audio_ns_enabled': -1,
            'audio_agc_enabled': -1,
          },
          {'audioAecEnabled': -1, 'audioNsEnabled': -1, 'audioAgcEnabled': -1},
        ),
        ({}, {}), // An older engine does not prove enabled OR disabled.
        (
          {
            'audio_aec_enabled': true,
            'audio_ns_enabled': 1.0,
            'audio_agc_enabled': 2,
          },
          {},
        ),
        (
          {
            'audio_aec_enabled': 'private-canary',
            'audio_ns_enabled': -2,
            'audio_agc_enabled': double.nan,
            'device': 'private-canary',
          },
          {},
        ),
      ]) {
        final journal = DiagnosticJournal(enabled: true, capacity: 1);
        journal.recordAudioStart(success: true, stats: fixture.$1);
        journal.recordMediaStats(fixture.$1);
        journal.record(DiagnosticEvent.transportSent);
        final evidence = journal.toJson()['last_evidence'] as Map;
        expect((evidence['audioStart'] as Map)['values'], {
          'success': 1,
          ...fixture.$2,
        });
        expect((evidence['mediaSample'] as Map)['values'], fixture.$2);
        expect(jsonEncode(journal.toJson()), isNot(contains('private-canary')));
      }
    },
  );
  test(
    'operator circuit DHT and TCP correlation never enters anonymous reports',
    () {
      final journal = DiagnosticJournal(enabled: true);
      final native = <String, Object?>{
        'audio_rx_pkts': 12,
        'token': 'private-circuit-token',
        'prefix': 'private-envelope-prefix',
        'origin_cid': 123456789,
        'data_seq': 987654321,
        'circuit_trace': _PrivateValue(),
        'raw_log': 'anonymity.circuit.trace.egress private-log-line',
        'opaque_sha256': 'private-forward-digest',
        'sealed_sha256': 'private-sealed-digest',
        'record_sha256': 'private-ordered-record-digest',
        'child_local': 314159265,
        'ordered_record_trace':
            'transport.ordered_record stage=flushed private-record-log',
        'opaque_record_link': _PrivateValue(),
        'queue_admission_trace':
            'delivery.opaque_trace stage=queue_admission outcome=missing private-queue-log',
        'queue_outcome': _PrivateValue(),
        'qtag': 'private-dht-query-fingerprint',
        'walk_tag': 'private-dht-walk-fingerprint',
        'op': 314159265,
        'lookup': 271828182,
        'local': 'private-node-prefix',
        'dht_trace': _PrivateValue(),
        'duplicate_trace':
            'dht.query.duplicate_drop local=private-node walk_tag=private-walk',
        'process_duplicates': 123456789,
        'tcp_handshake_trace': _PrivateValue(),
        'tcp_attempt_group': _PrivateValue(),
        'attempt': 223606797,
        'candidate': 'private-handshake-backup',
        'handshake_selection':
            'tcp_handshake outcome=selected attempt=223606797 candidate=private-backup',
        'tcp_trace': 'transport.tcp_trace.handshake private-tcp-snapshot',
        'connection': 161803398,
        'local_port': 45678,
        'peer_port': 45679,
        'written_bytes': 141421356,
        'read_bytes': 173205080,
        'ranges': [
          {'sid': 'private-stream', 'offset': 123456789},
        ],
      };
      journal.recordMediaStats(native);
      journal.recordBackgroundState(native);
      journal.recordVideoDelivery(native);
      final report = jsonEncode(journal.toJson());
      expect(report, contains('audioRxPackets'));
      for (final forbidden in [
        'private-',
        'circuit_trace',
        'origin_cid',
        'data_seq',
        '123456789',
        '987654321',
        'trace.egress',
        'opaque_sha256',
        'sealed_sha256',
        'record_sha256',
        'child_local',
        'ordered_record_trace',
        'ordered_record',
        'opaque_record_link',
        'queue_admission_trace',
        'stage=queue_admission',
        'outcome=missing',
        'queue_outcome',
        'qtag',
        'walk_tag',
        '314159265',
        '271828182',
        'dht_trace',
        'duplicate_trace',
        'duplicate_drop',
        'process_duplicates',
        'tcp_handshake_trace',
        'tcp_attempt_group',
        'handshake_selection',
        '223606797',
        'tcp_trace',
        '161803398',
        '45678',
        '45679',
        '141421356',
        '173205080',
        'local_port',
        'peer_port',
        'written_bytes',
        'read_bytes',
      ]) {
        expect(report, isNot(contains(forbidden)));
      }
    },
  );

  test('audio evidence is coarse, bounded and retained after the call', () {
    final journal = DiagnosticJournal(enabled: true, capacity: 1);
    journal.recordMediaStats({
      'audio_input_level_band': 2,
      'audio_output_level_band': 4,
      'audio_capture_start_result': 0,
      'audio_playout_start_result': 1,
      'speaker_muted': 0,
      'audio_level': 12345,
      'total_input_energy': 123456789,
      'device_name': _PrivateValue(),
    });
    journal.record(DiagnosticEvent.transportReceived);
    final row =
        (journal.toJson()['last_evidence'] as Map)['mediaSample'] as Map;
    expect(row['values'], {
      'audioInputLevelBand': 2,
      'audioOutputLevelBand': 4,
      'audioCaptureStartResult': 0,
      'audioPlayoutStartResult': 1,
      'speakerMuted': 0,
    });
    expect(jsonEncode(journal.toJson()), isNot(contains('12345')));
    for (final value in <Object?>[
      -2,
      6,
      1793000000000,
      2.5,
      'secret',
      _PrivateValue(),
    ]) {
      final malformed = DiagnosticJournal(enabled: true);
      malformed.recordMediaStats({
        'audio_input_level_band': value,
        'audio_output_level_band': value,
      });
      expect(
        ((malformed.toJson()['events'] as List).single as Map)['values'],
        isEmpty,
      );
    }
  });
  test(
    'last call end survives traffic-ring eviction without retaining identifiers',
    () {
      final journal = DiagnosticJournal(enabled: true, capacity: 2);
      journal.record(
        DiagnosticEvent.callEnded,
        values: {DiagnosticMetric.endReason: 7, DiagnosticMetric.origin: 9},
      );
      for (var i = 0; i < 5; i++) {
        journal.record(DiagnosticEvent.transportReceived);
      }
      final report = journal.toJson();
      expect(
        (report['events'] as List).where(
          (e) => (e as Map)['event'] == 'callEnded',
        ),
        isEmpty,
      );
      expect(report['last_call_end'], isA<Map>());
      final last = report['last_call_end'] as Map;
      expect(last['values'], {'endReason': 7, 'origin': 9});
      (last['values'] as Map)['origin'] = 999;
      expect((journal.toJson()['last_call_end'] as Map)['values'], {
        'endReason': 7,
        'origin': 9,
      });
      journal.clear();
      expect(journal.toJson().containsKey('last_call_end'), isFalse);
    },
  );

  test('native snapshots export only explicit numeric fields', () {
    final journal = DiagnosticJournal(enabled: true);
    final snapshot = <String, dynamic>{
      'audio_tx_pkts': 41,
      'audio_rx_pkts': 23,
      'video_rx_deliver_fps': 29.5,
      'video_tx_frames': 7,
      'video_rx_deliver_frames': 3,
      'video_send_paused': 1,
      'audio_packetization_video_hold': 1,
      'audio_packetization_long_requested': 1,
      'audio_rx_native_age_ms': 520,
      'audio_latency_recovery_count': 13,
      'audio_latency_discarded_ms': 280,
      'audio_latency_fallback_frames': 2,
      'audio_inserted_samples_for_deceleration': 960,
      'audio_removed_samples_for_acceleration': 480,
      'rtt_ms': -1,
      'audio_delay_ms': 'my private message',
      'jitter_ms': _PrivateValue(),
      'tx_drops': double.nan,
      'rx_drops': double.infinity,
      'tx_pkts': 1e30,
      'peer': '7084a345b55ef17031b793b96a9edca2c',
      'filename': '/Users/alice/secret.txt',
      'device': _PrivateValue(),
      'unknown_numeric_id': 12345678,
      'groups': {
        'private identity': {'audio_rx_pkts': 999},
      },
      'video_delivery_peers': {
        'private identity': {
          'frames': 99,
          'target_delay_ms': 260,
          'origin': 1793000000000000,
          'sample_us': 1793000001000000,
        },
      },
      'audio_receivers': {
        'private identity': {'audio_rx_pkts': 999},
      },
    };
    journal.recordMediaStats(snapshot);
    snapshot['audio_tx_pkts'] = 9999;
    final report = journal.toJson();
    final event = (report['events'] as List).single as Map;
    expect(event['values'], {
      'audioTxPackets': 41,
      'audioRxPackets': 23,
      'videoRxFps': 29.5,
      'videoTxFrames': 7,
      'videoRxFrames': 3,
      'videoSendPaused': 1,
      'audioPacketizationHold': 1,
      'audioLongPacketsRequested': 1,
      'audioReceiveAgeMs': 520,
      'audioRecoveryCount': 13,
      'audioDiscardedMs': 280,
      'audioRecoveryFallbackFrames': 2,
      'audioInsertedSamples': 960,
      'audioAcceleratedSamples': 480,
      'rttMs': -1,
    });
    final json = jsonEncode(report);
    for (final private in [
      'private',
      '7084a345',
      'alice',
      'secret.txt',
      'unknown_numeric_id',
      '9999',
      'filename',
    ]) {
      expect(json, isNot(contains(private)));
    }
    // A report cannot mutate the retained evidence either.
    (event['values'] as Map)['audioTxPackets'] = 0;
    expect(
      ((journal.toJson()['events'] as List).single as Map)['values'],
      containsPair('audioTxPackets', 41),
    );
  });

  test('disabled instrumentation retains no events or counters', () {
    final journal = DiagnosticJournal(enabled: false);
    journal.record(
      DiagnosticEvent.audioStart,
      values: {DiagnosticMetric.success: 1},
    );
    journal.recordMediaStats({'audio_rx_pkts': 23});
    journal.recordVideoDelivery({'phase': _PrivateValue()});
    expect(journal.toJson()['events'], isEmpty);
    expect(journal.toJson()['counts'], isEmpty);
  });

  test(
    'controller reports preserve bounded policy state without private data',
    () {
      final journal = DiagnosticJournal(enabled: true);
      final snapshot = <String, Object?>{
        'phase': 'probe',
        'supported': true,
        'probe_confirmed': false,
        'queue_pressure': true,
        'delivery_kbps': 125.5,
        'probe_interval_ms': 950,
        'source_epoch': 1793000000000000,
        'peer': 'private-peer-canary',
        'recent': _PrivateValue(),
        'video_delivery_peers': {'private-peer-canary': _PrivateValue()},
      };
      journal.recordVideoDelivery(snapshot);
      snapshot['probe_interval_ms'] = 3000;
      final event = (journal.toJson()['events'] as List).single as Map;
      expect(event['event'], 'videoDelivery');
      expect(event['values'], {
        'videoDeliveryPhase': 3,
        'videoDeliverySupported': 1,
        'videoDeliveryProbeConfirmed': 0,
        'videoDeliveryQueuePressure': 1,
        'videoDeliveryKbps': 125.5,
        'videoProbeIntervalMs': 950,
      });
      final exported = jsonEncode(journal.toJson());
      for (final private in [
        'private-peer-canary',
        'source_epoch',
        '1793000000',
        'recent',
      ]) {
        expect(exported, isNot(contains(private)));
      }
    },
  );

  test('malformed policy values cannot masquerade as report metrics', () {
    for (final value in <Object?>[
      null,
      _PrivateValue(),
      'private-canary',
      true,
      -1,
      949,
      3001,
      1793000000000,
      950.5,
      double.nan,
      double.infinity,
    ]) {
      final journal = DiagnosticJournal(enabled: true);
      journal.recordVideoDelivery({
        'phase': _PrivateValue(),
        'supported': 1,
        'probe_confirmed': 'yes',
        'queue_pressure': {'private-peer': _PrivateValue()},
        'delivery_kbps': double.infinity,
        'probe_interval_ms': value,
      });
      expect(
        ((journal.toJson()['events'] as List).single as Map)['values'],
        isEmpty,
      );
    }
    for (final value in <Object?>[
      _PrivateValue(),
      'private-canary',
      -1,
      1000001,
      1793000000000,
      double.nan,
      double.infinity,
    ]) {
      final journal = DiagnosticJournal(enabled: true);
      journal.recordVideoDelivery({'delivery_kbps': value});
      expect(
        ((journal.toJson()['events'] as List).single as Map)['values'],
        isEmpty,
      );
    }
  });

  test('controller phase codes and timing boundaries are stable', () {
    const phases = ['startup', 'drain', 'cruise', 'probe'];
    for (var code = 0; code < phases.length; code++) {
      final journal = DiagnosticJournal(enabled: true);
      journal.recordVideoDelivery({
        'phase': phases[code],
        'probe_interval_ms': code.isEven ? 950 : 3000,
      });
      expect(((journal.toJson()['events'] as List).single as Map)['values'], {
        'videoDeliveryPhase': code,
        'videoProbeIntervalMs': code.isEven ? 950 : 3000,
      });
    }
  });

  test('native and controller samples retain separate bounded cadences', () {
    final journal = DiagnosticJournal(enabled: true);
    final adapter = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 30);
    for (var n = 0; n < 1000; n++) {
      journal.recordMediaStats({'audio_rx_pkts': n});
      journal.recordVideoDelivery(adapter.videoDeliveryDiagnostics);
    }
    final report = journal.toJson();
    expect(report['counts'], {'mediaSample': 1000, 'videoDelivery': 1000});
    final events = report['events'] as List;
    expect(events, hasLength(2));
    expect(
      (events.last as Map)['values'],
      containsPair('videoProbeIntervalMs', 3000),
    );
  });

  test('bounded tail preserves aggregate counts and reports evictions', () {
    final journal = DiagnosticJournal(enabled: true, capacity: 2);
    for (var n = 0; n < 5; n++) {
      journal.record(
        DiagnosticEvent.transportFailed,
        values: {DiagnosticMetric.durationMs: n},
      );
    }
    final report = journal.toJson();
    expect(report['dropped_events'], 3);
    expect(report['counts'], {'transportFailed': 5});
    expect((report['events'] as List).map((e) => (e as Map)['values']), [
      {'durationMs': 3},
      {'durationMs': 4},
    ]);
    journal.clear();
    expect(journal.toJson()['counts'], isEmpty);
    expect(journal.toJson()['events'], isEmpty);
    expect(journal.toJson()['dropped_events'], 0);
  });

  test(
    'sampling retains errors and exact counts without a packet-sized log',
    () {
      final journal = DiagnosticJournal(enabled: true);
      for (var n = 0; n < 1000; n++) {
        journal.record(
          DiagnosticEvent.transportSent,
          minInterval: const Duration(days: 1),
        );
      }
      journal.record(DiagnosticEvent.transportFailed);
      expect(journal.toJson()['counts'], {
        'transportSent': 1000,
        'transportFailed': 1,
      });
      expect(journal.toJson()['events'] as List, hasLength(2));
    },
  );
}
