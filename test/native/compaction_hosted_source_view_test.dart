@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/multi_space_store.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/compaction_profile_authorization.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/multi_identity_session.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';
import '../support/fake_multi_space.dart';
import 'support/compaction_profile_fixture.dart';

class _HostedLegacy extends MultiIdentitySession {
  _HostedLegacy(this.active, {required this.confirmed})
    : super(
        SyncWrappedAsyncMultiSpaceBacking(FakeMultiSpaceBacking()),
        runtimeDirBase: '/private/tmp/xveil-hosted-compaction-unused',
        listenPortBase: 19000,
      );
  final Storage active;
  bool confirmed;
  @override
  Storage? storageFor(String label) => active;
  @override
  bool get containerLockReleased => confirmed && super.containerLockReleased;
  @override
  Future<void> disposeAll() async {
    if (!confirmed) return;
    await active.close();
    await super.disposeAll();
  }

  Future<void> forceClose() async {
    confirmed = true;
    await disposeAll();
  }
}

class _Controller extends AppController {
  _Controller({this.recoverNormally = false});
  final bool recoverNormally;

  @override
  AppState build() => const AppState(AppPhase.ready);
  // Supply the actual active child's legacy classification without booting
  // nodes in this host-native test. After session teardown use the real router.
  @override
  bool get usesManagedStorage =>
      ref.read(sessionProvider) == null ? super.usesManagedStorage : false;
  @override
  Future<void> unlock(String password) async {
    if (recoverNormally) return super.unlock(password);
    state = const AppState(AppPhase.ready);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  if (Platform.isWindows) {
    test(
      'hosted mixed publication requires source durability',
      () {},
      skip: 'Windows source-name durability is unimplemented',
    );
    return;
  }
  for (final publish in [false, true]) {
    for (final (confirmed, failSourceSelection) in [
      (true, false),
      (false, false),
      (true, true),
    ]) {
      test(
        failSourceSelection
            ? publish
                  ? 'failed source selection restores the original master before compaction'
                  : 'failed password collection lets its caller restore the master'
            : 'hosted legacy source selected only after release (publish=$publish confirmed=$confirmed)',
        () async {
          if (failSourceSelection) {
            SharedPreferences.setMockInitialValues({'keep_all_online': false});
          }
          final f = CompactionProfileFixture();
          await f.create();
          addTearDown(f.dispose);
          final selectionError = StateError('fixture legacy selection failure');
          var failNextLegacySelection = false;
          List<int>? sourceAtRefusal;
          Future<ProfileStorageRouter> route() => ProfileStorageRouter.open(
            profileDirectory: f.profile,
            legacyFactory: () {
              if (failNextLegacySelection) {
                failNextLegacySelection = false;
                sourceAtRefusal = File(f.source).readAsBytesSync();
                throw selectionError;
              }
              return HiddenVolumeStorage.async(
                workerSpaceOpener(f.source),
                keysOpener: workerKeysSpaceOpener(f.source),
              );
            },
          );
          final router = await route();
          final access = ManagedStorageLocator(
            id: f.id(1),
            protection: StorageProtection.encrypted,
          );
          await router.select(access);
          await router.rememberAccess();
          final owner = ProfileStorageRouterOwner(router, reopen: route);
          f.owners.add(owner);
          final hosted = HiddenVolumeStorage.async(workerSpaceOpener(f.source));
          expect(await hosted.open(password: 'master-fixture'), isTrue);
          final session = _HostedLegacy(hosted, confirmed: confirmed);
          addTearDown(session.forceClose);
          final before = File(f.source).readAsBytesSync();
          final controller = _Controller(recoverNormally: failSourceSelection);
          final container = ProviderContainer(
            overrides: [
              appControllerProvider.overrideWith(() => controller),
              profileStorageRouterOwnerProvider.overrideWithValue(owner),
              singleSpaceStorageProvider.overrideWith(
                (ref) => ref.watch(profileStorageRouterProvider)!.storage,
              ),
              deniableBootProvider.overrideWithValue(
                DeniableBootConfig(
                  runtimeDir: '${f.directory.path}/unused-runtime',
                  storePath: f.source,
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          container.read(appControllerProvider);
          container.read(sessionProvider.notifier).state = session;
          container.read(activeIdentityProvider.notifier).state =
              'master-fixture';
          expect(controller.usesManagedStorage, isFalse);
          expect(
            router.location,
            access,
          ); // Hosted views deliberately bypass this facade.
          if (failSourceSelection && !publish) {
            final lease = controller.leaseIdentity();
            failNextLegacySelection = true;
            expect(await controller.beginCompactionCollection(), isFalse);
            expect(sourceAtRefusal, before);
            await controller.recoverCompactionCollection(
              lease: lease,
              reopenWith: 'visible-fixture',
            );
            final recovered = container.read(appControllerProvider);
            expect(recovered.phase, AppPhase.pickingIdentity);
            expect(recovered.identities, ['child-fixture', 'master-fixture']);
            await controller.lock();
          } else if (publish) {
            final authority = CompactionProfileAuthorization(
              controller.compactionVisibleIdentities,
            );
            addTearDown(authority.dispose);
            for (final identity in authority.identities) {
              authority.authorize(
                identity,
                f.keys[identity.id]!,
                plaintextApproved:
                    identity.protection == StorageProtection.unencrypted,
              );
            }
            final roster = CompactionRoster();
            for (final entry in f.old.entries) {
              roster.addUnlocked(
                entry.key,
                passwordBytes: utf8.encode(entry.key),
                spaceKeys: entry.value,
              );
            }
            failNextLegacySelection = failSourceSelection;
            final operation = controller.compactStorageKeepingWithProfile(
              roster: roster,
              reopenWith: 'visible-fixture',
              profileAuthorization: authority,
            );
            if (failSourceSelection) {
              await expectLater(operation, throwsA(same(selectionError)));
              expect(router.access, access);
              final recovered = container.read(appControllerProvider);
              expect(recovered.phase, AppPhase.pickingIdentity);
              expect(recovered.identities, ['child-fixture', 'master-fixture']);
              expect(sourceAtRefusal, before);
              await controller.lock();
            } else if (confirmed) {
              final result = await operation;
              expect(result.after, greaterThan(0));
              expect(owner.router.access, access);
              expect(owner.router.location, const LegacyStorageLocator());
            } else {
              await expectLater(operation, throwsStateError);
              expect(File(f.source).readAsBytesSync(), before);
            }
          } else {
            expect(await controller.beginCompactionCollection(), confirmed);
            if (confirmed) {
              expect(owner.router.location, const LegacyStorageLocator());
              expect(owner.router.access, access);
              final probe = await controller.probeCompactionIdentity(
                'master-fixture',
              );
              expect(probe.opened, isTrue);
              expect(probe.spaceKeys, f.old['master-fixture']);
            } else {
              expect(owner.router.location, access);
              expect(hosted.isOpen, isTrue);
              expect(File(f.source).readAsBytesSync(), before);
            }
          }
          await session.forceClose();
          await owner.close();
          await f.verify(
            published: publish && confirmed && !failSourceSelection,
          );
        },
      );
    }
  }
}
