@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/storage/worker_multi_space.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';
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

class _Transport implements VeilTransport {
  final _inbound = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (masterMode, allOnline) in [
    (StorageProtection.hidden, false),
    (StorageProtection.encrypted, false),
    (StorageProtection.unencrypted, false),
    (StorageProtection.encrypted, true),
  ]) {
    test(
      'mixed roster, edits and cold access; master=${masterMode.name}, allOnline=$allOnline',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        SharedPreferences.setMockInitialValues({});
        final masterPassword = masterMode == StorageProtection.unencrypted
            ? ''
            : 'synthetic master password';
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-master-route-',
        );
        final profile = '${fixture.path}/profile';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        final legacyPath = '$profile/legacy.hv';
        final routers = <ProfileStorageRouter>[];
        final containers = <ProviderContainer>[];
        final keys = <Uint8List>[];
        Future<ProfileStorageRouter> open() async {
          final router = await ProfileStorageRouter.open(
            profileDirectory: profile,
            legacyFactory: () => HiddenVolumeStorage(
              hvSpaceOpener(
                legacyPath,
                argon: hv.ArgonPreset.min,
                paddingPreset: hv.PaddingPreset.none,
              ),
              keysOpener: hvKeysSpaceOpener(legacyPath),
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
              if (allOnline)
                deniableBootProvider.overrideWithValue(
                  DeniableBootConfig(
                    runtimeDir: '${fixture.path}/unused-runtime',
                    storePath: legacyPath,
                  ),
                ),
              if (allOnline)
                sessionBuilderProvider.overrideWithValue(
                  ({
                    required storePath,
                    required runtimeDir,
                    required listenPort,
                    required peersFor,
                    obfs4Psk,
                    required udpReflectors,
                    required lazyMining,
                    required proxy,
                    required paddingPreset,
                  }) => MultiIdentitySession(
                    WorkerMultiSpaceBacking(
                      storePath,
                      paddingPreset: hv.PaddingPreset.none,
                    ),
                    managedProfileDirectory: profile,
                    runtimeDirBase: runtimeDir,
                    listenPortBase: listenPort,
                    boot: (_, _) async {
                      final transport = _Transport();
                      return IdentityNode(
                        transport: transport,
                        dispose: transport.dispose,
                      );
                    },
                  ),
                ),
            ],
          );
          containers.add(container);
          container
              .read(appControllerProvider.notifier)
              .debugDeniableStackStarter = (_) async => throw StateError(
            'synthetic stand disables single-node network boot',
          );
          await container.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          return container;
        }

        try {
          final live = await open();
          final rows = <RosterEntry>[];
          for (final mode in StorageProtection.values) {
            await live.create(mode);
            expect(
              await live.storage.open(
                password: 'synthetic child password',
                createIfMissing: true,
              ),
              isTrue,
            );
            await live.storage.saveProfile(UserProfile(displayName: mode.name));
            await live.storage.putSetting('owner', mode.name);
            if (mode == StorageProtection.hidden) {
              await live.storage.putSetting('storage.autocompact.v1', '1');
            }
            final exported = await live.storage.exportSpaceKeys();
            keys.add(exported);
            rows.add(
              RosterEntry(
                label: mode.name,
                spaceKeys: exported,
                storageLocator: live.location,
              ),
            );
          }
          await live.create(masterMode);
          final masterLocator = live.location;
          expect(
            await live.storage.open(
              password: masterPassword,
              createIfMissing: true,
            ),
            isTrue,
          );
          await live.storage.saveRoster(rows);
          await live.storage.putSetting('master-fixture', 'preserve');
          await live.rememberAccess();
          await live.storage.close();
          final container = await app(live);
          final controller = container.read(appControllerProvider.notifier);
          if (masterMode == StorageProtection.hidden) {
            expect(
              await controller.selectStorageIdentity(masterLocator),
              isTrue,
            );
          }
          await controller.unlock(masterPassword);
          expect(
            container.read(appControllerProvider).phase,
            allOnline ? AppPhase.ready : AppPhase.pickingIdentity,
          );
          for (final row in rows) {
            await controller.pickIdentity(row.label);
            expect(container.read(appControllerProvider).phase, AppPhase.ready);
            expect(controller.activeIdentity, row.label);
            expect(
              container
                  .read(screenLockProvider.notifier)
                  .tryUnlock(masterPassword),
              isTrue,
            );
            expect(controller.usesManagedStorage, row.label != 'hidden');
            if (!allOnline) expect(live.location, row.storageLocator);
            expect(live.access, masterLocator);
            expect(container.read(storageAccessLocatorProvider), masterLocator);
            expect(
              await container.read(storageProvider).getSetting('owner'),
              row.label,
            );
            expect(await container.read(storageProvider).loadRoster(), isNull);
            if (row.label == 'hidden') {
              expect(
                await container
                    .read(storageProvider)
                    .getSetting('storage.autocompact.v1'),
                '0',
              );
            }
          }
          expect(
            await controller.setIdentityAnonymous('encrypted', true),
            isTrue,
          );
          expect(container.read(appControllerProvider).phase, AppPhase.ready);
          expect(controller.activeIdentity, 'unencrypted');
          expect(controller.isIdentityAnonymous('encrypted'), isTrue);
          expect(
            await container.read(storageProvider).getSetting('owner'),
            'unencrypted',
          );
          expect(await controller.unbindIdentity('encrypted'), isTrue);
          expect(container.read(appControllerProvider).identities, [
            'hidden',
            'unencrypted',
          ]);
          expect(live.access, masterLocator);
          expect(
            await controller.bindExistingIdentity(
              identityPassword: 'wrong synthetic password',
              label: 'encrypted-again',
              identityStorageLocator: rows[1].storageLocator,
            ),
            isFalse,
          );
          expect(container.read(appControllerProvider).phase, AppPhase.ready);
          if (allOnline) {
            expect(
              container.read(sessionProvider),
              isNotNull,
              reason: 'a rejected bind must restore every hosted identity',
            );
          }
          expect(
            await controller.bindExistingIdentity(
              identityPassword: 'synthetic child password',
              label: 'encrypted-again',
              identityStorageLocator: rows[1].storageLocator,
            ),
            isTrue,
          );
          expect(
            await controller.bindExistingIdentity(
              identityPassword: 'synthetic child password',
              label: 'duplicate',
              identityStorageLocator: rows[1].storageLocator,
            ),
            isFalse,
          );
          expect(container.read(appControllerProvider).phase, AppPhase.ready);
          await controller.switchIdentity('encrypted-again');
          expect(
            await container.read(storageProvider).getSetting('owner'),
            'encrypted',
          );
          expect(live.access, masterLocator);
          ManagedStorageLocator? fourth;
          if (allOnline) {
            final previousIds = live.catalog.identities
                .map((entry) => entry.id)
                .toSet();
            expect(
              await controller.addIdentity(
                masterPassword: masterPassword,
                label: 'fourth',
                password: '',
                protection: StorageProtection.unencrypted,
              ),
              isTrue,
            );
            fourth = live.catalog.identities
                .singleWhere((entry) => !previousIds.contains(entry.id))
                .locator;
            expect(container.read(sessionProvider), isNotNull);
            expect(controller.activeIdentity, 'fourth');
            expect(live.access, masterLocator);
          }
          await controller.lock();
          await live.close();
          container.dispose();
          containers.remove(container);
          final cold = await open();
          final coldApp = await app(cold);
          final coldController = coldApp.read(appControllerProvider.notifier);
          if (masterMode == StorageProtection.hidden) {
            expect(cold.selectionRequired, isTrue);
            expect(
              await coldController.selectStorageIdentity(masterLocator),
              isTrue,
            );
          }
          await coldController.unlock(masterPassword);
          expect(
            coldApp.read(appControllerProvider).phase,
            allOnline ? AppPhase.ready : AppPhase.pickingIdentity,
          );
          expect(coldApp.read(appControllerProvider).identities, [
            'hidden',
            'unencrypted',
            'encrypted-again',
            if (allOnline) 'fourth',
          ]);
          await coldController.pickIdentity('encrypted-again');
          expect(coldApp.read(appControllerProvider).phase, AppPhase.ready);
          expect(
            await coldApp.read(storageProvider).getSetting('owner'),
            'encrypted',
          );
          await coldController.lock();
          await cold.select(masterLocator, access: false);
          expect(await cold.storage.open(password: masterPassword), isTrue);
          expect(await cold.storage.getSetting('master-fixture'), 'preserve');
          final restored = (await cold.storage.loadRoster())!;
          expect(restored.map((r) => r.storageLocator), [
            rows[0].storageLocator,
            rows[2].storageLocator,
            rows[1].storageLocator,
            ?fourth,
          ]);
          expect(restored.every((r) => r.spaceKeys.length == 64), isTrue);
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
