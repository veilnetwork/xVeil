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
    int? targetPeer,
    int? targetLocal,
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
    peerTargetDelayMs: targetPeer,
    receiveTargetDelayMs: targetLocal,
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
      expect(observe(6, 100, true), isTrue);
      expect(
        observe(6, 100, false),
        isTrue,
        reason: 'cached report cannot erase native pressure',
      );
      for (var n = 7; n <= 18; n++) {
        observe(n, 100, false);
      }
      expect(observe(19, 100, false), isFalse);
      expect(
        observe(20, 200, false),
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

  test('source pressure follows sustained growth below the shared ceiling', () {
    for (final incoming in [false, true]) {
      final policy = CallAudioSourcePressure();
      recover(policy);
      for (final delay in [110, 120, 130, 140, 150, 160]) {
        sample(
          policy,
          peer: incoming ? 100 : delay,
          local: incoming ? delay : 100,
        );
      }
      expect(
        sample(policy, peer: incoming ? 100 : 160, local: incoming ? 160 : 100),
        isTrue,
      );
      recover(policy);
    }
  });

  test('cached peer report cannot fill a source growth window', () {
    final policy = CallAudioSourcePressure();
    recover(policy, receive: false);
    // An expired report breaks the trend, while the released latch is kept.
    expect(sample(policy, receive: false, peer: null), isNull);
    for (var i = 0; i < 5; i++) {
      policy.observe(
        sendExpected: true,
        receiveExpected: false,
        requirePeerPlayout: true,
        peerDelayMs: 60 + i * 10,
        peerSampleSequence: i,
        receiveDelayMs: null,
        receiveAgeMs: null,
        interrupted: false,
        audioTxDrops: 0,
      );
    }
    for (var i = 0; i < 20; i++) {
      expect(
        policy.observe(
          sendExpected: true,
          receiveExpected: false,
          requirePeerPlayout: true,
          peerDelayMs: 110,
          peerSampleSequence: 4,
          receiveDelayMs: null,
          receiveAgeMs: null,
          interrupted: false,
          audioTxDrops: 0,
        ),
        isFalse,
      );
    }
    expect(
      policy.observe(
        sendExpected: true,
        receiveExpected: false,
        requirePeerPlayout: true,
        peerDelayMs: 110,
        peerSampleSequence: 5,
        receiveDelayMs: null,
        receiveAgeMs: null,
        interrupted: false,
        audioTxDrops: 0,
      ),
      isTrue,
    );
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
      expect(sample(policy, peer: 300, currentPeer: 100, drops: 1), isNull);
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
        expect(sample(policy, peer: 200), isTrue);
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
    expect(sample(policy, peer: 200), isTrue);
    for (var i = 0; i < 20; i++) {
      expect(sample(policy, peer: 180), isTrue);
    }
    recover(policy);
    expect(sample(policy, local: 200), isTrue);
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

  test('drops and interruptions with stable buffers only withhold growth', () {
    final policy = CallAudioSourcePressure();
    recover(policy);
    expect(sample(policy, drops: 1), isNull);
    // A new engine may reset its native counter; history is not a new loss.
    expect(sample(policy), isFalse);
    expect(sample(policy, interrupted: true), isNull);
    expect(sample(policy), isFalse);
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
          targetPeer: incoming ? null : 220,
          targetLocal: incoming ? 220 : null,
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
