@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/domain/identity_setup_intent.dart';
import 'package:xveil/data/storage/identity_setup_journal.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/state/storage_router_providers.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/providers.dart';

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

class _MutatingStore extends HvKvLogStore {
  _MutatingStore(super.space);
  bool armed = false;
  @override
  int count(int namespace) {
    if (armed && namespace == 200) {
      armed = false;
      commit([
        PutOp(Ns.contacts, Uint8List.fromList([1]), Uint8List.fromList([2])),
      ]);
    }
    return super.count(namespace);
  }
}

class _CredentialRefusal extends HiddenVolumeStorage {
  bool refuse = true;
  bool loseJournalReply = false;
  bool refuseCleanup = false;
  bool refuseProfile = false, refuseConfig = false;
  @override
  Future<void> saveProfile(UserProfile profile) async {
    if (refuseProfile) {
      throw StateError('synthetic profile write must not happen');
    }
    await super.saveProfile(profile);
  }

  @override
  Future<void> saveNodeConfig(String config) async {
    if (refuseConfig) {
      throw StateError('synthetic config write must not happen');
    }
    await super.saveNodeConfig(config);
  }

  @override
  Future<bool> tryStoreFilePair(
    StoredFileWrite prerequisite,
    StoredFileWrite publication, {
    List<String> retireHints = const [],
  }) async {
    final result = await super.tryStoreFilePair(
      prerequisite,
      publication,
      retireHints: retireHints,
    );
    if (publication.id == kIdentitySetupJournalFile && loseJournalReply) {
      loseJournalReply = false;
      throw StateError('synthetic lost journal reply');
    }
    return result;
  }

  @override
  Future<void> deleteStoredFile(String id) async {
    if (refuseCleanup && id == kIdentitySetupJournalFile) {
      throw StateError('synthetic cleanup refusal');
    }
    await super.deleteStoredFile(id);
  }

  _CredentialRefusal(String path)
    : super(
        hvSpaceOpener(
          path,
          argon: hv.ArgonPreset.min,
          paddingPreset: hv.PaddingPreset.none,
        ),
        keysOpener: hvKeysSpaceOpener(path),
      );
  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async {
    if (refuse) throw StateError('synthetic credential storage refusal');
    await super.storeFile(fileId, bytes, name: name, retireHints: retireHints);
  }
}

