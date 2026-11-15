@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';
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
  for (final mode in StorageProtection.values) {
    for (final hasRoster in [true, false]) {
      test(
        'native pending master preserves data (${mode.name}, roster=$hasRoster)',
        () async {
          expect(ensureHiddenVolumeLoaded(), isTrue);
          SharedPreferences.setMockInitialValues({'onboarded': true});
          final directory = Directory.systemTemp.createTempSync(
            'xveil-pending-master-',
          );
          addTearDown(() {
            if (directory.existsSync()) directory.deleteSync(recursive: true);
          });
          final profile = '${directory.path}/visible-storage';
          expect(
            const ManagedFsPlatform().createPrivateDirectory(profile),
            isTrue,
          );
          final legacy = '${directory.path}/legacy.hv';
          final password = mode == StorageProtection.unencrypted
              ? ''
              : 'synthetic master password';
          final router = await ProfileStorageRouter.open(
            profileDirectory: profile,
            legacyPath: legacy,
            legacyFactory: () => HiddenVolumeStorage(
              hvSpaceOpener(
                legacy,
                argon: hv.ArgonPreset.min,
                paddingPreset: hv.PaddingPreset.none,
              ),
              keysOpener: hvKeysSpaceOpener(legacy),
            ),
          );
          ProviderContainer? app;
          Uint8List? keys;
          try {
            await router.create(mode);
            final storage = router.storage;
            expect(
              await storage.open(password: password, createIfMissing: true),
              isTrue,
            );
            keys = await storage.exportSpaceKeys();
            if (hasRoster) {
              await storage.saveRoster([
                RosterEntry(
                  label: 'preserved child reference',
                  spaceKeys: Uint8List(64)..fillRange(0, 64, 7),
                ),
              ]);
            } else {
              await storage.saveProfile(
                const UserProfile(displayName: 'preserved profile'),
              );
            }
            final marker = hasRoster ? '1' : 'future-stage';
            await storage.putSetting(kPendingMasterSetupSetting, marker);
            await storage.putSetting('fixture', 'preserve this value');
            await storage.close();
            await router.refresh();
            final catalog = router.catalog.encode();
            final node = _Node();
            app = ProviderContainer(
              overrides: [
                profileStorageRouterProvider.overrideWithValue(router),
                singleSpaceStorageProvider.overrideWithValue(storage),
                nodeControllerProvider.overrideWithValue(node),
              ],
            );
            final controller = app.read(appControllerProvider.notifier);
            await app.read(prefsProvider.future);
            await Future<void>.delayed(Duration.zero);
            await controller.unlock(password);
            expect(
              app.read(appControllerProvider).phase,
              AppPhase.identitySetupRecovery,
            );
            expect(controller.canResumeIdentitySetup, isFalse);
            expect(controller.canReplayIdentitySetup, isFalse);
            expect(node.starts, 0);
            expect(storage.isOpen, isFalse);
            expect(router.catalog.encode(), catalog);
            expect(await storage.open(password: password), isTrue);
            final actual = await storage.exportSpaceKeys();
            try {
              expect(actual, keys);
            } finally {
              actual.fillRange(0, actual.length, 0);
            }
            expect(
              await storage.getSetting(kPendingMasterSetupSetting),
              marker,
            );
            expect(await storage.getSetting('fixture'), 'preserve this value');
            expect(await storage.loadNodeConfig(), isNull);
            if (hasRoster) {
              final roster = (await storage.loadRoster())!;
              expect(roster.single.label, 'preserved child reference');
              expect(
                roster.single.spaceKeys,
                Uint8List(64)..fillRange(0, 64, 7),
              );
              for (final row in roster) {
                row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
              }
            } else {
              expect(
                (await storage.loadProfile())!.displayName,
                'preserved profile',
              );
            }
            await storage.close();
          } finally {
            app?.dispose();
            await router.close();
            keys?.fillRange(0, keys.length, 0);
          }
        },
      );
    }
  }
}
