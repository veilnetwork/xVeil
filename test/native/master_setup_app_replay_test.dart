@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
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
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';
import '../support/erasure_writer_process.dart';
import 'support/master_setup_fixture.dart';

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
    for (final phase in [
      'prepared',
      'child-created',
      'child-known',
      'child-profile-staged',
      'roster-published',
    ]) {
      for (final childMode
          in phase == 'prepared'
              ? StorageProtection.values
              : [StorageProtection.encrypted]) {
        test(
          'AppController cold replay $phase (${mode.name}/${childMode.name})',
          () async {
            expect(ensureHiddenVolumeLoaded(), isTrue);
            SharedPreferences.setMockInitialValues({'onboarded': true});
            final directory = Directory.systemTemp.createTempSync(
              'xveil-master-journal-',
            );
            final fixture = MasterSetupFixture(
              directory,
              mode,
              childMode: childMode,
            );
            await fixture.create();
            final request =
                jsonDecode(
                      File(
                        '${directory.path}/request-private.json',
                      ).readAsStringSync(),
                    )
                    as Map;
            final rootKeys = base64.decode(request['keys'] as String);
            final password = mode == StorageProtection.unencrypted
                ? ''
                : utf8.decode(fixture.password);
            Uint8List? existingChildKeys;
            final routers = <ProfileStorageRouter>[];
            final apps = <ProviderContainer>[];
            Future<ProfileStorageRouter> open() async {
              final router = await ProfileStorageRouter.open(
                profileDirectory: fixture.profile,
                legacyPath: fixture.legacy,
                legacyFactory: () => HiddenVolumeStorage(
                  hvSpaceOpener(
                    fixture.legacy,
                    argon: hv.ArgonPreset.min,
                    paddingPreset: hv.PaddingPreset.none,
                  ),
                  keysOpener: hvKeysSpaceOpener(fixture.legacy),
                ),
              );
              routers.add(router);
              return router;
            }

            Future<(ProviderContainer, _Node)> app(
              ProfileStorageRouter router,
            ) async {
              final node = _Node();
              final container = ProviderContainer(
                overrides: [
                  profileStorageRouterProvider.overrideWithValue(router),
                  singleSpaceStorageProvider.overrideWith((ref) {
                    ref.watch(storageRouteRevisionProvider);
                    return router.storage;
                  }),
                  nodeControllerProvider.overrideWithValue(node),
                ],
              );
              apps.add(container);
              container.read(appControllerProvider);
              await container.read(prefsProvider.future);
              return (container, node);
            }

            try {
              await killErasureWriter(
                directory.path,
                phase,
                () {},
                script: 'test/native/master_setup_journal_writer.dart',
                writerArguments: [mode.name],
              );
              if (phase != 'prepared') {
                final owner = ManagedDirectoryCatalog.openExisting(
                  fixture.profile,
                )!;
                try {
                  final child = ManagedIdentityFiles.openWithPassword(
                    owner,
                    id: fixture.id('b'),
                    password: fixture.childPassword,
                  );
                  try {
                    existingChildKeys = child.exportKeys();
                    if (phase == 'roster-published') {
                      final later = HiddenVolumeStorage.fromStore(child);
                      try {
                        await later.saveProfile(
                          const UserProfile(displayName: 'newer name'),
                        );
                        await later.putSetting('newer-data', 'preserve');
                      } finally {
                        await later.close();
                      }
                    }
                  } finally {
                    child.close();
                  }
                } finally {
                  owner.close();
                }
              }
              final router = await open();
              await router.select(fixture.root);
              final (container, node) = await app(router);
              final controller = container.read(appControllerProvider.notifier);
              await controller.unlock(password);
              expect(
                container.read(appControllerProvider).phase,
                AppPhase.identitySetupRecovery,
              );
              expect(controller.canReplayMasterSetup, isTrue);
              expect(controller.canReplayIdentitySetup, isFalse);
              expect(
                controller.setupRecoveryChildProtection,
                ['prepared', 'child-created'].contains(phase)
                    ? childMode
                    : isNull,
              );
              expect(node.starts, 0);
              if (mode != StorageProtection.unencrypted) {
                expect(
                  await controller.replayMasterSetup(
                    'incorrect master',
                    childPassword: utf8.decode(fixture.childPassword),
                  ),
                  isFalse,
                );
                expect(
                  container.read(appControllerProvider).phase,
                  AppPhase.identitySetupRecovery,
                );
                expect(node.starts, 0);
              }
              if (phase == 'child-created') {
                expect(
                  await controller.replayMasterSetup(
                    password,
                    childPassword: 'incorrect child',
                  ),
                  isFalse,
                );
                expect(router.location, fixture.root);
                expect(node.starts, 0);
              }
              expect(
                await controller.replayMasterSetup(
                  password,
                  childPassword: childMode == StorageProtection.unencrypted
                      ? ''
                      : utf8.decode(fixture.childPassword),
                ),
                isTrue,
              );
              expect(
                container.read(appControllerProvider).phase,
                AppPhase.ready,
              );
              expect(controller.activeIdentity, 'new child');
              expect(router.access, fixture.root);
              expect(router.location, fixture.child);
              expect(
                await router.storage.getSetting(kPendingIdentitySetupSetting),
                '0',
              );
              expect(
                (await router.storage.loadProfile())!.displayName,
                phase == 'roster-published' ? 'newer name' : 'new child',
              );
              if (phase == 'roster-published') {
                expect(
                  await router.storage.getSetting('newer-data'),
                  'preserve',
                );
              }
              expect(await router.storage.loadRoster(), isNull);
              if (existingChildKeys != null) {
                final actual = await router.storage.exportSpaceKeys();
                try {
                  expect(actual, existingChildKeys);
                } finally {
                  actual.fillRange(0, actual.length, 0);
                }
              }
              await controller.lock();
              await router.close();
              container.dispose();
              apps.remove(container);
              final coldRouter = await open();
              await coldRouter.select(fixture.root);
              final (cold, _) = await app(coldRouter);
              final coldController = cold.read(appControllerProvider.notifier);
              await coldController.unlock(password);
              expect(
                cold.read(appControllerProvider).phase,
                AppPhase.pickingIdentity,
              );
              expect(cold.read(appControllerProvider).identities, [
                'original identity',
                'new child',
              ]);
              await coldController.pickIdentity('original identity');
              expect(cold.read(appControllerProvider).phase, AppPhase.ready);
              expect(
                await coldRouter.storage.getSetting('fixture'),
                'original payload',
              );
              await coldController.pickIdentity('new child');
              expect(cold.read(appControllerProvider).phase, AppPhase.ready);
              expect(coldRouter.location, fixture.child);
            } finally {
              for (final container in apps.reversed) {
                await container.read(appControllerProvider.notifier).lock();
                container.dispose();
              }
              for (final router in routers.reversed) {
                await router.close();
              }
              rootKeys.fillRange(0, rootKeys.length, 0);
              existingChildKeys?.fillRange(0, existingChildKeys.length, 0);
              directory.deleteSync(recursive: true);
            }
          },
        );
      }
    }
  }
}
