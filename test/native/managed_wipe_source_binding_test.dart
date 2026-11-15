@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_profile_wipe.dart';
import 'package:xveil/data/storage/profile_preferences.dart';
import 'package:xveil/data/storage/profile_preferences_bootstrap.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/domain/storage_locator.dart';
import '../support/background_resource_backend.dart';
import '../support/retirement_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in ['xveil.store', 'архив #100%?.hv']) {
    for (final mismatch in [true, false]) {
      test(
        'whole-profile wipe binds exact source (custom=${name != 'xveil.store'}, mismatch=$mismatch)',
        () async {
          final original = SharedPreferencesStorePlatform.instance;
          final fixture = Directory.systemTemp.createTempSync(
            'xveil-wipe-source-binding-',
          );
          final profile = '${fixture.path}/visible-storage';
          final source = '${fixture.path}/$name';
          final neighbor = '${fixture.path}/neighbor.hv';
          ProfileStorageRouterOwner? owner;
          ProfilePreferencesLifetime? preferences;
          ManagedProfileWipe? job;
          CaptureResourceLifetime.resetForTesting();
          try {
            SharedPreferences.setMockInitialValues({'locale': 'en'});
            final boot = await bootstrapProfilePreferences(
              supportDir: () async => fixture.path,
              args: const [],
              environment: {'XVEIL_STORE_PATH': source},
              managedStorage: true,
            );
            expect(boot.erasurePending, isFalse);
            preferences = ProfilePreferencesLifetime.current();
            expect(ensureHiddenVolumeLoaded(), isTrue);
            final hidden = hv.HvSpace.create(
              path: source,
              password: Uint8List.fromList(
                'synthetic source password'.codeUnits,
              ),
              argon: hv.ArgonPreset.min,
            );
            hidden.close();
            File(neighbor).createSync(exclusive: true);
            const ManagedFsPlatform().restrictNewFile(neighbor);
            File(
              neighbor,
            ).writeAsBytesSync(File(source).readAsBytesSync(), flush: true);
            final root = ManagedDirectoryCatalog.createOrOpen(profile);
            try {
              ManagedIdentityFiles.createUnencrypted(
                root,
                id: ManagedIdentityId('1' * 32),
              ).close();
              ManagedIdentityFiles.createEncrypted(
                root,
                id: ManagedIdentityId('2' * 32),
                password: Uint8List.fromList(
                  'synthetic master password'.codeUnits,
                ),
              ).close();
            } finally {
              root.close();
            }
            Future<ProfileStorageRouter> open() => ProfileStorageRouter.open(
              profileDirectory: profile,
              legacyPath: mismatch ? neighbor : source,
              legacyFactory: () => HiddenVolumeStorage.async(
                workerSpaceOpener(mismatch ? neighbor : source),
              ),
            );
            owner = ProfileStorageRouterOwner(await open(), reopen: open);
            final background = BackgroundResourceBackend();
            final secrets = RetirementSecretStore();
            var quiesces = 0;
            ManagedProfileWipe construct() => ManagedProfileWipe(
              router: owner!,
              preferences: preferences!,
              source: boot.legacyPreferences!,
              secretStore: secrets,
              authentication: RetirementAuthentication(),
              retireBackground: background.acquire,
              quiesce: () async {
                quiesces++;
              },
              verifyOtherDataAbsent: () async {},
            );
            Map<String, String> inventory() => {
              for (final file
                  in fixture.listSync(recursive: true).whereType<File>())
                file.path: sha256.convert(file.readAsBytesSync()).toString(),
            };
            final before = inventory();
            if (mismatch) {
              expect(construct, throwsA(isA<ManagedProfileWipeFailure>()));
              expect(inventory(), before);
              expect(quiesces, 0);
              expect(background.acquires, 0);
              expect(secrets.reads, 0);
              expect(
                StorageProfileCoordinator.hasErasureIntent(profile),
                isFalse,
              );
              expect(owner.router.catalog.identities, hasLength(2));
            } else {
              job = construct();
              await job.resume();
              expect(File(source).existsSync(), isFalse);
              expect(
                sha256.convert(File(neighbor).readAsBytesSync()).toString(),
                before[neighbor],
              );
              expect(owner.router.catalog.identities, isEmpty);
              expect(
                StorageProfileCoordinator.hasErasureIntent(profile),
                isFalse,
              );
              expect(quiesces, 1);
              expect(background.releases, 1);
            }
          } finally {
            await job?.close();
            await owner?.close();
            await preferences?.releaseFile();
            final backend = SharedPreferencesStorePlatform.instance;
            if (backend is ProfilePreferencesStore) await backend.releaseFile();
            SharedPreferencesStorePlatform.instance = original;
            CaptureResourceLifetime.resetForTesting();
            fixture.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
