@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';

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
  late Directory fixture;
  late String profile;
  final routers = <ProfileStorageRouter>[];
  final containers = <ProviderContainer>[];
  Future<ProviderContainer> app(ProfileStorageRouter router) async {
    final container = ProviderContainer(
      overrides: [
        profileStorageRouterProvider.overrideWithValue(router),
        singleSpaceStorageProvider.overrideWith((ref) {
          ref.watch(storageRouteRevisionProvider);
          return router.storage;
        }),
        nodeControllerProvider.overrideWithValue(_Node()),
      ],
    );
    containers.add(container);
    container.read(appControllerProvider);
    await container.read(prefsProvider.future);
    await Future<void>.delayed(Duration.zero);
    return container;
  }

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    SharedPreferences.setMockInitialValues({});
    fixture = Directory.systemTemp.createTempSync('xveil-master-select-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final container in containers.reversed) {
      container.dispose();
    }
    for (final router in routers.reversed) {
      await router.close();
    }
    containers.clear();
    routers.clear();
    fixture.deleteSync(recursive: true);
  });

  test('a legacy master opens a managed child in its actual store', () async {
    final path = '$profile/legacy.hv';
    final router = await ProfileStorageRouter.open(
      profileDirectory: profile,
      legacyFactory: () => HiddenVolumeStorage(
        hvSpaceOpener(
          path,
          argon: hv.ArgonPreset.min,
          paddingPreset: hv.PaddingPreset.none,
        ),
        keysOpener: hvKeysSpaceOpener(path),
      ),
    );
    routers.add(router);
    await router.create(StorageProtection.unencrypted);
    final child = router.location;
    expect(
      await router.storage.open(password: '', createIfMissing: true),
      isTrue,
    );
    await router.storage.saveProfile(
      const UserProfile(displayName: 'synthetic child'),
    );
    await router.storage.putSetting('witness', 'managed child');
    final keys = await router.storage.exportSpaceKeys();
    try {
      await router.create(StorageProtection.hidden);
      expect(
        await router.storage.open(
          password: 'synthetic master',
          createIfMissing: true,
        ),
        isTrue,
      );
      await router.storage.saveRoster([
        RosterEntry(label: 'child', spaceKeys: keys, storageLocator: child),
      ]);
      await router.storage.close();
      final container = await app(router);
      final controller = container.read(appControllerProvider.notifier);
      expect(
        await controller.selectStorageIdentity(const LegacyStorageLocator()),
        isTrue,
      );
      await controller.unlock('synthetic master');
      expect(
        container.read(appControllerProvider).phase,
        AppPhase.pickingIdentity,
      );
      await controller.pickIdentity('child');
      expect(container.read(appControllerProvider).phase, AppPhase.ready);
      expect(router.location, child);
      expect(router.access, const LegacyStorageLocator());
      expect(
        await container.read(storageProvider).getSetting('witness'),
        'managed child',
      );
      await controller.lock();
    } finally {
      keys.fillRange(0, keys.length, 0);
    }
  });

  test(
    'lock after accepted selection cannot strand providers on the retired facade',
    () async {
      final id = ManagedIdentityId('e' * 32);
      final seed = await ManagedWorkerIdentity.createUnencrypted(
        profileDirectory: profile,
        id: id,
      );
      await seed.close();
      final target = ManagedStorageLocator(
        id: id,
        protection: StorageProtection.unencrypted,
      );
      late AppController controller;
      Future<void>? locking;
      HiddenVolumeStorage fake() => HiddenVolumeStorage(
        ({required password, required create}) => FakeKvLogStore(),
      );
      final router = await ProfileStorageRouter.open(
        profileDirectory: profile,
        legacyFactory: fake,
        storageFactory: (locator, _) {
          if (locator == target) {
            // Inject cancellation at facade construction, after the router's
            // final await. It must not leave the provider on its old facade.
            // This tests a lifecycle boundary, not a historical incident.
            locking = controller.lock();
          }
          return fake();
        },
      );
      routers.add(router);
      final container = await app(router);
      controller = container.read(appControllerProvider.notifier);
      final previous = container.read(singleSpaceStorageProvider);
      final selected = await controller.selectStorageIdentity(target);
      await locking;
      expect(selected, isFalse);
      expect(container.read(appControllerProvider).phase, AppPhase.locked);
      expect(router.location, target);
      expect(router.access, target);
      expect(identical(router.storage, previous), isFalse);
      expect(
        identical(container.read(singleSpaceStorageProvider), router.storage),
        isTrue,
      );
      expect(container.read(storageAccessLocatorProvider), target);
    },
  );
}
