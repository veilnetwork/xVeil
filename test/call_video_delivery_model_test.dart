import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_bitrate_adapter.dart';
import 'package:xveil/state/call_video_delivery_model.dart';

Map<String, dynamic> report(
  int n, {
  int origin = 1,
  int? timestamp,
  int? sent,
  int delay = 60,
  int? bytes,
}) => {
  'origin': origin,
  'sample_us': n * 1000000,
  'arrival_us': n * 1000000 + 120000,
  'bytes': bytes ?? n * 10000,
  'frames': n * 30,
  'timestamp': timestamp ?? n * 90000,
  'sent_timestamp': sent ?? n * 90000,
  'sent_bytes': n * 10000,
  'sent_timestamp_valid': true,
  'delay_ms': delay,
};
final epoch = DateTime(2026, 10, 21);
DateTime at(int n) => epoch.add(Duration(seconds: n));
const ceiling = (maxBitrateKbps: 900, maxFps: 60.0);
const floor = (maxBitrateKbps: 15, maxFps: 1.0);
void observe(
  CallVideoDeliveryModel m,
  int n,
  Map<String, dynamic> peers, {
  int expected = 1,
  int route = 0,
}) => m.observe(
  {'video_delivery_peers': peers, 'video_rtt_route_epoch': route},
  at(n),
  expected,
);

