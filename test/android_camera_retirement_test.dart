import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camera/camera.dart' as camera;
import 'package:xveil/core/capture_resource_lifetime.dart';
import 'package:xveil/state/owned_camera_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_camera_capture.dart';
import 'support/camera_retirement_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraPlatform previous;
  late RetirementCameraPlatform platform;
  late AndroidCameraCapture capture;
  setUp(() {
    previous = CameraPlatform.instance;
    platform = RetirementCameraPlatform();
    CameraPlatform.instance = platform;
    capture = AndroidCameraCapture();
  });
  tearDown(() async {
    platform.refuseDispose = false;
    if (platform.disposeGate != null && !platform.disposeGate!.isCompleted) {
      platform.disposeGate!.complete();
    }
    try {
      await capture.stop();
    } catch (_) {}
    // The old implementation loses the native id on refusal. This fixture
    // cleanup cannot make its failed ownership assertion pass.
    for (final id in platform.errors.keys.toList()) {
      await platform.dispose(id);
    }
    CameraPlatform.instance = previous;
  });

  test(
    'failed native camera close remains owned and a retry reaches the platform',
    () async {
      expect(
        await capture.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
        isTrue,
      );
      platform.refuseDispose = true;
      await expectLater(capture.stop(), throwsA(isA<Exception>()));
      expect(platform.errors, isNotEmpty);
      platform.refuseDispose = false;
      await capture.stop();
      expect(platform.disposals, 2);
      expect(platform.errors, isEmpty);
    },
  );

  test('concurrent stops join the same native camera release', () async {
    expect(
      await capture.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
      isTrue,
    );
    platform.disposeGate = Completer<void>();
    final first = capture.stop();
    await platform.disposeEntered.future;
    var secondReturned = false;
    final second = capture.stop().then((_) => secondReturned = true);
    try {
      await Future<void>(() {});
      expect(
        secondReturned,
        isFalse,
        reason: 'the native release is still pending',
      );
    } finally {
      platform.disposeGate!.complete();
      await Future.wait([first, second]);
    }
    expect(platform.disposals, 1);
  });
  test(
    'retirement joins accepted camera discovery and permanently seals source',
    () async {
      final listing = Completer<List<CameraDescription>>();
      capture = AndroidCameraCapture(listCameras: () => listing.future);
      final starting = capture.startAndroid420(
        (_, _, _, _, _, _, _, _, _, _) => true,
      );
      var retired = false;
      final retiring = capture.retire().then((_) => retired = true);
      try {
        await Future<void>(() {});
        expect(retired, isFalse);
        expect(platform.attempted, isEmpty);
      } finally {
        listing.complete(RetirementCameraPlatform.cameras);
        expect(await starting, isFalse);
        await retiring;
      }
      expect(platform.attempted, isEmpty);
      expect(
        await capture.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
        isFalse,
      );
    },
  );

  test(
    'superseded initialization cannot forget an unacknowledged native close',
    () async {
      platform.initializeGate = Completer<void>();
      final starting = capture.startAndroid420(
        (_, _, _, _, _, _, _, _, _, _) => true,
      );
      await platform.initializeEntered.future;
      platform.refuseDispose = true;
      final refusing = expectLater(
        capture.retire(),
        throwsA(isA<CameraCaptureRetirementFailure>()),
      );
      platform.initializeGate!.complete();
      try {
        await starting;
      } catch (_) {}
      await refusing;
      expect(platform.errors, isNotEmpty);
      final attempts = platform.disposals;
      platform.refuseDispose = false;
      await capture.retire();
      expect(platform.disposals, greaterThan(attempts));
      expect(platform.errors, isEmpty);
    },
  );

  test(
    'simultaneous starts share the same native camera acquisition',
    () async {
      platform.initializeGate = Completer<void>();
      final first = capture.startAndroid420(
        (_, _, _, _, _, _, _, _, _, _) => true,
      );
      await platform.initializeEntered.future;
      final second = capture.startAndroid420(
        (_, _, _, _, _, _, _, _, _, _) => true,
      );
      platform.initializeGate!.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(platform.attempted, ['front']);
      await capture.retire();
      expect(platform.errors, isEmpty);
    },
  );

  test('retirement observes actual converter isolate exit', () async {
    var exits = 0;
    capture = AndroidCameraCapture(onWorkerExit: () => exits++);
    expect(await capture.start((_, _, _, _, _) {}), isTrue);
    expect(exits, 0);
    await capture.retire();
    expect(exits, 1);
    expect(platform.errors, isEmpty);
    await capture.retire();
    expect(exits, 1);
  });
  test('failed singleton-camera release cannot close a replacement', () async {
    expect(
      await capture.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
      isTrue,
    );
    platform.refuseDispose = true;
    await expectLater(
      capture.stop(),
      throwsA(isA<CameraCaptureRetirementFailure>()),
    );
    final replacement = AndroidCameraCapture();
    addTearDown(replacement.retire);
    expect(
      await replacement.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
      isFalse,
    );
    expect(platform.attempted, ['front']);
    platform.refuseDispose = false;
    await capture.stop();
    expect(
      await replacement.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
      isTrue,
    );
    final activeId = platform.errors.keys.single;
    final before = platform.disposals;
    await capture.stop();
    expect(platform.disposals, before);
    expect(platform.errors.keys.single, activeId);
  });

  test('attachment lease cannot supply a camera-only erasure proof', () async {
    final lifetime = CaptureResourceLifetime.current();
    final controller = camera.CameraController(
      RetirementCameraPlatform.cameras.first,
      camera.ResolutionPreset.low,
      enableAudio: false,
    );
    final owner = OwnedCameraController.tryOwn(
      controller,
      lifetime: lifetime,
      automaticRetirement: false,
    )!;
    await controller.initialize();
    try {
      await expectLater(
        lifetime.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      expect(platform.disposals, 0);
      expect(platform.errors, hasLength(1));
    } finally {
      await owner.close();
      final receipt = await lifetime.retire();
      receipt.releaseAdmission();
    }
  });

  test(
    'late old-profile factory cannot use freshly published camera admission',
    () async {
      final old = CaptureResourceLifetime.current();
      final receipt = await old.retire();
      receipt.releaseAdmission();
      capture = AndroidCameraCapture(captureLifetime: old);
      expect(
        await capture.startAndroid420((_, _, _, _, _, _, _, _, _, _) => true),
        isFalse,
      );
      expect(platform.attempted, isEmpty);
    },
  );
}
