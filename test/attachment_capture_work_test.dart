import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';
import 'package:xveil/state/attachment_capture_work.dart';
import 'package:xveil/state/owned_camera_controller.dart';

import 'support/camera_retirement_platform.dart';

class _Platform extends RetirementCameraPlatform {
  final picture = Completer<XFile>();
  final entered = Completer<void>();
  XFile? video;
  bool loseVideoReply = false, refuseStop = false;
  int stops = 0;
  @override
  Future<XFile> takePicture(int id) {
    entered.complete();
    return picture.future;
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    if (loseVideoReply) throw PlatformException(code: 'synthetic_lost_start');
  }

  @override
  Future<XFile> stopVideoRecording(int id) async {
    stops++;
    if (refuseStop) throw PlatformException(code: 'synthetic_lost_stop');
    return video!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraPlatform previous;
  late _Platform platform;
  late CaptureResourceLifetime lifetime;
  late AttachmentCaptureWork work;
  late CameraController camera;
  late Directory dir;
  setUp(() async {
    previous = CameraPlatform.instance;
    platform = _Platform();
    CameraPlatform.instance = platform;
    lifetime = CaptureResourceLifetime.isolatedForTesting();
    work = AttachmentCaptureWork(lifetime: lifetime);
    dir = Directory.systemTemp.createTempSync('xveil-attachment-work-');
    camera = CameraController(
      RetirementCameraPlatform.cameras.first,
      ResolutionPreset.low,
      enableAudio: true,
    );
    expect(work.own(camera), isNotNull);
    await work.run(camera.initialize);
  });
  tearDown(() async {
    try {
      await work.retire();
    } catch (_) {}
    expect(
      platform.errors,
      isEmpty,
      reason: 'modeled hardware closes even if output is unknown',
    );
    CameraPlatform.instance = previous;
    dir.deleteSync(recursive: true);
  });

  test(
    'late photo is retained for cleanup but never handed to a retired caller',
    () async {
      final file = File('${dir.path}/late.jpg')..writeAsStringSync('synthetic');
      final taking = work.takePicture(camera);
      await platform.entered.future;
      final retiring = work.retire();
      platform.picture.complete(XFile(file.path));
      expect(await taking, isNull);
      await retiring;
      expect(file.existsSync(), isFalse);
      await lifetime.retire();
    },
  );

  test(
    'lost video-start reply is resolved by stop before releasing ownership',
    () async {
      final file = File('${dir.path}/video.mp4')
        ..writeAsStringSync('synthetic');
      platform.video = XFile(file.path);
      platform.loseVideoReply = true;
      await expectLater(
        work.startVideo(camera),
        throwsA(isA<PlatformException>()),
      );
      await work.retire();
      expect(platform.stops, 1);
      expect(file.existsSync(), isFalse);
      await lifetime.retire();
    },
  );

  test(
    'empty video output refuses cleanup without stranding the reply',
    () async {
      platform.video = XFile('');
      expect(await work.startVideo(camera), isTrue);
      await expectLater(
        work.finishVideo(camera),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      await expectLater(
        work.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      expect(platform.errors, isEmpty);
      await expectLater(
        lifetime.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
    },
  );

  test(
    'unknown output refuses retirement even after hardware is stopped',
    () async {
      platform.loseVideoReply = true;
      platform.refuseStop = true;
      await expectLater(
        work.startVideo(camera),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        work.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      expect(platform.errors, isEmpty);
      final stopsBeforeReplacement = platform.stops;
      expect(stopsBeforeReplacement, greaterThan(0));
      final replacement = CameraController(
        RetirementCameraPlatform.cameras.first,
        ResolutionPreset.low,
      );
      final nextScope = CaptureResourceLifetime.isolatedForTesting();
      final owner = OwnedCameraController.tryOwn(
        replacement,
        lifetime: nextScope,
      );
      expect(
        owner,
        isNotNull,
        reason: 'failed output does not keep hardware open',
      );
      try {
        await replacement.initialize();
        final closesBeforeRetry = platform.disposals;
        await expectLater(
          lifetime.retire(),
          throwsA(isA<CaptureResourceRetirementFailure>()),
        );
        expect(platform.disposals, closesBeforeRetry);
        expect(
          platform.stops,
          stopsBeforeReplacement,
          reason: 'never send a stale stop after backend lease release',
        );
      } finally {
        await nextScope.retire();
      }
    },
  );
}
