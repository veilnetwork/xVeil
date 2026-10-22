import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/diagnostic_journal.dart';

class _PrivateValue {
  @override
  String toString() => throw StateError('must never stringify private data');
}

void main() {
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
    expect(journal.toJson()['events'], isEmpty);
    expect(journal.toJson()['counts'], isEmpty);
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
