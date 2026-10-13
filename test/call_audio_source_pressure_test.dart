import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_source_pressure.dart';
import 'package:xveil/state/call_peer_audio_playout.dart';
import 'package:xveil/domain/call_signal.dart';

void main() {
  bool? sample(
    CallAudioSourcePressure policy, {
    bool send = true,
    bool receive = true,
    bool requirePeer = true,
    int? peer = 100,
    int? currentPeer,
    int? local = 100,
    int? age = 50,
    bool interrupted = false,
    int? drops = 0,
  }) => policy.observe(
    sendExpected: send,
    receiveExpected: receive,
    requirePeerPlayout: requirePeer,
    peerDelayMs: peer,
    peerCurrentDelayMs: currentPeer,
    receiveDelayMs: local,
    receiveAgeMs: age,
    interrupted: interrupted,
    audioTxDrops: drops,
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

  test('audio-only source waits for sustained measured recovery', () {
    final policy = CallAudioSourcePressure();
    expect(sample(policy, peer: null), isTrue);
    recover(policy);
    expect(sample(policy, peer: 300), isTrue);
    recover(policy);
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
      expect(sample(policy, peer: 300, currentPeer: 160), isTrue);
      // Local failures still override the healthy peer's current measurement.
      expect(sample(policy, peer: 300, currentPeer: 100, local: 180), isTrue);
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
        isTrue,
      );
    },
  );

  test('recovered latch cannot authorize growth with intermediate playout', () {
    for (final localDirection in [false, true]) {
      final policy = CallAudioSourcePressure();
      recover(policy);
      for (final delay in [120, 126, 146, 159]) {
        expect(
          sample(
            policy,
            peer: localDirection ? 100 : delay,
            local: localDirection ? delay : 100,
          ),
          isTrue,
        );
      }
      // Intermediate measurements withhold growth without changing the
      // existing 160-ms degradation latch or its 12-sample bad-path recovery.
      expect(sample(policy), isFalse);
      expect(sample(policy, peer: 160), isTrue);
      recover(policy);
    }
  });

  test('intermediate receive age cannot authorize growth after recovery', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, age: 500), isTrue);
    expect(sample(policy, age: 999), isTrue);
    expect(sample(policy, age: 50), isFalse);
    // Muted/legacy directions still do not require unused measurements.
    expect(sample(policy, receive: false, local: null, age: null), isFalse);
    expect(sample(policy, send: false, peer: null), isFalse);
  });

  test(
    'standing delay throttles other bindings before the PCM budget is spent',
    () {
      final policy = CallAudioSourcePressure();
      recover(policy);
      expect(sample(policy, peer: 180), isTrue);
      for (var i = 0; i < 20; i++) {
        expect(sample(policy, peer: 140), isTrue);
      }
      recover(policy);
      expect(sample(policy, local: 180), isTrue);
    },
  );

  test('fresh peer measurements cannot hide stalled or old local audio', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, local: null), isTrue);
    expect(sample(policy, age: 1000), isTrue);
    expect(sample(policy, age: null), isTrue);
    expect(sample(policy, age: -1), isTrue);
    recover(policy);
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

  test('primary failures and interruptions restrain all competing sources', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, drops: 1), isTrue);
    // A new engine may reset its native counter; history is not a new loss.
    recover(policy);
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
      expect(sample(policy, receive: false, peer: null), isTrue);
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
    expect(sample(policy, requirePeer: false, peer: null, local: null), isTrue);
  });
}
