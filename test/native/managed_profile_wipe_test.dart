@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/veil_stack.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_profile_wipe.dart';
import 'package:xveil/data/storage/profile_preferences.dart';
import 'package:xveil/data/storage/profile_preferences_bootstrap.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/data/vpn/windows_managed_vpn_backend.dart';
import 'package:xveil/data/vpn/windows_process_probe.dart';
import 'package:xveil/data/whisper_model_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/background_node_controller.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/profile_model_work.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';
import 'package:xveil/state/storage_router_providers.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/vpn_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';
import '../support/retirement_secret_store.dart';

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.locked);
}

class _Notifications extends NotificationService {
  @override
  Future<void> cancelAll() async {}
}

class _Vpn implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnknownWindowsProcess extends WindowsProcessProbe {
  @override
  WindowsProcessState read(int pid) => WindowsProcessState.unknown;
}

class _Source extends InMemorySharedPreferencesStore {
  _Source(super.data) : super.withData();
  final removes = <String>[];
  Completer<void>? removeEntered, removeRelease;
  @override
  Future<bool> remove(String key) async {
    removes.add(key);
    if (removeRelease case final gate?) {
      if (!removeEntered!.isCompleted) removeEntered!.complete();
      await gate.future;
    }
    return super.remove(key);
  }
}

class _BootNode implements NodeController {
  int stops = 0;
  bool refuseStop = false;
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
  @override
  Future<void> stop() async {
    stops++;
    if (refuseStop) throw StateError('synthetic unpublished stop refusal');
  }
}