class _PausingProfileStorage extends HiddenVolumeStorage {
  _PausingProfileStorage(String path)
    : super(
        hvSpaceOpener(
          path,
          argon: hv.ArgonPreset.min,
          paddingPreset: hv.PaddingPreset.none,
        ),
        keysOpener: hvKeysSpaceOpener(path),
      );
  final saved = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> saveProfile(UserProfile profile) async {
    await super.saveProfile(profile);
    if (!saved.isCompleted) {
      saved.complete();
      await release.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late HiddenVolumeStorage storage;
  late ProviderContainer app;
  late _Node node;
  setUp(() async {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    SharedPreferences.setMockInitialValues({'onboarded': true});
    fixture = Directory.systemTemp.createTempSync('xveil-setup-recovery-');
    final path = '${fixture.path}/legacy.hv';
    storage = HiddenVolumeStorage(
      hvSpaceOpener(
        path,
        argon: hv.ArgonPreset.min,
        paddingPreset: hv.PaddingPreset.none,
      ),
      keysOpener: hvKeysSpaceOpener(path),
    );
    node = _Node();
    app = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => storage),
        nodeControllerProvider.overrideWithValue(node),
      ],
    );
    app.read(appControllerProvider);
    await app.read(prefsProvider.future);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    await app.read(appControllerProvider.notifier).lock();
    app.dispose();
    await storage.close();
    fixture.deleteSync(recursive: true);
  });
  test(
    'unwritten hidden space never boots an identity automatically',
    () async {
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      expect(await storage.initializationIsBlank(), isTrue);
      await storage.close();
      await app.read(appControllerProvider.notifier).unlock('fixture password');
      expect(app.read(appControllerProvider).phase, isNot(AppPhase.ready));
      expect(node.starts, 0);
    },
  );
  test(
    'a setup marker alone preserves explicit blank-space continuation',
    () async {
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      await storage.putSetting(kPendingIdentitySetupSetting, '1');
      await storage.close();
      final ctrl = app.read(appControllerProvider.notifier);
      await ctrl.unlock('fixture password');
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.identitySetupRecovery,
      );
      expect(ctrl.canResumeIdentitySetup, isTrue);
      expect(node.starts, 0);
    },
  );

  test(
    'onboarding cannot overwrite an existing master or forget its onboarding preference',
    () async {
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      final row = RosterEntry(
        label: 'preserved child',
        spaceKeys: Uint8List.fromList(List.filled(64, 7)),
      );
      await storage.saveRoster([row]);
      await storage.close();
      await expectLater(
        app
            .read(appControllerProvider.notifier)
            .completeOnboarding(
              password: 'fixture password',
              mode: StorageMode.hiddenSpace,
            ),
        throwsA(isA<ContainerAlreadyHasAnIdentity>()),
      );
      expect(node.starts, 0);
      expect(await storage.open(password: 'fixture password'), isTrue);
      expect(await storage.loadProfile(), isNull);
      expect((await storage.loadRoster())!.single.spaceKeys, row.spaceKeys);
      expect(
        (await SharedPreferences.getInstance()).getBool('onboarded'),
        isTrue,
      );
      await storage.close();
      row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
    },
  );
  test('explicit blank-space creation keeps the same storage keys', () async {
    expect(
      await storage.open(password: 'fixture password', createIfMissing: true),
      isTrue,
    );
    final keys = await storage.exportSpaceKeys();
    await storage.close();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('storage_mode', StorageMode.plain.name);
    final ctrl = app.read(appControllerProvider.notifier);
    try {
      await ctrl.unlock('fixture password');
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.identitySetupRecovery,
      );
      final cached = ctrl.debugSetupRecoveryKeys!;
      expect(cached, keys);
      expect(cached, hasLength(64));
      expect(ctrl.holdsIdentity(ctrl.leaseIdentity()), isFalse);
      expect(ctrl.beginIdentitySetupRecovery(), isTrue);
      await ctrl.completeOnboarding(
        password: 'fixture password',
        mode: StorageMode.hiddenSpace,
        displayName: 'Recovered',
      );
      expect(app.read(appControllerProvider).phase, AppPhase.ready);
      expect(cached, everyElement(0));
      expect(ctrl.debugSetupRecoveryKeys, isNull);
      expect(await storage.exportSpaceKeys(), keys);
      expect((await storage.loadProfile())!.displayName, 'Recovered');
      expect(await storage.getSetting(kPendingIdentitySetupSetting), '0');
      expect(prefs.getString('storage_mode'), StorageMode.plain.name);
      expect(node.starts, 1);
      await ctrl.lock();
      await ctrl.unlock('fixture password');
      expect(app.read(appControllerProvider).phase, AppPhase.ready);
    } finally {
      keys.fillRange(0, keys.length, 0);
    }
  });

  for (final mode in StorageProtection.values) {
    test(
      'blank ${mode.name} resumes in its original locator with no extra catalog entry',
      () async {
        final profile = '${fixture.path}/profile';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        final path = '$profile/hidden.hv';
        final router = await ProfileStorageRouter.open(
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
        ProviderContainer? scoped;
        Uint8List? keys;
        try {
          await router.create(mode);
          final target = router.location;
          final password = mode == StorageProtection.unencrypted
              ? ''
              : 'fixture password';
          expect(
            await router.storage.open(
              password: password,
              createIfMissing: true,
            ),
            isTrue,
          );
          keys = await router.storage.exportSpaceKeys();
          await router.rememberAccess();
          await router.storage.close();
          final catalog = router.catalog.encode();
          final localNode = _Node();
          scoped = ProviderContainer(
            overrides: [
              profileStorageRouterProvider.overrideWithValue(router),
              singleSpaceStorageProvider.overrideWith((ref) {
                ref.watch(storageRouteRevisionProvider);
                return router.storage;
              }),
              nodeControllerProvider.overrideWithValue(localNode),
            ],
          );
          final ctrl = scoped.read(appControllerProvider.notifier);
          await scoped.read(prefsProvider.future);
          await Future<void>.delayed(Duration.zero);
          await ctrl.unlock(password);
          expect(
            scoped.read(appControllerProvider).phase,
            AppPhase.identitySetupRecovery,
          );
          expect(ctrl.canResumeIdentitySetup, isTrue);
          expect(localNode.starts, 0);
          expect(ctrl.beginIdentitySetupRecovery(), isTrue);
          await ctrl.completeOnboarding(
            password: password,
            mode: StorageMode.hiddenSpace,
            protection: mode,
            displayName: 'Recovered',
          );
          expect(scoped.read(appControllerProvider).phase, AppPhase.ready);
          expect(router.location, target);
          expect(router.access, target);
          expect(await router.storage.exportSpaceKeys(), keys);
          expect(router.catalog.encode(), catalog);
          expect(localNode.starts, 1);
          await ctrl.lock();
          await ctrl.unlock(password);
          expect(scoped.read(appControllerProvider).phase, AppPhase.ready);
        } finally {
          if (scoped != null) {
            await scoped.read(appControllerProvider.notifier).lock();
            scoped.dispose();
          }
          await router.close();
          if (keys != null) keys.fillRange(0, keys.length, 0);
        }
      },
    );
  }

  test(
    'data added while the recovery screen is open refuses initialization',
    () async {
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      final keys = await storage.exportSpaceKeys();
      await storage.close();
      final ctrl = app.read(appControllerProvider.notifier);
      try {
        await ctrl.unlock('fixture password');
        expect(await storage.openWithKeys(keys), isTrue);
        await storage.putSetting('foreign fixture', 'preserve');
        await storage.close();
        expect(ctrl.beginIdentitySetupRecovery(), isTrue);
        await expectLater(
          ctrl.completeOnboarding(
            password: 'fixture password',
            mode: StorageMode.hiddenSpace,
          ),
          throwsA(isA<ContainerAlreadyHasAnIdentity>()),
        );
        expect(node.starts, 0);
        expect(ctrl.canResumeIdentitySetup, isFalse);
        expect(await storage.openWithKeys(keys), isTrue);
        expect(await storage.loadProfile(), isNull);
        expect(await storage.getSetting('foreign fixture'), 'preserve');
        await storage.close();
      } finally {
        keys.fillRange(0, keys.length, 0);
      }
    },
  );

  test(
    'the password for another blank hidden space cannot redirect recovery',
    () async {
      for (final pw in ['fixture password', 'other fixture password']) {
        expect(await storage.open(password: pw, createIfMissing: true), isTrue);
        await storage.close();
      }
      final ctrl = app.read(appControllerProvider.notifier);
      await ctrl.unlock('fixture password');
      expect(ctrl.beginIdentitySetupRecovery(), isTrue);
      await expectLater(
        ctrl.completeOnboarding(
          password: 'other fixture password',
          mode: StorageMode.hiddenSpace,
        ),
        throwsA(isA<ContainerAlreadyHasAnIdentity>()),
      );
      expect(node.starts, 0);
      expect(await storage.open(password: 'other fixture password'), isTrue);
      expect(await storage.loadProfile(), isNull);
      await storage.close();
      await ctrl.lock();
      await ctrl.unlock('fixture password');
      expect(ctrl.canResumeIdentitySetup, isTrue);
    },
  );

  test(
    'namespace inspection detects a concurrent write behind its cursor',
    () async {
      final space = hv.HvSpace.create(
        path: '${fixture.path}/probe.hv',
        password: Uint8List.fromList(utf8.encode('fixture password')),
        argon: hv.ArgonPreset.min,
      );
      space.setPaddingPolicy(hv.PaddingPreset.none);
      final backing = _MutatingStore(space);
      final probe = HiddenVolumeStorage(
        ({required password, required create}) => backing,
      );
      try {
        expect(await probe.open(password: 'fixture password'), isTrue);
        expect(await probe.initializationIsBlank(), isTrue);
        backing.armed = true;
        expect(await probe.initializationIsBlank(), isFalse);
        expect(backing.count(Ns.contacts), 1);
      } finally {
        await probe.close();
      }
    },
  );

  test(
    'unknown application records cannot authorize a fresh identity',
    () async {
      final space = hv.HvSpace.create(
        path: '${fixture.path}/unknown.hv',
        password: Uint8List.fromList(utf8.encode('fixture password')),
        argon: hv.ArgonPreset.min,
      );
      space.setPaddingPolicy(hv.PaddingPreset.none);
      final raw = HvKvLogStore(space);
      final probe = HiddenVolumeStorage(
        ({required password, required create}) => raw,
      );
      try {
        expect(await probe.open(password: 'fixture password'), isTrue);
        raw.commit([
          AppendLogOp(255, 1, Uint8List.fromList([8])),
        ]);
        expect(await probe.initializationIsBlank(), isFalse);
        expect(raw.readLog(255, 1), [8]);
      } finally {
        await probe.close();
      }
    },
  );

  test(
    'failure after profile persistence never boots an uncertified identity',
    () async {
      await storage.close();
      storage = _CredentialRefusal('${fixture.path}/partial.hv');
      // The existing provider reads this fixture's current immutable facade.
      app.invalidate(storageProvider);
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      await storage.close();
      final ctrl = app.read(appControllerProvider.notifier);
      await ctrl.unlock('fixture password');
      expect(ctrl.beginIdentitySetupRecovery(), isTrue);
      await expectLater(
        ctrl.completeOnboarding(
          password: 'fixture password',
          mode: StorageMode.hiddenSpace,
          sovereignCredential: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<StateError>()),
      );
      expect(node.starts, 0);
      await ctrl.lock();
      await ctrl.unlock('fixture password');
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.identitySetupRecovery,
      );
      expect(ctrl.canResumeIdentitySetup, isFalse);
      expect(ctrl.beginIdentitySetupRecovery(), isFalse);
      expect(node.starts, 0);
    },
  );
  test(
    'onboarding snapshots the borrowed credential before its first await',
    () async {
      await storage.close();
      final gated = _PausingProfileStorage('${fixture.path}/owned.hv');
      storage = gated;
      app.invalidate(storageProvider);
      final caller = Uint8List.fromList([1, 2, 3]);
      final future = app
          .read(appControllerProvider.notifier)
          .completeOnboarding(
            password: 'fixture password',
            mode: StorageMode.hiddenSpace,
            sovereignCredential: caller,
          );
      try {
        await gated.saved.future;
        caller.fillRange(0, caller.length, 0);
      } finally {
        gated.release.complete();
      }
      await future;
      expect(await storage.loadFile(kSovereignBundleSetting), [1, 2, 3]);
    },
  );

  test(
    'lock during an accepted profile save retires recovery and prevents boot',
    () async {
      await storage.close();
      final gated = _PausingProfileStorage('${fixture.path}/locked.hv');
      storage = gated;
      app.invalidate(storageProvider);
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      await storage.close();
      final ctrl = app.read(appControllerProvider.notifier);
      await ctrl.unlock('fixture password');
      final cached = ctrl.debugSetupRecoveryKeys!;
      expect(ctrl.beginIdentitySetupRecovery(), isTrue);
      final attempt = ctrl.completeOnboarding(
        password: 'fixture password',
        mode: StorageMode.hiddenSpace,
      );
      final refused = expectLater(attempt, throwsA(isA<StateError>()));
      await gated.saved.future;
      final locking = ctrl.lock();
      gated.release.complete();
      await Future.wait([refused, locking]);
      expect(app.read(appControllerProvider).phase, AppPhase.locked);
      expect(cached, everyElement(0));
      expect(node.starts, 0);
      await ctrl.unlock('fixture password');
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.identitySetupRecovery,
      );
      expect(ctrl.canResumeIdentitySetup, isFalse);
      expect(node.starts, 0);
    },
  );
  test(
    'cold replay preserves the exact original certificate after write refusal',
    () async {
      await storage.close();
      final failing = _CredentialRefusal('${fixture.path}/replay.hv');
      storage = failing;
      app.invalidate(storageProvider);
      final original = Uint8List.fromList(
        List.generate(16384, (i) => (i * 37 + 11) & 255),
      );
      final ctrl = app.read(appControllerProvider.notifier);
      await expectLater(
        ctrl.completeOnboarding(
          password: 'fixture password',
          mode: StorageMode.hiddenSpace,
          displayName: 'Preserved',
          identityPhrase: 'synthetic fixture phrase',
          sovereignCredential: original,
          nodeConfigToml: 'synthetic fixture config',
          recoveryCertificateSaved: true,
        ),
        throwsStateError,
      );
      await ctrl.lock();
      failing.refuse = false;
      expect(await storage.open(password: 'fixture password'), isTrue);
      final keys = await storage.exportSpaceKeys();
      final saved = await IdentitySetupJournal.read(storage, () {});
      try {
        expect(saved, isNotNull);
        await IdentitySetupJournal.validate(
          storage,
          saved!,
          const LegacyStorageLocator(),
          keys,
          () {},
        );
      } finally {
        saved?.destroy();
        keys.fillRange(0, keys.length, 0);
        await storage.close();
      }
      await ctrl.unlock('fixture password');
      expect(ctrl.canReplayIdentitySetup, isTrue);
      expect(ctrl.canResumeIdentitySetup, isFalse);
      expect(node.starts, 0);
      expect(await ctrl.replayIdentitySetup('wrong fixture'), isFalse);
      expect(await ctrl.replayIdentitySetup('fixture password'), isTrue);
      expect(app.read(appControllerProvider).phase, AppPhase.ready);
      expect(await storage.loadFile(kSovereignBundleSetting), original);
      expect(await storage.loadNodeConfig(), 'synthetic fixture config');
      expect((await storage.loadProfile())!.displayName, 'Preserved');
      expect(await storage.getSetting(kRecoveryCertificateSavedSetting), '1');
      expect(await storage.getSetting(kPendingIdentitySetupSetting), '0');
      expect(await storage.hasFile(kIdentitySetupJournalFile), isFalse);
      expect(await storage.hasFile(kIdentitySetupCredentialFile), isFalse);
      expect(ctrl.takePendingIdentityPhrase(), 'synthetic fixture phrase');
      expect(node.starts, 1);
      original.fillRange(0, original.length, 0);
    },
  );

  test(
    'a lost atomic journal reply immediately exposes durable replay',
    () async {
      await storage.close();
      final failing = _CredentialRefusal('${fixture.path}/lost.hv')
        ..refuse = false
        ..loseJournalReply = true;
      storage = failing;
      app.invalidate(storageProvider);
      final ctrl = app.read(appControllerProvider.notifier);
      await expectLater(
        ctrl.completeOnboarding(
          password: 'fixture password',
          mode: StorageMode.hiddenSpace,
          sovereignCredential: Uint8List.fromList([7, 8, 9]),
        ),
        throwsStateError,
      );
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.identitySetupRecovery,
      );
      expect(ctrl.canReplayIdentitySetup, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool('onboarded'),
        isTrue,
      );
      expect(node.starts, 0);
      expect(await ctrl.replayIdentitySetup('fixture password'), isTrue);
      expect(await storage.loadFile(kSovereignBundleSetting), [7, 8, 9]);
      expect(node.starts, 1);
    },
  );

  test(
    'cleanup failure preserves an ordinary ready identity and retries on cold entry',
    () async {
      await storage.close();
      final failing = _CredentialRefusal('${fixture.path}/cleanup.hv')
        ..refuse = false
        ..refuseCleanup = true;
      storage = failing;
      app.invalidate(storageProvider);
      final ctrl = app.read(appControllerProvider.notifier);
      await ctrl.completeOnboarding(
        password: 'fixture password',
        mode: StorageMode.hiddenSpace,
        sovereignCredential: Uint8List.fromList([7, 8, 9]),
      );
      expect(app.read(appControllerProvider).phase, AppPhase.ready);
      expect(await storage.hasFile(kIdentitySetupJournalFile), isTrue);
      expect(await storage.hasFile(kIdentitySetupCredentialFile), isFalse);
      expect(await storage.loadFile(kSovereignBundleSetting), [7, 8, 9]);
      await ctrl.lock();
      failing.refuseCleanup = false;
      await ctrl.unlock('fixture password');
      expect(app.read(appControllerProvider).phase, AppPhase.ready);
      expect(await storage.hasFile(kIdentitySetupJournalFile), isFalse);
      expect(await storage.loadFile(kSovereignBundleSetting), [7, 8, 9]);
    },
  );

  test(
    'lock during accepted replay prevents late boot and preserves the next retry',
    () async {
      await storage.close();
      final gated = _PausingProfileStorage('${fixture.path}/replay-lock.hv');
      storage = gated;
      app.invalidate(storageProvider);
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      final keys = await storage.exportSpaceKeys();
      final intent = IdentitySetupIntent.create(
        root: const LegacyStorageLocator(),
        keys: keys,
        mode: StorageMode.hiddenSpace,
        persistLegacyMode: false,
        credential: Uint8List.fromList([1, 2, 3]),
      );
      try {
        await IdentitySetupJournal.save(storage, intent, () {});
        await storage.close();
        final ctrl = app.read(appControllerProvider.notifier);
        await ctrl.unlock('fixture password');
        final authority = ctrl.debugSetupRecoveryKeys!;
        expect(ctrl.canReplayIdentitySetup, isTrue);
        final pending = ctrl.replayIdentitySetup('fixture password');
        await gated.saved.future;
        final locking = ctrl.lock();
        gated.release.complete();
        expect(await pending, isFalse);
        await locking;
        expect(app.read(appControllerProvider).phase, AppPhase.locked);
        expect(authority, everyElement(0));
        expect(node.starts, 0);
        await ctrl.unlock('fixture password');
        expect(ctrl.canReplayIdentitySetup, isTrue);
        expect(await ctrl.replayIdentitySetup('fixture password'), isTrue);
        expect(await storage.loadFile(kSovereignBundleSetting), [1, 2, 3]);
        expect(node.starts, 1);
      } finally {
        intent.destroy();
        keys.fillRange(0, keys.length, 0);
      }
    },
  );

  test(
    'a changed profile after showing replay cannot be overwritten by stale consent',
    () async {
      await storage.close();
      final failing = _CredentialRefusal('${fixture.path}/stale-replay.hv');
      storage = failing;
      app.invalidate(storageProvider);
      final ctrl = app.read(appControllerProvider.notifier);
      await expectLater(
        ctrl.completeOnboarding(
          password: 'fixture password',
          mode: StorageMode.hiddenSpace,
          sovereignCredential: Uint8List.fromList([1, 2, 3]),
        ),
        throwsStateError,
      );
      expect(ctrl.canReplayIdentitySetup, isTrue);
      failing.refuse = false;
      expect(await storage.open(password: 'fixture password'), isTrue);
      await storage.saveProfile(
        const UserProfile(displayName: 'Preserve changed data'),
      );
      await storage.close();
      expect(await ctrl.replayIdentitySetup('fixture password'), isFalse);
      expect(node.starts, 0);
      expect(await storage.open(password: 'fixture password'), isTrue);
      expect(
        (await storage.loadProfile())!.displayName,
        'Preserve changed data',
      );
      expect(await storage.hasFile(kIdentitySetupJournalFile), isTrue);
      expect(await storage.hasFile(kIdentitySetupCredentialFile), isTrue);
      await storage.close();
    },
  );

  test(
    'stage two replays boot without calling any identity payload writer',
    () async {
      await storage.close();
      final guarded = _CredentialRefusal('${fixture.path}/published.hv')
        ..refuse = false;
      storage = guarded;
      app.invalidate(storageProvider);
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      final keys = await storage.exportSpaceKeys();
      final intent = IdentitySetupIntent.create(
        root: const LegacyStorageLocator(),
        keys: keys,
        mode: StorageMode.hiddenSpace,
        persistLegacyMode: false,
        displayName: 'Published',
        nodeConfig: 'synthetic config',
        credential: Uint8List.fromList([1, 2, 3]),
      );
      try {
        await IdentitySetupJournal.save(storage, intent, () {});
        await storage.saveProfile(const UserProfile(displayName: 'Published'));
        await storage.saveNodeConfig('synthetic config');
        await storage.storeFile(
          kSovereignBundleSetting,
          Uint8List.fromList([1, 2, 3]),
        );
        await storage.putSetting('synthetic newer durable state', 'preserve');
        await storage.putSetting(kPendingIdentitySetupSetting, '2');
        await storage.close();
        guarded.refuse = true;
        guarded.refuseProfile = true;
        guarded.refuseConfig = true;
        final ctrl = app.read(appControllerProvider.notifier);
        await ctrl.unlock('fixture password');
        expect(ctrl.canReplayIdentitySetup, isTrue);
        expect(await ctrl.replayIdentitySetup('fixture password'), isTrue);
        expect(app.read(appControllerProvider).phase, AppPhase.ready);
        expect(
          await storage.getSetting('synthetic newer durable state'),
          'preserve',
        );
        expect(await storage.loadFile(kSovereignBundleSetting), [1, 2, 3]);
        expect(node.starts, 1);
      } finally {
        intent.destroy();
        keys.fillRange(0, keys.length, 0);
      }
    },
  );

  test(
    'an unknown setup stage cannot boot an otherwise readable profile',
    () async {
      expect(
        await storage.open(password: 'fixture password', createIfMissing: true),
        isTrue,
      );
      await storage.saveProfile(const UserProfile(displayName: 'Preserved'));
      await storage.putSetting(kPendingIdentitySetupSetting, 'future-stage');
      await storage.close();
      final ctrl = app.read(appControllerProvider.notifier);
      await ctrl.unlock('fixture password');
      expect(
        app.read(appControllerProvider).phase,
        AppPhase.identitySetupRecovery,
      );
      expect(ctrl.canReplayIdentitySetup, isFalse);
      expect(ctrl.canResumeIdentitySetup, isFalse);
      expect(node.starts, 0);
    },
  );
}
