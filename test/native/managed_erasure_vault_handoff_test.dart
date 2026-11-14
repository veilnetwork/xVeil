@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/local_authentication.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/quick_unlock_retirement.dart' as public_api;
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/startup_unlock.dart';
import '../support/retirement_secret_store.dart';

class _Stop implements Exception {}

class _Store extends RetirementSecretStore {
  String? _heldOperation, _heldScope;
  late Completer<void> entered, release;
  int calls = 0, prompts = 0;
  void arm(String operation, String scope) {
    _heldOperation = operation;
    _heldScope = scope;
    entered = Completer<void>();
    release = Completer<void>();
  }

  Future<void> hold(String operation, String key) async {
    if (operation != _heldOperation || !key.contains(_heldScope!)) return;
    _heldOperation = null; // Exactly one operation; removal must not stall too.
    entered.complete();
    await release.future;
  }

  @override
  Future<String?> read(String key, {bool biometric = false}) async {
    calls++;
    final value = await super.read(key, biometric: biometric);
    if (!biometric) await hold('read', key);
    return value;
  }

  @override
  Future<String?> readAuthenticated(
    String key,
    String reason,
    LocalScreenAuthentication authentication,
  ) async {
    calls++;
    prompts++;
    final value = await super.read(key, biometric: true);
    await hold('auth', key);
    return value;
  }

  @override
  Future<void> write(String key, String value, {bool biometric = false}) async {
    calls++;
    if (!biometric) await hold('write', key);
    await super.write(key, value, biometric: biometric);
  }

  @override
  Future<void> delete(String key, {bool biometric = false}) async {
    calls++;
    await hold('delete', key);
    await super.delete(key, biometric: biometric);
  }

  @override
  Future<bool> contains(String key, {bool biometric = false}) {
    calls++;
    return super.contains(key, biometric: biometric);
  }
}

class _LastSyncFault extends ManagedFsPlatform {
  bool enabled = true, published = false;
  @override
  bool publishFileNoReplace(String from, String to) {
    return published = super.publishFileNoReplace(from, to);
  }

  @override
  void syncDirectory(String path) {
    if (enabled &&
        published &&
        !path.endsWith('/${ManagedRootErasure.pendingName}') &&
        !File('$path/${ManagedRootErasure.completionName}').existsSync() &&
        !Directory('$path/${ManagedRootErasure.pendingName}').existsSync()) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    super.syncDirectory(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fs = ManagedFsPlatform();
  final first = 'a' * 64, second = 'b' * 64, unrelated = 'c' * 64;
  late Directory fixture;
  late _Store store;
  final auth = RetirementAuthentication();
  final live = <ManagedRootErasure>[];
  QuickUnlockVault vault(String scope) => QuickUnlockVault(store, scope, auth);

  Future<ManagedRootErasure> intent(
    String leaf,
    List<String> scopes, {
    ManagedFsPlatform platform = fs,
  }) async {
    final profile = '${fixture.path}/$leaf';
    if (!Directory(profile).existsSync()) {
      expect(fs.createPrivateDirectory(profile), isTrue);
    }
    final owner = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      final data = ManagedIdentityFiles.createUnencrypted(
        owner,
        id: ManagedIdentityId('1' * 32),
      );
      try {
        data.commit([
          PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([2, 3])),
        ]);
      } finally {
        data.close();
      }
    } finally {
      owner.close();
    }
    final exclusive = ManagedDirectoryCatalog.openExclusiveMaintenance(
      profile,
    )!;
    try {
      await ManagedRootErasure.prepare(
        exclusive,
        unlockScopes: StorageUnlockScopes(scopes),
      );
    } finally {
      exclusive.close();
    }
    final result = ManagedRootErasure.openPending(profile, fs: platform);
    live.add(result);
    return result;
  }