void main() {
  test('fresh causal decoder ACK doubles, cached and pre-probe ACK do not', () {
    final m = CallVideoDeliveryModel();
    observe(m, 1, {'p': report(1, sent: 90000)});
    expect(m.propose(floor, ceiling, at(1), healthy: true), isNull);
    observe(m, 2, {'p': report(2, sent: 270000)});
    final probe = m.propose(floor, ceiling, at(2), healthy: true)!;
    expect(probe, (maxBitrateKbps: 30, maxFps: 2.0));
    m.applied(at(2), reduced: false);
    observe(m, 3, {'p': report(2, sent: 360000)});
    expect(m.propose(probe, ceiling, at(3), healthy: true), isNull);
    observe(m, 4, {'p': report(3, timestamp: 270000)});
    expect(m.propose(probe, ceiling, at(4), healthy: true), isNull);
    observe(m, 5, {'p': report(4, timestamp: 360000)});
    expect(m.propose(probe, ceiling, at(5), healthy: true)!.maxFps, 4);
  });
  test(
    'empty source clock cannot pin random high RTP timestamps at the floor',
    () {
      final m = CallVideoDeliveryModel();
      final empty = report(1, sent: 0, timestamp: 0, bytes: 0)
        ..['frames'] = 0
        ..['sent_bytes'] =
            9000 // Lifetime counter can survive a source restart.
        ..['sent_timestamp_valid'] = false;
      observe(m, 1, {'p': empty});
      m.applied(at(1), reduced: false);
      const first = 0xfba80000;
      observe(m, 2, {'p': report(2, sent: first, timestamp: first)});
      expect(m.propose(floor, ceiling, at(2), healthy: true), isNull);
      observe(m, 3, {
        'p': report(3, sent: first + 90000, timestamp: first + 90000),
      });
      expect(m.propose(floor, ceiling, at(3), healthy: true)!.maxFps, 2);
      final zero = CallVideoDeliveryModel();
      observe(zero, 1, {'p': report(1, sent: 0, timestamp: 0)});
      observe(zero, 2, {'p': report(2, sent: 90000, timestamp: 90000)});
      expect(zero.propose(floor, ceiling, at(2), healthy: true), isNotNull);
    },
  );
  test('all group receivers acknowledge, including staggered reports', () {
    final m = CallVideoDeliveryModel();
    observe(m, 0, {'a': report(1), 'b': {}}, expected: 2);
    expect(m.supported, isFalse); // mixed old/new engines use the legacy ladder
    observe(m, 1, {'a': report(1), 'b': report(1)}, expected: 2);
    observe(m, 2, {'a': report(2), 'b': report(1)}, expected: 2);
    expect(m.propose(floor, ceiling, at(2), healthy: true), isNull);
    observe(m, 3, {'a': report(2), 'b': report(3)}, expected: 2);
    expect(m.propose(floor, ceiling, at(3), healthy: true), isNotNull);
    m.applied(at(3), reduced: false);
    observe(m, 4, {'a': report(4), 'b': {}}, expected: 2);
    expect(m.propose(floor, ceiling, at(4), healthy: true), isNull);
  });
  test('drain holds three seconds, then periodic bounded probes return', () {
    final m = CallVideoDeliveryModel();
    observe(m, 1, {'p': report(1)});
    m.applied(at(1), reduced: true);
    for (var n = 2; n < 7; n++) {
      observe(m, n, {'p': report(n)});
      expect(m.propose(floor, ceiling, at(n), healthy: true), isNull);
    }
    observe(m, 7, {'p': report(7)});
    final probe = m.propose(floor, ceiling, at(7), healthy: true)!;
    expect(probe.maxBitrateKbps, 19);
    m.applied(at(7), reduced: false);
    observe(m, 8, {'p': report(8)});
    expect(m.propose(probe, ceiling, at(8), healthy: true), isNull);
    observe(m, 10, {'p': report(10)});
    expect(m.propose(probe, ceiling, at(10), healthy: true), isNotNull);
  });
  test('decoder queue tolerates spike, drains sustained rise and ceiling', () {
    final m = CallVideoDeliveryModel();
    observe(m, 1, {'p': report(1)});
    observe(m, 2, {'p': report(2, delay: 160)});
    expect(m.queuePressure, isFalse);
    expect(m.propose(floor, ceiling, at(2), healthy: true), isNull);
    observe(m, 3, {'p': report(3)});
    expect(m.queuePressure, isFalse);
    for (var n = 4; n <= 7; n++) {
      observe(m, n, {'p': report(n, delay: 160)});
    }
    expect(m.queuePressure, isTrue);
    observe(m, 8, {'p': report(8, delay: 500)});
    expect(m.queuePressure, isTrue);
  });
  test('decoder restart, route and membership start a new measurement', () {
    final m = CallVideoDeliveryModel();
    observe(m, 1, {'p': report(1)});
    observe(m, 2, {'p': report(2)});
    m.applied(at(2), reduced: false);
    observe(m, 3, {'p': report(3, origin: 2)});
    expect(m.propose(floor, ceiling, at(3), healthy: true), isNull);
    observe(m, 4, {'p': report(4, origin: 2)});
    expect(m.propose(floor, ceiling, at(4), healthy: true), isNotNull);
    observe(m, 5, {'p': report(5, origin: 2)}, route: 1);
    expect(m.propose(floor, ceiling, at(5), healthy: true), isNull);
    observe(m, 6, {'p': report(6), 'q': report(6)}, expected: 2, route: 1);
    expect(m.propose(floor, ceiling, at(6), healthy: true), isNull);
  });
  test(
    'application-limited sample retains max and ACK compression is bounded',
    () {
      final m = CallVideoDeliveryModel();
      observe(m, 1, {'p': report(1)});
      observe(m, 2, {'p': report(2, bytes: 1000000)});
      expect(m.deliveryKbps, 80); // bounded by actual sender production
      observe(m, 3, {'p': report(3, bytes: 1000001)});
      expect(m.deliveryKbps, 80);
      expect(m.propose(floor, ceiling, at(3), healthy: false), isNull);
    },
  );
  test(
    'RTP timestamp wrap is causal, malformed and idle reports cannot probe',
    () {
      final m = CallVideoDeliveryModel();
      observe(m, 1, {'p': report(1, timestamp: 0xfffffff0, sent: 0xfffffff0)});
      m.applied(at(1), reduced: false);
      observe(m, 2, {'p': report(2, timestamp: 50, sent: 50)});
      expect(m.propose(floor, ceiling, at(2), healthy: true), isNotNull);
      m.applied(at(2), reduced: false);
      observe(m, 3, {'p': report(3, timestamp: 0xfffffff0)});
      expect(m.propose(floor, ceiling, at(3), healthy: true), isNull);
      observe(m, 4, {
        'p': {...report(4), 'frames': -1},
      });
      expect(m.propose(floor, ceiling, at(4), healthy: true), isNull);
    },
  );
  test('busy encoder never spends a probe or jumps an unapplied budget', () {
    final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
    a.applyPendingTarget((_) => true);
    for (var n = 1; n <= 6; n++) {
      a.onNativeStats(
        {
          'audio_feedback_reports': 1,
          'rtt_ms': 120,
          'tx_jitter_ms': 10,
          'video_tx_frames': n * 2,
          'video_delivery_peers': {'p': report(n)},
        },
        sampledAt: at(n),
        sendAudioExpected: true,
      );
      if (n > 1) {
        expect(
          a.applyPendingTarget((target) {
            expect(target.maxFps, 2);
            return false;
          }),
          isFalse,
        );
      }
    }
    expect(a.acknowledgedTarget, floor);
    expect(a.applyPendingTarget((target) => target.maxFps == 2), isTrue);
    expect(a.applyPendingTarget((_) => fail('same ACK reused')), isNull);
  });
  test(
    'missing ACK holds a pending probe instead of falling back to growth',
    () {
      final m = CallVideoDeliveryModel();
      observe(m, 1, {
        'p': {...report(1), 'route_epoch': 1},
      });
      observe(m, 2, {
        'p': {...report(2), 'route_epoch': 1},
      });
      m.applied(at(2), reduced: false);
      final generation = m.generation;
      for (var n = 3; n < 20; n++) {
        observe(m, n, {'p': {}});
        expect(m.propose(floor, ceiling, at(n), healthy: true), isNull);
      }
      expect(m.supported, isTrue);
      expect(m.generation, generation);
    },
  );
  test('camera source restart cannot inherit old decoded acknowledgements', () {
    final m = CallVideoDeliveryModel();
    observe(m, 1, {
      'p': {...report(1), 'source_epoch': 1},
    });
    observe(m, 2, {
      'p': {...report(2), 'source_epoch': 1},
    });
    m.applied(at(2), reduced: false);
    observe(m, 3, {
      'p': {...report(3), 'source_epoch': 2},
    });
    expect(m.propose(floor, ceiling, at(3), healthy: true), isNull);
    observe(m, 4, {
      'p': {...report(4), 'source_epoch': 2},
    });
    expect(m.propose(floor, ceiling, at(4), healthy: true), isNotNull);
  });
  for (final rtt in [10, 120]) {
    test(
      'adapter reaches cap in 8s with measured delivery at ${rtt}ms RTT',
      () {
        final a = CallBitrateAdapter(baseBitrateKbps: 900, baseFps: 60);
        a.applyPendingTarget((_) => true);
        a.applyPendingPause((_) => true);
        for (var n = 1; n <= 8; n++) {
          a.onNativeStats(
            {
              'worker_stalled': 0,
              'video_worker_stalled': 0,
              'audio_feedback_reports': 1,
              'video_feedback_reports': 1,
              'rtt_ms': rtt,
              'tx_loss_pct': 0,
              'tx_jitter_ms': 10,
              'audio_rx_pkts': n * 100,
              'audio_rx_native_age_ms': 10,
              'audio_delay_ms': 60,
              'audio_tx_rtp_drops': 0,
              'video_tx_rtp_drops': 0,
              'tx_drops': 0,
              'video_tx_frames': n * 30,
              'video_delivery_peers': {'p': report(n)},
            },
            sampledAt: at(n),
            requireAudioReceivePlayout: true,
            requirePeerAudioPlayout: true,
            audioReceiveDelayMs: 60,
            peerAudioDelayMs: 60,
            peerAudioSampleSequence: n,
            receiveAudioExpected: true,
          );
          a.applyPendingTarget((_) => true);
        }
        expect(a.acknowledgedTarget, ceiling);
        a.onNativeStats({
          'worker_stalled': 0,
          'video_worker_stalled': 0,
          'audio_feedback_reports': 1,
          'rtt_ms': rtt,
          'audio_tx_rtp_drops': 1,
          'video_tx_frames': 300,
          'video_delivery_peers': {'p': report(9)},
        }, sampledAt: at(9));
        a.applyPendingTarget((_) => true);
        expect(a.acknowledgedTarget!.maxFps, lessThan(60));
      },
    );
  }
}
