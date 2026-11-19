import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';

import '../support/retirement_secret_store.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _ManualController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> unlock(String password) async {}
}

class _AutoController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Storage extends HiddenVolumeStorage {
  _Storage(String path) : super.async(workerSpaceOpener(path));
  @override
  Future<String?> getSetting(String key) {
    // Exercise the public unlock through classification and maintenance, then
    // stop before booting a node or opening a network connection.
    if (key == 'anonymous') {
      throw StateError('fixture stops before network boot');
    }
    return super.getSetting(key);
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'storage.autoCompactSetup.v1': 'fixture-setup',
    }),
  );
  for (final automatic in [false, true]) {
    for (final scenario in [
      'setting',
      'file',
      'none',
      if (automatic) ...[
        'cancel',
        'abandoned',
        'start-over',
        'other-instance',
        'other-instance-after-close',
        'other-instance-stale-write',
        'old-consent',
      ],
    ]) {
      final restoring = scenario == 'cancel' || scenario == 'abandoned';
      final startOver = scenario == 'start-over';
      final otherInstanceAfterClose = scenario == 'other-instance-after-close';
      final staleWrite = scenario == 'other-instance-stale-write';
      final otherInstance =
          scenario == 'other-instance' || otherInstanceAfterClose || staleWrite;
      final corruption = switch (scenario) {
        'setting' || 'file' => scenario,
        _ => 'none',
      };
      final hasChild = scenario != 'none';
      final storedConsent = switch (scenario) {
        'cancel' || 'abandoned' || 'start-over' => '0',
        'old-consent' => '1',
        _ => 'v2:fixture-setup',
      };
      test(
        switch (scenario) {
          'cancel' || 'abandoned' =>
            '$scenario collection preserves an independent hidden space',
          'start-over' => 'onboarding revokes old automatic compaction consent',
          'other-instance' =>
            'an older preference snapshot cannot compact away a later space',
          'other-instance-after-close' =>
            'new space after source close cancels the prepared publication',
          'other-instance-stale-write' =>
            'saving an unrelated old preference cannot restore compaction consent',
          'old-consent' =>
            'unbound automatic compaction consent cannot delete a space',
          _ => 'native solo admission: automatic=$automatic roster=$corruption',
        },
        () async {
          expect(ensureHiddenVolumeLoaded(), isTrue);
          final directory = await Directory.systemTemp.createTemp(
            'xveil-entry-native-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final path = '${directory.path}/fixture.hv';
          final preferencesPath = profilePrefsPath(directory.path, 'default');
          if (otherInstance) {
            final first = await ProfilePreferencesStore.load(
              preferencesPath,
              ownedFile: await ManagedProfilePreferencesFile.open(
                preferencesPath,
              ),
            );
            addTearDown(first.releaseFile);
            expect(
              await first.setValue(
                'String',
                'flutter.storage.autoCompactSetup.v1',
                'fixture-setup',
              ),
              isTrue,
            );
            SharedPreferencesStorePlatform.instance = first;
          } else if (startOver) {
            SharedPreferencesStorePlatform.instance =
                await ProfilePreferencesStore.load(preferencesPath);
          }
          final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
          HvKvLogStore(
            hv.HvSpace.create(
              path: path,
              password: _bytes('root-fixture'),
              argon: hv.ArgonPreset.min,
              initialGarbageChunks: 4096,
              padding: hv.PaddingPreset.none,
            ),
          ).close();
          HiddenVolumeStorage facade() =>
              HiddenVolumeStorage.async(workerSpaceOpener(path));
          final seed = facade();
          try {
            Uint8List? childKeys;
            if (hasChild && !startOver && !otherInstance) {
              expect(
                await seed.open(
                  password: 'child-fixture',
                  createIfMissing: true,
                ),
                isTrue,
              );
              await seed.saveProfile(
                const UserProfile(displayName: 'Child fixture'),
              );
              await seed.storeFile('fixture-body', body);
              childKeys = await seed.exportSpaceKeys();
              await seed.close();
            }
            expect(await seed.open(password: 'root-fixture'), isTrue);
            await seed.saveProfile(
              const UserProfile(displayName: 'Root fixture'),
            );
            await seed.storeFile('fixture-body', body);
            await seed.putSetting('storage.autocompact.v1', storedConsent);
            if (childKeys != null && corruption != 'none') {
              await seed.saveRoster([
                for (var i = 0; i < (corruption == 'file' ? 24 : 1); i++)
                  RosterEntry(label: 'child-$i', spaceKeys: childKeys),
              ]);
            }
            childKeys?.fillRange(0, childKeys.length, 0);
          } finally {
            await seed.close();
          }
          Future<void> addOtherSpace() async {
            final second = await ProfilePreferencesStore.load(
              preferencesPath,
              ownedFile: await ManagedProfilePreferencesFile.open(
                preferencesPath,
              ),
            );
            try {
              expect(
                await second.setValue(
                  'String',
                  'flutter.storage.autoCompactSetup.v1',
                  'new-setup',
                ),
                isTrue,
              );
            } finally {
              await second.releaseFile();
            }
            try {
              expect(
                await seed.open(
                  password: 'child-fixture',
                  createIfMissing: true,
                ),
                isTrue,
              );
              await seed.saveProfile(
                const UserProfile(displayName: 'Child fixture'),
              );
              await seed.storeFile('fixture-body', body);
            } finally {
              await seed.close();
            }
          }

          if (corruption != 'none') {
            final raw = HvKvLogStore(
              hv.HvSpace.open(path: path, password: _bytes('root-fixture')),
            );
            try {
              final key = _bytes(
                corruption == 'file'
                    ? 'file:master:roster.v2'
                    : 'master:roster',
              );
              expect(raw.get(Ns.settings, key), isNotNull);
              raw.commit([PutOp(Ns.settings, key, _bytes('unreadable'))]);
            } finally {
              raw.close();
            }
          }
          // A real container, not a sparse size-only witness: auto maintenance's
          // normal size gate must actually be eligible in both control branches.
          expect(await File(path).length(), greaterThanOrEqualTo(16 << 20));
          final storage = restoring || startOver ? facade() : _Storage(path);
          final controller = automatic
              ? _AutoController()
              : _ManualController();
          var nativeCalls = 0;
          final providers = ProviderContainer(
            overrides: [
              appControllerProvider.overrideWith(() => controller),
              singleSpaceStorageProvider.overrideWithValue(storage),
              notificationServiceProvider.overrideWithValue(_Notifications()),
              quickUnlockSecretStoreProvider.overrideWithValue(
                RetirementSecretStore(),
              ),
              deniableBootProvider.overrideWithValue(
                DeniableBootConfig(
                  runtimeDir: '${directory.path}/runtime',
                  storePath: path,
                ),
              ),
              containerCompactorProvider.overrideWithValue((
                path,
                passwords, {
                required beforePublication,
                dylibPath,
              }) async {
                nativeCalls++;
                if (otherInstanceAfterClose) await addOtherSpace();
                await hv.compactKnownPreparedAsync(
                  path,
                  passwords,
                  repairMetadata: (_) => beforePublication(),
                  dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
                );
              }),
              preparedContainerCompactorProvider.overrideWithValue((
                path,
                passwords, {
                required repairMetadata,
                dylibPath,
              }) async {
                nativeCalls++;
                await hv.compactKnownPreparedAsync(
                  path,
                  passwords,
                  repairMetadata: repairMetadata,
                  dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
                );
              }),
            ],
          );
          providers.read(appControllerProvider);
          try {
            if (otherInstance) {
              final prefs = await providers.read(prefsProvider.future);
              if (!otherInstanceAfterClose) await addOtherSpace();
              expect(
                prefs.getString('storage.autoCompactSetup.v1'),
                'fixture-setup',
              );
              if (staleWrite) {
                expect(
                  await prefs.setBool('unrelated-fixture-setting', true),
                  isTrue,
                );
                final saved = await ProfilePreferencesStore.load(
                  preferencesPath,
                );
                expect(
                  (await saved.getAll())['flutter.unrelated-fixture-setting'],
                  isTrue,
                );
              }
              await controller.unlock('root-fixture');
            } else if (restoring || startOver) {
              controller.debugDeniableStackStarter = (_) async =>
                  throw StateError('network disabled for fixture');
              await controller.unlock('root-fixture');
              expect(
                providers.read(appControllerProvider).phase,
                AppPhase.ready,
              );
              await controller.setAutoCompactEnabled(true);
              expect(await controller.autoCompactEnabled(), isTrue);
              if (startOver) {
                await controller.lock();
                await controller.startOver();
                expect(
                  providers.read(appControllerProvider).phase,
                  AppPhase.onboarding,
                );
                await controller.completeOnboarding(
                  password: 'child-fixture',
                  mode: StorageMode.plain,
                  displayName: 'Child fixture',
                );
                await storage.storeFile('fixture-body', body);
                await controller.lock();
                SharedPreferencesStorePlatform.instance =
                    await ProfilePreferencesStore.load(preferencesPath);
                providers.invalidate(prefsProvider);
                await controller.unlock('root-fixture');
              } else {
                final lease = controller.leaseIdentity();
                expect(await controller.beginCompactionCollection(), isTrue);
                if (scenario == 'cancel') {
                  await controller.cancelCompactionCollection('root-fixture');
                } else {
                  await controller.recoverCompactionCollection(
                    lease: lease,
                    reopenWith: 'root-fixture',
                  );
                }
              }
              expect(
                providers.read(appControllerProvider).phase,
                AppPhase.ready,
              );
              expect(await controller.autoCompactEnabled(), restoring);
              await controller.lock();
            } else if (automatic) {
              await controller.unlock('root-fixture');
            } else {
              expect(await storage.open(password: 'root-fixture'), isTrue);
              if (corruption == 'none') {
                await controller.compactStorage('root-fixture');
              } else {
                await expectLater(
                  controller.compactStorage('root-fixture'),
                  throwsStateError,
                );
                expect(storage.isOpen, isTrue);
              }
            }
          } finally {
            await storage.close();
            providers.dispose();
          }
          // Verify independently by password, including the child that a wrongly
          // admitted one-password rewrite would silently drop.
          final reader = facade();
          try {
            for (final password in [
              'root-fixture',
              if (hasChild) 'child-fixture',
            ]) {
              expect(
                await reader.open(password: password),
                isTrue,
                reason: password == 'root-fixture'
                    ? 'the originating space must remain accessible'
                    : 'the second space must remain accessible',
              );
              expect(
                (await reader.loadProfile())?.displayName,
                password == 'root-fixture' ? 'Root fixture' : 'Child fixture',
              );
              expect(await reader.loadFile('fixture-body'), body);
              await reader.close();
            }
          } finally {
            await reader.close();
          }
          expect(
            nativeCalls,
            otherInstanceAfterClose || (corruption == 'none' && !hasChild)
                ? 1
                : 0,
          );
        },
        skip: Platform.environment['XVEIL_NATIVE_COMPACTION_ENTRY'] != '1',
      );
    }
  }
}
