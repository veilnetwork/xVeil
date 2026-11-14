@Timeout(Duration(minutes: 4))
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/identity_setup_journal.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/identity_setup_intent.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';

class _Node implements NodeController {
  int starts = 0;
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    SharedPreferences.setMockInitialValues({'onboarded': true});
  });
  for (final mode in StorageProtection.values) {
    for (var cut = 0; cut <= 4; cut++) {
      test(
        'cold ${mode.name} replay after durable checkpoint $cut retains exact identity',
        () async {
          final temp = Directory.systemTemp.createTempSync(
            'xveil-setup-journal-',
          );
          final profile = '${temp.path}/profile';
          expect(
            const ManagedFsPlatform().createPrivateDirectory(profile),
            isTrue,
          );
          final path = '$profile/hidden.hv';
          ProfileStorageRouter? router;
          ProviderContainer? app;
          Uint8List? keys;
          IdentitySetupIntent? intent;
          final bytes = Uint8List.fromList(
            List.generate(16384, (i) => (i * 53 + 7) & 255),
          );
          final password = mode == StorageProtection.unencrypted
              ? ''
              : 'synthetic setup password';
          try {
            Future<ProfileStorageRouter> openRouter() =>
                ProfileStorageRouter.open(
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
            router = await openRouter();
            await router.create(mode);
            final target = router.location;
            expect(
              await router.storage.open(
                password: password,
                createIfMissing: true,
              ),
              isTrue,
            );
            keys = await router.storage.exportSpaceKeys();
            intent = IdentitySetupIntent.create(
              root: target,
              keys: keys,
              mode: StorageMode.hiddenSpace,
              persistLegacyMode: false,
              displayName: 'Unchanged',
              credential: bytes,
              phrase: 'synthetic preserved phrase',
              restoring: true,
              joinExisting: true,
              certificateOffered: true,
              certificateSaved: true,
              nodeConfig: 'synthetic saved config',
            );
            await IdentitySetupJournal.save(router.storage, intent, () {});
            if (cut >= 1) {
              await router.storage.saveProfile(
                const UserProfile(displayName: 'Unchanged'),
              );
            }
            if (cut >= 2) {
              await router.storage.saveNodeConfig('synthetic saved config');
            }
            if (cut >= 3) {
              await router.storage.storeFile(kSovereignBundleSetting, bytes);
            }
            if (cut == 4) {
              await router.storage.putSetting(
                kRecoveryCertificateSavedSetting,
                '1',
              );
              await router.storage.putSetting(
                'synthetic data after first boot',
                'preserve',
              );
              await router.storage.putSetting(
                kPendingIdentitySetupSetting,
                '2',
              );
            }
            await router.rememberAccess();
            await router.close();
            // A NEW owner and controller: no open worker or in-memory intent survives.
            router = await openRouter();
            final actualRouter = router;
            final node = _Node();
            app = ProviderContainer(
              overrides: [
                profileStorageRouterProvider.overrideWithValue(actualRouter),
                singleSpaceStorageProvider.overrideWith((ref) {
                  ref.watch(storageRouteRevisionProvider);
                  return actualRouter.storage;
                }),
                nodeControllerProvider.overrideWithValue(node),
              ],
            );
            final ctrl = app.read(appControllerProvider.notifier);
            await app.read(prefsProvider.future);
            await Future<void>.delayed(Duration.zero);
            await ctrl.unlock(password);
            expect(
              app.read(appControllerProvider).phase,
              AppPhase.identitySetupRecovery,
            );
            expect(ctrl.canReplayIdentitySetup, isTrue);
            expect(ctrl.canResumeIdentitySetup, isFalse);
            final authority = ctrl.debugSetupRecoveryKeys!;
            expect(authority, keys);
            expect(node.starts, 0);
            final catalog = actualRouter.catalog.encode();
            expect(await ctrl.replayIdentitySetup(password), isTrue);
            expect(app.read(appControllerProvider).phase, AppPhase.ready);
            expect(authority, everyElement(0));
            expect(await actualRouter.storage.exportSpaceKeys(), keys);
            expect(actualRouter.location, target);
            expect(actualRouter.access, target);
            expect(actualRouter.catalog.encode(), catalog);
            expect(
              await actualRouter.storage.loadFile(kSovereignBundleSetting),
              bytes,
            );
            expect(
              await actualRouter.storage.loadNodeConfig(),
              'synthetic saved config',
            );
            expect(
              await actualRouter.storage.getSetting(
                kRecoveryCertificateSavedSetting,
              ),
              '1',
            );
            expect(
              await actualRouter.storage.getSetting(
                kPendingIdentitySetupSetting,
              ),
              '0',
            );
            expect(
              await actualRouter.storage.hasFile(kIdentitySetupJournalFile),
              isFalse,
            );
            expect(
              await actualRouter.storage.hasFile(kIdentitySetupCredentialFile),
              isFalse,
            );
            expect(app.read(pendingDeviceLinkProvider), isTrue);
            expect(app.read(pendingRecoveryCertificateProvider), isFalse);
            expect(
              ctrl.takePendingIdentityPhrase(),
              'synthetic preserved phrase',
            );
            expect(ctrl.takePendingRestoringIdentity(), isTrue);
            expect(node.starts, 1);
            if (cut == 4) {
              expect(
                await actualRouter.storage.getSetting(
                  'synthetic data after first boot',
                ),
                'preserve',
              );
            }
            await ctrl.lock();
            await ctrl.unlock(password);
            expect(app.read(appControllerProvider).phase, AppPhase.ready);
            expect(
              await actualRouter.storage.loadFile(kSovereignBundleSetting),
              bytes,
            );
          } finally {
            intent?.destroy();
            keys?.fillRange(0, keys.length, 0);
            bytes.fillRange(0, bytes.length, 0);
            if (app != null) {
              await app.read(appControllerProvider.notifier).lock();
              app.dispose();
            }
            await router?.close();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }

  for (final conflict in [
    'profile',
    'config',
    'credential',
    'setting',
    'owner',
  ]) {
    test(
      'replay refuses changed $conflict without erasing staged certificate',
      () async {
        final temp = Directory.systemTemp.createTempSync(
          'xveil-setup-conflict-',
        );
        final path = '${temp.path}/hidden.hv';
        final storage = HiddenVolumeStorage(
          hvSpaceOpener(
            path,
            argon: hv.ArgonPreset.min,
            paddingPreset: hv.PaddingPreset.none,
          ),
          keysOpener: hvKeysSpaceOpener(path),
        );
        ProviderContainer? app;
        IdentitySetupIntent? intent;
        Uint8List? keys;
        final original = Uint8List.fromList([1, 2, 3]);
        try {
          expect(
            await storage.open(
              password: 'synthetic root',
              createIfMissing: true,
            ),
            isTrue,
          );
          keys = await storage.exportSpaceKeys();
          intent = IdentitySetupIntent.create(
            root: const LegacyStorageLocator(),
            keys: keys,
            mode: StorageMode.hiddenSpace,
            persistLegacyMode: false,
            displayName: 'Original',
            credential: original,
          );
          await IdentitySetupJournal.save(storage, intent, () {});
          switch (conflict) {
            case 'profile':
              await storage.saveProfile(
                const UserProfile(displayName: 'Other'),
              );
            case 'config':
              await storage.saveNodeConfig('other synthetic config');
            case 'credential':
              await storage.storeFile(
                kSovereignBundleSetting,
                Uint8List.fromList([4, 5, 6]),
              );
            case 'setting':
              await storage.putSetting('unrelated synthetic data', 'preserve');
            case 'owner':
              final metadata = await storage.loadFile(
                kIdentitySetupJournalFile,
              );
              final credential = await storage.loadFile(
                kIdentitySetupCredentialFile,
              );
              try {
                await storage.close();
                expect(
                  await storage.open(
                    password: 'other synthetic root',
                    createIfMissing: true,
                  ),
                  isTrue,
                );
                await storage.putSetting(kPendingIdentitySetupSetting, '1');
                await storage.storeFile(kIdentitySetupJournalFile, metadata!);
                await storage.storeFile(
                  kIdentitySetupCredentialFile,
                  credential!,
                );
              } finally {
                metadata?.fillRange(0, metadata.length, 0);
                credential?.fillRange(0, credential.length, 0);
              }
          }
          final staged = await storage.loadFile(kIdentitySetupJournalFile);
          await storage.close();
          final node = _Node();
          app = ProviderContainer(
            overrides: [
              singleSpaceStorageProvider.overrideWithValue(storage),
              nodeControllerProvider.overrideWithValue(node),
            ],
          );
          final ctrl = app.read(appControllerProvider.notifier);
          await app.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          final pw = conflict == 'owner'
              ? 'other synthetic root'
              : 'synthetic root';
          await ctrl.unlock(pw);
          expect(ctrl.canReplayIdentitySetup, isFalse);
          expect(ctrl.canResumeIdentitySetup, isFalse);
          expect(await ctrl.replayIdentitySetup(pw), isFalse);
          expect(node.starts, 0);
          expect(await storage.open(password: pw), isTrue);
          expect(await storage.loadFile(kIdentitySetupJournalFile), staged);
          expect(
            await storage.loadFile(kIdentitySetupCredentialFile),
            original,
          );
          staged?.fillRange(0, staged.length, 0);
        } finally {
          intent?.destroy();
          keys?.fillRange(0, keys.length, 0);
          original.fillRange(0, original.length, 0);
          if (app != null) {
            await app.read(appControllerProvider.notifier).lock();
            app.dispose();
          }
          await storage.close();
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
