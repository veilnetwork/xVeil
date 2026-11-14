@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import '../support/retirement_secret_store.dart';

class _Store extends RetirementSecretStore {
  int mutations = 0;
  Completer<void>? removalReadEntered, removalReadRelease;
  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    final entered = removalReadEntered, release = removalReadRelease;
    if (!biometric && entered != null && release != null) {
      removalReadEntered = null;
      entered.complete();
      await release.future;
    }
    return super.read(key, biometric: biometric);
  }

  @override
  Future<void> write(String key, String value, {bool biometric = false}) {
    mutations++;
    return super.write(key, value, biometric: biometric);
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) {
    mutations++;
    return super.delete(key, biometric: biometric);
  }
}

class _ReconcileSyncFault extends ManagedFsPlatform {
  bool refuse = true;
  int syncs = 0;
  @override
  void syncDirectory(String path) {
    syncs++;
    if (refuse) throw const ManagedFsFailure(ManagedFsFailureKind.io);
    super.syncDirectory(path);
  }
}

Future<Object?> _outcome(Future<Object?> future) =>
    future.then<Object?>((v) => v, onError: (Object e) => e);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fs = ManagedFsPlatform(), ns = 'synthetic-profile';
  late Directory fixture;
  late String profile, legacy;
  late _Store store;
  final auth = RetirementAuthentication();
  final owners = <ManagedErasureWorker>[];
  final locators = <ManagedStorageLocator>[];
  Map<String, String> files(String path) => {
    for (final f in Directory(
      path,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };
  Future<void> create({bool visible = true}) async {
    expect(fs.createPrivateDirectory(profile), isTrue);
    File(legacy).writeAsStringSync('synthetic legacy fixture');
    if (!visible) return;
    expect(ensureHiddenVolumeLoaded(), isTrue);
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      for (final mode in [
        StorageProtection.unencrypted,
        StorageProtection.encrypted,
      ]) {
        final id = ManagedIdentityId(
          (mode == StorageProtection.encrypted ? '2' : '1') * 32,
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
  }

  String normalized() =>
      Directory(profile).absolute.uri.normalizePath().toFilePath();
  List<String> scopes() => StorageUnlockScopes.forProfile(
    profile: ns,
    legacyPath: legacy,
    managedPath: normalized(),
    identities: locators,
  ).ids;
  Future<void> seed() async {
    for (final scope in scopes()) {
      await QuickUnlockVault(
        store,
        scope,
        auth,
      ).configure(password: 'old synthetic', system: true);
    }
  }

  Future<ManagedErasureWorker> begin() async {
    final owner = await ManagedErasureWorker.begin(
      profileDirectory: profile,
      profileNamespace: ns,
      legacyPath: legacy,
    );
    owners.add(owner);
    return owner;
  }

  QuickUnlockRetirement retire(ManagedErasureWorker worker) =>
      QuickUnlockRetirement.forWorker(worker.scopeLease, store, auth);
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-erasure-worker-');
    profile = '${fixture.path}/managed';
    legacy = '${fixture.path}/./legacy-fixture';
    store = _Store();
    locators.clear();
  });
  tearDown(() async {
    for (final owner in owners) {
      try {
        await owner.close();
      } catch (_) {}
    }
    owners.clear();
    fixture.deleteSync(recursive: true);
  });

  for (final visible in [false, true]) {
    test(
      'worker owns actual visible=$visible inventory and exact OS namespaces until verified release',
      () async {
        await create(visible: visible);
        await seed();
        final w = await begin();
        final view = await w.snapshot();
        expect(view.catalog.identities, hasLength(visible ? 2 : 0));
        expect(view.unlockScopes.ids.toSet(), scopes().toSet());
        final lease = w.scopeLease;
        final r = QuickUnlockRetirement.forWorker(lease, store, auth);
        expect(
          () => StorageProfileCoordinator.openExisting(profile),
          throwsA(anything),
        );
        await w.removeManagedFiles(retireScopes: r.retire);
        expect(store.values, isEmpty);
        expect(File(legacy).existsSync(), isTrue);
        expect(Directory('$profile/identities').existsSync(), isFalse);
        File(legacy).deleteSync();
        final proof = await w.finish(
          verifyOtherDataAbsent: () async {
            await r.verifyAbsent();
            expect(File(legacy).existsSync(), isFalse);
          },
        );
        expect(proof.authorizes(view.binding), isTrue);
        r.admitFreshLifetime(proof);
        final key = view.unlockScopes.ids.first;
        final fresh = QuickUnlockVault(store, key, auth);
        await fresh.configure(password: 'fresh synthetic', system: true);
        final before = Map.of(store.values), mutations = store.mutations;
        expect(
          () => QuickUnlockRetirement.forWorker(lease, store, auth),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        expect(store.values, before);
        expect(store.mutations, mutations);
        expect(await fresh.openSystem('fixture'), 'fresh synthetic');
        await w.finish(
          verifyOtherDataAbsent: () async =>
              fail('Lost reply retry must reuse the released receipt'),
        );
        ManagedDirectoryCatalog.createOrOpen(profile).close();
        expect(ManagedErasureWorker.retiringCount, 0);
      },
    );
  }
  test('captured worker retirement cannot mutate after owner close', () async {
    await create(visible: false);
    await seed();
    final w = await begin();
    final r = retire(w);
    await w.close();
    final before = Map.of(store.values), mutations = store.mutations;
    await expectLater(r.retire(), throwsA(isA<QuickUnlockRetirementFailure>()));
    expect(store.values, before);
    expect(store.mutations, mutations);
    expect(File(legacy).existsSync(), isTrue);
    expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
  });

  test('closing during accepted vault read refuses later mutations', () async {
    await create(visible: false);
    await seed();
    final w = await begin();
    final r = retire(w);
    final entered = Completer<void>(), release = Completer<void>();
    store.removalReadEntered = entered;
    store.removalReadRelease = release;
    final before = Map.of(store.values), mutations = store.mutations;
    final removal = _outcome(w.removeManagedFiles(retireScopes: r.retire));
    await entered.future;
    final closing = _outcome(w.close());
    release.complete();
    expect(await removal, isA<ManagedWorkerFailure>());
    expect(await closing, isNull);
    expect(store.values, before);
    expect(store.mutations, mutations);
    expect(File(legacy).existsSync(), isTrue);
    expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
    final recovered = await ManagedErasureWorker.recover(profile);
    owners.add(recovered);
    await recovered.removeManagedFiles(retireScopes: retire(recovered).retire);
    expect(store.values, isEmpty);
  });

  test(
    'callback refusal preserves the native payloads and a retryable intent',
    () async {
      await create();
      await seed();
      final before = files('$profile/identities');
      final w = await begin();
      await expectLater(
        w.removeManagedFiles(
          retireScopes: () async {
            throw StateError('private synthetic text');
          },
        ),
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (e) => e.toString(),
            'bounded',
            isNot(contains('private synthetic text')),
          ),
        ),
      );
      expect(files('$profile/identities'), before);
      expect(File(legacy).existsSync(), isTrue);
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );

  test(
    'close joins accepted UI verification; ordinary admission stays blocked',
    () async {
      await create(visible: false);
      await seed();
      final w = await begin();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      final entered = Completer<void>(), release = Completer<void>();
      final finishing = _outcome(
        w.finish(
          verifyOtherDataAbsent: () async {
            entered.complete();
            await release.future;
            throw StateError('synthetic verification refusal');
          },
        ),
      );
      await entered.future;
      var closed = false;
      final closing = w.close().then((_) => closed = true);
      try {
        await Future<void>(() {});
        expect(closed, isFalse);
        expect(
          () => StorageProfileCoordinator.openExisting(profile),
          throwsA(anything),
        );
        expect(() => w.scopeLease, throwsA(isA<ManagedWorkerFailure>()));
      } finally {
        release.complete();
      }
      expect(await finishing, isA<ManagedWorkerFailure>());
      await closing;
      expect(closed, isTrue);
      expect(
        () => ManagedDirectoryCatalog.openExisting(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
    },
  );

  test(
    'recover keeps the original binding and cannot replace a pending nonce',
    () async {
      await create(visible: false);
      await seed();
      final first = await begin();
      final original = await first.snapshot();
      await first.close();
      await expectLater(
        ManagedErasureWorker.begin(
          profileDirectory: profile,
          profileNamespace: ns,
          legacyPath: legacy,
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      final recovered = await ManagedErasureWorker.recover(profile);
      owners.add(recovered);
      final r = retire(recovered);
      await recovered.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      final proof = await recovered.finish(
        verifyOtherDataAbsent: r.verifyAbsent,
      );
      expect(proof.authorizes(original.binding), isTrue);
      r.admitFreshLifetime(proof);
    },
  );

  test(
    'bound resume refuses another intent without mutating its inventory',
    () async {
      await create(visible: false);
      final old = await begin();
      final original = await old.snapshot();
      final r = retire(old);
      await old.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await old.finish(verifyOtherDataAbsent: r.verifyAbsent);
      File(legacy).writeAsStringSync('synthetic replacement payload');
      final replacement = await begin();
      final current = await replacement.snapshot();
      expect(current.binding.sameOperation(original.binding), isFalse);
      await replacement.close();
      final before = files(profile);
      await expectLater(
        ManagedErasureWorker.resumeBound(profile, original.binding).then((
          value,
        ) {
          owners.add(value); // Own unexpected success in omission controls too.
          return value;
        }),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files(profile), before);
      expect(File(legacy).readAsStringSync(), 'synthetic replacement payload');
      final resumed = await ManagedErasureWorker.resumeBound(
        profile,
        current.binding,
      );
      owners.add(resumed);
      expect(
        (await resumed.snapshot()).binding.sameOperation(current.binding),
        isTrue,
      );
    },
  );

  test(
    'bound resume cannot erase a newly created root after terminal release',
    () async {
      await create(visible: false);
      final old = await begin();
      final original = await old.snapshot();
      final r = retire(old);
      await old.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await old.finish(verifyOtherDataAbsent: r.verifyAbsent);
      ManagedDirectoryCatalog.createOrOpen(profile).close();
      final before = files(profile);
      await expectLater(
        ManagedErasureWorker.resumeBound(profile, original.binding).then((
          value,
        ) {
          owners.add(value); // Own unexpected success in omission controls too.
          return value;
        }),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files(profile), before);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
    },
  );

  test(
    'worker death after native release before reply can reconcile read-only and retain OS lifetime',
    () async {
      await create(visible: false);
      await seed();
      final gate = ReceivePort();
      try {
        final w = await ManagedErasureWorker.beginWithReleaseGateForTesting(
          profileDirectory: profile,
          profileNamespace: ns,
          legacyPath: legacy,
          afterNativeRelease: gate.sendPort,
        );
        owners.add(w);
        final view = await w.snapshot();
        final r = retire(w);
        await w.removeManagedFiles(retireScopes: r.retire);
        File(legacy).deleteSync();
        var finished = false;
        final finishing =
            _outcome(w.finish(verifyOtherDataAbsent: r.verifyAbsent)).then((v) {
              finished = true;
              return v;
            });
        final blocked = await gate.first;
        expect(blocked, isA<SendPort>());
        expect(finished, isFalse);
        // This actual exclusive grant proves native release happened; no root is
        // fabricated just to observe readiness. The reply is still gated.
        StorageProfileCoordinator.openExisting(
          profile,
          exclusive: true,
        )!.close();
        w.killReleasedWorkerForTesting();
        expect(await finishing, isA<ManagedWorkerFailure>());
        await expectLater(w.close(), throwsA(isA<ManagedWorkerFailure>()));
        expect(ManagedErasureWorker.retiringCount, 1);
        final recovered = await ManagedErasureWorker.reconcile(
          profile,
          view.binding,
        );
        owners.add(recovered);
        expect(() => recovered.scopeLease, throwsA(isA<ManagedFsFailure>()));
        var checked = 0;
        final mutations = store.mutations;
        final proof = await recovered.finish(
          verifyOtherDataAbsent: () async {
            checked++;
            await r.verifyAbsent();
            expect(File(legacy).existsSync(), isFalse);
          },
        );
        expect(checked, 1);
        expect(store.mutations, mutations);
        expect(proof.authorizes(view.binding), isTrue);
        r.admitFreshLifetime(proof);
        await QuickUnlockVault(
          store,
          view.unlockScopes.ids.first,
          auth,
        ).configure(password: 'recovered synthetic', system: true);
        expect(ManagedErasureWorker.retiringCount, 0);
      } finally {
        gate.close();
      }
    },
  );

  test(
    'reconciliation refuses existing root, pending markers and another profile binding intact',
    () async {
      await create(visible: false);
      final w = await begin();
      final view = await w.snapshot();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
      final other = '${fixture.path}/other';
      expect(fs.createPrivateDirectory(other), isTrue);
      StorageProfileCoordinator.createOrOpen(other).close();
      await expectLater(
        ManagedErasureWorker.reconcile(other, view.binding),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      final root = ManagedDirectoryCatalog.createOrOpen(profile);
      root.close();
      final before = files('$profile/identities');
      await expectLater(
        ManagedErasureWorker.reconcile(profile, view.binding),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files('$profile/identities'), before);
      Directory('$profile/identities').deleteSync(recursive: true);
      final marker = File(
        '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}',
      )..createSync(exclusive: true);
      fs.restrictNewFile(marker.path);
      marker.writeAsStringSync('preserved pending marker');
      await expectLater(
        ManagedErasureWorker.reconcile(profile, view.binding),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(marker.readAsStringSync(), 'preserved pending marker');
    },
  );

  test(
    'read-only OS verification refuses a new record and never removes it',
    () async {
      await create(visible: false);
      await seed();
      final w = await begin();
      final view = await w.snapshot();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      final proof = await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
      final key = 'false:xveil.quick.v1.${view.unlockScopes.ids.first}';
      store.values[key] = 'new synthetic data';
      final recon = await ManagedErasureWorker.reconcile(profile, view.binding);
      owners.add(recon);
      final before = Map.of(store.values), mutations = store.mutations;
      await expectLater(
        recon.finish(verifyOtherDataAbsent: r.verifyAbsent),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(store.values, before);
      expect(store.mutations, mutations);
      // Only this fixture removes the injected record; reconciliation cannot.
      store.values.remove(key);
      final freshProof = await recon.finish(
        verifyOtherDataAbsent: r.verifyAbsent,
      );
      expect(proof.authorizes(view.binding), isTrue);
      r.admitFreshLifetime(freshProof);
    },
  );
  test(
    'terminal-only recovery transfers a genuine snapshot without inventing a scope list',
    () async {
      await create(visible: false);
      await seed();
      final w = await begin();
      final view = await w.snapshot();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await w.close();
      // Place the real durable terminal between plan removal and directory
      // removal; the following worker must use that same immutable binding.
      final native = ManagedRootErasure.openPending(profile);
      try {
        await expectLater(
          native.finish(
            verifyOtherDataAbsent: r.verifyAbsent,
            afterStage: (stage) async {
              if (stage == ManagedErasureFinishStage.planRemoved) {
                throw StateError('synthetic interruption');
              }
            },
          ),
          throwsStateError,
        );
      } finally {
        native.close();
      }
      final recovered = await ManagedErasureWorker.recover(profile);
      owners.add(recovered);
      final snapshot = await recovered.snapshot();
      expect(snapshot.phase, ManagedRootErasurePhase.finishing);
      expect(() => snapshot.unlockScopes, throwsA(isA<ManagedFsFailure>()));
      expect(() => recovered.scopeLease, throwsA(isA<ManagedFsFailure>()));
      final proof = await recovered.finish(
        verifyOtherDataAbsent: () async =>
            fail('Terminal already verified the enclosing cleanup'),
      );
      expect(proof.authorizes(view.binding), isTrue);
      r.admitFreshLifetime(proof);
    },
  );

  test(
    'read-only reconciliation revalidates root absence after the UI callback',
    () async {
      await create(visible: false);
      await seed();
      final w = await begin();
      final view = await w.snapshot();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
      final recon = await ManagedErasureWorker.reconcile(profile, view.binding);
      owners.add(recon);
      await expectLater(
        recon.finish(
          verifyOtherDataAbsent: () async {
            await r.verifyAbsent();
            expect(fs.createPrivateDirectory('$profile/identities'), isTrue);
            File(
              '$profile/identities/new-fixture',
            ).writeAsStringSync('preserved');
          },
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(
        File('$profile/identities/new-fixture').readAsStringSync(),
        'preserved',
      );
      // Only the fixture removes its own newly introduced content.
      Directory('$profile/identities').deleteSync(recursive: true);
      final proof = await recon.finish(verifyOtherDataAbsent: r.verifyAbsent);
      r.admitFreshLifetime(proof);
    },
  );

  test(
    'terminal sync failure cannot revive cached scope mutation authority',
    () async {
      await create(visible: false);
      await seed();
      final w = await ManagedErasureWorker.beginWithFinalSyncFailureForTesting(
        profileDirectory: profile,
        profileNamespace: ns,
        legacyPath: legacy,
      );
      owners.add(w);
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await expectLater(
        w.finish(verifyOtherDataAbsent: r.verifyAbsent),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      await store.write(
        'xveil.quick.v1.${scopes().first}',
        '{"v":1,"id":"new synthetic","system":false,"grid":null,"pattern":null}',
      );
      final before = Map.of(store.values), mutations = store.mutations;
      await expectLater(
        r.retire(),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.values, before);
      expect(store.mutations, mutations);
      expect(() => w.scopeLease, throwsA(isA<ManagedWorkerFailure>()));
      expect((await w.snapshot()).phase, ManagedRootErasurePhase.finishing);
      expect(() => w.scopeLease, throwsA(isA<ManagedWorkerFailure>()));
    },
  );

  test(
    'preterminal refusal revalidates native plan before restoring scope cleanup',
    () async {
      await create(visible: false);
      final w = await begin();
      final view = await w.snapshot();
      final original = retire(w);
      await expectLater(
        w.finish(
          verifyOtherDataAbsent: () async {
            throw StateError('synthetic refusal before terminal');
          },
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(w.scopeLease.snapshot.binding.sameOperation(view.binding), isTrue);
      await w.removeManagedFiles(retireScopes: original.retire);
      File(legacy).deleteSync();
      final proof = await w.finish(
        verifyOtherDataAbsent: original.verifyAbsent,
      );
      expect(proof.authorizes(view.binding), isTrue);
    },
  );

  test('failed native revalidation cannot restore a cached scope grant', () async {
    await create(visible: false);
    await seed();
    final w = await begin();
    final r = retire(w);
    await w.removeManagedFiles(retireScopes: r.retire);
    File(legacy).deleteSync();
    final plan = File(
      '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}/plan.json',
    );
    await expectLater(
      w.finish(
        verifyOtherDataAbsent: () async {
          await store.write(
            'xveil.quick.v1.${scopes().first}',
            '{"v":1,"id":"new synthetic","system":false,"grid":null,"pattern":null}',
          );
          plan.writeAsStringSync('synthetic changed plan');
          throw StateError('synthetic refusal with unverified native state');
        },
      ),
      throwsA(isA<ManagedWorkerFailure>()),
    );
    final before = Map.of(store.values), mutations = store.mutations;
    await expectLater(r.retire(), throwsA(isA<QuickUnlockRetirementFailure>()));
    expect(() => w.scopeLease, throwsA(isA<ManagedWorkerFailure>()));
    expect(store.values, before);
    expect(store.mutations, mutations);
    expect(plan.readAsStringSync(), 'synthetic changed plan');
  });

  test(
    'finish joins previously accepted scope cleanup before sealing mutations',
    () async {
      await create(visible: false);
      await seed();
      final w = await begin();
      final r = retire(w);
      final entered = Completer<void>(), release = Completer<void>();
      store.removalReadEntered = entered;
      store.removalReadRelease = release;
      final removing = _outcome(w.removeManagedFiles(retireScopes: r.retire));
      await entered.future;
      File(legacy).deleteSync();
      final finishing = _outcome(
        w.finish(verifyOtherDataAbsent: r.verifyAbsent),
      );
      expect(() => w.scopeLease, throwsA(isA<ManagedWorkerFailure>()));
      release.complete();
      final result = await Future.wait([removing, finishing]);
      expect(result.first, isNull);
      expect(result.last, isA<ManagedErasureRelease>());
      expect(store.values, isEmpty);
    },
  );

  test(
    'close can confirm a failed final sync instead of stranding a closed RPC owner',
    () async {
      await create(visible: false);
      await seed();
      final w = await ManagedErasureWorker.beginWithFinalSyncFailureForTesting(
        profileDirectory: profile,
        profileNamespace: ns,
        legacyPath: legacy,
      );
      owners.add(w);
      final view = await w.snapshot();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await expectLater(
        w.finish(verifyOtherDataAbsent: r.verifyAbsent),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(
        () => StorageProfileCoordinator.openExisting(profile),
        throwsA(anything),
      );
      await w.close();
      StorageProfileCoordinator.openExisting(profile, exclusive: true)!.close();
      final recon = await ManagedErasureWorker.reconcile(profile, view.binding);
      owners.add(recon);
      final proof = await recon.finish(verifyOtherDataAbsent: r.verifyAbsent);
      r.admitFreshLifetime(proof);
      expect(ManagedErasureWorker.retiringCount, 0);
    },
  );
  test(
    'reconciliation must confirm directory durability before issuing its release',
    () async {
      await create(visible: false);
      await seed();
      final w = await begin();
      final view = await w.snapshot();
      final r = retire(w);
      await w.removeManagedFiles(retireScopes: r.retire);
      File(legacy).deleteSync();
      await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
      final fault = _ReconcileSyncFault();
      final native = ManagedErasureReconciliation.open(
        profile,
        view.binding,
        fs: fault,
      );
      var checks = 0;
      try {
        await expectLater(
          native.verifyAndRelease(
            verifyOtherDataAbsent: () async {
              checks++;
              await r.verifyAbsent();
            },
          ),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(checks, 1);
        expect(fault.syncs, 1);
        expect(
          () => StorageProfileCoordinator.openExisting(profile),
          throwsA(anything),
        );
        fault.refuse = false;
        final proof = await native.verifyAndRelease(
          verifyOtherDataAbsent: () async {
            checks++;
            await r.verifyAbsent();
          },
        );
        expect(checks, 2);
        expect(fault.syncs, 2);
        expect(proof.authorizes(view.binding), isTrue);
        r.admitFreshLifetime(proof);
      } finally {
        native.close();
      }
    },
  );
}
