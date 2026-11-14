import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';
import 'package:xveil/domain/screen_lock.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/features/chat/camera_capture_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/attachment_capture_work.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';

import 'support/camera_retirement_platform.dart';
import 'support/fake_hv_container.dart';

class _Camera extends RetirementCameraPlatform {
  @override
  Widget buildPreview(int id) => const ColoredBox(color: Colors.black);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraPlatform previous;
  late _Camera camera;
  late ProviderContainer providers;
  late HiddenVolumeStorage storage;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    previous = CameraPlatform.instance;
    camera = _Camera();
    CameraPlatform.instance = camera;
    storage = FakeHvContainer().storage();
    await storage.open(password: 'synthetic', createIfMissing: true);
    providers = ProviderContainer(
      overrides: [storageProvider.overrideWithValue(storage)],
    );
  });
  tearDown(() async {
    await CaptureResourceLifetime.current().retire();
    CaptureResourceLifetime.resetForTesting();
    providers.dispose();
    await storage.close();
    CameraPlatform.instance = previous;
    expect(camera.errors, isEmpty);
  });

  Future<void> armScreenLock() async {
    final lock = providers.read(screenLockProvider.notifier);
    await lock.setTimeout(ScreenLockTimeout.immediately);
    lock.rememberPassword('synthetic');
  }

  testWidgets(
    'screen lock stops an attachment and an old resume cannot reopen it',
    (tester) async {
      await armScreenLock();
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: CameraCaptureScreen(video: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        camera.errors,
        hasLength(1),
        reason: 'a camera must actually be open',
      );
      try {
        providers.read(screenLockProvider.notifier).onLeftForeground();
        await tester.pumpAndSettle();
        expect(providers.read(screenLockProvider).locked, isTrue);
        expect(
          camera.errors,
          isEmpty,
          reason: 'attachment must not capture under lock',
        );
        expect(
          providers.read(screenLockProvider.notifier).tryUnlock('synthetic'),
          isTrue,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(
          camera.nextId,
          1,
          reason: 'an old attachment cannot resume after privacy lock',
        );
        expect(find.byType(CameraPreview), findsNothing);
        await tester.pumpWidget(
          const MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: CameraCaptureScreen(
              key: ValueKey('fresh capture'),
              video: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          camera.nextId,
          2,
          reason: 'a fresh user action after unlock may capture',
        );
        expect(find.byType(CameraPreview), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'a camera choice predating screen lock cannot start capture later',
    (tester) async {
      await armScreenLock();
      var returned = false;
      CapturedComposerMedia? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await captureComposerMedia(context);
                returned = true;
              },
              child: const Text('open synthetic capture'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open synthetic capture'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      final lock = providers.read(screenLockProvider.notifier);
      lock.onLeftForeground();
      expect(lock.tryUnlock('synthetic'), isTrue);
      try {
        await tester.tap(find.byType(SimpleDialogOption).first);
        await tester.pumpAndSettle();
        expect(
          camera.nextId,
          0,
          reason: 'late dialog choice belongs to the old privacy session',
        );
        expect(returned, isTrue);
        expect(result, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  test(
    'container lock stops an independently owned attachment camera',
    () async {
      final app = providers.read(appControllerProvider.notifier);
      for (
        var i = 0;
        i < 20 &&
            providers.read(appControllerProvider).phase ==
                AppPhase.bootstrapping;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final work = AttachmentCaptureWork(
        lifetime: CaptureResourceLifetime.current(),
      );
      final controller = CameraController(
        RetirementCameraPlatform.cameras.first,
        ResolutionPreset.low,
      );
      expect(work.own(controller), isNotNull);
      try {
        await work.run(controller.initialize);
        expect(camera.errors, hasLength(1));
        await app.lock();
        await Future<void>(() {});
        expect(
          camera.errors,
          isEmpty,
          reason: 'container lock must reach attachment resources',
        );
      } finally {
        await work.retire();
      }
    },
  );
}
