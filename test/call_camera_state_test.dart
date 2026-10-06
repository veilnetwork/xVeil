import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_camera_state.dart';

void main() {
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
