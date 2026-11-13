@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';

class _Node implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'default add creates encrypted master and child while preserving source',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      SharedPreferences.setMockInitialValues({});
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-default-master-',
      );
      final profile = '${fixture.path}/profile';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      ProfileStorageRouter? router;
      ProviderContainer? container;
      try {
        router = await ProfileStorageRouter.open(
          profileDirectory: profile,
          legacyFactory: () => HiddenVolumeStorage(
            ({required password, required create}) => FakeKvLogStore(),
          ),
        );
        await router.create(StorageProtection.unencrypted);
        expect(
          await router.storage.open(password: '', createIfMissing: true),
          isTrue,
        );
        await router.storage.saveProfile(
          const UserProfile(displayName: 'original source'),
        );
        await router.storage.putSetting('original', 'retain');
        final source = router.location;
        await router.rememberAccess();
        await router.storage.close();
        final owned = router;
        container = ProviderContainer(
          overrides: [
            profileStorageRouterProvider.overrideWithValue(owned),
            singleSpaceStorageProvider.overrideWith((ref) {
              ref.watch(storageRouteRevisionProvider);
              return owned.storage;
            }),
            nodeControllerProvider.overrideWithValue(_Node()),
          ],
        );
        final controller = container.read(appControllerProvider.notifier);
        await container.read(prefsProvider.future);
        await Future<void>.delayed(Duration.zero);
        await controller.unlock('');
        expect(container.read(appControllerProvider).phase, AppPhase.ready);
        expect(
          await controller.addIdentity(
            masterPassword: 'synthetic master password',
            label: 'new child',
            password: 'synthetic child password',
            existingLabel: 'source',
          ),
          isTrue,
        );
        expect(
          (router.access as ManagedStorageLocator).protection,
          StorageProtection.encrypted,
        );
        expect(
          (router.location as ManagedStorageLocator).protection,
          StorageProtection.encrypted,
        );
        expect(router.access, isNot(router.location));
        expect(
          container
              .read(screenLockProvider.notifier)
              .tryUnlock('synthetic master password'),
          isTrue,
          reason:
              'the new child view must retain the authenticated master recognizer',
        );
        await controller.switchIdentity('source');
        expect(router.location, source);
        expect(
          await container.read(storageProvider).getSetting('original'),
          'retain',
        );
        expect(
          (await container.read(storageProvider).loadProfile())!.displayName,
          'original source',
        );
      } finally {
        if (container != null) {
          await container.read(appControllerProvider.notifier).lock();
          container.dispose();
        }
        if (router != null) await router.close();
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
