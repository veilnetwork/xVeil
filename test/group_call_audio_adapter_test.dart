import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/group_call_audio_adapter.dart';

DateTime at(int seconds) =>
    DateTime(2026, 10, 16).add(Duration(seconds: seconds));
Map<String, dynamic> sample(
  int sequence, {
  int loss = 0,
  int drops = 0,
  int recoveries = 0,
  int delay = 80,
  int reports = 2,
  int worker = 0,
}) => {
  'worker_stalled': worker,
  'audio_config_valid': 1,
  'audio_loss_report_us': loss,
  'audio_tx_rtp_drops': drops,
  'audio_latency_recovery_count': recoveries,
  'audio_playout_sequence': sequence,
  'audio_playout_reports': reports,
  'audio_feedback_reports': reports,
  'audio_playout_ms': delay,
};
void observe(
  GroupCallAudioAdapter policy,
  Map<String, dynamic> stats,
  int second, {
  bool sending = true,
  bool receiving = true,
}) => policy.observe(
  stats,
  at(second),
  expectedPeers: 2,
  sending: sending,
  receiving: receiving,
);
GroupCallAudioAdapter start() {
  final policy = GroupCallAudioAdapter();
  expect(policy.target, (packetMs: 40, payloadBps: 32000));
  expect(policy.applyPending((_) => true, at(0)), isTrue);
  return policy;
}

