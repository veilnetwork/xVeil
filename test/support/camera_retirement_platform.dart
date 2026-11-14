import 'dart:async';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';

class RetirementCameraPlatform extends CameraPlatform {
  final attempted = <String>[];
  final errors = <int, StreamController<CameraErrorEvent>>{};
  bool rejectBack = false;
  var nextId = 0;
  bool refuseDispose = false;
  int disposals = 0;
  Completer<void>? disposeGate;
  Completer<void>? initializeGate;
  final initializeEntered = Completer<void>();
  final disposeEntered = Completer<void>();
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
  }) async {
    if (!initializeEntered.isCompleted) initializeEntered.complete();
    await initializeGate?.future;
  }

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
    disposals++;
    if (!disposeEntered.isCompleted) disposeEntered.complete();
    await disposeGate?.future;
    if (refuseDispose) throw StateError('synthetic native close refusal');
    final stream = errors.remove(id);
    if (stream != null) {
      stream.add(CameraErrorEvent(id, 'disposed test capture'));
      await stream.close();
    }
  }
}
