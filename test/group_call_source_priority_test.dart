import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/group_call_source_priority.dart';

DateTime at(int n) => DateTime(2026, 10, 19).add(Duration(seconds: n));
Map<String, dynamic> stats({
  int packets = 20,
  int sequence = 1,
  num fps = 1,
  bool paused = false,
  bool healthy = false,
}) => {
  'video_worker_stalled': 0,
  'video_tx_payload_pkts': packets,
  'max_fps': fps,
  'video_send_paused': paused ? 1 : 0,
  'worker_stalled': 0,
  'audio_config_valid': 1,
  'audio_tx_packet_duration_ms': 40,
  'audio_playout_sequence': sequence,
  'audio_playout_reports': 2,
  'audio_feedback_reports': 2,
  'audio_loss_report_us': 0,
  'audio_playout_ms': healthy ? 80 : 240,
};
void poll(
  GroupCallSourcePriority p,
  int n,
  Map<String, dynamic> s, {
  int audioMs = 40,
  bool video = true,
  bool sending = true,
}) => p.observe(
  s,
  at(n),
  videoExpected: video,
  appliedAudioMs: audioMs,
  expectedPeers: 2,
  audioSending: sending,
);

GroupCallSourcePriority pausedSource() {
  final p = GroupCallSourcePriority();
  p.requestYield(at(0));
  poll(p, 0, stats(packets: 18));
  p.acknowledgeFloor(at(0));
  poll(p, 1, stats(packets: 19));
  poll(p, 2, stats(packets: 20));
  p.requestYield(at(2));
  expect(p.paused, isTrue);
  return p;
}