void main() {
  test('concealment yields secondary work before lengthening room audio', () {
    final p = start();
    Map<String, dynamic> measured(int n, int witness) => {
      ...sample(n),
      'audio_peer_concealment_report_us': witness,
      'audio_max_packet_ms': 60,
      'audio_tx_packet_duration_ms': 40,
      'audio_tx_payload_pkts': n * 20,
    };
    observe(p, measured(1, 100), 1);
    expect(p.target, (packetMs: 40, payloadBps: 24000));
    p.applyPending((_) => true, at(1));
    p.observe(
      measured(2, 200),
      at(5),
      expectedPeers: 2,
      sending: true,
      receiving: true,
      secondaryYielded: false,
    );
    expect(p.needsSecondaryYield, isTrue);
    expect(p.target.packetMs, 40);
    observe(p, measured(3, 300), 9);
    expect(
      p.target.packetMs,
      40,
      reason: 'PLC alone does not fund longer packets',
    );
    p.observe(
      measured(4, 400),
      at(13),
      expectedPeers: 2,
      sending: false,
      receiving: false,
      secondaryYielded: false,
    );
    expect(p.needsSecondaryYield, isFalse);
    p.observe(
      measured(5, 400),
      at(17),
      expectedPeers: 2,
      sending: true,
      receiving: true,
      secondaryYielded: false,
    );
    expect(p.needsSecondaryYield, isFalse, reason: 'muted event replay');
  });

  test(
    'incoming catch-up cannot lengthen healthy or unknown outgoing audio',
    () {
      for (final kind in ['incoming', 'peer_recovered', 'unknown']) {
        final p = start();
        Map<String, dynamic> measured(int n) => {
          ...sample(
            n,
            recoveries: kind == 'peer_recovered' ? 0 : n,
            reports: kind == 'unknown' ? 0 : 2,
          ),
          if (kind == 'peer_recovered')
            'audio_peer_recovery_report_us': n * 100,
          'audio_max_packet_ms': 60,
          'audio_tx_packet_duration_ms': 40,
          'audio_tx_payload_pkts': n * 20,
        };
        p.observe(
          measured(1),
          at(1),
          expectedPeers: 2,
          sending: true,
          receiving: true,
          secondaryYielded: false,
        );
        p.observe(
          measured(2),
          at(2),
          expectedPeers: 2,
          sending: true,
          receiving: true,
          secondaryYielded: false,
        );
        p.applyPending((_) => true, at(2));
        p.observe(
          measured(3),
          at(8),
          expectedPeers: 2,
          sending: true,
          receiving: true,
          secondaryYielded: true,
        );
        expect(p.target, (packetMs: 40, payloadBps: 24000), reason: kind);
        p.observe(
          measured(4),
          at(12),
          expectedPeers: 2,
          sending: true,
          receiving: true,
          secondaryYielded: false,
        );
        expect(
          p.needsSecondaryYield,
          isTrue,
          reason: 'secondary work still yields to recovered sound',
        );
        expect(p.target.packetMs, 40);
        // A fresh real receiver ceiling can still use the emergency cadence.
        p.observe(
          {
            ...measured(5),
            'audio_playout_reports': 2,
            'audio_feedback_reports': 2,
            'audio_playout_ms': 240,
          },
          at(16),
          expectedPeers: 2,
          sending: true,
          receiving: true,
          secondaryYielded: true,
        );
        expect(p.target.packetMs, 60);
      }
    },
  );

  test('renewed pressure yields video even at the long audio floor', () {
    final p = start();
    Map<String, dynamic> measured(int n, int loss, int duration) => {
      ...sample(n, loss: loss),
      'audio_max_packet_ms': 60,
      'audio_tx_packet_duration_ms': duration,
      'audio_tx_payload_pkts': n * 20,
      'rtt_ms': 40,
    };
    for (var n = 1; n <= 2; n++) {
      observe(p, measured(n, n * 100, 40), n * 4);
      p.applyPending((_) => true, at(n * 4));
    }
    expect(p.applied, (packetMs: 60, payloadBps: 24000));
    p.observe(
      measured(3, 300, 60),
      at(12),
      expectedPeers: 2,
      sending: true,
      receiving: true,
      secondaryYielded: false,
    );
    expect(p.needsSecondaryYield, isTrue);
    expect(
      p.pending,
      isFalse,
      reason: 'audio is already at its safe payload floor',
    );
    p.observe(
      measured(4, 300, 60),
      at(16),
      expectedPeers: 2,
      sending: true,
      receiving: true,
      secondaryYielded: false,
    );
    expect(
      p.needsSecondaryYield,
      isFalse,
      reason: 'cached loss is not new pressure',
    );
  });

  test('healthy long audio does not fund a shorter packet cadence', () {
    final p = start();
    for (var n = 1; n <= 2; n++) {
      observe(p, {
        ...sample(n, loss: n * 100),
        'audio_max_packet_ms': 60,
        'audio_tx_packet_duration_ms': 40,
        'audio_tx_payload_pkts': n * 20,
        'rtt_ms': 40,
      }, n * 4);
      p.applyPending((_) => true, at(n * 4));
    }
    for (var n = 30; n < 60; n++) {
      p.observe(
        {
          ...sample(n),
          'audio_max_packet_ms': 60,
          'audio_tx_packet_duration_ms': 60,
          'audio_tx_payload_pkts': n * 20,
          'rtt_ms': 77,
        },
        at(n),
        expectedPeers: 2,
        sending: true,
        receiving: true,
        secondaryYielded: true,
      );
    }
    expect(p.target, (packetMs: 60, payloadBps: 24000));
    for (var n = 60; n < 68; n++) {
      observe(p, {...sample(n), 'rtt_ms': 40}, n);
    }
    expect(p.target, (packetMs: 40, payloadBps: 24000));
  });

  test('sustained pressure preserves the characterized Opus payload floor', () {
    for (final supported in [false, true]) {
      final policy = start();
      for (var n = 1; n < 20; n++) {
        observe(policy, {
          ...sample(n, loss: n * 100),
          if (supported) 'audio_max_packet_ms': 60,
          'audio_tx_packet_duration_ms': policy.target.packetMs,
          'audio_tx_payload_pkts': n * 20,
        }, n * 4);
        policy.applyPending((_) => true, at(n * 4));
        expect(policy.target.payloadBps, greaterThanOrEqualTo(24000));
      }
    }
  });
  test(
    'starts with bounded packet overhead and keeps full payload quality',
    () {
      final policy = start();
      expect(policy.pending, isFalse);
      expect(
        policy.applyPending((_) => throw StateError('no retune'), at(1)),
        isNull,
      );
    },
  );
  test('decoded catch-up cuts payload promptly before another cooldown', () {
    final policy = start();
    observe(policy, sample(1), 1);
    observe(policy, sample(2, recoveries: 1), 2);
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
  });
  test('fresh room-wide headroom restores short packets', () {
    final policy = start();
    for (var i = 1; i <= 8; i++) {
      observe(policy, sample(i), i * 2);
    }
    expect(policy.target, (packetMs: 20, payloadBps: 32000));
  });
  test('cached feedback cannot manufacture healthy samples', () {
    final policy = start();
    for (var i = 1; i <= 40; i++) {
      observe(policy, sample(1), i * 2);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
  });
  test('queued transport cannot earn a more expensive packet cadence', () {
    final policy = start();
    observe(policy, {...sample(1), 'rtt_ms': 20}, 1);
    for (var i = 2; i <= 30; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 80}, i);
    }
    expect(
      policy.target,
      (packetMs: 40, payloadBps: 32000),
      reason:
          'healthy playout at the current rate does not prove wire headroom',
    );
    for (var i = 31; i <= 38; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 20}, i);
    }
    expect(
      policy.target,
      (packetMs: 20, payloadBps: 32000),
      reason: 'fresh recovered transport still permits shorter audio packets',
    );
  });
  test('a stable 120-ms RTT is not accumulating transport delay', () {
    final policy = start();
    for (var i = 1; i <= 8; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 120}, i * 2);
    }
    expect(policy.target, (packetMs: 20, payloadBps: 32000));
  });
  test('missing RTT cannot erase already observed transport queueing', () {
    final policy = start();
    observe(policy, {...sample(1), 'rtt_ms': 20}, 1);
    observe(policy, {...sample(2), 'rtt_ms': 80}, 2);
    for (var i = 3; i <= 20; i++) {
      observe(policy, sample(i), i);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
  });
  test('transport growth alone cannot degrade an established audio budget', () {
    final policy = start();
    for (var i = 1; i <= 8; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 20}, i * 2);
    }
    policy.applyPending((_) => true, at(16));
    for (var i = 9; i <= 20; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 120}, i * 2);
    }
    expect(policy.target, (packetMs: 20, payloadBps: 32000));
  });
  test('a changed stable route can age out the old RTT floor', () {
    final policy = start();
    observe(policy, {...sample(1), 'rtt_ms': 20}, 1);
    for (var i = 2; i <= 30; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 120}, i);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
    for (var i = 31; i <= 38; i++) {
      observe(policy, {...sample(i), 'rtt_ms': 120}, 200 + i);
    }
    expect(policy.target, (packetMs: 20, payloadBps: 32000));
  });
  test('one healthy listener cannot speak for a room', () {
    final policy = start();
    for (var i = 1; i <= 30; i++) {
      observe(policy, sample(i, reports: 1), i * 2);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
  });
  test(
    'fresh loss reacts once; cached and replayed losses cannot repeat it',
    () {
      final policy = start();
      Map<String, dynamic> feedback(int n, int loss) => {
        ...sample(n, loss: loss),
        'audio_max_packet_ms': 60,
        'audio_tx_packet_duration_ms': 40,
        'audio_tx_payload_pkts': n * 20,
      };
      observe(policy, feedback(1, 100), 1);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      policy.applyPending((_) => true, at(1));
      for (var i = 2; i <= 20; i++) {
        observe(policy, feedback(i, i.isEven ? 100 : 50), i);
      }
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      observe(policy, feedback(21, 200), 21);
      expect(policy.target, (packetMs: 60, payloadBps: 24000));
    },
  );
  test('losses on a short-packet stream first reduce packet overhead', () {
    final policy = start();
    for (var i = 1; i <= 8; i++) {
      observe(policy, sample(i), i * 2);
    }
    policy.applyPending((_) => true, at(16));
    observe(policy, sample(9, loss: 100), 17);
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
  });
  test(
    'failed native retune stays pending and is retried before further cuts',
    () {
      final policy = start();
      Map<String, dynamic> feedback(int n, int loss) => {
        ...sample(n, loss: loss),
        'audio_max_packet_ms': 60,
        'audio_tx_packet_duration_ms': 40,
        'audio_tx_payload_pkts': n * 20,
      };
      observe(policy, feedback(1, 100), 1);
      final wanted = policy.target;
      expect(policy.applyPending((_) => false, at(1)), isFalse);
      observe(policy, feedback(2, 200), 8);
      expect(policy.target, wanted);
      expect(policy.pending, isTrue);
      expect(policy.applyPending((target) => target == wanted, at(8)), isTrue);
      observe(policy, feedback(3, 300), 9);
      expect(
        policy.target,
        wanted,
      ); // Real cooldown starts when native applies.
      observe(policy, feedback(4, 400), 11);
      expect(policy.target, (packetMs: 60, payloadBps: 24000));
    },
  );
  test(
    'native recovery baselines, resets and cached counters are not events',
    () {
      final policy = start();
      observe(policy, sample(1, recoveries: 10), 1);
      observe(policy, sample(2, recoveries: 10), 2);
      expect(policy.target, (packetMs: 40, payloadBps: 32000));
      observe(policy, sample(3, recoveries: 11), 3);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      policy.applyPending((_) => true, at(3));
      // Restore one rung with fresh complete room evidence, so a mistaken
      // counter-reset cut would remain observable above the floor.
      for (var i = 4; i <= 30; i++) {
        observe(policy, sample(i, recoveries: 11), i);
        policy.applyPending((_) => true, at(i));
      }
      expect(policy.target, (packetMs: 40, payloadBps: 32000));
      observe(policy, sample(31, recoveries: 0), 31);
      observe(policy, sample(32, recoveries: 0), 32);
      expect(policy.target, (packetMs: 40, payloadBps: 32000));
      observe(policy, sample(33, recoveries: 1), 33);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
    },
  );
  test('stalled samples cannot invent drops or decoded recovery', () {
    final policy = start();
    observe(policy, sample(1), 1);
    for (var i = 2; i < 20; i++) {
      observe(policy, sample(i, worker: 1, recoveries: i, drops: i), i);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
  });
  test('local drops are measured as increments, never the initial total', () {
    final policy = start();
    observe(policy, sample(1, drops: 10), 1);
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
    observe(policy, sample(2, drops: 11), 2);
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
  });
  test('mute consumes old reports without degrading the audio source', () {
    final policy = start();
    observe(policy, sample(1, loss: 100, recoveries: 10), 1, sending: false);
    observe(policy, sample(1, loss: 100, recoveries: 10), 3);
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
    observe(policy, sample(2, loss: 200, recoveries: 10), 5);
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
  });
  test('bounded oscillations never become a growing backlog', () {
    final policy = start();
    const values = [36, 56, 36, 36, 56, 56];
    for (var i = 1; i <= 30; i++) {
      observe(policy, sample(i, delay: values[i % values.length]), i * 2);
    }
    expect(policy.target, (packetMs: 20, payloadBps: 32000));
  });
  test('real sustained growth acts below the absolute ceiling', () {
    final policy = start();
    for (var i = 1; i <= 6; i++) {
      observe(policy, sample(i, delay: 40 + i * 10), i * 2);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
  });
  test('cached ceiling cannot repeatedly degrade the payload', () {
    final policy = start();
    observe(policy, sample(1, delay: 200), 4);
    policy.applyPending((_) => true, at(4));
    for (var i = 5; i < 20; i++) {
      observe(policy, sample(1, delay: 200), i);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
    observe(policy, sample(2, delay: 200), 20);
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
  });
  test('persistent overload stops at the speech payload floor', () {
    final policy = start();
    for (var i = 1; i <= 30; i++) {
      observe(policy, sample(i, loss: i * 100), i * 4);
      policy.applyPending((_) => true, at(i * 4));
    }
    expect(policy.target, (packetMs: 40, payloadBps: 24000));
  });
  test(
    'new engines may reduce framing only after real loss at a measured 40-ms floor',
    () {
      final policy = start();
      Map<String, dynamic> capable(
        int seq, {
        int loss = 0,
        int? packets,
        int duration = 40,
      }) => {
        ...sample(seq, loss: loss),
        'audio_max_packet_ms': 60,
        'audio_tx_packet_duration_ms': duration,
        'audio_tx_payload_pkts': packets,
      };
      observe(policy, capable(1, packets: 10), 1);
      observe(policy, capable(2, loss: 100, packets: 20), 2);
      policy.applyPending((_) => true, at(2));
      observe(policy, capable(3, loss: 200, packets: 30, duration: 20), 5);
      policy.applyPending((_) => true, at(5));
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      observe(policy, capable(4, loss: 300, packets: 31), 8);
      expect(policy.target, (packetMs: 60, payloadBps: 24000));
      policy.applyPending((_) => true, at(8));
      // Replay/expiry cannot produce a second event or immediate recovery.
      for (var n = 9; n < 20; n++) {
        observe(
          policy,
          capable(n, loss: 300, packets: 32 + n, duration: 60),
          n,
        );
      }
      expect(policy.target, (packetMs: 60, payloadBps: 24000));
      // Fresh room-wide headroom returns toward the short-packet mode.
      for (var n = 30; n < 38; n++) {
        observe(policy, capable(n, packets: 32 + n, duration: 60), n);
      }
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
    },
  );

  test(
    'capability, unknown feedback and an unmeasured floor cannot select 60 ms',
    () {
      for (final kind in ['unknown', 'stale', 'no_packets', 'wrong_duration']) {
        final policy = start();
        for (var n = 1; n < 12; n++) {
          final stats = {
            ...sample(n, loss: n * 100),
            'audio_max_packet_ms': 60,
            if (kind != 'no_packets') 'audio_tx_payload_pkts': n * 20,
            'audio_tx_packet_duration_ms': kind == 'wrong_duration' ? 20 : 40,
            if (kind == 'stale') 'worker_stalled': 1,
          };
          if (kind == 'unknown') stats.remove('audio_max_packet_ms');
          observe(policy, stats, n * 4);
          policy.applyPending((_) => true, at(n * 4));
        }
        expect(policy.target, (packetMs: 40, payloadBps: 24000), reason: kind);
      }
    },
  );

  test(
    'fresh peer decoded loss is consumed while muted and never replayed',
    () {
      final policy = start();
      observe(
        policy,
        {...sample(1), 'audio_peer_recovery_report_us': 100},
        1,
        sending: false,
      );
      observe(policy, {...sample(2), 'audio_peer_recovery_report_us': 100}, 2);
      expect(policy.target, (packetMs: 40, payloadBps: 32000));
      observe(policy, {...sample(3), 'audio_peer_recovery_report_us': 200}, 3);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
    },
  );

  test(
    'a rejected 60-ms retune stays pending and an explicit legacy cap cancels it',
    () {
      final policy = start();
      for (var n = 1; n <= 4; n++) {
        observe(policy, {
          ...sample(n, loss: n * 100),
          'audio_max_packet_ms': 60,
          'audio_tx_packet_duration_ms': 40,
          'audio_tx_payload_pkts': n * 25,
        }, n * 4);
        if (n < 2) policy.applyPending((_) => true, at(n * 4));
      }
      expect(policy.target, (packetMs: 60, payloadBps: 24000));
      expect(policy.applyPending((_) => false, at(16)), isFalse);
      expect(policy.pending, isTrue);
      observe(policy, {
        ...sample(5, loss: 500),
        'audio_max_packet_ms': 40,
        'audio_tx_packet_duration_ms': 40,
        'audio_tx_payload_pkts': 125,
      }, 20);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      expect(policy.pending, isFalse);
    },
  );

  test('a backward clock change cannot complete a healthy streak', () {
    final policy = start();
    for (var i = 1; i < 8; i++) {
      observe(policy, sample(i), i * 2);
    }
    observe(policy, sample(8), -1);
    for (var i = 9; i < 20; i++) {
      observe(policy, sample(i), i - 9);
    }
    expect(policy.target, (packetMs: 40, payloadBps: 32000));
  });
}
