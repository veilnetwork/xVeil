import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_camera_capture.dart';
import 'package:xveil/state/android_native_call_camera.dart';
import 'package:xveil/state/android_native_call_video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      'previewRotation': 0,
      'mirror': true,
      'fps': 60,
    });
    expect(preview?.textureId, 7);
    expect(preview?.rotation, 0);
    expect(preview?.mirror, isTrue);

    expect(
      AndroidNativeCameraPreview.fromMap(const {
        'textureId': 7,
        'width': 640,
        'height': 360,
        'previewRotation': 45,
        'mirror': true,
        'fps': 60,
      }),
      isNull,
    );

    // Keep a bounded compatibility window for an APK/platform half left over
    // across a hot restart. New native code always sends previewRotation.
    expect(
      AndroidNativeCameraPreview.fromMap(const {
        'textureId': 8,
        'width': 640,
        'height': 360,
        'rotation': 270,
        'mirror': false,
        'fps': 30,
      })?.rotation,
      270,
    );
  });

  test(
    'native remote renderer moves only texture metadata over channel',
    () async {
      const channel = MethodChannel('xveil/test_native_call_video');
      final calls = <MethodCall>[];
      var frames = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'start' => <String, Object?>{'textureId': 17},
              'stats' => <String, Object?>{
                'video_texture_running': true,
                'video_texture_frames': frames,
                'video_texture_width': 640,
                'video_texture_height': 360,
              },
              'stop' => true,
              _ => null,
            };
          });
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        androidNativeCallVideoTexture.value = null;
      });

      final renderer = AndroidNativeCallVideoRenderer(channel: channel);
      expect(await renderer.start(engineAddress: 1234), isTrue);
      expect(calls.first.method, 'stop');
      expect(calls[1].method, 'start');
      expect(calls[1].arguments, <String, Object?>{'engine': 1234});
      expect(androidNativeCallVideoTexture.value?.textureId, 17);
      expect(androidNativeCallVideoTexture.value?.hasFrame, isFalse);

      frames = 5;
      await renderer.refreshStats();
      final texture = androidNativeCallVideoTexture.value;
      expect(texture?.frames, 5);
      expect(texture?.width, 640);
      expect(texture?.height, 360);
      expect(texture?.hasFrame, isTrue);
      expect(texture?.lastFrameAt, isNotNull);

      await renderer.stop();
      expect(androidNativeCallVideoTexture.value, isNull);
      expect(calls.last.method, 'stop');
    },
  );
}
