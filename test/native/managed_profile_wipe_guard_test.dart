@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

class _Idle extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final ownerOverride in [false, true]) {
    test(
      'empty catalog cannot enter legacy full wipe; owner override=$ownerOverride',
      () async {
        SharedPreferences.setMockInitialValues({'onboarded': true});
        FlutterSecureStorage.setMockInitialValues({});
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-profile-wipe-guard-',
        );
        final managed = '${fixture.path}/managed';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(managed),
          isTrue,
        );
        ManagedDirectoryCatalog.createOrOpen(managed).close();
        final legacy = File('${fixture.path}/legacy.hv')
          ..writeAsStringSync('synthetic hidden-container data');
        HiddenVolumeStorage storage() => HiddenVolumeStorage(
          ({required password, required create}) => FakeKvLogStore(),
        );
        final router = await ProfileStorageRouter.open(
          profileDirectory: managed,
          legacyFactory: storage,
        );
        final owner = ProfileStorageRouterOwner(
          router,
          reopen: () => ProfileStorageRouter.open(
            profileDirectory: managed,
            legacyFactory: storage,
          ),
        );
        final container = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(_Idle.new),
            if (ownerOverride)
              profileStorageRouterOwnerProvider.overrideWithValue(owner)
            else
              profileStorageRouterProvider.overrideWithValue(router),
            singleSpaceStorageProvider.overrideWithValue(router.storage),
            notificationServiceProvider.overrideWithValue(_Notifications()),
            vpnBackendProvider.overrideWithValue(_Vpn()),
            whisperModelStoreProvider.overrideWithValue(
              WhisperModelStore(supportDirectory: () async => fixture),
            ),
            translationModelsRootProvider.overrideWithValue(() async => null),
            deniableBootProvider.overrideWithValue(
              DeniableBootConfig(
                runtimeDir: '${fixture.path}/runtime',
                storePath: legacy.path,
              ),
            ),
          ],
        );
        try {
          expect(router.catalog.identities, isEmpty);
          final before = {
            for (final f
                in fixture
                    .listSync(recursive: true, followLinks: false)
                    .whereType<File>())
              f.path: sha256.convert(f.readAsBytesSync()).toString(),
          };
          await expectLater(
            container.read(appControllerProvider.notifier).wipeContainers(),
            throwsStateError,
          );
          expect(container.read(appControllerProvider).phase, AppPhase.locked);
          expect({
            for (final f
                in fixture
                    .listSync(recursive: true, followLinks: false)
                    .whereType<File>())
              f.path: sha256.convert(f.readAsBytesSync()).toString(),
          }, before);
          expect(
            await legacy.readAsString(),
            'synthetic hidden-container data',
          );
          expect(
            (await SharedPreferences.getInstance()).getBool('onboarded'),
            isTrue,
          );
        } finally {
          container.dispose();
          await owner.close();
          fixture.deleteSync(recursive: true);
        }
      },
    );
  }
}
