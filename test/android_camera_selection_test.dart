import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_camera_capture.dart';

class _Cameras extends CameraPlatform {
  final attempted = <String>[];
  final errors = <int, StreamController<CameraErrorEvent>>{};
  bool rejectBack = false;
  var nextId = 0;
  static const cameras = [
    CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 270,
    ),
    CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];
  @override
  Future<List<CameraDescription>> availableCameras() async => cameras;
  @override
  Future<int> createCameraWithSettings(
    CameraDescription camera,
    MediaSettings settings,
  ) async {
    attempted.add(camera.name);
    if (rejectBack && camera.name == 'back') {
      throw PlatformException(code: 'fixture_camera_unavailable');
    }
    final id = ++nextId;
    errors[id] = StreamController<CameraErrorEvent>();
    return id;
  }

  @override
  Future<void> initializeCamera(
    int id, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int id) => Stream.value(
    CameraInitializedEvent(
      id,
      640,
      480,
      ExposureMode.auto,
      true,
      FocusMode.auto,
      true,
    ),
  );
  @override
  Stream<CameraErrorEvent> onCameraError(int id) => errors[id]!.stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream.value(
        const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp),
      );
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int id, {
    CameraImageStreamOptions? options,
  }) => const Stream.empty();
  @override
  Future<void> dispose(int id) async {
    final stream = errors.remove(id);
    if (stream != null) {
      stream.add(CameraErrorEvent(id, 'disposed test capture'));
      await stream.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capabilities = MethodChannel('xveil/camera_capabilities');
  late CameraPlatform previous;
  late _Cameras platform;
  setUp(() {
    previous = CameraPlatform.instance;
    platform = _Cameras();
    CameraPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(capabilities, (_) async => [30]);
  });
  tearDown(() {
    CameraPlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(capabilities, null);
    expect(androidCallCameraPreviewController.value, isNull);
    expect(platform.errors, isEmpty);
  });
  for (final requested in [null, 'front', 'back', 'missing']) {
    test('plugin capture honors camera choice $requested', () async {
      final capture = AndroidCameraCapture(requestedCameraId: requested);
      addTearDown(capture.stop);
      final ok = await capture.startAndroid420(
        (_, _, _, _, _, _, _, _, _, _) => true,
      );
      expect(ok, requested != 'missing');
      if (requested == 'missing') {
        expect(platform.attempted, isEmpty);
        expect(androidCallCameraPreviewController.value, isNull);
      } else {
        expect(platform.attempted, [requested ?? 'front']);
        expect(capture.cameraId, requested ?? 'front');
        expect(
          androidCallCameraPreviewController.value!.description.name,
          requested ?? 'front',
        );
      }
      await capture.stop();
      expect(capture.cameraId, isNull);
    });
  }
  test(
    'FPS retries cannot replace a rejected rear camera with the front one',
    () async {
      platform.rejectBack = true;
      final capture = AndroidCameraCapture(
        requestedCameraId: 'back',
        highQuality: true,
      );
      addTearDown(capture.stop);
      expect(
        await capture.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
        isFalse,
      );
      expect(platform.attempted, ['back', 'back']);
      expect(androidCallCameraPreviewController.value, isNull);
      await capture.stop();
    },
  );
}
