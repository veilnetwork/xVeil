import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/camera_capture_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

class _LifecycleCameraPlatform extends CameraPlatform {
  static const description = CameraDescription(
    name: 'back',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );

  int createCount = 0;
  final disposedIds = <int>[];

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    description,
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async => ++createCount;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      Stream.value(CameraErrorEvent(cameraId, 'test-only event'));

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream.value(
        const DeviceOrientationChangedEvent(DeviceOrientation.portraitUp),
      );

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.black);

  @override
  Future<void> dispose(int cameraId) async {
    disposedIds.add(cameraId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('attachment camera releases and reopens across app lifecycle', (
    tester,
  ) async {
    final previousPlatform = CameraPlatform.instance;
    final platform = _LifecycleCameraPlatform();
    CameraPlatform.instance = platform;
    addTearDown(() {
      CameraPlatform.instance = previousPlatform;
    });

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: CameraCaptureScreen(video: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(platform.createCount, 1);
    expect(find.byType(CameraPreview), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(platform.disposedIds, contains(1));
    expect(find.byType(CameraPreview), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(platform.createCount, 2);
    expect(find.byType(CameraPreview), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(platform.disposedIds, contains(2));
  });
}
