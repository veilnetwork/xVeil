@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/core/startup_unlock_consent.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/profile_preferences.dart';
import 'package:xveil/data/storage/profile_preferences_bootstrap.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/domain/storage_locator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final operation in ['managed-off', 'legacy-on', 'legacy-off']) {
    test(
      'scoped consent survives native preference-file reopen ($operation)',
      () async {
        final original = SharedPreferencesStorePlatform.instance;
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-consent-reopen-',
        );
        try {
          SharedPreferences.setMockInitialValues({
            if (operation == 'legacy-off') kStartupUnlockOptIn: true,
          });
          final platform = SharedPreferencesStorePlatform.instance;
          Future<SharedPreferences> boot() async {
            SharedPreferencesStorePlatform.instance = platform;
            final result = await bootstrapProfilePreferences(
              supportDir: () async => fixture.path,
              args: const [],
              environment: const {},
              managedStorage: true,
            );
            expect(result.erasurePending, isFalse);
            return profilePreferences();
          }

          final prefs = await boot();
          final root = ManagedDirectoryCatalog.createOrOpen(
            '${fixture.path}/visible-storage',
          );
          late List<ManagedStorageLocator> entries;
          try {
            for (final n in [1, 2]) {
              ManagedIdentityFiles.createEncrypted(
                root,
                id: ManagedIdentityId('$n' * 32),
                password: Uint8List.fromList('synthetic password $n'.codeUnits),
              ).close();
            }
            entries = [
              for (final entry in root.snapshot().catalog.identities)
                entry.locator,
            ];
          } finally {
            root.close();
          }
          final a = entries[0], b = entries[1];
          if (operation == 'managed-off') {
            expect(await setStartupUnlockConsent(prefs, a), isTrue);
            expect(await setStartupUnlockConsent(prefs, b), isTrue);
          }
          expect(await clearStartupUnlockConsent(prefs, a), isTrue);
          if (operation == 'legacy-on') {
            expect(
              await setStartupUnlockConsent(
                prefs,
                const LegacyStorageLocator(),
                managedSiblings: entries,
              ),
              isTrue,
            );
          } else if (operation == 'legacy-off') {
            expect(
              await clearStartupUnlockConsent(
                prefs,
                const LegacyStorageLocator(),
                managedSiblings: entries,
              ),
              isTrue,
            );
          }
          await ProfilePreferencesLifetime.current().releaseFile();
          final reopened = await boot();
          expect(startupUnlockConsented(reopened, a), isFalse);
          expect(startupUnlockConsented(reopened, b), operation != 'legacy-on');
          expect(
            startupUnlockConsented(reopened, const LegacyStorageLocator()),
            operation == 'legacy-on',
          );
          expect(reopened.getBool(startupUnlockConsentKey(a)), isFalse);
          expect(
            reopened.getBool(startupUnlockConsentKey(b)),
            operation != 'legacy-on',
          );
        } finally {
          final current = SharedPreferencesStorePlatform.instance;
          if (current is ProfilePreferencesStore) await current.releaseFile();
          SharedPreferencesStorePlatform.instance = original;
          fixture.deleteSync(recursive: true);
        }
      },
    );
  }
}
