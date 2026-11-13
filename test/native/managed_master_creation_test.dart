@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/data/node/node_controller.dart';
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
import 'package:xveil/state/startup_unlock.dart';
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

class _Vault extends QuickUnlockVault {
  _Vault()
    : super(
        const QuickUnlockSecretStore(),
        'synthetic legacy scope',
        LocalScreenAuthentication(),
      );
  int forgotten = 0;
  @override
  Future<void> forget() async {
    forgotten++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (sourceMode, masterMode, childMode) in [
    (
      StorageProtection.encrypted,
      StorageProtection.encrypted,
      StorageProtection.encrypted,
    ),
    (
      StorageProtection.unencrypted,
      StorageProtection.hidden,
      StorageProtection.unencrypted,
    ),
    (
      StorageProtection.hidden,
      StorageProtection.unencrypted,
      StorageProtection.hidden,
    ),
    (
      StorageProtection.hidden,
      StorageProtection.hidden,
      StorageProtection.hidden,
    ),
  ]) {
    test(
      'create/append/cold reopen: ${sourceMode.name}/${masterMode.name}/${childMode.name}',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-master-create-',
        );
        final profile = '${fixture.path}/profile';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        final path = '$profile/legacy.hv';
        final routers = <ProfileStorageRouter>[];
        final containers = <ProviderContainer>[];
        final keys = <Uint8List>[];
        final vault = _Vault();
        final sameLegacy =
            sourceMode == StorageProtection.hidden &&
            masterMode == StorageProtection.hidden;
        SharedPreferences.setMockInitialValues({
          if (sameLegacy) kStartupUnlockOptIn: true,
        });
        Future<ProfileStorageRouter> open() async {
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
          return router;
        }

        Future<ProviderContainer> app(ProfileStorageRouter router) async {
          final container = ProviderContainer(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(router),
              singleSpaceStorageProvider.overrideWith((ref) {
                ref.watch(storageRouteRevisionProvider);
                return router.storage;
              }),
              nodeControllerProvider.overrideWithValue(_Node()),
              quickUnlockVaultProvider.overrideWithValue(vault),
            ],
          );
          containers.add(container);
          container.read(appControllerProvider);
          await container.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          return container;
        }

