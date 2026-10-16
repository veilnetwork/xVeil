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
    expect(policy.target, (packetMs: 40, payloadBps: 16000));
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
      observe(policy, sample(1, loss: 100), 1);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      policy.applyPending((_) => true, at(1));
      for (var i = 2; i <= 20; i++) {
        observe(policy, sample(i, loss: i.isEven ? 100 : 50), i);
      }
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      observe(policy, sample(21, loss: 200), 21);
      expect(policy.target, (packetMs: 40, payloadBps: 16000));
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
      observe(policy, sample(1, loss: 100), 1);
      final wanted = policy.target;
      expect(policy.applyPending((_) => false, at(1)), isFalse);
      observe(policy, sample(2, loss: 200), 8);
      expect(policy.target, wanted);
      expect(policy.pending, isTrue);
      expect(policy.applyPending((target) => target == wanted, at(8)), isTrue);
      observe(policy, sample(3, loss: 300), 9);
      expect(
        policy.target,
        wanted,
      ); // Real cooldown starts when native applies.
      observe(policy, sample(4, loss: 400), 11);
      expect(policy.target, (packetMs: 40, payloadBps: 16000));
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
      expect(policy.target, (packetMs: 40, payloadBps: 16000));
      policy.applyPending((_) => true, at(3));
      // Restore one rung with fresh complete room evidence, so a mistaken
      // counter-reset cut would remain observable above the floor.
      for (var i = 4; i <= 30; i++) {
        observe(policy, sample(i, recoveries: 11), i);
        policy.applyPending((_) => true, at(i));
      }
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      observe(policy, sample(31, recoveries: 0), 31);
      observe(policy, sample(32, recoveries: 0), 32);
      expect(policy.target, (packetMs: 40, payloadBps: 24000));
      observe(policy, sample(33, recoveries: 1), 33);
      expect(policy.target, (packetMs: 40, payloadBps: 16000));
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
    expect(policy.target, (packetMs: 40, payloadBps: 16000));
  });
  test('persistent overload stops at the speech payload floor', () {
    final policy = start();
    for (var i = 1; i <= 30; i++) {
      observe(policy, sample(i, loss: i * 100), i * 4);
      policy.applyPending((_) => true, at(i * 4));
    }
    expect(policy.target, (packetMs: 40, payloadBps: 16000));
  });
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
