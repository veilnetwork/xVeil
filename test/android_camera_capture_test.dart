import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_camera_capture.dart';
import 'package:xveil/state/android_native_call_camera.dart';

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

  test('native Camera2 preview parser accepts only complete geometry', () {
    final preview = AndroidNativeCameraPreview.fromMap(const {
      'textureId': 7,
      'width': 640,
      'height': 360,
      'rotation': 90,
      'mirror': true,
      'fps': 60,
    });
    expect(preview?.textureId, 7);
    expect(preview?.rotation, 90);
    expect(preview?.mirror, isTrue);

    expect(
      AndroidNativeCameraPreview.fromMap(const {
        'textureId': 7,
        'width': 640,
        'height': 360,
        'rotation': 45,
        'mirror': true,
        'fps': 60,
      }),
      isNull,
    );
  });
}
