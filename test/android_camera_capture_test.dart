import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_camera_capture.dart';

void main() {
  test('camera FPS prefers an exact 60 Hz mode when supported', () {
    expect(preferredExactCameraFps([15, 24, 30, 60]), 60);
  });

  test('camera FPS uses stable 30 instead of inventing unsupported 60', () {
    expect(preferredExactCameraFps([10, 15, 24, 30]), 30);
  });

  test(
    'camera FPS picks the best bounded exact mode and has a safe fallback',
    () {
      expect(preferredExactCameraFps([15, 24, 120]), 24);
      expect(preferredExactCameraFps(const []), 30);
    },
  );
}
