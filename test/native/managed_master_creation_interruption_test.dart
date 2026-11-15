@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';
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
  for (final mode in StorageProtection.values) {
    test(
      'ordinary creation journals original source before child allocation (${mode.name})',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        SharedPreferences.setMockInitialValues({});
        final dir = Directory.systemTemp.createTempSync(
          'xveil-master-interrupt-',
        );
        final profile = '${dir.path}/visible-storage';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        final path = '${dir.path}/legacy.hv';
        Storage legacy() => HiddenVolumeStorage(
          hvSpaceOpener(
            path,
            argon: hv.ArgonPreset.min,
            paddingPreset: hv.PaddingPreset.none,
          ),
          keysOpener: hvKeysSpaceOpener(path),
        );
        var armed = false;
        final creations = <IdentityStorageLocator>[];
        final router = await ProfileStorageRouter.open(
          profileDirectory: profile,
          legacyPath: path,
          legacyFactory: legacy,
          storageFactory: (location, create) {
            if (armed && create) {
              creations.add(location);
              if (creations.length == 2) {
                throw StateError('synthetic child creation refusal');
              }
            }
            return switch (location) {
              LegacyStorageLocator() => legacy(),
              ManagedStorageLocator() =>
                (create
                        ? ManagedIdentityStorage.forCreation(
                            profileDirectory: profile,
                            entry: ManagedIdentityEntry.fromLocator(location),
                          )
                        : ManagedIdentityStorage.existing(
                            profileDirectory: profile,
                            entry: ManagedIdentityEntry.fromLocator(location),
                          ))
                    .storage,
            };
          },
        );
        final app = ProviderContainer(
          overrides: [
            profileStorageRouterProvider.overrideWithValue(router),
            singleSpaceStorageProvider.overrideWith((ref) {
              ref.watch(storageRouteRevisionProvider);
              return router.storage;
            }),
            nodeControllerProvider.overrideWithValue(_Node()),
          ],
        );
        final controller = app.read(appControllerProvider.notifier);
        try {
          await app.read(prefsProvider.future);
          await controller.completeOnboarding(
            password: 'synthetic source',
            mode: StorageMode.plain,
            protection: StorageProtection.encrypted,
            displayName: 'original',
          );
          expect(app.read(appControllerProvider).phase, AppPhase.ready);
          final source = router.location;
          final sourceKeys = await router.storage.exportSpaceKeys();
          try {
            await router.storage.putSetting('source-payload', 'preserve');
            armed = true;
            expect(
              await controller.addIdentity(
                masterPassword: mode == StorageProtection.unencrypted
                    ? ''
                    : 'synthetic master',
                existingLabel: 'original',
                label: 'planned',
                password: 'synthetic child',
                protection: StorageProtection.encrypted,
                masterProtection: mode,
              ),
              isFalse,
            );
            armed = false;
            expect(creations, hasLength(2));
            expect(creations.last, isA<ManagedStorageLocator>());
            await controller.lock();
            await router.refresh();
            expect(
              router.catalog.identities.any((e) => e.locator == creations.last),
              isFalse,
            );
            await router.select(creations.first, access: false);
            expect(
              await router.storage.open(
                password: mode == StorageProtection.unencrypted
                    ? ''
                    : 'synthetic master',
              ),
              isTrue,
            );
            expect(
              await router.storage.getSetting(kPendingMasterSetupSetting),
              '1',
            );
            final intent = (await MasterSetupJournal.read(
              router.storage,
              () {},
            ))!;
            try {
              expect(intent.childKnown, isFalse);
              expect(intent.childLocator, creations.last);
              expect(intent.childLabel, 'planned');
              final rows = intent.copyBase();
              try {
                expect(rows.single.storageLocator, source);
                expect(rows.single.spaceKeys, sourceKeys);
                expect(rows.single.label, 'original');
              } finally {
                for (final row in rows) {
                  row.spaceKeys.fillRange(0, 64, 0);
                }
              }
              expect(await router.storage.loadProfile(), isNull);
              expect(await router.storage.loadRoster(), isNull);
            } finally {
              intent.destroy();
            }
            await router.storage.close();
            await router.select(source);
            expect(
              await router.storage.open(password: 'synthetic source'),
              isTrue,
            );
            expect(
              (await router.storage.loadProfile())!.displayName,
              'original',
            );
            expect(
              await router.storage.getSetting('source-payload'),
              'preserve',
            );
            final actual = await router.storage.exportSpaceKeys();
            try {
              expect(actual, sourceKeys);
            } finally {
              actual.fillRange(0, actual.length, 0);
            }
          } finally {
            sourceKeys.fillRange(0, sourceKeys.length, 0);
          }
        } finally {
          await controller.lock();
          app.dispose();
          await router.close();
          dir.deleteSync(recursive: true);
        }
      },
    );
  }
}
