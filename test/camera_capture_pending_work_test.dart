import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camera/camera.dart' as camera;
import 'package:xveil/state/owned_camera_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';
import 'package:xveil/core/capture_output_file.dart';
import 'package:xveil/features/chat/camera_capture_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

import 'support/camera_retirement_platform.dart';

class _PendingCamera extends RetirementCameraPlatform {
  final picture = Completer<XFile>();
  final videoStart = Completer<void>();
  final entered = Completer<void>();
  final disposed = <int>[];
  XFile? videoOutput;
  XFile? lateVideoOutput;
  int videoStops = 0;

  @override
  Widget buildPreview(int id) => const ColoredBox(color: Colors.black);
  @override
  Future<XFile> takePicture(int id) {
    if (!entered.isCompleted) entered.complete();
    return picture.future;
  }

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) {
    if (!entered.isCompleted) entered.complete();
    return videoStart.future;
  }

  @override
  Future<XFile> stopVideoRecording(int id) async {
    videoStops++;
    return videoStops > 1 ? (lateVideoOutput ?? videoOutput!) : videoOutput!;
  }

  @override
  Future<void> dispose(int id) async {
    disposed.add(id);
    await super.dispose(id);
  }
}

class _SyncOutputs implements CaptureOutputStore {
  @override
  Future<void> remove(String path) async {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final video in [false, true]) {
    testWidgets(
      'disposed attachment joins pending ${video ? 'video start' : 'photo'}',
      (tester) async {
        final previous = CameraPlatform.instance;
        final platform = _PendingCamera();
        CameraPlatform.instance = platform;
        final dir = Directory.systemTemp.createTempSync('xveil-capture-work-');
        final output = File('${dir.path}/synthetic.bin')
          ..writeAsStringSync('synthetic output');
        platform.videoOutput = XFile(output.path);
        final lateOutput = video
            ? (File('${dir.path}/late-video.bin')
                ..writeAsStringSync('synthetic late recording'))
            : null;
        platform.lateVideoOutput = lateOutput == null
            ? null
            : XFile(lateOutput.path);
        addTearDown(() async {
          CameraPlatform.instance = previous;
          if (dir.existsSync()) dir.deleteSync(recursive: true);
          CaptureResourceLifetime.resetForTesting();
        });
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: CameraCaptureScreen(
              video: video,
              outputStore: _SyncOutputs(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('composer-camera-capture')));
        await tester.pump();
        expect(platform.entered.isCompleted, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        try {
          expect(
            platform.disposed,
            isNotEmpty,
            reason: 'hardware stop is requested promptly',
          );
          final candidate = camera.CameraController(
            RetirementCameraPlatform.cameras.first,
            camera.ResolutionPreset.low,
            enableAudio: false,
          );
          final lease = OwnedCameraController.tryOwn(
            candidate,
            lifetime: CaptureResourceLifetime.current(),
          );
          try {
            expect(
              lease,
              isNull,
              reason:
                  'accepted camera operation still owns the backend and its result',
            );
          } finally {
            if (lease != null) {
              await lease.close();
            } else {
              await candidate.dispose();
            }
          }
        } finally {
          if (video) {
            platform.videoStart.complete();
          } else {
            platform.picture.complete(XFile(output.path));
          }
          await tester.pumpAndSettle();
        }
        expect(output.existsSync(), isFalse);
        expect(platform.disposed, hasLength(2));
        if (video) {
          expect(platform.videoStops, 2);
          expect(lateOutput!.existsSync(), isFalse);
        }
      },
    );
  }
  testWidgets(
    'profile retirement closes an idle attachment and cannot reopen old admission',
    (tester) async {
      final previous = CameraPlatform.instance;
      final platform = _PendingCamera();
      CameraPlatform.instance = platform;
      addTearDown(() {
        CameraPlatform.instance = previous;
        CaptureResourceLifetime.resetForTesting();
      });
      final lifetime = CaptureResourceLifetime.current();
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CameraCaptureScreen(video: false),
        ),
      );
      await tester.pumpAndSettle();
      final retiring = lifetime.retire();
      await tester.pumpAndSettle();
      final receipt = await retiring;
      expect(platform.disposed, hasLength(1));
      receipt.releaseAdmission();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(platform.nextId, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('handed-off output remains owned until its consumer settles', (
    tester,
  ) async {
    final previous = CameraPlatform.instance;
    final platform = _PendingCamera();
    CameraPlatform.instance = platform;
    final dir = Directory.systemTemp.createTempSync('xveil-camera-handoff-');
    final file = File('${dir.path}/output.bin')..writeAsStringSync('synthetic');
    addTearDown(() {
      CameraPlatform.instance = previous;
      CaptureResourceLifetime.resetForTesting();
      dir.deleteSync(recursive: true);
    });
    final scope = CaptureResourceLifetime.current();
    CapturedComposerMedia? captured;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              captured = await Navigator.of(context)
                  .push<CapturedComposerMedia>(
                    MaterialPageRoute(
                      builder: (_) => CameraCaptureScreen(
                        video: false,
                        outputStore: _SyncOutputs(),
                      ),
                    ),
                  );
            },
            child: const Text('open fixture'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open fixture'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('composer-camera-capture')));
    await tester.pump();
    platform.picture.complete(XFile(file.path));
    await tester.pumpAndSettle();
    expect(captured, isNotNull);
    expect(file.existsSync(), isTrue);
    expect(platform.disposed, hasLength(1));
    final entered = Completer<void>(), release = Completer<void>();
    bool? existedDuringRead;
    final consuming = captured!.use((path) async {
      entered.complete();
      await release.future;
      existedDuringRead = File(path).existsSync();
    });
    await tester.pump();
    expect(entered.isCompleted, isTrue);
    final retiring = scope.retire();
    await tester.pump();
    expect(file.existsSync(), isTrue);
    release.complete();
    await tester.pumpAndSettle();
    await consuming;
    expect(existedDuringRead, isTrue);
    await retiring;
    expect(file.existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
