import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_audio_source_pressure.dart';

void main() {
  bool? sample(
    CallAudioSourcePressure policy, {
    bool send = true,
    bool receive = true,
    bool requirePeer = true,
    int? peer = 100,
    int? local = 100,
    int? age = 50,
    bool interrupted = false,
    int? drops = 0,
  }) => policy.observe(
    sendExpected: send,
    receiveExpected: receive,
    requirePeerPlayout: requirePeer,
    peerDelayMs: peer,
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