void main() {
  test('a cached floor counter cannot justify pausing video', () {
    final p = GroupCallSourcePriority()..acknowledgeFloor(at(0));
    for (var n = 0; n <= 5; n++) {
      poll(p, n, stats());
    }
    p.requestYield(at(5));
    expect(p.floor, isTrue);
    expect(p.paused, isFalse);
    poll(p, 6, stats(packets: 21));
    p.requestYield(at(6));
    expect(p.paused, isFalse, reason: 'only one output progress sample');
    poll(p, 7, stats(packets: 22));
    p.requestYield(at(7));
    expect(p.paused, isTrue);
  });

  test('counter reset retires old floor evidence', () {
    final p = GroupCallSourcePriority()..acknowledgeFloor(at(0));
    for (var n = 0; n < 3; n++) {
      poll(p, n, stats(packets: 20 + n));
    }
    poll(p, 3, stats(packets: 1));
    p.requestYield(at(3));
    expect(p.paused, isFalse);
    poll(p, 4, stats(packets: 2));
    poll(p, 5, stats(packets: 3));
    p.requestYield(at(5));
    expect(p.paused, isFalse, reason: 'new stream has no acknowledged floor');
  });

  test('completed impairment keeps video running at its sparse floor', () {
    final p = GroupCallSourcePriority()..acknowledgeFloor(at(0));
    for (var n = 0; n < 12; n++) {
      poll(p, n, stats(packets: 20 + n, sequence: n + 1, healthy: true));
      p.requestYield(at(n), transient: true);
      expect(p.floor, isTrue);
      expect(
        p.paused,
        isFalse,
        reason: 'a fresh short impairment is not ongoing congestion',
      );
    }
    for (var n = 12; n <= 14; n++) {
      poll(p, n, {
        ...stats(packets: 20 + n, sequence: n + 1, healthy: true),
        'audio_peer_recovery_report_us':
            100, // already consumed, retained witness
      });
    }
    expect(p.floor, isFalse);
  });

  test('transient recovery requires fresh complete measured audio', () {
    final p = GroupCallSourcePriority()..requestYield(at(0), transient: true);
    for (var n = 1; n < 10; n++) {
      poll(p, n, stats(healthy: true));
    }
    expect(p.floor, isTrue, reason: 'cached reports cannot earn release');
    for (var n = 10; n < 15; n++) {
      poll(p, n, {
        ...stats(healthy: true, sequence: n),
        'audio_playout_reports': 1,
      });
    }
    expect(p.floor, isTrue, reason: 'one listener cannot prove room recovery');
    for (var n = 15; n < 18; n++) {
      poll(p, n, stats(healthy: true, sequence: n));
    }
    expect(p.floor, isFalse);
  });

  test('transient events neither shorten nor extend a genuine quiet hold', () {
    final p = pausedSource()..acknowledgePause(true, at(2));
    for (var n = 3; n < 10; n++) {
      poll(p, n, stats(paused: true, healthy: true, sequence: n));
    }
    p.requestYield(at(10), transient: true);
    for (var n = 10; n <= 21; n++) {
      poll(p, n, stats(paused: true, healthy: true, sequence: n));
      expect(
        p.paused,
        isTrue,
        reason: 'original genuine quiet interval not elapsed',
      );
    }
    poll(p, 22, stats(paused: true, healthy: true, sequence: 22));
    expect(
      p.paused,
      isFalse,
      reason: 'transient event did not restart the twenty-second hold',
    );
  });

  test('new congestion overrides a transient restriction', () {
    final p = GroupCallSourcePriority()..requestYield(at(0), transient: true);
    p.requestYield(at(2));
    for (var n = 3; n <= 21; n++) {
      poll(p, n, stats(healthy: true, sequence: n));
      expect(p.floor, isTrue);
    }
    poll(p, 22, stats(healthy: true, sequence: 22));
    expect(p.floor, isFalse);
  });

  test('an already applied video floor is not requested a second time', () {
    final p = GroupCallSourcePriority()..acknowledgeFloor(at(0));
    poll(p, 0, stats(packets: 19));
    poll(p, 1, stats(packets: 20));
    poll(p, 2, stats(packets: 21));
    expect(p.floor, isFalse, reason: 'no audio pressure yet');
    p.requestYield(at(2));
    expect(p.paused, isTrue, reason: 'the measured floor already yielded');
  });

  test('a raised native cadence retires an earlier floor acknowledgement', () {
    final p = GroupCallSourcePriority()..acknowledgeFloor(at(0));
    poll(p, 1, stats());
    poll(p, 2, stats());
    poll(p, 3, stats(fps: 15));
    poll(p, 4, stats());
    poll(p, 5, stats());
    p.requestYield(at(5));
    expect(p.paused, isFalse);
  });

  test('future ACKs cannot start floor or quiet evidence early', () {
    final p = GroupCallSourcePriority()..requestYield(at(0));
    p.acknowledgeFloor(at(10));
    for (var n = 1; n < 5; n++) {
      poll(p, n, stats());
      p.requestYield(at(n));
    }
    expect(p.paused, isFalse);
    final q = pausedSource()..acknowledgePause(true, at(20));
    for (var n = 3; n < 10; n++) {
      poll(q, n, stats(paused: true));
    }
    expect(q.yielded, isFalse);
  });

  test(
    'a refused floor or contradictory native cadence cannot justify pause',
    () {
      final p = GroupCallSourcePriority()..requestYield(at(0));
      for (var n = 1; n < 4; n++) {
        poll(p, n, stats());
        p.requestYield(at(n));
      }
      expect(p.floor, isTrue);
      expect(p.paused, isFalse);
      p.acknowledgeFloor(at(4));
      for (var n = 5; n < 9; n++) {
        poll(p, n, stats(fps: 15));
        p.requestYield(at(n));
      }
      expect(p.paused, isFalse);
      expect(p.yielded, isFalse);
    },
  );

  test('pause ACK and actual quiet output precede long-packet permission', () {
    final p = pausedSource();
    poll(p, 3, stats(paused: true));
    poll(p, 6, stats(paused: true));
    expect(p.yielded, isFalse, reason: 'native flag alone is not our ACK');
    p.acknowledgePause(true, at(6));
    poll(p, 7, stats(packets: 22, paused: true));
    poll(p, 8, stats(packets: 23, paused: true));
    expect(p.yielded, isFalse, reason: 'old queued video still progresses');
    poll(p, 9, stats(packets: 23, paused: true));
    poll(p, 10, stats(packets: 23, paused: true));
    expect(p.yielded, isFalse);
    poll(p, 11, stats(packets: 23, paused: true));
    expect(p.yielded, isTrue);
    poll(p, 12, {
      ...stats(packets: 23, paused: true),
      'video_worker_stalled': 1,
    });
    expect(p.yielded, isFalse, reason: 'a cached worker cannot prove quiet');
  });

  test(
    'repeated timestamps and a clock rollback cannot bank a quiet interval',
    () {
      final p = pausedSource()..acknowledgePause(true, at(2));
      poll(p, 3, stats(paused: true));
      for (var n = 0; n < 10; n++) {
        poll(p, 3, stats(paused: true));
      }
      expect(p.yielded, isFalse);
      poll(p, 1, stats(paused: true));
      poll(p, 6, stats(paused: true));
      expect(
        p.yielded,
        isFalse,
        reason: 'clock correction retired acknowledgements',
      );
    },
  );

  test(
    'roster invalidation preserves restriction without old quiet credit',
    () {
      final p = pausedSource()..acknowledgePause(true, at(2));
      for (var n = 3; n < 7; n++) {
        poll(p, n, stats(paused: true));
      }
      expect(p.yielded, isTrue);
      p.invalidate();
      poll(p, 8, stats(paused: true));
      expect(p.paused, isTrue);
      expect(p.yielded, isFalse);
    },
  );

  test('long audio alone cannot pause a late video source', () {
    final p = GroupCallSourcePriority();
    poll(p, 0, stats(), video: false, audioMs: 60);
    for (var n = 1; n < 30; n++) {
      poll(p, n, {
        ...stats(sequence: n, healthy: true),
        'audio_tx_packet_duration_ms': 60,
      }, audioMs: 60);
      expect(p.floor, isFalse);
    }
  });

  test('video recovers without increasing the audio packet rate', () {
    final p = pausedSource()..acknowledgePause(true, at(2));
    for (var n = 3; n < 20; n++) {
      poll(p, n, {
        ...stats(sequence: n, paused: true),
        'audio_tx_packet_duration_ms': 60,
      }, audioMs: 60);
    }
    expect(p.paused, isTrue);
    for (var n = 20; n < 30; n++) {
      poll(p, n, {
        ...stats(sequence: n, healthy: true, paused: true),
        'audio_tx_packet_duration_ms': 60,
      }, audioMs: 60);
    }
    expect(p.paused, isFalse);
    poll(p, 30, {
      ...stats(sequence: 30, healthy: true),
      'audio_tx_packet_duration_ms': 60,
    }, audioMs: 60);
    expect(p.floor, isFalse, reason: 'steady 60-ms audio is not new pressure');
  });

  test(
    'only fresh complete recovered audio can release the video restriction',
    () {
      final p = pausedSource()..acknowledgePause(true, at(2));
      for (var n = 3; n < 25; n++) {
        poll(p, n, stats(paused: true, healthy: true));
      }
      expect(
        p.paused,
        isTrue,
        reason: 'cached peer reports do not earn recovery',
      );
      for (var n = 25; n < 33; n++) {
        poll(p, n, stats(paused: true, healthy: true, sequence: n));
      }
      expect(p.paused, isFalse);
      expect(p.floor, isFalse);
    },
  );

  test(
    'no local video or muted capture needs no extra secondary restriction',
    () {
      for (final video in [false, true]) {
        final p = pausedSource();
        poll(p, 3, stats(), video: video, sending: !video);
        expect(p.floor, isFalse);
        expect(p.yielded, isTrue);
      }
    },
  );
}