class _BootTransport implements VeilTransport {
  @override
  Future<NodeId> nodeId() async => NodeId(Uint8List(32));
  @override
  Stream<InboundMessage> messages() => const Stream.empty();
  @override
  Stream<int> sessionCount() => const Stream.empty();
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault extends RetirementSecretStore {
  int deletes = 0;
  @override
  Future<void> delete(String key, {bool biometric = false}) {
    deletes++;
    return super.delete(key, biometric: biometric);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late String legacy, profile, namespace;
  late SharedPreferencesStorePlatform original;
  late _Source source;
  late ProfileStorageRouterOwner owner;
  late ProfilePreferencesLifetime oldPreferences;
  late SharedPreferences oldView;
  late ProviderContainer app;
  late _Controller controller;
  late _Vault vault;
  late VpnBackend vpn;
  late List<ManagedStorageLocator> locators;
  bool failReopen = false;
  late Directory translationRoot;
  Completer<void>? modelGate;

  HiddenVolumeStorage legacyStorage() =>
      HiddenVolumeStorage.async(workerSpaceOpener(legacy));
  Future<ProfileStorageRouter> openRouter() => ProfileStorageRouter.open(
    profileDirectory: profile,
    legacyFactory: legacyStorage,
  );
  Future<void> blockSibling() async {
    final directory = '${fixture.path}/profiles/decoy';
    Directory(directory).createSync(recursive: true);
    StorageProfileCoordinator.forPreferences(directory).close();
    final gate = StorageProfileCoordinator.openExisting(
      '$directory/visible-storage',
      exclusive: true,
    )!;
    try {
      await ManagedRootErasure.prepareAbsent(
        gate,
        unlockScopes: StorageUnlockScopes(['c' * 64]),
      );
    } finally {
      gate.close();
    }
  }

  setUp(() async {
    original = SharedPreferencesStorePlatform.instance;
    fixture = Directory.systemTemp.createTempSync('xveil-full-profile-wipe-');
    legacy = '${fixture.path}/xveil.store';
    profile = '${fixture.path}/visible-storage';
    failReopen = false;
    translationRoot = Directory('${fixture.path}/translate');
    modelGate = null;
    await blockSibling();
    source = _Source({
      'flutter.onboarded': true,
      'flutter.locale': 'old',
      'flutter.locale.decoy': 'de',
    });
    SharedPreferencesStorePlatform.instance = source;
    final boot = await bootstrapProfilePreferences(
      supportDir: () async => fixture.path,
      args: const [],
      environment: const {},
      managedStorage: true,
    );
    expect(boot.erasurePending, isFalse);
    expect(
      (await source.getAll())['flutter.locale'],
      'old',
      reason: 'a blocked sibling retains the actual migration source',
    );
    namespace = boot.legacyPreferences!.profile;
    oldPreferences = ProfilePreferencesLifetime.current();
    oldView = await oldPreferences.preferences;
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final hidden = legacyStorage();
    expect(
      await hidden.open(
        password: 'synthetic hidden password',
        createIfMissing: true,
      ),
      isTrue,
    );
    await hidden.saveProfile(
      const UserProfile(displayName: 'Synthetic hidden'),
    );
    await hidden.close();
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    locators = [];
    try {
      for (final mode in [
        StorageProtection.encrypted,
        StorageProtection.unencrypted,
      ]) {
        final id = ManagedIdentityId(
          (mode == StorageProtection.encrypted ? '1' : '2') * 32,
        );
        final data = mode == StorageProtection.encrypted
            ? ManagedIdentityFiles.createEncrypted(
                root,
                id: id,
                password: Uint8List.fromList('synthetic password'.codeUnits),
              )
            : ManagedIdentityFiles.createUnencrypted(root, id: id);
        data.close();
        locators.add(ManagedStorageLocator(id: id, protection: mode));
      }
    } finally {
      root.close();
    }
    final router = await openRouter();
    owner = ProfileStorageRouterOwner(
      router,
      reopen: () {
        if (failReopen) throw StateError('synthetic reopen refusal');
        return openRouter();
      },
    );
    vault = _Vault();
    vpn = _Vpn();
    controller = _Controller();
    app = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(() => controller),
        profileStorageRouterOwnerProvider.overrideWithValue(owner),
        singleSpaceStorageProvider.overrideWith(
          (ref) => ref.watch(profileStorageRouterProvider)!.storage,
        ),
        quickUnlockSecretStoreProvider.overrideWithValue(vault),
        localScreenAuthenticationProvider.overrideWithValue(
          RetirementAuthentication(),
        ),
        notificationServiceProvider.overrideWithValue(_Notifications()),
        vpnBackendProvider.overrideWith((ref) => vpn),
        backgroundServiceProvider.overrideWithValue(
          BackgroundServiceActions(start: () async {}, stop: () async {}),
        ),
        whisperModelStoreProvider.overrideWithValue(
          WhisperModelStore(supportDirectory: () async => fixture),
        ),
        translationModelsRootProvider.overrideWithValue(
          () async => translationRoot,
        ),
        deniableBootProvider.overrideWithValue(
          DeniableBootConfig(
            runtimeDir: '${fixture.path}/runtime',
            storePath: legacy,
          ),
        ),
      ],
    );
    app.read(appControllerProvider);
    await app.read(prefsProvider.future);
    // Seed through the actual frontend namespace derivation, including its
    // normalized managed-root path, rather than inventing a path hash here.
    for (final locator in [const LegacyStorageLocator(), ...locators]) {
      final provider = Provider<QuickUnlockVault>(
        (ref) => quickUnlockVaultForLocator(ref, locator),
      );
      await app
          .read(provider)
          .configure(password: 'synthetic old', system: true);
    }
    expect(vault.values, hasLength(6));
  });
  tearDown(() async {
    if (modelGate != null && !modelGate!.isCompleted) modelGate!.complete();
    app.dispose();
    await owner.close();
    await oldPreferences.releaseFile();
    final backend = SharedPreferencesStorePlatform.instance;
    if (backend is ProfilePreferencesStore) await backend.releaseFile();
    SharedPreferencesStorePlatform.instance = original;
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  ManagedProfileWipe makeJob(
    Future<ManagedErasureWorker> Function(
      ManagedProfileErasureRequest request,
      bool retry,
    )
    opener,
  ) => ManagedProfileWipe.withWorkerOpenerForTesting(
    router: owner,
    preferences: oldPreferences,
    source: oldPreferences.legacyPreferences!,
    secretStore: vault,
    authentication: RetirementAuthentication(),
    quiesce: () async {}, // Locked fixture has no network/model work.
    verifyOtherDataAbsent: () async {},
    openWorker: opener,
  );

  for (final lost in ['reply', 'worker']) {
    test(
      'lost initial $lost retries the same published application intent',
      () async {
        var attempts = 0;
        late ManagedErasureBinding originalBinding;
        final job = makeJob((request, retry) async {
          final worker = retry
              ? await ManagedErasureWorker.recoverApplicationRequest(
                  profile,
                  request,
                )
              : await ManagedErasureWorker.beginApplicationProfile(
                  profileDirectory: profile,
                  profileNamespace: namespace,
                  request: request,
                  legacyPath: legacy,
                  auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
                );
          attempts++;
          final snapshot = await worker.snapshot();
          if (attempts == 1) {
            originalBinding = snapshot.binding;
            if (lost == 'reply') {
              await worker.close(); // Actual release; no payload removal.
            } else {
              worker.killReleasedWorkerForTesting();
              await expectLater(
                worker.snapshot(),
                throwsA(isA<ManagedWorkerFailure>()),
              );
            }
            throw StateError('synthetic loss before the enclosing binding');
          }
          expect(snapshot.binding.sameOperation(originalBinding), isTrue);
          return worker;
        });
        addTearDown(() async {
          try {
            await job.close();
          } catch (_) {}
        });
        final oldRecords = Map.of(vault.values);
        await expectLater(
          job.resume(),
          throwsA(isA<ManagedProfileWipeFailure>()),
        );
        expect(attempts, 1);
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
        expect(File(legacy).existsSync(), isTrue);
        expect(vault.values, oldRecords);
        await job.resume();
        expect(attempts, 2);
        expect(owner.router.catalog.identities, isEmpty);
        expect(File(legacy).existsSync(), isFalse);
        expect(vault.values, isEmpty);
      },
    );
  }

  test(
    'returned worker death before binding capture uses the retained request',
    () async {
      var opens = 0;
      final job = makeJob((request, retry) async {
        opens++;
        final worker = await ManagedErasureWorker.beginApplicationProfile(
          profileDirectory: profile,
          profileNamespace: namespace,
          legacyPath: legacy,
          request: request,
        );
        worker.killReleasedWorkerForTesting();
        await expectLater(
          worker.snapshot(),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        return worker; // The enclosing owner has no binding yet.
      });
      addTearDown(() async {
        try {
          await job.close();
        } catch (_) {}
      });
      final oldRecords = Map.of(vault.values);
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(vault.values, oldRecords);
      expect(File(legacy).existsSync(), isTrue);
      await job.resume();
      expect(opens, 1);
      expect(owner.router.catalog.identities, isEmpty);
      expect(vault.values, isEmpty);
    },
  );

  test(
    'ambiguous prepare failure cannot start a new wipe over fresh payloads',
    () async {
      final unknown = File('$profile/identities/unrecognized.data')
        ..writeAsStringSync('synthetic unowned content');
      final job = ManagedProfileWipe(
        router: owner,
        preferences: oldPreferences,
        source: oldPreferences.legacyPreferences!,
        secretStore: vault,
        authentication: RetirementAuthentication(),
        quiesce: () async {},
        verifyOtherDataAbsent: () async {},
      );
      addTearDown(() async {
        try {
          await job.close();
        } catch (_) {}
      });
      final oldRecords = Map.of(vault.values);
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      expect(unknown.readAsStringSync(), 'synthetic unowned content');
      unknown.deleteSync(); // Only the fixture resolves its unknown object.
      File(legacy).writeAsStringSync('synthetic newly appearing data');
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          job.resume(),
          throwsA(isA<ManagedProfileWipeFailure>()),
        );
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
        expect(
          File(legacy).readAsStringSync(),
          'synthetic newly appearing data',
        );
        expect(vault.values, oldRecords);
      }
    },
  );

  test(
    'same live wipe resumes after worker death with accepted source work',
    () async {
      late ManagedErasureWorker worker;
      final job = makeJob(
        (request, retry) async =>
            worker = await ManagedErasureWorker.beginApplicationProfile(
              profileDirectory: profile,
              profileNamespace: namespace,
              request: request,
              legacyPath: legacy,
              auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
            ),
      );
      addTearDown(() async {
        try {
          await job.close();
        } catch (_) {}
      });
      source.removeEntered = Completer<void>();
      source.removeRelease = Completer<void>();
      var returned = false;
      final failed = expectLater(
        job.resume().whenComplete(() => returned = true),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      await source.removeEntered!.future;
      worker.killReleasedWorkerForTesting();
      expect(returned, isFalse);
      expect(File(legacy).existsSync(), isTrue);
      source.removeRelease!.complete();
      await failed;
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
      await job.resume();
      expect(owner.router.catalog.identities, isEmpty);
      expect(File(legacy).existsSync(), isFalse);
      expect(vault.values, isEmpty);
      expect((await source.getAll())['flutter.locale'], isNull);
      expect((await source.getAll())['flutter.locale.decoy'], 'de');
    },
  );

  test(
    'lost release reply resumes read-only without repeating OS deletion',
    () async {
      final gate = ReceivePort();
      addTearDown(gate.close);
      late ManagedErasureWorker worker;
      final job = makeJob(
        (request, retry) async =>
            worker = await ManagedErasureWorker.beginWithReleaseGateForTesting(
              profileDirectory: profile,
              profileNamespace: namespace,
              applicationRequest: request,
              legacyPath: legacy,
              auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
              afterNativeRelease: gate.sendPort,
            ),
      );
      addTearDown(() async {
        try {
          await job.close();
        } catch (_) {}
      });
      final failed = expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(await gate.first, isA<SendPort>());
      final deletes = vault.deletes, removes = source.removes.length;
      expect(File(legacy).existsSync(), isFalse);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      worker.killReleasedWorkerForTesting();
      await failed;
      await job.resume();
      expect(owner.router.catalog.identities, isEmpty);
      expect(vault.deletes, deletes);
      expect(source.removes.length, removes);
      expect(vault.values, isEmpty);
      expect((await source.getAll())['flutter.locale.decoy'], 'de');
    },
  );

  test(
    'same live worker rechecks OS absence after failed final sync',
    () async {
      final key = vault.values.keys.first;
      late ManagedErasureWorker worker;
      final job = makeJob(
        (request, retry) async => worker =
            await ManagedErasureWorker.beginWithFinalSyncFailureForTesting(
              profileDirectory: profile,
              profileNamespace: namespace,
              applicationRequest: request,
              legacyPath: legacy,
              auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
            ),
      );
      addTearDown(() async {
        try {
          await job.close();
        } catch (_) {}
      });
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(worker.exitedUnexpectedly, isFalse);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      vault.values[key] = 'synthetic newly appeared';
      final deletes = vault.deletes;
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(vault.values[key], 'synthetic newly appeared');
      expect(vault.deletes, deletes);
      expect(() => owner.router, throwsStateError);
      vault.values.remove(key); // Fixture resolution, not recovery deletion.
      await job.resume();
      expect(owner.router.catalog.identities, isEmpty);
      expect(vault.deletes, deletes);
    },
  );

  for (final stage in [
    ManagedErasureFinishStage.completionPublished,
    ManagedErasureFinishStage.planRemoved,
    ManagedErasureFinishStage.pendingRemoved,
    ManagedErasureFinishStage.completionRemoved,
  ]) {
    test('live wipe resumes a worker interrupted at ${stage.name}', () async {
      final gate = ReceivePort();
      addTearDown(gate.close);
      late ManagedErasureWorker worker;
      final job = makeJob(
        (request, retry) async =>
            worker = await ManagedErasureWorker.beginWithFinishGateForTesting(
              profileDirectory: profile,
              profileNamespace: namespace,
              applicationRequest: request,
              legacyPath: legacy,
              auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
              checkpoint: gate.sendPort,
              stage: stage,
            ),
      );
      addTearDown(() async {
        try {
          await job.close();
        } catch (_) {}
      });
      final failed = expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(await gate.first, isA<SendPort>());
      final deletes = vault.deletes, removes = source.removes.length;
      worker.killReleasedWorkerForTesting();
      await failed;
      await job.resume();
      expect(owner.router.catalog.identities, isEmpty);
      expect(File(legacy).existsSync(), isFalse);
      expect(vault.values, isEmpty);
      expect(vault.deletes, deletes);
      expect(source.removes.length, removes);
      expect((await source.getAll())['flutter.locale.decoy'], 'de');
    });
  }

  for (final target in ['vault', 'bio', 'source', 'file']) {
    test(
      'read-only live retry preserves a new $target record until resolved',
      () async {
        final gate = ReceivePort();
        addTearDown(gate.close);
        final vaultKey = target == 'bio'
            ? vault.values.keys.firstWhere((key) => key.startsWith('true:'))
            : vault.values.keys.first;
        late ManagedErasureWorker worker;
        final job = makeJob(
          (request, retry) async => worker =
              await ManagedErasureWorker.beginWithReleaseGateForTesting(
                profileDirectory: profile,
                profileNamespace: namespace,
                applicationRequest: request,
                legacyPath: legacy,
                auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
                afterNativeRelease: gate.sendPort,
              ),
        );
        addTearDown(() async {
          try {
            await job.close();
          } catch (_) {}
        });
        final failed = expectLater(
          job.resume(),
          throwsA(isA<ManagedProfileWipeFailure>()),
        );
        expect(await gate.first, isA<SendPort>());
        worker.killReleasedWorkerForTesting();
        await failed;
        switch (target) {
          case 'vault':
          case 'bio':
            vault.values[vaultKey] = 'synthetic new secret';
          case 'source':
            await source.setValue('String', 'flutter.locale', 'new');
          case 'file':
            File(legacy).writeAsStringSync('synthetic new payload');
        }
        final deletes = vault.deletes, removes = source.removes.length;
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            job.resume(),
            throwsA(isA<ManagedProfileWipeFailure>()),
          );
          expect(() => owner.router, throwsStateError);
          expect(vault.deletes, deletes);
          expect(source.removes.length, removes);
          switch (target) {
            case 'vault':
            case 'bio':
              expect(vault.values[vaultKey], 'synthetic new secret');
            case 'source':
              expect((await source.getAll())['flutter.locale'], 'new');
            case 'file':
              expect(File(legacy).readAsStringSync(), 'synthetic new payload');
          }
        }
        // Only this fixture removes the new record; recovery must never do so.
        switch (target) {
          case 'vault':
          case 'bio':
            vault.values.remove(vaultKey);
          case 'source':
            await source.remove('flutter.locale');
          case 'file':
            File(legacy).deleteSync();
        }
        final afterResolution = source.removes.length;
        await job.resume();
        expect(owner.router.catalog.identities, isEmpty);
        expect(vault.deletes, deletes);
        expect(source.removes.length, afterResolution);
      },
    );
  }

