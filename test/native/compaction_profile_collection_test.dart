@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/domain/compaction_profile_authorization.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_compaction_policy.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/storage_router_providers.dart';

import 'support/compaction_profile_fixture.dart';
import '../support/fake_hv_container.dart';

class _Controller extends AppController {
  final reopened = <String>[];
  bool failReopen = false;
  String reopenStage = 'not-started';
  Object? reopenError;
  bool authorizationCurrent = true;
  @override
  bool holdsIdentity(IdentityLease lease) =>
      authorizationCurrent && super.holdsIdentity(lease);
  @override
  AppState build() => const AppState(AppPhase.ready);
  @override
  Future<void> unlock(String password) async {
    try {
      final router = ref.read(profileStorageRouterProvider);
      final access = router?.access;
      if (router != null && router.location != access) {
        reopenStage = 'select-access';
        await router.select(access!, access: false);
        ref.read(storageRouteRevisionProvider.notifier).state++;
        ref.invalidate(storageProvider);
      }
      final storage = ref.read(storageProvider);
      reopenStage = 'open-access';
      if (!await storage.open(password: password)) {
        throw StateError('fixture access credential refused');
      }
      reopened.add(password);
      if (failReopen) throw StateError('fixture reopen failed');
      if (access is ManagedStorageLocator) {
        reopenStage = 'read-access-roster';
        final rows = (await (storage as HiddenVolumeStorage)
            .loadRosterForMaintenance())!;
        final keys = Uint8List.fromList(
          rows.firstWhere((row) => row.label == 'master-fixture').spaceKeys,
        );
        try {
          reopenStage = 'close-access';
          await storage.close();
          reopenStage = 'select-hidden';
          await router!.select(const LegacyStorageLocator(), access: false);
          ref.read(storageRouteRevisionProvider.notifier).state++;
          ref.invalidate(storageProvider);
          reopenStage = 'open-hidden-by-updated-key';
          expect(await ref.read(storageProvider).openWithKeys(keys), isTrue);
        } finally {
          keys.fillRange(0, keys.length, 0);
        }
      }
      state = const AppState(AppPhase.ready);
    } catch (error) {
      reopenError = error;
      rethrow;
    }
  }
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _GatedProbe extends HiddenVolumeStorage {
  _GatedProbe(super.opener);
  final entered = Completer<void>(), release = Completer<void>();
  var closes = 0;
  @override
  Future<List<RosterEntry>?> loadRosterForMaintenance() async {
    final rows = await super.loadRosterForMaintenance();
    entered.complete();
    await release.future;
    return rows;
  }

  @override
  Future<void> close() {
    closes++;
    return super.close();
  }
}

Future<({ProviderContainer container, _Controller controller})> _bindProbe(
  CompactionProfileFixture f, {
  Storage Function(String profile, ManagedIdentityEntry entry)? factory,
}) async {
  Future<ProfileStorageRouter> route() => ProfileStorageRouter.open(
    profileDirectory: f.profile,
    legacyFactory: () => HiddenVolumeStorage.async(
      workerSpaceOpener(f.source),
      keysOpener: workerKeysSpaceOpener(f.source),
    ),
  );
  final owner = ProfileStorageRouterOwner(await route(), reopen: route);
  f.owners.add(owner);
  final controller = _Controller();
  final container = ProviderContainer(
    overrides: [
      appControllerProvider.overrideWith(() => controller),
      profileStorageRouterOwnerProvider.overrideWithValue(owner),
      storageProvider.overrideWith(
        (ref) => ref.watch(profileStorageRouterProvider)!.storage,
      ),
      if (factory != null)
        compactionVisibleStorageProvider.overrideWithValue(factory),
    ],
  );
  container.read(appControllerProvider);
  return (container: container, controller: controller);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    errorJournal.clear();
  });
  if (Platform.isWindows) {
    test(
      'mixed collection requires source-directory durability',
      () {},
      skip: 'Windows source-name recovery barrier is not implemented',
    );
    return;
  }
  for (final mode in [
    'success',
    'incomplete',
    'warning-reopen',
    'success-reopen',
    'pending-recovery',
    'managed-access-encrypted',
    'managed-access-plain',
    'managed-access-wrong',
  ]) {
    final incomplete = mode == 'incomplete';
    test('ordinary collection and controller publish safely ($mode)', () async {
      final f = CompactionProfileFixture();
      await f.create();
      addTearDown(f.dispose);
      if (mode == 'pending-recovery') {
        await f.seedRetainedSourceIntents();
      }
      Future<ProfileStorageRouter> route() => ProfileStorageRouter.open(
        profileDirectory: f.profile,
        legacyFactory: () => HiddenVolumeStorage.async(
          workerSpaceOpener(f.source),
          keysOpener: workerKeysSpaceOpener(f.source),
        ),
      );
      final router = await route();
      if (mode.startsWith('managed-access')) {
        await router.select(
          ManagedStorageLocator(
            id: mode == 'managed-access-plain' ? f.id(2) : f.id(1),
            protection: mode == 'managed-access-plain'
                ? StorageProtection.unencrypted
                : StorageProtection.encrypted,
          ),
        );
        await router.rememberAccess();
        await router.select(const LegacyStorageLocator(), access: false);
      }
      final owner = ProfileStorageRouterOwner(router, reopen: route);
      f.owners.add(owner);
      final controller = _Controller();
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(() => controller),
          profileStorageRouterOwnerProvider.overrideWithValue(owner),
          storageProvider.overrideWith(
            (ref) => ref.watch(profileStorageRouterProvider)!.storage,
          ),
          notificationServiceProvider.overrideWithValue(_Notifications()),
          deniableBootProvider.overrideWithValue(
            DeniableBootConfig(
              runtimeDir: '${f.directory.path}/runtime',
              storePath: f.source,
            ),
          ),
          preparedContainerCompactorProvider.overrideWithValue((
            path,
            passwords, {
            required repairMetadata,
            dylibPath,
          }) async {
            fail('mixed profile fell through to the legacy publisher');
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(appControllerProvider);
      expect(
        await container.read(storageProvider).open(password: 'master-fixture'),
        isTrue,
      );
      expect(controller.canCompactStorage, isFalse);
      expect(await controller.beginCompactionCollection(), isTrue);
      final roster = CompactionRoster();
      final authority = CompactionProfileAuthorization(
        controller.compactionVisibleIdentities,
      );
      addTearDown(authority.dispose);
      for (final identity in authority.identities) {
        if (incomplete &&
            identity.protection == StorageProtection.unencrypted) {
          continue;
        }
        final probe = await controller.probeCompactionVisibleIdentity(
          identity,
          password: identity.protection == StorageProtection.encrypted
              ? 'visible-fixture'
              : '',
          plaintextApproved:
              identity.protection == StorageProtection.unencrypted,
        );
        expect(probe, isNotNull);
        expect(probe!.keys, f.keys[identity.id]);
        expect(probe.children, hasLength(2));
        roster.expectSpaces(probe.children);
        authority.authorize(
          identity,
          probe.keys,
          plaintextApproved:
              identity.protection == StorageProtection.unencrypted,
        );
        probe.keys.fillRange(0, probe.keys.length, 0);
      }
      for (final password in ['master-fixture', 'child-fixture']) {
        final probe = await controller.probeCompactionIdentity(password);
        expect(probe.opened, isTrue);
        roster.expectSpaces(probe.children);
        roster.addUnlocked(
          password,
          passwordBytes: utf8.encode(password),
          spaceKeys: probe.spaceKeys,
        );
      }
      expect(roster.isComplete, isTrue);
      final before = File(f.source).readAsBytesSync();
      // The old public route remains guarded even with all hidden passwords.
      await expectLater(
        controller.compactStorageKeeping(
          roster: roster,
          reopenWith: 'master-fixture',
        ),
        throwsStateError,
      );
      if (incomplete) {
        expect(
          () => controller.compactStorageKeepingWithProfile(
            roster: roster,
            reopenWith: 'master-fixture',
            profileAuthorization: authority,
          ),
          throwsStateError,
        );
        expect(File(f.source).readAsBytesSync(), before);
        expect(controller.reopened, isEmpty);
        await owner.close();
        await f.verify(published: false);
      } else if (mode == 'managed-access-wrong') {
        await expectLater(
          controller.compactStorageKeepingWithProfile(
            roster: roster,
            reopenWith: 'incorrect-access-fixture',
            profileAuthorization: authority,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'bound access credential',
              'compaction access credential refused',
            ),
          ),
        );
        expect(File(f.source).readAsBytesSync(), before);
        expect(controller.reopened, isEmpty);
        await owner.close();
        await f.verify(published: false);
      } else {
        final reopen = mode == 'managed-access-plain'
            ? ''
            : mode == 'managed-access-encrypted'
            ? 'visible-fixture'
            : 'master-fixture';
        if (mode == 'warning-reopen') {
          final linked = await Process.run('/bin/ln', [
            f.source,
            '${f.source}.fixture-alias',
          ]);
          expect(linked.exitCode, 0);
        }
        controller.failReopen = mode.endsWith('reopen');
        final compacting = controller.compactStorageKeepingWithProfile(
          roster: roster,
          reopenWith: reopen,
          profileAuthorization: authority,
        );
        // A disappearing route owns/disposes its model. The accepted command
        // must already own independent snapshots, through native recovery.
        authority.dispose();
        for (final credential in roster.credentials()) {
          credential.password.fillRange(0, credential.password.length, 0);
          credential.oldSpaceKeys.fillRange(
            0,
            credential.oldSpaceKeys.length,
            0,
          );
        }
        if (controller.failReopen) {
          await expectLater(
            compacting,
            throwsA(
              isA<ManagedLegacyCompactionFailure>()
                  .having(
                    (error) => error.mayHaveApplied,
                    'publication may apply',
                    isTrue,
                  )
                  .having(
                    (error) => error.recovery,
                    'actual recovery',
                    LegacyReferenceRepairOutcome.publishedReplacement,
                  )
                  .having(
                    (error) => error.warning,
                    'native warning preserved',
                    mode == 'warning-reopen'
                        ? ManagedLegacyPublicationWarning.aliasesNotRevoked
                        : null,
                  ),
            ),
          );
        } else {
          final result = await compacting.catchError((
            Object error,
            StackTrace stack,
          ) {
            fail(
              'Unexpected operation outcome: $error; fixture ${controller.reopenStage}: ${controller.reopenError}; reopen frames: ${errorJournal.entries.where((entry) => entry.kind == 'storage-compaction-reopen').map((entry) => entry.frames).toList()}',
            );
          });
          expect(result.before, greaterThan(0));
          expect(result.after, greaterThan(0));
        }
        expect(controller.reopened, [reopen]);
        expect(
          await container.read(storageProvider).loadFile('fixture-body'),
          f.payload,
        );
        await owner.close();
        await f.verify(published: true);
      }
    });
  }
  for (final scenario in [
    'wrong-password',
    'plaintext-consent',
    'factory-failure',
    'late-lease',
  ]) {
    test(
      'visible probe refuses $scenario and releases its owned barrier',
      () async {
        final f = CompactionProfileFixture();
        await f.create();
        addTearDown(f.dispose);
        final before = File(f.source).readAsBytesSync();
        final fake = FakeHvContainer();
        final delayed = _GatedProbe(fake.passwordOpener);
        // Seed a readable, selected synthetic owner for the lease-revocation gate.
        final seed = fake.storage();
        await seed.open(password: 'probe-fixture', createIfMissing: true);
        await seed.saveRoster([]);
        await seed.close();
        addTearDown(delayed.close);
        Future<Object?>? pendingProbe;
        addTearDown(() async {
          if (!delayed.release.isCompleted) delayed.release.complete();
          try {
            await pendingProbe;
          } catch (_) {}
        });
        var failFactory = scenario == 'factory-failure';
        final binding = await _bindProbe(
          f,
          factory: scenario == 'factory-failure' || scenario == 'late-lease'
              ? (profile, entry) {
                  if (failFactory) {
                    throw StateError('fixture constructor refused');
                  }
                  if (scenario == 'late-lease') return delayed;
                  return ManagedIdentityStorage.existing(
                    profileDirectory: profile,
                    entry: entry,
                  ).storage;
                }
              : null,
        );
        addTearDown(binding.container.dispose);
        final controller = binding.controller;
        final encrypted = controller.compactionVisibleIdentities.first;
        final plain = controller.compactionVisibleIdentities.last;
        if (scenario == 'wrong-password') {
          expect(
            await controller.probeCompactionVisibleIdentity(
              encrypted,
              password: 'incorrect-fixture',
            ),
            isNull,
          );
        } else if (scenario == 'plaintext-consent') {
          await expectLater(
            controller.probeCompactionVisibleIdentity(plain),
            throwsStateError,
          );
        } else if (scenario == 'factory-failure') {
          await expectLater(
            controller.probeCompactionVisibleIdentity(
              encrypted,
              password: 'visible-fixture',
            ),
            throwsStateError,
          );
          failFactory = false;
        } else {
          final probing = controller.probeCompactionVisibleIdentity(
            encrypted,
            password: 'probe-fixture',
          );
          pendingProbe = probing;
          await delayed.entered.future;
          controller.authorizationCurrent = false;
          delayed.release.complete();
          expect(await probing, isNull);
          expect(delayed.closes, greaterThan(0));
          expect(File(f.source).readAsBytesSync(), before);
          return;
        }
        // A refused constructor/authentication cannot strand _compactionProbeInFlight.
        final retry = await controller.probeCompactionVisibleIdentity(
          encrypted,
          password: 'visible-fixture',
        );
        expect(retry, isNotNull);
        expect(retry!.keys, f.keys[encrypted.id]);
        retry.keys.fillRange(0, retry.keys.length, 0);
        expect(File(f.source).readAsBytesSync(), before);
      },
    );
  }
}
