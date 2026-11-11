import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

class _Controller extends AppController {
  final waiting = Completer<void>();
  @override
  AppState build() => const AppState(AppPhase.onboarding);
  @override
  Future<void> waitForCompaction() {
    if (!waiting.isCompleted) waiting.complete();
    return super.waitForCompaction();
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn extends Fake implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['XVEIL_HV_DYLIB'];
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final wipe in [false, true]) {
    test(
      'accepted native create settles after ${wipe ? 'wipe' : 'lock'}',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final dir = await Directory.systemTemp.createTemp(
          'xveil-native-onboarding-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/fixture.hv';
        const original = 'original-fixture';
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode(original)),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
        final seed = HiddenVolumeStorage.async(workerSpaceOpener(path));
        try {
          expect(await seed.open(password: original), isTrue);
          await seed.saveProfile(
            const UserProfile(displayName: 'Original native fixture'),
          );
          await seed.storeFile('fixture-body', body);
        } finally {
          await seed.close();
        }

        final opened = Completer<void>();
        final release = Completer<void>();
        final nativeOpen = workerSpaceOpener(path);
        var openCalls = 0;
        final storage = HiddenVolumeStorage.async(({
          required password,
          required create,
        }) async {
          openCalls++;
          final handle = await nativeOpen(password: password, create: create);
          // The real native worker owns the flock and has created the new space,
          // but HiddenVolumeStorage has not adopted its response yet.
          opened.complete();
          await release.future;
          return handle;
        });
        final controller = _Controller();
        final c = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(() => controller),
            singleSpaceStorageProvider.overrideWithValue(storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            vpnBackendProvider.overrideWithValue(_Vpn()),
            whisperModelStoreProvider.overrideWithValue(
              WhisperModelStore(supportDirectory: () async => dir),
            ),
            translationModelsRootProvider.overrideWithValue(() async => null),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${dir.path}/runtime',
                storePath: path,
              ),
            ),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(storage.close);
        c.read(appControllerProvider);
        controller.debugDeniableStackStarter = (_) async {
          throw StateError('fixture forbids node boot');
        };
        final creating = controller.completeOnboarding(
          password: 'new-fixture',
          mode: StorageMode.plain,
          displayName: 'New native fixture',
        );
        final refused = expectLater(creating, throwsStateError);
        await opened.future;
        expect(
          storage.isOpen,
          isFalse,
          reason: 'the response must still be held',
        );
        Future<List<String>>? wiping;
        try {
          if (wipe) {
            wiping = controller.wipeContainers();
            await Future.any<void>([
              controller.waiting.future,
              wiping.then(
                (_) => throw StateError('wipe returned before native opener'),
              ),
            ]);
            var settled = false;
            final barrier = controller.waitForCompaction().then(
              (_) => settled = true,
            );
            await Future<void>.delayed(Duration.zero);
            expect(settled, isFalse);
            expect(await File(path).exists(), isTrue);
            release.complete();
            await barrier;
          } else {
            await controller.lock();
            await controller.unlock('missing-fixture');
            expect(
              openCalls,
              1,
              reason: 'new unlock must not enter the held native opener',
            );
          }
        } finally {
          if (!release.isCompleted) release.complete();
          await refused;
          if (wiping != null) expect(await wiping, isEmpty);
        }
        expect(storage.isOpen, isFalse);
        if (wipe) {
          expect(await File(path).exists(), isFalse);
        } else {
          expect(c.read(appControllerProvider).phase, AppPhase.locked);
          final reader = HiddenVolumeStorage.async(workerSpaceOpener(path));
          try {
            expect(await reader.open(password: original), isTrue);
            expect(
              (await reader.loadProfile())!.displayName,
              'Original native fixture',
            );
            expect(await reader.loadFile('fixture-body'), body);
            await reader.close();
            // An accepted native create may persist an empty space; cancellation
            // prevents publishing a profile/session, not that already accepted IO.
            expect(await reader.open(password: 'new-fixture'), isTrue);
            expect(await reader.loadProfile(), isNull);
          } finally {
            await reader.close();
          }
        }
      },
      skip: library == null
          ? 'Set XVEIL_HV_DYLIB to a qualified library'
          : false,
    );
  }
}
