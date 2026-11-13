@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
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

/// Delegates real native I/O. Only the second roster response is withheld,
/// after physical child deletion and before publishing the reduced roster.
class _GatedParent implements Storage, StorageOpeningOwner {
  _GatedParent(this.inner);
  final Storage inner;
  final entered = Completer<void>(), release = Completer<void>();
  int reads = 0;
  List<RosterEntry>? heldRows;
  final exports = <Uint8List>[];
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
  Future<void> saveRoster(List<RosterEntry> rows) => inner.saveRoster(rows);
  @override
  Future<Uint8List> exportSpaceKeys() async {
    final result = await inner.exportSpaceKeys();
    exports.add(result);
    return result;
  }

  @override
  Future<List<RosterEntry>?> loadRoster() async {
    final rows = await inner.loadRoster();
    if (++reads == 2) {
      heldRows = rows;
      entered.complete();
      await release.future;
    }
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused fixture parent operation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'lock after native child removal preserves intent and retires late roster keys before retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-roster-erase-lifecycle-',
      );
      final profile = '${fixture.path}/profile';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      ManagedIdentityEntry entry(int i) => ManagedIdentityEntry(
        id: ManagedIdentityId('$i' * 32),
        protection: StorageProtection.unencrypted,
      );
      final parent = ManagedIdentityStorage.forCreation(
        profileDirectory: profile,
        entry: entry(9),
      );
      final keep = ManagedIdentityStorage.forCreation(
        profileDirectory: profile,
        entry: entry(1),
      );
      final remove = ManagedIdentityStorage.forCreation(
        profileDirectory: profile,
        entry: entry(2),
      );
      final keys = <Uint8List>[];
      ProfileStorageRouter? router;
      ProviderContainer? container;
      _GatedParent? gate;
      try {
        final rows = <RosterEntry>[];
        for (final (host, label) in [(keep, 'keep'), (remove, 'remove')]) {
          expect(
            await host.storage.open(password: '', createIfMissing: true),
            isTrue,
          );
          await host.storage.saveProfile(UserProfile(displayName: label));
          final value = await host.storage.exportSpaceKeys();
          keys.add(value);
          rows.add(
            RosterEntry(
              label: label,
              spaceKeys: value,
              storageLocator: host.entry.locator,
            ),
          );
          await host.storage.close();
        }
        expect(
          await parent.storage.open(password: '', createIfMissing: true),
          isTrue,
        );
        await parent.storage.saveRoster(rows);
        final rootKeys = await parent.storage.exportSpaceKeys();
        keys.add(rootKeys);
        final intent = PendingIdentityErase.authorized(
          root: parent.entry.locator,
          masterKeys: rootKeys,
          target: rows.last,
        );
        await parent.storage.putSetting(kPendingIdentityErase, intent.encode());
        intent.destroy();
        await parent.storage.close();
        final catalog = ManagedDirectoryCatalog.openExisting(profile)!;
        try {
          catalog.select(parent.entry);
        } finally {
          catalog.close();
        }
        final native = ManagedIdentityStorage.existing(
          profileDirectory: profile,
          entry: parent.entry,
        );
        final held = _GatedParent(native.storage);
        gate = held;
        router = await ProfileStorageRouter.open(
          profileDirectory: profile,
          legacyFactory: () => throw StateError('unexpected legacy route'),
          storageFactory: (locator, _) {
            expect(locator, parent.entry.locator);
            return held;
          },
        );
        final ownedRouter = router;
        container = ProviderContainer(
          overrides: [
            profileStorageRouterProvider.overrideWithValue(ownedRouter),
            singleSpaceStorageProvider.overrideWith((ref) {
              ref.watch(storageRouteRevisionProvider);
              return ownedRouter.storage;
            }),
          ],
        );
        final controller = container.read(appControllerProvider.notifier);
        await container.read(prefsProvider.future);
        await Future<void>.delayed(Duration.zero);
        final unlocking = controller.unlock('');
        await Future.any<void>([
          held.entered.future,
          unlocking.then<void>(
            (_) => throw StateError('unlock ended before the fixture gate'),
          ),
        ]);
        expect(
          Directory(
            ManagedIdentityLayout(profile).directory(remove.entry.id),
          ).existsSync(),
          isFalse,
        );
        await controller.lock();
        expect(container.read(appControllerProvider).phase, AppPhase.locked);
        held.release.complete();
        await unlocking;
        expect(container.read(appControllerProvider).phase, AppPhase.locked);
        expect(controller.debugRoster, isNull);
        expect(controller.debugMasterKeys, isNull);
        expect(held.heldRows, isNotEmpty);
        expect(
          held.heldRows!.every((e) => e.spaceKeys.every((b) => b == 0)),
          isTrue,
        );
        expect(held.exports.every((key) => key.every((b) => b == 0)), isTrue);
        expect(held.isOpen, isFalse);
        await controller.unlock('');
        expect(
          container.read(appControllerProvider).phase,
          AppPhase.pickingIdentity,
        );
        expect(container.read(appControllerProvider).identities, ['keep']);
        expect(controller.debugRoster!.single.spaceKeys, rows.first.spaceKeys);
        await controller.lock();
        expect(await native.storage.open(password: ''), isTrue);
        expect(await native.storage.getSetting(kPendingIdentityErase), '');
        expect((await native.storage.loadRoster())!.single.label, 'keep');
        await native.storage.close();
      } finally {
        if (gate != null && !gate.release.isCompleted) gate.release.complete();
        if (container != null) {
          await container.read(appControllerProvider.notifier).lock();
          container.dispose();
        }
        await router?.close();
        await parent.storage.close();
        await keep.storage.close();
        await remove.storage.close();
        for (final key in keys) {
          key.fillRange(0, key.length, 0);
        }
        fixture.deleteSync(recursive: true);
      }
    },
  );
}
