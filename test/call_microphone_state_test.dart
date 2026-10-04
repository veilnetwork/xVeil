import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_microphone_state.dart';

void main() {
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