        final sourcePassword = sourceMode == StorageProtection.unencrypted
            ? ''
            : 'synthetic source';
        final masterPassword = masterMode == StorageProtection.unencrypted
            ? ''
            : 'synthetic master';
        final childPassword = childMode == StorageProtection.unencrypted
            ? ''
            : 'synthetic child';
        try {
          final router = await open();
          final container = await app(router);
          final controller = container.read(appControllerProvider.notifier);
          await controller.completeOnboarding(
            password: sourcePassword,
            mode: StorageMode.plain,
            protection: sourceMode,
            displayName: 'source',
          );
          expect(container.read(appControllerProvider).phase, AppPhase.ready);
          final sourceLocator = router.location;
          await router.storage.putSetting('witness', 'original source');
          keys.add(await router.storage.exportSpaceKeys());
          expect(
            await controller.addIdentity(
              masterPassword: masterPassword,
              label: 'second',
              password: childPassword,
              existingLabel: 'source',
              anonymous: true,
              // Omit the modes in the default case: this must choose encrypted.
              protection: masterMode == StorageProtection.encrypted
                  ? null
                  : childMode,
              masterProtection: masterMode == StorageProtection.encrypted
                  ? null
                  : masterMode,
            ),
            isTrue,
          );
          expect(container.read(appControllerProvider).phase, AppPhase.ready);
          expect(controller.activeIdentity, 'second');
          expect(
            container
                .read(screenLockProvider.notifier)
                .tryUnlock(masterPassword),
            isTrue,
          );
          expect(controller.isIdentityAnonymous('second'), isTrue);
          final masterLocator = router.access;
          final secondLocator = router.location;
          if (masterMode == StorageProtection.hidden) {
            expect(masterLocator, const LegacyStorageLocator());
          } else {
            expect(
              (masterLocator as ManagedStorageLocator).protection,
              masterMode,
            );
          }
          if (childMode == StorageProtection.hidden) {
            expect(secondLocator, const LegacyStorageLocator());
          } else {
            expect(
              (secondLocator as ManagedStorageLocator).protection,
              childMode,
            );
            expect(secondLocator, isNot(sourceLocator));
            expect(secondLocator, isNot(masterLocator));
          }
          expect(await container.read(storageProvider).loadRoster(), isNull);
          expect(
            (await container.read(storageProvider).loadProfile())!.displayName,
            'second',
          );
          expect(vault.forgotten, sameLegacy ? 1 : 0);
          if (sameLegacy) {
            expect(
              (await container.read(
                prefsProvider.future,
              )).getBool(kStartupUnlockOptIn),
              isNull,
            );
          }
          final addedMode = childMode == StorageProtection.unencrypted
              ? StorageProtection.encrypted
              : StorageProtection.unencrypted;
          final thirdPassword = addedMode == StorageProtection.unencrypted
              ? ''
              : 'synthetic third';
          expect(
            await controller.addIdentity(
              masterPassword: masterPassword,
              label: 'third',
              password: thirdPassword,
              protection: addedMode,
            ),
            isTrue,
          );
          final thirdLocator = router.location;
          expect(router.access, masterLocator);
          expect((thirdLocator as ManagedStorageLocator).protection, addedMode);
          final count = router.catalog.identities.length;
          expect(
            await controller.addIdentity(
              masterPassword: masterPassword,
              label: 'third',
              password: 'synthetic duplicate',
            ),
            isFalse,
          );
          expect(router.catalog.identities, hasLength(count));
          expect(container.read(appControllerProvider).phase, AppPhase.ready);
          expect(controller.activeIdentity, 'third');
          if (masterMode != StorageProtection.unencrypted) {
            expect(
              await controller.addIdentity(
                masterPassword: 'incorrect master password',
                label: 'refused',
                password: 'synthetic refused',
              ),
              isFalse,
            );
            expect(router.catalog.identities, hasLength(count));
            expect(container.read(appControllerProvider).phase, AppPhase.ready);
          }
          if (masterMode == StorageProtection.hidden) {
            final other = HiddenVolumeStorage(
              hvSpaceOpener(
                path,
                argon: hv.ArgonPreset.min,
                paddingPreset: hv.PaddingPreset.none,
              ),
              keysOpener: hvKeysSpaceOpener(path),
            );
            try {
              expect(
                await other.open(
                  password: 'synthetic other master',
                  createIfMissing: true,
                ),
                isTrue,
              );
              await other.saveRoster([
                RosterEntry(
                  label: 'untouched reference',
                  spaceKeys: keys.first,
                  storageLocator: sourceLocator,
                ),
              ]);
              await other.close();
              expect(
                await controller.addIdentity(
                  masterPassword: 'synthetic other master',
                  label: 'must not enter other master',
                  password: '',
                  protection: StorageProtection.unencrypted,
                ),
                isFalse,
              );
              expect(router.catalog.identities, hasLength(count));
              expect(
                await other.open(password: 'synthetic other master'),
                isTrue,
              );
              final unrelated = (await other.loadRoster())!;
              expect(unrelated.map((entry) => entry.label), [
                'untouched reference',
              ]);
            } finally {
              await other.close();
            }
          }
          if (sourceMode == StorageProtection.hidden) {
            expect(
              await controller.addIdentity(
                masterPassword: masterPassword,
                label: 'existing hidden collision',
                password: sourcePassword,
                protection: StorageProtection.hidden,
              ),
              isFalse,
            );
            expect(container.read(appControllerProvider).phase, AppPhase.ready);
            expect(router.catalog.identities, hasLength(count));
          }
          if (masterMode != StorageProtection.unencrypted) {
            expect(
              await controller.addIdentity(
                masterPassword: masterPassword,
                label: 'shared password refused',
                password: masterPassword,
                protection: StorageProtection.encrypted,
              ),
              isFalse,
            );
            expect(router.catalog.identities, hasLength(count));
          }
          await controller.switchIdentity('source');
          expect(router.location, sourceLocator);
          expect(
            await container.read(storageProvider).getSetting('witness'),
            'original source',
          );
          expect(
            await container.read(storageProvider).exportSpaceKeys(),
            keys.first,
          );
          await controller.lock();
          await router.close();
          container.dispose();
          containers.remove(container);
          final coldRouter = await open();
          final cold = await app(coldRouter);
          final coldController = cold.read(appControllerProvider.notifier);
          if (masterMode == StorageProtection.hidden) {
            expect(
              await coldController.selectStorageIdentity(
                const LegacyStorageLocator(),
              ),
              isTrue,
            );
          }
          await coldController.unlock(masterPassword);
          expect(
            cold.read(appControllerProvider).phase,
            AppPhase.pickingIdentity,
          );
          expect(cold.read(appControllerProvider).identities, [
            'source',
            'second',
            'third',
          ]);
          for (final (label, locator) in [
            ('source', sourceLocator),
            ('second', secondLocator),
            ('third', thirdLocator),
          ]) {
            await coldController.pickIdentity(label);
            expect(cold.read(appControllerProvider).phase, AppPhase.ready);
            expect(coldRouter.location, locator);
            expect(coldRouter.access, masterLocator);
            expect(
              cold.read(screenLockProvider.notifier).tryUnlock(masterPassword),
              isTrue,
            );
            expect(
              (await cold.read(storageProvider).loadProfile())!.displayName,
              label,
            );
          }
          await coldController.lock();
          await coldRouter.select(masterLocator, access: false);
          expect(
            await coldRouter.storage.open(password: masterPassword),
            isTrue,
          );
          final roster = (await coldRouter.storage.loadRoster())!;
          expect(roster.map((entry) => entry.storageLocator), [
            sourceLocator,
            secondLocator,
            thirdLocator,
          ]);
          expect(roster.map((entry) => entry.label), [
            'source',
            'second',
            'third',
          ]);
          expect(roster[1].anonymous, isTrue);
        } finally {
          for (final container in containers.reversed) {
            await container.read(appControllerProvider.notifier).lock();
            container.dispose();
          }
          for (final router in routers.reversed) {
            await router.close();
          }
          for (final key in keys) {
            key.fillRange(0, key.length, 0);
          }
          fixture.deleteSync(recursive: true);
        }
      },
    );
  }
}
