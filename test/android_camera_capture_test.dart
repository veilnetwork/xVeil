import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
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
      'cameraId': '1',
      'facing': 'front',
    });
    expect(preview?.textureId, 7);
    expect(preview?.rotation, 0);
    expect(preview?.mirror, isTrue);
    expect(preview?.cameraId, '1');
    expect(preview?.facing, 'front');

    expect(
      AndroidNativeCameraPreview.fromMap(const {
        'textureId': 7,
        'width': 640,
        'height': 360,
        'previewRotation': 45,
        'mirror': true,
        'fps': 60,
        'cameraId': '1',
        'facing': 'front',
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
        'cameraId': '0',
        'facing': 'back',
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

  group('a stop during a start (report22 XV-CAM1)', () {
    bool noFrames(
      Uint8List y,
      Uint8List u,
      Uint8List v,
      int width,
      int height,
      int yStride,
      int uStride,
      int vStride,
      int uvPixelStride,
      int rotation,
    ) => false;

    // A start walks several awaits before it owns anything the caller can see.
    // `stop()` used to look at `_ctrl`, find the null the start had not filled
    // in yet, clear nothing and return — and the start then published its
    // controller to a capturer nobody was holding. The camera stayed open with
    // no owner: the OS indicator lit after a hangup, and the next call could
    // not open the camera at all.
    //
    // The camera list is the first of those awaits, and the only one a test
    // can hold open without a device. The rest of the rule — the controller
    // open, and the publish — is the same check at the next two points.

    tearDown(() => androidCallCameraPreviewController.value = null);

    test('a start superseded at its first await publishes nothing', () async {
      final listing = Completer<List<CameraDescription>>();
      final cam = AndroidCameraCapture(listCameras: () => listing.future);

      final starting = cam.startAndroid420(noFrames);
      await Future<void>.delayed(Duration.zero);

      // The hangup lands while the start is still asking what cameras exist.
      final stopping = cam.stop();
      listing.complete(const <CameraDescription>[
        CameraDescription(
          name: 'front',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 90,
        ),
      ]);
      await stopping;

      expect(
        await starting,
        isFalse,
        reason:
            'the superseded start reported that video was running, so the '
            'caller believes it has a camera nobody owns',
      );
      expect(
        androidCallCameraPreviewController.value,
        isNull,
        reason: 'the superseded start published a preview controller',
      );
    });

    test('stop waits for the start instead of racing past it', () async {
      final listing = Completer<List<CameraDescription>>();
      final cam = AndroidCameraCapture(listCameras: () => listing.future);

      unawaited(cam.startAndroid420(noFrames));
      await Future<void>.delayed(Duration.zero);

      var stopped = false;
      final stopping = cam.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        stopped,
        isFalse,
        reason:
            'stop returned while a start was still in flight — the teardown '
            'then races whatever that start is about to open',
      );

      listing.complete(const <CameraDescription>[]);
      await stopping;
      expect(stopped, isTrue);
    });

    /// The body of [signature] in the capture source, comment lines removed.
    String body(String src, String signature) {
      final at = src.indexOf(signature);
      expect(at, isNot(-1), reason: 'not found, so unguarded: $signature');
      final close = src.indexOf('\n  }\n', at);
      expect(close, greaterThan(at));
      return src
          .substring(at, close)
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    }

    test('every await in the start path is followed by a supersede check', () {
      // The behavioural tests above can only hold the FIRST await open — the
      // camera list. The two after it (the worker isolate, and the controller
      // open with its per-fps retries) need a device, and they are where the
      // window is widest. So the rule itself is asserted here.
      //
      // Watched fail: deleting the check after the camera list, and deleting
      // the generation bump in stop(), each redden this.
      final src = File('lib/state/android_camera_capture.dart')
          .readAsStringSync();

      final start = body(src, 'Future<bool> _startOnce({');
      expect(
        start,
        contains('final gen = ++_generation;'),
        reason: 'a start that does not take a generation cannot be superseded',
      );
      expect(
        RegExp(r'gen != _generation').allMatches(start).length,
        greaterThanOrEqualTo(3),
        reason:
            'each await in the start path spans a possible stop: the worker, '
            'the camera list, and the controller open. Every one of them needs '
            'its own check — the last is not enough, because the earlier ones '
            'are where the window is widest',
      );

      final open = body(src, 'Future<CameraController?> _openController(');
      expect(
        RegExp(r'gen != _generation').allMatches(open).length,
        greaterThanOrEqualTo(2),
        reason:
            'the open retries per fps candidate and needs BOTH checks: one at '
            'the top of the loop, so a stop does not wait for every remaining '
            'candidate, and one after initialize(), so a superseded open does '
            'not hand back a live controller',
      );

      final stop = body(src, 'Future<void> stop() async {');
      expect(
        stop,
        contains('_generation++'),
        reason: 'stop does not end the current start, so nothing supersedes it',
      );
      expect(
        stop.indexOf('_generation++'),
        lessThan(stop.indexOf('await starting')),
        reason:
            'the generation is ended AFTER the wait, so the start it waits for '
            'still believes it is the current one and publishes its controller',
      );
    });

    test('CONTROL: an unraced start gets as far as the camera list', () async {
      // Vacuity guard: both tests above pass on a start that does nothing at
      // all. This one shows the seam is really reached.
      var asked = 0;
      final cam = AndroidCameraCapture(listCameras: () async {
        asked++;
        return const <CameraDescription>[];
      });
      expect(await cam.startAndroid420(noFrames), isFalse); // no cameras
      expect(asked, 1);
      await cam.stop();
    });
  });
}
