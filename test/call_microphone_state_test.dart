import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_microphone_state.dart';

void main() {
  test(
    'pending permission permits receive startup without opening capture',
    () async {
      final answer = Completer<bool>();
      final permission = CallMicrophonePermission(answer.future);
      final state = CallMicrophoneState()..beginCall('call', micOn: true);
      var captureStarts = 0;
      var engineMuted = permission.captureMuted(state.mutedForCall('call'));
      // Model the observed ADM refusal: opening input without a grant fails,
      // whereas receive-only start does not need RECORD_AUDIO.
      bool startAudio() => engineMuted;
      expect(startAudio(), isTrue);
      final pending = permission.applyWhenGranted(
        isCurrent: () => state.belongsToCall('call'),
        isMuted: () => state.mutedForCall('call'),
        apply: (muted) {
          engineMuted = muted;
          if (!muted) captureStarts++;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(captureStarts, 0);
      answer.complete(true);
      await pending;
      expect(engineMuted, isFalse);
      expect(captureStarts, 1);
    },
  );

  test('denial leaves native capture muted', () async {
    final permission = CallMicrophonePermission(Future<bool>.value(false));
    var applied = false;
    await permission.applyWhenGranted(
      isCurrent: () => true,
      isMuted: () => false,
      apply: (_) {
        applied = true;
      },
    );
    expect(applied, isFalse);
    expect(permission.captureMuted(false), isTrue);
  });

  for (final choice in [true, false]) {
    test(
      'late grant uses current mute=$choice rather than initial snapshot',
      () async {
        final state = CallMicrophoneState()..beginCall('call', micOn: choice);
        final answer = Completer<bool>();
        final permission = CallMicrophonePermission(answer.future);
        bool? applied;
        final pending = permission.applyWhenGranted(
          isCurrent: () => state.belongsToCall('call'),
          isMuted: () => state.mutedForCall('call'),
          apply: (muted) {
            applied = muted;
          },
        );
        state.setMuted(choice);
        expect(permission.captureMuted(false), isTrue);
        answer.complete(true);
        await pending;
        expect(applied, choice);
        expect(permission.captureMuted(choice), choice);
      },
    );
  }

  for (final change in ['hangup', 'new-call', 'new-engine']) {
    test('late grant cannot revive capture after $change', () async {
      final state = CallMicrophoneState()..beginCall('call', micOn: true);
      final answer = Completer<bool>();
      final permission = CallMicrophonePermission(answer.future);
      var current = true;
      var applied = false;
      final pending = permission.applyWhenGranted(
        isCurrent: () => current && state.belongsToCall('call'),
        isMuted: () => state.muted,
        apply: (_) {
          applied = true;
        },
      );
      switch (change) {
        case 'hangup':
          state.clear();
        case 'new-call':
          state.beginCall('other', micOn: true);
        case 'new-engine':
          current = false;
      }
      answer.complete(true);
      await pending;
      expect(applied, isFalse);
    });
  }

  test(
    'existing grant does not hide an unmuted capture device refusal',
    () async {
      final permission = CallMicrophonePermission(Future<bool>.value(true));
      await permission.result;
      expect(permission.captureMuted(false), isFalse);
      expect(permission.captureMuted(true), isTrue);
    },
  );

  test('mute survives route rebuilding from an older call snapshot', () {
    final state = CallMicrophoneState()..beginCall('call', micOn: true);
    state.setMuted(true);
    state.beginCall('call', micOn: true);
    expect(state.mutedForCall('call'), isTrue);
    // The person can unmute while a replacement engine is still opening.
    state.setMuted(false);
    state.beginCall('call', micOn: false);
    expect(state.muted, isFalse);
  });

  test('cancelled or replaced setup cannot open the previous microphone', () {
    final state = CallMicrophoneState()..beginCall('first', micOn: true);
    state.clear();
    expect(state.mutedForCall('first'), isTrue);
    state.beginCall('second', micOn: true);
    expect(state.belongsToCall('first'), isFalse);
    expect(state.mutedForCall('first'), isTrue);
    expect(state.mutedForCall('second'), isFalse);
  });

  test('new calls use their own initial capture choice', () {
    final state = CallMicrophoneState()..beginCall('first', micOn: false);
    expect(state.muted, isTrue);
    state.beginCall('second', micOn: true);
    expect(state.muted, isFalse);
    state.clear();
    // A late action after hangup cannot change the next call's capture.
    state.setMuted(false);
    state.beginCall('third', micOn: false);
    expect(state.muted, isTrue);
  });
}
