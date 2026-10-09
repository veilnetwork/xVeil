import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/call_camera_state.dart';
import 'package:xveil/state/desktop_screen_capture_start.dart';

void main() {
  for (final throws in [false, true]) {
    test(
      'failed screen start restores the selected camera (throws=$throws)',
      () {
        var cameraRunning = true;
        var sourceIsScreen = false;
        final state = CallCameraState()..beginCall('call', enabled: true);
        final started = startDesktopScreenCapture(
          selectSource: (screen) => sourceIsScreen = screen,
          startCapture: () {
            cameraRunning = false; // Native screen start stops the old source.
            if (throws) throw StateError('capture unavailable');
            return false;
          },
          mayRestoreCamera: () => state.enabledForCall('call'),
          restoreCamera: () => cameraRunning = true,
        );
        expect(started, isFalse);
        expect(sourceIsScreen, isFalse);
        expect(cameraRunning, isTrue);
      },
    );
  }

  for (final retire in [false, true]) {
    test('failed capture respects camera-off or retired call ($retire)', () {
      var cameraRunning = true;
      final state = CallCameraState()..beginCall('call', enabled: true);
      expect(
        startDesktopScreenCapture(
          selectSource: (_) => true,
          startCapture: () {
            cameraRunning = false;
            if (retire) {
              state.clear();
              state.beginCall('replacement', enabled: true);
            } else {
              state.setEnabled(false);
            }
            return false;
          },
          mayRestoreCamera: () => state.enabledForCall('call'),
          restoreCamera: () => cameraRunning = true,
        ),
        isFalse,
      );
      expect(cameraRunning, isFalse);
    });
  }

  test('source rejection never opens either capture', () {
    var captures = 0;
    expect(
      startDesktopScreenCapture(
        selectSource: (_) => false,
        startCapture: () {
          captures++;
          return false;
        },
        mayRestoreCamera: () => true,
        restoreCamera: () => captures++,
      ),
      isFalse,
    );
    expect(captures, 0);
  });

  test(
    'successful screen keeps the camera stopped and screen queue selected',
    () {
      var sourceIsScreen = false;
      var cameraRunning = true;
      expect(
        startDesktopScreenCapture(
          selectSource: (screen) => sourceIsScreen = screen,
          startCapture: () {
            cameraRunning = false;
            return true;
          },
          mayRestoreCamera: () => true,
          restoreCamera: () => cameraRunning = true,
        ),
        isTrue,
      );
      expect(sourceIsScreen, isTrue);
      expect(cameraRunning, isFalse);
    },
  );
}