  public_api.QuickUnlockRetirement retirement(ManagedRootErasure e) =>
      public_api.QuickUnlockRetirement.forManagedErasure(e, store, auth);
  Future<ManagedErasureRelease> finish(
    ManagedRootErasure e,
    public_api.QuickUnlockRetirement r,
  ) async {
    final scopes = e.unlockScopes.ids;
    await e.removeManagedFiles(retireScopes: (_) => r.retire());
    await e.finish(
      verifyOtherDataAbsent: () async {
        expect(store.values.keys.any((k) => scopes.any(k.contains)), isFalse);
      },
    );
    return e.releaseCompleted();
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-vault-handoff-');
    store = _Store();
  });
  tearDown(() {
    for (final e in live) {
      e.close();
    }
    live.clear();
    fixture.deleteSync(recursive: true);
  });

  test('captured actor retirement refuses after native owner close', () async {
    final e = await intent('profile', [first]);
    await vault(first).configure(password: 'old synthetic', system: true);
    final r = retirement(e);
    e.close();
    final before = Map.of(store.values);
    await expectLater(
      r.retire(),
      throwsA(isA<public_api.QuickUnlockRetirementFailure>()),
    );
    expect(store.values, before);
  });

  for (final operation in ['write', 'delete']) {
    test(
      'owner loss during OS $operation preserves a recoverable intent',
      () async {
        final e = await intent('profile', [first]);
        await vault(first).configure(password: 'old synthetic', system: true);
        final r = retirement(e);
        store.arm(operation, first);
        final removing = r.retire().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await store.entered.future;
        final calls = store.calls;
        e.close();
        store.release.complete();
        expect(await removing, isA<public_api.QuickUnlockRetirementFailure>());
        expect(store.calls, calls, reason: 'no later OS call after owner loss');
        expect(
          store.values['false:xveil.quick.v1.$first'],
          contains('"bioPending":true'),
        );
        final recovered = ManagedRootErasure.openPending(
          '${fixture.path}/profile',
        );
        live.add(recovered);
        final next = retirement(recovered);
        await recovered.removeManagedFiles(retireScopes: (_) => next.retire());
        expect(store.values, isEmpty);
      },
    );
  }

  test(
    'only completed terminal protocol and actual native close issue a release',
    () async {
      final e = await intent('profile', [first]);
      final r = retirement(e);
      expect(e.releaseCompleted, throwsA(isA<ManagedFsFailure>()));
      await e.removeManagedFiles(retireScopes: (_) => r.retire());
      expect(e.releaseCompleted, throwsA(isA<ManagedFsFailure>()));
      final entered = Completer<void>(), release = Completer<void>();
      final finishing = e.finish(
        verifyOtherDataAbsent: () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      try {
        expect(e.releaseCompleted, throwsA(isA<ManagedFsFailure>()));
      } finally {
        release.complete();
        await finishing;
      }
      // Even a complete actor still owns the real SQLite/POSIX lifetime grant.
      expect(
        () => ManagedDirectoryCatalog.createOrOpen('${fixture.path}/profile'),
        throwsA(anything),
      );
      final proof = e.releaseCompleted();
      expect(proof.authorizes(e.binding), isTrue);
      final fresh = ManagedDirectoryCatalog.createOrOpen(
        '${fixture.path}/profile',
      );
      fresh.close();
      r.admitFreshLifetime(proof);
      await vault(first).configure(password: 'fresh synthetic', system: true);
      expect(await vault(first).openSystem('fixture'), 'fresh synthetic');
    },
  );

  test(
    'an unconfirmed final unlink cannot issue a receipt or enable new saved entry',
    () async {
      final fault = _LastSyncFault();
      final e = await intent('profile', [first], platform: fault);
      final r = retirement(e);
      await e.removeManagedFiles(retireScopes: (_) => r.retire());
      try {
        await expectLater(
          e.finish(verifyOtherDataAbsent: () async {}),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(e.releaseCompleted, throwsA(isA<ManagedFsFailure>()));
        expect(e.close, throwsA(isA<ManagedLeaseFailure>()));
        await expectLater(
          vault(first).configure(password: 'premature synthetic', system: true),
          throwsStateError,
        );
      } finally {
        fault.enabled = false;
        await e.finish(
          verifyOtherDataAbsent: () async => fail('Only final sync remains'),
        );
      }
      final proof = e.releaseCompleted();
      r.admitFreshLifetime(proof);
      await vault(first).configure(password: 'fresh synthetic', system: true);
    },
  );

  test(
    'old wrappers, duplicate owners and old receipts cannot touch fresh credentials',
    () async {
      final old = [vault(first), vault(second)];
      for (final v in old) {
        await v.configure(password: 'old synthetic', system: true);
      }
      await vault(
        unrelated,
      ).configure(password: 'unrelated synthetic', system: true);
      final e = await intent('profile', [first, second]);
      final r = retirement(e), duplicate = retirement(e);
      await duplicate.retire();
      final proof = await finish(e, r);
      final alsoOld = vault(first);
      r.admitFreshLifetime(proof);
      final fresh = vault(first);
      await fresh.configure(password: 'new synthetic', system: true);
      final before = Map.of(store.values), calls = store.calls;
      for (final v in [...old, alsoOld]) {
        expect((await v.options()).enabled, isFalse);
        expect(await v.openSystem('old reason'), isNull);
        expect(await v.openPattern([0, 1, 4, 8]), isNull);
        await expectLater(v.forget(), throwsStateError);
        await expectLater(v.retireForErasure(), throwsStateError);
        await expectLater(
          v.configure(password: 'late synthetic', system: true),
          throwsStateError,
        );
      }
      expect(
        () => r.admitFreshLifetime(proof),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(
        () => duplicate.admitFreshLifetime(proof),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      await expectLater(
        r.retire(),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      await expectLater(
        duplicate.retire(),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.calls, calls);
      expect(store.values, before);
      expect(await fresh.openSystem('new reason'), 'new synthetic');
      expect(
        await vault(unrelated).openSystem('unrelated reason'),
        'unrelated synthetic',
      );
    },
  );

  test(
    'a wrong operation receipt or unbound retirement cannot partially detach a scope set',
    () async {
      final e = await intent('profile', [first, second]);
      final r = retirement(e);
      await e.removeManagedFiles(retireScopes: (_) => r.retire());
      final other = await intent('other', [unrelated]);
      final otherProof = await finish(other, retirement(other));
      expect(otherProof.authorizes(e.binding), isFalse);
      expect(
        () => r.admitFreshLifetime(otherProof),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      for (final scope in [first, second]) {
        await expectLater(
          vault(scope).configure(password: 'premature synthetic', system: true),
          throwsStateError,
        );
      }
      final unbound = public_api.QuickUnlockRetirement(
        store,
        StorageUnlockScopes([first]),
        auth,
      );
      await unbound.retire();
      await e.finish(verifyOtherDataAbsent: () async {});
      final proof = e.releaseCompleted();
      expect(
        () => unbound.admitFreshLifetime(proof),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      r.admitFreshLifetime(proof);
      for (final scope in [first, second]) {
        await vault(scope).configure(password: 'new synthetic', system: true);
      }
    },
  );

  test('terminal recovery preserves the binding after plan removal', () async {
    final e = await intent('profile', [first, second]);
    final r = retirement(e);
    await e.removeManagedFiles(retireScopes: (_) => r.retire());
    await expectLater(
      e.finish(
        verifyOtherDataAbsent: () async {},
        afterStage: (stage) async {
          if (stage == ManagedErasureFinishStage.planRemoved) throw _Stop();
        },
      ),
      throwsA(isA<_Stop>()),
    );
    e.close();
    final recovered = ManagedRootErasure.openPending('${fixture.path}/profile');
    live.add(recovered);
    expect(recovered.phase, ManagedRootErasurePhase.finishing);
    await recovered.finish(
      verifyOtherDataAbsent: () async =>
          fail('Terminal recovery must not need erased scopes'),
    );
    final proof = recovered.releaseCompleted();
    expect(proof.authorizes(e.binding), isTrue);
    for (final description in [proof.toString(), e.binding.toString()]) {
      expect(description, isNot(contains(fixture.path)));
      expect(description, isNot(contains(first)));
    }
    r.admitFreshLifetime(proof);
    await vault(first).configure(password: 'new synthetic', system: true);
  });

  test(
    'an earlier receipt cannot authorize a later erasure at the same profile path',
    () async {
      final e1 = await intent('profile', [first]);
      final r1 = retirement(e1);
      final proof1 = await finish(e1, r1);
      r1.admitFreshLifetime(proof1);
      await vault(first).configure(password: 'between synthetic', system: true);
      final e2 = await intent('profile', [first]);
      final r2 = retirement(e2);
      await r2.retire();
      expect(proof1.authorizes(e2.binding), isFalse);
      expect(
        () => r2.admitFreshLifetime(proof1),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      final proof2 = await finish(e2, r2);
      r2.admitFreshLifetime(proof2);
      await vault(first).configure(password: 'latest synthetic', system: true);
      expect(
        () => r1.admitFreshLifetime(proof1),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(await vault(first).openSystem('fixture'), 'latest synthetic');
    },
  );

  test(
    'a queued late forget refuses the entire handoff until all accepted work settles',
    () async {
      final e = await intent('profile', [first, second]);
      final r = retirement(e);
      final proof = await finish(e, r);
      final late = vault(second);
      store.arm('delete', second);
      final deleting = late.forget();
      await store.entered.future;
      try {
        expect(
          () => r.admitFreshLifetime(proof),
          throwsA(isA<QuickUnlockRetirementFailure>()),
        );
        // The earlier scope must not have been detached before finding this job.
        await expectLater(
          vault(first).configure(password: 'premature synthetic', system: true),
          throwsStateError,
        );
      } finally {
        store.release.complete();
        await deleting;
      }
      r.admitFreshLifetime(proof);
      for (final scope in [first, second]) {
        await vault(scope).configure(password: 'fresh synthetic', system: true);
      }
      final before = Map.of(store.values);
      await expectLater(late.forget(), throwsStateError);
      expect(store.values, before);
    },
  );

  for (final operation in ['read', 'auth']) {
    test(
      'late $operation across completed handoff cannot read or return the new profile secret',
      () async {
        final old = vault(first);
        await old.configure(password: 'old synthetic', system: true);
        store.arm(operation, first);
        final opening = old.openSystem('old reason');
        await store.entered.future;
        try {
          final e = await intent('profile', [first]);
          final r = retirement(e);
          final proof = await finish(e, r);
          r.admitFreshLifetime(proof);
          await vault(first).configure(password: 'new synthetic', system: true);
        } finally {
          store.release.complete();
        }
        final calls = store.calls;
        expect(await opening, isNull);
        expect(store.calls, calls);
        expect(store.prompts, operation == 'auth' ? 1 : 0);
        expect(await vault(first).openSystem('new reason'), 'new synthetic');
      },
    );
  }

  test(
    'provider handoff invalidates both cached options and the retired vault wrapper',
    () async {
      SharedPreferences.setMockInitialValues({kStartupUnlockOptIn: true});
      final prefs = await SharedPreferences.getInstance();
      final probe = Provider(
        (ref) => (QuickUnlockRetirement r, ManagedErasureRelease proof) {
          admitFreshStartupUnlock(ref, r, proof);
        },
      );
      final container = ProviderContainer(
        overrides: [
          quickUnlockSecretStoreProvider.overrideWithValue(store),
          localScreenAuthenticationProvider.overrideWithValue(auth),
          prefsProvider.overrideWith((_) async => prefs),
        ],
      );
      try {
        final old = container.read(quickUnlockVaultProvider);
        await old.configure(password: 'old provider synthetic', system: true);
        expect(
          (await container.read(startupUnlockOptionsProvider.future)).system,
          isTrue,
        );
        final e = await intent('profile', [old.scope]);
        final r = retirement(e);
        final proof = await finish(e, r);
        container.read(probe)(r, proof);
        final fresh = container.read(quickUnlockVaultProvider);
        expect(identical(old, fresh), isFalse);
        expect(
          (await container.read(startupUnlockOptionsProvider.future)).enabled,
          isFalse,
        );
        await fresh.configure(
          password: 'fresh provider synthetic',
          system: true,
        );
        await expectLater(old.forget(), throwsStateError);
        expect(
          await fresh.openSystem('new reason'),
          'fresh provider synthetic',
        );
      } finally {
        container.dispose();
      }
    },
  );
  test(
    'a disposed provider owner cannot consume the handoff before a live owner can refresh',
    () async {
      final probe = Provider(
        (ref) => (QuickUnlockRetirement r, ManagedErasureRelease proof) {
          admitFreshStartupUnlock(ref, r, proof);
        },
      );
      ProviderContainer makeContainer() => ProviderContainer(
        overrides: [
          quickUnlockSecretStoreProvider.overrideWithValue(store),
          localScreenAuthenticationProvider.overrideWithValue(auth),
        ],
      );
      final stale = makeContainer();
      final old = stale.read(quickUnlockVaultProvider);
      final obsolete = stale.read(probe);
      stale.dispose();
      final e = await intent('profile', [old.scope]);
      final r = retirement(e);
      final proof = await finish(e, r);
      expect(() => obsolete(r, proof), throwsStateError);
      await expectLater(
        vault(
          old.scope,
        ).configure(password: 'premature synthetic', system: true),
        throwsStateError,
      );
      final current = makeContainer();
      try {
        current.read(probe)(r, proof);
        final fresh = current.read(quickUnlockVaultProvider);
        await fresh.configure(password: 'new provider synthetic', system: true);
        await expectLater(old.forget(), throwsStateError);
        expect(
          await fresh.openSystem('fresh reason'),
          'new provider synthetic',
        );
      } finally {
        current.dispose();
      }
    },
  );
}