  test(
    'unverified Windows status cannot authorize full-profile erasure',
    () async {
      final session = Directory('${fixture.path}/vpn-request')..createSync();
      final status = File('${fixture.path}/protected-vpn-status.json');
      const token = 'synthetic valid token';
      var controls = 0;
      vpn = WindowsManagedVpnBackend.withSessionForTesting(
        directory: session,
        statusFile: status,
        token: token,
        helperPid: 77,
        processProbe: _UnknownWindowsProcess(),
        stopTimeout: Duration.zero,
        requestStop: () async => controls++,
      );
      await status.writeAsString(
        jsonEncode({'token': 'unverified', 'phase': 'stopped'}),
      );
      expect((await vpn.status()).phase, VpnBackendPhase.error);
      await expectLater(
        controller.wipeContainers(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.profileErasureRecovery,
      );
      expect(session.existsSync(), isTrue);
      expect(File(legacy).existsSync(), isTrue);
      expect(Directory('$profile/identities').existsSync(), isTrue);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      await status.writeAsString(
        jsonEncode({'token': token, 'phase': 'stopped'}),
      );
      expect(await controller.wipeContainers(), isEmpty);
      expect(controls, 2);
      expect(session.existsSync(), isFalse);
      expect(File(legacy).existsSync(), isFalse);
      expect(app.read(appControllerProvider).phase, AppPhase.onboarding);
    },
  );

  test(
    'full controller wipe erases mixed storage and publishes fresh owners only after release',
    () async {
      final oldStorage = owner.router.storage;
      addTearDown(oldStorage.close);
      expect(await controller.wipeContainers(), isEmpty);
      expect(app.read(appControllerProvider).phase, AppPhase.onboarding);
      expect(owner.router.catalog.identities, isEmpty);
      expect(File(legacy).existsSync(), isFalse);
      for (final locator in locators) {
        expect(
          Directory('$profile/identities/${locator.id.value}').existsSync(),
          isFalse,
        );
      }
      expect(vault.values, isEmpty);
      expect((await source.getAll())['flutter.locale'], isNull);
      expect((await source.getAll())['flutter.locale.decoy'], 'de');
      expect(
        await app
            .read(prefsProvider.future)
            .then((p) => p.getBool('onboarded')),
        isNull,
      );
      await expectLater(oldView.setBool('onboarded', true), throwsStateError);
      await expectLater(
        oldStorage.open(password: 'stale', createIfMissing: true),
        throwsStateError,
      );
      expect(File(legacy).existsSync(), isFalse);
      final task = app.read(profileModelWorkProvider).begin();
      expect(
        task,
        isNotNull,
        reason: 'fresh model admission is published after completion',
      );
      await task!.run(() {});
    },
  );

  test(
    'OS refusal keeps native files and a retryable recovery state',
    () async {
      vault.deniedScopes.add('');
      final hidden = File(legacy).readAsBytesSync();
      await expectLater(
        controller.wipeContainers(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(File(legacy).readAsBytesSync(), hidden);
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.profileErasureRecovery,
      );
      expect(app.read(appControllerProvider).erasureBusy, isFalse);
      await controller.unlock('synthetic hidden password');
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.profileErasureRecovery,
      );
      await expectLater(
        controller.lock(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      await expectLater(
        controller.startOver(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      vault.deniedScopes.clear();
      expect(await controller.wipeContainers(), isEmpty);
      expect(app.read(appControllerProvider).phase, AppPhase.onboarding);
      expect(vault.values, isEmpty);
    },
  );

  test(
    'accepted model work is joined before an intent or destructive cleanup',
    () async {
      final gate = modelGate = Completer<void>();
      final task = app.read(profileModelWorkProvider).begin()!;
      final running = task.run(() => gate.future);
      final wiping = controller.wipeContainers();
      await Future<void>(() {});
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.profileErasureRecovery,
      );
      expect(File(legacy).existsSync(), isTrue);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      expect(vault.values, isNotEmpty);
      expect(app.read(profileModelWorkProvider).begin(), isNull);
      gate.complete();
      await running;
      expect(await wiping, isEmpty);
    },
  );

  test(
    'unowned runtime residue refuses before intent and retry rechecks absence',
    () async {
      final runtime = Directory('${fixture.path}/runtime')..createSync();
      File(
        '${runtime.path}/foreign',
      ).writeAsStringSync('synthetic unrelated data');
      await expectLater(
        controller.wipeContainers(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(File(legacy).existsSync(), isTrue);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      expect(
        File('${runtime.path}/foreign').readAsStringSync(),
        'synthetic unrelated data',
      );
      runtime.deleteSync(recursive: true);
      expect(await controller.wipeContainers(), isEmpty);
    },
  );

  Future<({Future<void> unlock, Completer<void> release, _BootNode node})>
  pendingBoot() async {
    await owner.router.select(const LegacyStorageLocator());
    final entered = Completer<void>(), release = Completer<void>();
    final node = _BootNode(), transport = _BootTransport();
    final stack = RealVeilStack.overParts(
      controller: node,
      transport: transport,
      myInvite: BootstrapInvite(publicKey: Uint8List(32), nonce: Uint8List(8)),
    );
    addTearDown(() async {
      try {
        await stack.dispose();
      } catch (_) {}
    });
    controller.debugDeniableStackStarter = (_) async {
      entered.complete();
      await release.future;
      return stack;
    };
    final unlock = controller.unlock('synthetic hidden password');
    await entered.future;
    return (unlock: unlock, release: release, node: node);
  }

  test(
    'maintenance waits for an accepted unlock through unpublished node boot',
    () async {
      final boot = await pendingBoot();
      var completed = false;
      final waiting = controller.waitForCompaction().then(
        (_) => completed = true,
      );
      try {
        // The old barrier contains only settled/null futures in this fixture.
        // One event-loop turn drains runnable microtasks; no timing threshold.
        await Future<void>(() {});
        expect(
          completed,
          isFalse,
          reason: 'an unpublished boot is still accepted work',
        );
      } finally {
        boot.release.complete();
        await Future.wait([boot.unlock, waiting]);
      }
      expect(completed, isTrue);
    },
  );

  test(
    'late rollback refusal blocks managed erasure before native intent',
    () async {
      final boot = await pendingBoot();
      boot.node.refuseStop = true;
      final wiping = controller.wipeContainers();
      final refused = expectLater(
        wiping,
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      try {
        await Future<void>(() {});
        expect(File(legacy).existsSync(), isTrue);
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      } finally {
        boot.release.complete();
        await boot.unlock;
        await refused;
      }
      expect(boot.node.stops, 1);
      expect(File(legacy).existsSync(), isTrue);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.profileErasureRecovery,
      );
    },
  );

  test('profile model ownership follows directory aliases', () async {
    final alias = Link('${fixture.path}/model-alias')..createSync(fixture.path);
    translationRoot = Directory('${alias.path}/translate');
    Directory('${translationRoot.path}/ru-en').createSync(recursive: true);
    File(
      '${translationRoot.path}/ru-en/model.bin',
    ).writeAsStringSync('synthetic model');
    expect(await controller.wipeContainers(), isEmpty);
    expect(Directory('${fixture.path}/translate').existsSync(), isFalse);
  });

  test(
    'profile-owned stale models are erased while external models remain',
    () async {
      final external = Directory.systemTemp.createTempSync(
        'xveil-external-model-',
      );
      addTearDown(() => external.deleteSync(recursive: true));
      translationRoot = external;
      File('${external.path}/model.bin').writeAsStringSync('external data');
      final owned = Directory('${fixture.path}/translate')..createSync();
      Directory('${owned.path}/ru-en').createSync();
      File(
        '${owned.path}/ru-en/model.bin',
      ).writeAsStringSync('old profile model');
      expect(await controller.wipeContainers(), isEmpty);
      expect(owned.existsSync(), isFalse);
      expect(
        File('${external.path}/model.bin').readAsStringSync(),
        'external data',
      );
    },
  );

  test(
    'fresh-router retry never repeats deletion after the native release',
    () async {
      failReopen = true;
      await expectLater(
        controller.wipeContainers(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(File(legacy).existsSync(), isFalse);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      File(legacy).writeAsStringSync('new data after completed deletion');
      failReopen = false;
      translationRoot = Directory('${fixture.path}/translate');
      expect(await controller.wipeContainers(), isEmpty);
      expect(
        File(legacy).readAsStringSync(),
        'new data after completed deletion',
      );
    },
  );
}
