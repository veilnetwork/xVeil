@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/pending_identity_erase.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';

/// Real native parent with one optional failure BEFORE intent persistence.
class _Parent extends StorageProxy {
  _Parent(super.inner);
  bool refuseIntent = false;
  @override
  Future<void> putSetting(String key, String value) async {
    if (refuseIntent && key == kPendingIdentityErase && value.isNotEmpty) {
      refuseIntent = false;
      throw StateError('synthetic intent refusal');
    }
    await inner.putSetting(key, value);
  }
}

class StorageProxy implements Storage, StorageOpeningOwner {
  StorageProxy(this.inner);
  final Storage inner;
  @override
  bool get isOpen => inner.isOpen;
  @override
  Future<bool> open({required String password, bool createIfMissing = false}) =>
      inner.open(password: password, createIfMissing: createIfMissing);
  @override
  Future<bool> openWithKeys(Uint8List keys) => inner.openWithKeys(keys);
  @override
  Future<void> close() => inner.close();
  @override
  Future<void> settleOpening() =>
      (inner as StorageOpeningOwner).settleOpening();
  @override
  Future<String?> getSetting(String key) => inner.getSetting(key);
  @override
  Future<void> putSetting(String key, String value) =>
      inner.putSetting(key, value);
  @override
  Future<Uint8List> exportSpaceKeys() => inner.exportSpaceKeys();
  @override
  Future<List<RosterEntry>?> loadRoster() => inner.loadRoster();
  @override
  Future<void> saveRoster(List<RosterEntry> roster) => inner.saveRoster(roster);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused fixture parent operation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final coldIntent in [true, false]) {
    test(
      'authenticated erase recovery and retry; durable intent=$coldIntent',
      () async {
        SharedPreferences.setMockInitialValues({});
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-erase-recovery-',
        );
        final profile = '${fixture.path}/profile';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        ManagedIdentityEntry entry(int i, StorageProtection mode) =>
            ManagedIdentityEntry(
              id: ManagedIdentityId('$i' * 32),
              protection: mode,
            );
        final parentEntry = entry(9, StorageProtection.encrypted);
        final parent = ManagedIdentityStorage.forCreation(
          profileDirectory: profile,
          entry: parentEntry,
        );
        final children = [
          for (final i in [1, 2])
            ManagedIdentityStorage.forCreation(
              profileDirectory: profile,
              entry: entry(i, StorageProtection.unencrypted),
            ),
        ];
        final ownedKeys = <Uint8List>[];
        ProfileStorageRouter? router;
        ProviderContainer? container;
        try {
          final roster = <RosterEntry>[];
          for (var i = 0; i < children.length; i++) {
            final child = children[i];
            expect(
              await child.storage.open(password: '', createIfMissing: true),
              isTrue,
            );
            await child.storage.saveProfile(
              UserProfile(displayName: i == 0 ? 'keep' : 'remove'),
            );
            final key = await child.storage.exportSpaceKeys();
            ownedKeys.add(key);
            roster.add(
              RosterEntry(
                label: i == 0 ? 'keep' : 'remove',
                spaceKeys: key,
                storageLocator: child.entry.locator,
              ),
            );
            await child.storage.close();
          }
          expect(
            await parent.storage.open(
              password: 'fixture recovery password',
              createIfMissing: true,
            ),
            isTrue,
          );
          await parent.storage.saveRoster(roster);
          final keys = await parent.storage.exportSpaceKeys();
          ownedKeys.add(keys);
          if (coldIntent) {
            final intent = PendingIdentityErase.authorized(
              root: parentEntry.locator,
              masterKeys: keys,
              target: roster.last,
            );
            await parent.storage.putSetting(
              kPendingIdentityErase,
              intent.encode(),
            );
            intent.destroy();
          }
          await parent.storage.close();
          final catalog = ManagedDirectoryCatalog.openExisting(profile)!;
          try {
            catalog.select(parentEntry);
          } finally {
            catalog.close();
          }
          final foreign = File(
            '${ManagedIdentityLayout(profile).directory(children.last.entry.id)}/foreign-fixture',
          );
          if (coldIntent) foreign.writeAsBytesSync([7, 8, 9]);
          final native = ManagedIdentityStorage.existing(
            profileDirectory: profile,
            entry: parentEntry,
          );
          final proxy = _Parent(native.storage);
          router = await ProfileStorageRouter.open(
            profileDirectory: profile,
            legacyFactory: () => throw StateError('unexpected legacy route'),
            storageFactory: (locator, _) {
              expect(locator, parentEntry.locator);
              return proxy;
            },
          );
          final selected = router;
          container = ProviderContainer(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(selected),
              singleSpaceStorageProvider.overrideWith((ref) {
                ref.watch(storageRouteRevisionProvider);
                return selected.storage;
              }),
            ],
          );
          final controller = container.read(appControllerProvider.notifier);
          await container.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          await controller.unlock('wrong fixture password');
          expect(container.read(appControllerProvider).phase, AppPhase.locked);
          expect(container.read(appControllerProvider).unlockError, isTrue);
          expect(controller.debugMasterKeys, isNull);
          expect(await controller.retryIdentityErasure(), isFalse);
          await controller.unlock('fixture recovery password');
          if (!coldIntent) {
            expect(
              container.read(appControllerProvider).phase,
              AppPhase.pickingIdentity,
            );
            proxy.refuseIntent = true;
            expect(await controller.deleteIdentity('remove'), isFalse);
          }
          expect(
            container.read(appControllerProvider).phase,
            AppPhase.identityEraseRecovery,
          );
          expect(container.read(appControllerProvider).unlockError, isFalse);
          expect(controller.debugMasterKeys, isNotNull);
          expect(controller.debugRoster!.length, 2);
          expect(controller.holdsIdentity(controller.leaseIdentity()), isFalse);
          expect(await controller.unbindIdentity('keep'), isFalse);
          expect(await controller.deleteIdentity('keep'), isFalse);
          await controller.pickIdentity('keep');
          await controller.unlock(
            'wrong password must not replace recovery authority',
          );
          expect(
            container.read(appControllerProvider).phase,
            AppPhase.identityEraseRecovery,
          );
          if (coldIntent) {
            expect(await controller.retryIdentityErasure(), isFalse);
            expect(foreign.readAsBytesSync(), [7, 8, 9]);
            final cachedRoot = controller.debugMasterKeys!;
            final cachedChildren = controller.debugRoster!
                .map((e) => e.spaceKeys)
                .toList();
            await controller.lock();
            expect(cachedRoot, everyElement(0));
            expect(cachedChildren, everyElement(everyElement(0)));
            expect(await controller.retryIdentityErasure(), isFalse);
            await controller.unlock('fixture recovery password');
            expect(
              container.read(appControllerProvider).phase,
              AppPhase.identityEraseRecovery,
            );
            foreign
                .deleteSync(); // Explicit fixture repair, never an automatic sweep.
          }
          expect(await controller.retryIdentityErasure(), isTrue);
          expect(
            container.read(appControllerProvider).phase,
            AppPhase.pickingIdentity,
          );
          expect(container.read(appControllerProvider).identities, ['keep']);
          expect(
            Directory(
              ManagedIdentityLayout(profile).directory(children.last.entry.id),
            ).existsSync(),
            isFalse,
          );
          await controller.lock();
          expect(
            await native.storage.open(password: 'fixture recovery password'),
            isTrue,
          );
          expect(await native.storage.getSetting(kPendingIdentityErase), '');
          expect((await native.storage.loadRoster())!.single.label, 'keep');
          await native.storage.close();
        } finally {
          if (container != null) {
            await container.read(appControllerProvider.notifier).lock();
            container.dispose();
          }
          await router?.close();
          await parent.storage.close();
          for (final child in children) {
            await child.storage.close();
          }
          for (final key in ownedKeys) {
            key.fillRange(0, key.length, 0);
          }
          fixture.deleteSync(recursive: true);
        }
      },
    );
  }
}
