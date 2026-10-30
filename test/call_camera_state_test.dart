import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_camera_state.dart';

void main() {
  test('late permission starts capture only after the actual grant', () async {
    final state = CallCameraState()..beginCall('call', enabled: true);
    final permission = Completer<bool>();
    var starts = 0;
    final pending = state.startWhenGranted(
      callId: 'call',
      permission: permission.future,
      isCurrent: () => true,
      start: () async {
        starts++;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(starts, 0);
    permission.complete(true);
    await pending;
    expect(starts, 1);
  });

  for (final cancelled in [
    'denied',
    'camera-off',
    'ended',
    'replaced-engine',
    'new-call',
  ]) {
    test('late permission cannot start capture after $cancelled', () async {
      final state = CallCameraState()..beginCall('call', enabled: true);
      final permission = Completer<bool>();
      var current = true;
      var starts = 0;
      final pending = state.startWhenGranted(
        callId: 'call',
        permission: permission.future,
        isCurrent: () => current,
        start: () async {
          starts++;
        },
      );
      switch (cancelled) {
        case 'camera-off':
          state.setEnabled(false);
        case 'ended':
          state.clear();
        case 'replaced-engine':
          current = false;
        case 'new-call':
          state.beginCall('other', enabled: true);
      }
      permission.complete(cancelled != 'denied');
      await pending;
      expect(starts, 0);
    });
  }
  test('camera stays off after rebuilding from an older call snapshot', () {
    final state = CallCameraState()..beginCall('call', enabled: true);
    state.setEnabled(false);
    state.beginCall('call', enabled: true);
    expect(state.enabledForCall('call'), isFalse);
    state.setEnabled(true);
    state.beginCall('call', enabled: false);
    expect(state.enabledForCall('call'), isTrue);
  });

  test('a cancelled capture cannot authorize a replacement call', () {
    final state = CallCameraState()..beginCall('first', enabled: true);
    state.clear();
    state.setEnabled(true);
    expect(state.enabledForCall('first'), isFalse);
    state.beginCall('second', enabled: false);
    expect(state.enabledForCall('first'), isFalse);
    expect(state.enabledForCall('second'), isFalse);
  });
}
