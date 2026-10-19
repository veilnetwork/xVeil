import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_source_pressure.dart';
import 'package:xveil/state/call_peer_audio_playout.dart';
import 'package:xveil/domain/call_signal.dart';

void main() {
  final times = Expando<DateTime>();
  bool? sample(
    CallAudioSourcePressure policy, {
    bool send = true,
    bool receive = true,
    bool requirePeer = true,
    int? peer = 100,
    int? currentPeer,
    int? targetPeer,
    int? targetLocal,
    int? local = 100,
    int? age = 50,
    bool interrupted = false,
    int? drops = 0,
    Object? lossReportUs,
    Object? peerRecoveryReportUs,
    Object? concealmentReportUs,
    Object? localConcealmentReportUs,
    bool recovered = false,
    DateTime? at,
  }) => policy.observe(
    sampledAt: times[policy] =
        at ??
        (times[policy] ?? DateTime(2026, 10, 19)).add(
          const Duration(seconds: 1),
        ),
    sendExpected: send,
    receiveExpected: receive,
    requirePeerPlayout: requirePeer,
    peerDelayMs: peer,
    peerCurrentDelayMs: currentPeer,
    peerTargetDelayMs: targetPeer,
    receiveTargetDelayMs: targetLocal,
    receiveDelayMs: local,
    receiveAgeMs: age,
    interrupted: interrupted,
    audioTxDrops: drops,
    audioLossReportUs: lossReportUs,
    peerAudioRecoveryReportUs: peerRecoveryReportUs,
    peerAudioConcealmentReportUs: concealmentReportUs,
    localAudioConcealmentReportUs: localConcealmentReportUs,
    recovered: recovered,
  );

  void recover(
    CallAudioSourcePressure policy, {
    bool send = true,
    bool receive = true,
  }) {
    for (var i = 0; i < 11; i++) {
      expect(sample(policy, send: send, receive: receive), isTrue);
    }
    expect(sample(policy, send: send, receive: receive), isFalse);
  }

  test('fresh peer audio loss restrains sources without a growing buffer', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, lossReportUs: 100), isTrue);
    for (var i = 0; i < 11; i++) {
      expect(sample(policy, lossReportUs: 100), isTrue);
    }
    expect(sample(policy, lossReportUs: 100), isFalse);
    expect(sample(policy, lossReportUs: 0), isFalse);
    expect(sample(policy, lossReportUs: 50), isFalse);
    expect(sample(policy, lossReportUs: 101), isTrue);
  });

  test('peer concealment yields sources once, including mute/resume', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, concealmentReportUs: 100), isTrue);
    for (var n = 0; n < 2; n++) {
      expect(sample(policy, concealmentReportUs: 100), isTrue);
    }
    expect(sample(policy, concealmentReportUs: 100), isFalse);
    sample(policy, send: false, concealmentReportUs: 200);
    expect(sample(policy, concealmentReportUs: 200), isFalse);
    sample(policy, send: false, receive: false, concealmentReportUs: 300);
    sample(policy, send: false, receive: false, concealmentReportUs: 0);
    recover(policy);
    expect(sample(policy, concealmentReportUs: 300), isFalse);
    expect(sample(policy, concealmentReportUs: 301), isTrue);
  });

  test('incoming concealment yields sources with the microphone muted', () {
    final policy = CallAudioSourcePressure();
    recover(policy, send: false);
    expect(sample(policy, send: false, localConcealmentReportUs: 100), isTrue);
    expect(sample(policy, send: false, localConcealmentReportUs: 100), isTrue);
    expect(sample(policy, send: false, localConcealmentReportUs: 100), isTrue);
    expect(sample(policy, send: false, localConcealmentReportUs: 100), isFalse);
    // A second event in the same receive episode needs sustained recovery,
    // even though sending was resumed between the two receive events.
    expect(sample(policy, localConcealmentReportUs: 200), isTrue);
    recover(policy);
    expect(sample(policy, localConcealmentReportUs: 200), isFalse);
  });

  test('incoming events while receive is off cannot replay on resume', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(
      sample(policy, receive: false, localConcealmentReportUs: 100),
      isFalse,
    );
    expect(sample(policy, localConcealmentReportUs: 100), isFalse);
    sample(policy, send: false, receive: false, localConcealmentReportUs: 200);
    sample(policy, send: false, receive: false, localConcealmentReportUs: 0);
    recover(policy);
    expect(sample(policy, localConcealmentReportUs: 200), isFalse);
    expect(sample(policy, localConcealmentReportUs: 201), isTrue);
    expect(
      sample(policy, receive: false, localConcealmentReportUs: 202),
      isTrue,
    );
    expect(sample(policy), isTrue);
    expect(sample(policy), isFalse);
    expect(sample(policy, localConcealmentReportUs: 202), isFalse);
    expect(sample(policy, localConcealmentReportUs: 203), isTrue);
    expect(sample(policy, localConcealmentReportUs: 203), isTrue);
    expect(sample(policy, localConcealmentReportUs: 203), isTrue);
    expect(sample(policy, localConcealmentReportUs: 203), isFalse);
  });

  test(
    'planned catch-up uses brief pressure without shortening genuine failure recovery',
    () {
      final policy = CallAudioSourcePressure();
      recover(policy);
      expect(sample(policy, recovered: true), isTrue);
      expect(sample(policy), isTrue);
      expect(sample(policy), isTrue);
      expect(sample(policy), isFalse);
      expect(sample(policy, interrupted: true), isTrue);
      expect(sample(policy, recovered: true), isTrue);
      recover(policy);
    },
  );

  test('peer catch-up yields briefly without renewing cached reports', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, peerRecoveryReportUs: 100), isTrue);
    expect(sample(policy, peerRecoveryReportUs: 100), isTrue);
    expect(sample(policy, peerRecoveryReportUs: 100), isTrue);
    expect(sample(policy, peerRecoveryReportUs: 100), isFalse);
    expect(sample(policy, peerRecoveryReportUs: 0), isFalse);
    expect(sample(policy, peerRecoveryReportUs: 90), isFalse);
    expect(sample(policy, peerRecoveryReportUs: 200), isTrue);
  });

  test(
    'a second fresh transient inside six seconds keeps sustained protection',
    () {
      final policy = CallAudioSourcePressure();
      recover(policy);
      expect(sample(policy, concealmentReportUs: 100), isTrue);
      expect(sample(policy, concealmentReportUs: 101), isTrue);
      recover(policy);
      // An expired episode only gets the short hold again.
      expect(sample(policy, concealmentReportUs: 102), isTrue);
      expect(sample(policy, concealmentReportUs: 102), isTrue);
      expect(sample(policy, concealmentReportUs: 102), isTrue);
      expect(sample(policy, concealmentReportUs: 102), isFalse);
    },
  );

  test('peer catch-up while not sending is consumed without later replay', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    sample(policy, send: false, peerRecoveryReportUs: 100);
    expect(sample(policy, peerRecoveryReportUs: 100), isFalse);
    expect(sample(policy, peerRecoveryReportUs: 200), isTrue);
  });

  test(
    'source budget consumes native trend and cannot ignore a capped current buffer',
    () {
      final policy = CallAudioSourcePressure();
      recover(policy, receive: false);
      bool? observe(int seq, int delay, bool growing) => policy.observe(
        sendExpected: true,
        receiveExpected: false,
        requirePeerPlayout: true,
        peerDelayMs: delay,
        peerCurrentDelayMs: delay,
        peerSampleSequence: seq,
        peerBufferGrowing: growing,
        receiveDelayMs: null,
        receiveAgeMs: null,
        interrupted: false,
        audioTxDrops: 0,
      );
      expect(observe(6, 100, true), isNull);
      expect(
        observe(6, 100, false),
        isNull,
        reason: 'cached report cannot confirm native pressure',
      );
      for (var n = 7; n <= 18; n++) {
        observe(n, 100, false);
      }
      expect(observe(19, 100, false), isFalse);
      expect(
        observe(20, 300, false),
        isTrue,
        reason: 'hard ceiling is independent of the hint',
      );
    },
  );

  test('audio-only source waits for sustained measured recovery', () {
    final policy = CallAudioSourcePressure();
    expect(sample(policy, peer: null), isTrue);
    recover(policy);
    expect(sample(policy, peer: 300), isTrue);
    recover(policy);
  });

  test('bounded playout oscillations leave competing sources admitted', () {
    for (final incoming in [false, true]) {
      for (final values in [
        [36, 56, 36, 36, 56, 56],
        [31, 1, 31, 31, 51, 51],
        [1, 19, 19, 19, 39, 39],
        [3, 3, 23, 3, 43, 43],
      ]) {
        final policy = CallAudioSourcePressure();
        recover(policy);
        for (var repeat = 0; repeat < 4; repeat++) {
          for (final delay in values) {
            expect(
              sample(
                policy,
                peer: incoming ? 100 : delay,
                local: incoming ? delay : 100,
              ),
              isFalse,
              reason: 'ordinary packet timing must not throttle video or DATA',
            );
          }
        }
      }
    }
  });

  test('source pressure follows sustained growth below the shared ceiling', () {
    for (final incoming in [false, true]) {
      final policy = CallAudioSourcePressure();
      recover(policy);
      for (final delay in [20, 40, 60, 80, 100, 120, 140, 160, 180]) {
        sample(
          policy,
          peer: incoming ? 100 : delay,
          local: incoming ? delay : 100,
        );
      }
      expect(
        sample(policy, peer: incoming ? 100 : 200, local: incoming ? 200 : 100),
        isTrue,
      );
      recover(policy);
    }
  });

  test('cached peer report cannot confirm source growth', () {
    final policy = CallAudioSourcePressure();
    recover(policy, receive: false);
    final start = DateTime(2026, 10, 20);
    bool? observe(int seq, int second, {bool growing = true}) => policy.observe(
      sampledAt: start.add(Duration(seconds: second)),
      sendExpected: true,
      receiveExpected: false,
      requirePeerPlayout: true,
      peerDelayMs: 100,
      peerCurrentDelayMs: 100,
      peerSampleSequence: seq,
      peerBufferGrowing: growing,
      receiveDelayMs: null,
      receiveAgeMs: null,
      interrupted: false,
      audioTxDrops: 0,
    );
    expect(observe(1, 0), isNull);
    for (var second = 1; second <= 3; second++) {
      expect(observe(1, second), isNull);
    }
    expect(observe(2, 3), isTrue);
    expect(observe(1, 4, growing: false), isTrue);
  });

  test(
    'recovered current playout releases pressure despite a retained peak',
    () {
      final policy = CallAudioSourcePressure();
      expect(sample(policy, peer: 300, currentPeer: 300), isTrue);
      for (var i = 0; i < 11; i++) {
        expect(sample(policy, peer: 300, currentPeer: 100), isTrue);
      }
      expect(sample(policy, peer: 300, currentPeer: 100), isFalse);
      expect(sample(policy, peer: 300, currentPeer: 160), isNull);
      // Local failures still override the healthy peer's current measurement.
      expect(sample(policy, peer: 300, currentPeer: 100, local: 180), isNull);
      expect(sample(policy, peer: 300, currentPeer: 100, drops: 1), isTrue);
    },
  );

  test('invalid or orphaned current measurements cannot hide pressure', () {
    for (final current in [-1, 301, 60001]) {
      final policy = CallAudioSourcePressure();
      for (var i = 0; i < 20; i++) {
        expect(sample(policy, peer: 300, currentPeer: current), isTrue);
      }
    }
    for (final peak in [null, -1, 60001]) {
      final policy = CallAudioSourcePressure();
      for (var i = 0; i < 20; i++) {
        expect(sample(policy, peer: peak, currentPeer: 100), isTrue);
      }
    }
  });

  test(
    'expired or replayed peer reports cannot keep source recovery alive',
    () {
      final policy = CallAudioSourcePressure();
      final tracker = CallPeerAudioPlayout();
      final now = DateTime(2026, 10, 13);
      final report = CallAudioPlayoutFeedback(
        sequence: 1,
        delayMs: 300,
        currentDelayMs: 100,
      );
      tracker.observe(report, now);
      for (var i = 0; i < 12; i++) {
        final at = now.add(Duration(seconds: i));
        expect(
          sample(
            policy,
            peer: tracker.delayMs(at),
            currentPeer: tracker.currentDelayMs(at),
          ),
          i < 11 ? isTrue : isFalse,
        );
      }
      final expired = now.add(
        CallPeerAudioPlayout.lifetime + const Duration(milliseconds: 1),
      );
      tracker.observe(report, expired);
      expect(
        sample(
          policy,
          peer: tracker.delayMs(expired),
          currentPeer: tracker.currentDelayMs(expired),
        ),
        isNull,
      );
    },
  );

  test('recovered latch cannot authorize growth with intermediate playout', () {
    for (final localDirection in [false, true]) {
      for (final delay in [160, 170, 180, 199]) {
        final policy = CallAudioSourcePressure();
        recover(policy);
        expect(
          sample(
            policy,
            peer: localDirection ? 100 : delay,
            local: localDirection ? delay : 100,
          ),
          isNull,
        );
        expect(sample(policy), isFalse);
        expect(sample(policy, peer: 300), isTrue);
        recover(policy);
      }
    }
  });

  test('intermediate receive age cannot authorize growth after recovery', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, age: 500), isNull);
    expect(sample(policy, age: 999), isNull);
    expect(sample(policy, age: 50), isFalse);
    // Muted/legacy directions still do not require unused measurements.
    expect(sample(policy, receive: false, local: null, age: null), isFalse);
    expect(sample(policy, send: false, peer: null), isFalse);
  });

  test('capped buffers throttle sources until sustained recovery', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, peer: 300), isTrue);
    for (var i = 0; i < 20; i++) {
      expect(sample(policy, peer: 180), isTrue);
    }
    recover(policy);
    expect(sample(policy, local: 300), isTrue);
  });

  test('fresh peer measurements cannot hide stalled or old local audio', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, local: null), isNull);
    expect(sample(policy, age: 1000), isNull);
    expect(sample(policy, age: null), isNull);
    expect(sample(policy, age: -1), isNull);
    expect(sample(policy), isFalse);
  });

  test(
    'missing feedback and intermediate delays restart the recovery streak',
    () {
      final policy = CallAudioSourcePressure();
      for (var i = 0; i < 11; i++) {
        sample(policy);
      }
      expect(sample(policy, peer: null), isTrue);
      for (var i = 0; i < 11; i++) {
        sample(policy);
      }
      expect(sample(policy, peer: 250), isTrue);
      recover(policy);
    },
  );

  test('fresh audio loss restrains other sources until sustained recovery', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, drops: 1), isTrue);
    for (var n = 0; n < 11; n++) {
      expect(sample(policy, drops: 1), isTrue);
    }
    expect(
      sample(policy, drops: 1),
      isFalse,
      reason: 'a cached drop count cannot renew pressure',
    );
    expect(sample(policy), isFalse, reason: 'counter reset is not loss');
    expect(sample(policy, interrupted: true), isTrue);
    recover(policy);
  });

  test('muted local mic still protects measured incoming audio', () {
    final policy = CallAudioSourcePressure();
    recover(policy, send: false);
    expect(sample(policy, send: false, peer: null), isFalse);
    expect(sample(policy, send: false, peer: null, local: 300), isTrue);
  });

  test(
    'muted remote capture does not require a nonexistent receive stream',
    () {
      final policy = CallAudioSourcePressure();
      recover(policy, receive: false);
      expect(sample(policy, receive: false, local: null, age: null), isFalse);
      expect(sample(policy, receive: false, peer: null), isNull);
    },
  );

  test('no expected audio stops the lease; a new source starts unproven', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, send: false, receive: false), isNull);
    expect(sample(policy), isTrue);
    policy.reset();
    recover(policy);
  });

  test('legacy peer does not invent end-to-end measurements', () {
    final policy = CallAudioSourcePressure();
    for (var i = 0; i < 12; i++) {
      sample(policy, requirePeer: false, peer: null);
    }
    expect(sample(policy, requirePeer: false, peer: null), isFalse);
    expect(sample(policy, requirePeer: false, peer: null, local: null), isNull);
  });
  test('requested buffer ceiling restricts competing DATA until recovery', () {
    for (final incoming in [false, true]) {
      final policy = CallAudioSourcePressure();
      recover(policy);
      expect(
        sample(
          policy,
          targetPeer: incoming ? null : 320,
          targetLocal: incoming ? 320 : null,
        ),
        isTrue,
      );
      recover(policy);
      expect(sample(policy, targetPeer: 199, targetLocal: 199), isNull);
      expect(
        sample(policy, receive: false, peer: null, targetPeer: 300),
        isNull,
      );
    }
  });
}
