@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/domain/storage_protection.dart';
import '../support/retirement_secret_store.dart';

class _Watch extends ManagedFsPlatform {
  int rootCreationAttempts = 0;
  bool refuseBefore = false, refuseAfter = false, published = false;
  void Function()? duringStage;
  @override
  bool createPrivateDirectory(String path) {
    if (path.endsWith('/identities')) rootCreationAttempts++;
    return super.createPrivateDirectory(path);
  }

  @override
  bool publishDirectoryNoReplace(String from, String to) {
    if (to.endsWith('/${ManagedRootErasure.pendingName}')) {
      if (refuseBefore) {
        throw FileSystemException('synthetic private failure', to);
      }
      return published = super.publishDirectoryNoReplace(from, to);
    }
    return super.publishDirectoryNoReplace(from, to);
  }

  @override
  void syncDirectory(String path) {
    if (path.contains('/.erasure-')) {
      final action = duringStage;
      duringStage = null;
      action?.call();
    }
    if (published && refuseAfter) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    super.syncDirectory(path);
  }
}

/// Model ordinary filesystem object-number reuse after the previous directory
/// has been removed. Keep all actual ownership/privacy checks and file I/O.
class _ReusedDirectoryIds extends ManagedFsPlatform {
  @override
  ManagedPathWitness inspect(String path) {
    final actual = super.inspect(path);
    if (!path.endsWith('/${ManagedRootErasure.pendingName}') ||
        !actual.directory) {
      return actual;
    }
    return ManagedPathWitness(
      identity: 'simulated-reused-directory',
      directory: actual.directory,
      ownerOnly: actual.ownerOnly,
      ownedByCurrentUser: actual.ownedByCurrentUser,
      safeAncestor: actual.safeAncestor,
    );
  }
}

void main() {
  const fs = ManagedFsPlatform();
  final scope = 'a' * 64;
  late Directory fixture;
  late String profile;
  final parents = <StorageProfileCoordinator>[];
  final actors = <ManagedRootErasure>[];
  String coordinator() => '$profile/${StorageProfileCoordinator.directoryName}';
  String pending() => '${coordinator()}/${ManagedRootErasure.pendingName}';
  String plan() => '${pending()}/plan.json';
  Map<String, String> contents(String path) => {
    for (final f in Directory(
      path,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };
  StorageProfileCoordinator parent({
    ManagedFsPlatform platform = fs,
    bool exclusive = true,
  }) {
    final result = StorageProfileCoordinator.openExisting(
      profile,
      fs: platform,
      exclusive: exclusive,
    )!;
    parents.add(result);
    return result;
  }

  Future<void> prepare({ManagedFsPlatform platform = fs}) async {
    final owner = parent(platform: platform);
    try {
      await ManagedRootErasure.prepareAbsent(
        owner,
        unlockScopes: StorageUnlockScopes([scope]),
      );
    } finally {
      owner.close();
    }
  }

  ManagedRootErasure recover({ManagedFsPlatform platform = fs}) {
    final result = ManagedRootErasure.openPending(profile, fs: platform);
    actors.add(result);
    return result;
  }

  void insertRoot() {
    expect(fs.createPrivateDirectory('$profile/identities'), isTrue);
    File('$profile/identities/foreign-fixture').writeAsBytesSync([9, 8, 7]);
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-absent-root-erasure-');
    profile = '${fixture.path}/profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
    StorageProfileCoordinator.createOrOpen(profile).close();
  });
  tearDown(() {
    for (final a in actors) {
      a.close();
    }
    for (final p in parents) {
      p.close();
    }
    actors.clear();
    parents.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'hidden-only erasure records root absence, retires the exact scope and enables a fresh lifetime',
    () async {
      final watch = _Watch();
      final legacy = File('$profile/legacy-fixture')
        ..writeAsStringSync('synthetic legacy data');
      final sibling = File('${fixture.path}/sibling')
        ..writeAsStringSync('unrelated synthetic data');
      final roleBytes = contents(coordinator());
      final store = RetirementSecretStore(), auth = RetirementAuthentication();
      final old = QuickUnlockVault(store, scope, auth);
      await old.configure(password: 'synthetic old', system: true);
      await prepare(platform: watch);
      expect(watch.rootCreationAttempts, 0);
      expect(Directory('$profile/identities').existsSync(), isFalse);
      final raw = jsonDecode(File(plan()).readAsStringSync()) as Map;
      expect(raw['entries'], isEmpty);
      expect(
        ManagedIdentityCatalog.decode(raw['catalog'] as String).identities,
        isEmpty,
      );
      expect(raw['unlockScopes'], [scope]);
      expect(File(plan()).readAsStringSync(), isNot(contains('synthetic old')));
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      final e = recover();
      expect(e.catalog.identities, isEmpty);
      final retirement = QuickUnlockRetirement.forManagedErasure(
        e,
        store,
        auth,
      );
      var callbacks = 0;
      await e.removeManagedFiles(
        retireScopes: (catalog) async {
          expect(catalog.identities, isEmpty);
          callbacks++;
          await retirement.retire();
        },
        afterUnlink: (_) async => fail('An absent root has no planned unlinks'),
      );
      expect(callbacks, 1);
      expect(legacy.readAsStringSync(), 'synthetic legacy data');
      expect(store.values, isEmpty);
      await e.finish(
        verifyOtherDataAbsent: () async {
          legacy.deleteSync();
          expect(legacy.existsSync(), isFalse);
        },
      );
      final proof = e.releaseCompleted();
      retirement.admitFreshLifetime(proof);
      final fresh = QuickUnlockVault(store, scope, auth);
      await fresh.configure(password: 'synthetic new', system: true);
      await expectLater(old.forget(), throwsStateError);
      expect(await fresh.openSystem('fixture'), 'synthetic new');
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(contents(coordinator()), roleBytes);
      expect(sibling.readAsStringSync(), 'unrelated synthetic data');
      expect(watch.rootCreationAttempts, 0);
      // Ordinary root initialization is now an explicit fresh-profile action.
      ManagedDirectoryCatalog.createOrOpen(profile).close();
    },
  );

  test('shared admission cannot plan absent-root destruction', () async {
    final shared = parent(exclusive: false);
    final before = contents(profile);
    await expectLater(
      ManagedRootErasure.prepareAbsent(
        shared,
        unlockScopes: StorageUnlockScopes([scope]),
      ),
      throwsA(isA<ManagedLeaseFailure>()),
    );
    expect(contents(profile), before);
    expect(Directory(pending()).existsSync(), isFalse);
  });

  for (final kind in ['file', 'directory', 'link']) {
    test(
      'an existing $kind cannot be treated as absent or adopted',
      () async {
        final outside = File('${fixture.path}/outside')
          ..writeAsStringSync('outside synthetic data');
        if (kind == 'file') {
          File('$profile/identities').writeAsBytesSync([9, 8, 7]);
        }
        if (kind == 'directory') insertRoot();
        if (kind == 'link') {
          Link('$profile/identities').createSync(outside.path);
        }
        final before = contents(profile);
        await expectLater(prepare(), throwsA(isA<ManagedFsFailure>()));
        expect(contents(profile), before);
        expect(outside.readAsStringSync(), 'outside synthetic data');
        expect(Directory(pending()).existsSync(), isFalse);
      },
      skip: kind == 'link' && Platform.isWindows,
    );
  }

  for (final after in [false, true]) {
    test(
      'publication failure after=$after preserves absence or the complete recoverable plan',
      () async {
        final watch = _Watch()
          ..refuseBefore = !after
          ..refuseAfter = after;
        final before = contents(coordinator());
        await expectLater(
          prepare(platform: watch),
          throwsA(
            isA<ManagedFsFailure>().having(
              (e) => e.toString(),
              'bounded',
              isNot(contains(profile)),
            ),
          ),
        );
        expect(watch.rootCreationAttempts, 0);
        expect(Directory('$profile/identities').existsSync(), isFalse);
        if (!after) {
          expect(contents(coordinator()), before);
          await prepare();
        } else {
          expect(File(plan()).existsSync(), isTrue);
          expect(
            () => ManagedDirectoryCatalog.openExisting(profile),
            throwsA(isA<ManagedFsFailure>()),
          );
        }
        final e = recover();
        await e.removeManagedFiles(
          retireScopes: (catalog) async {
            expect(catalog.identities, isEmpty);
          },
        );
        expect(File(plan()).existsSync(), isTrue);
      },
    );
  }

  test(
    'root appearance during staging refuses publication and preserves the new content',
    () async {
      final watch = _Watch()..duringStage = insertRoot;
      await expectLater(
        prepare(platform: watch),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(Directory(pending()).existsSync(), isFalse);
      expect(File('$profile/identities/foreign-fixture').readAsBytesSync(), [
        9,
        8,
        7,
      ]);
      expect(
        Directory(
          coordinator(),
        ).listSync().any((f) => f.path.contains('/.erasure-')),
        isFalse,
      );
    },
  );

  test(
    'root appearance before recovery refuses without changing intent or content',
    () async {
      await prepare();
      insertRoot();
      final before = contents(profile);
      ManagedRootErasure? unexpected;
      try {
        expect(
          () => unexpected = ManagedRootErasure.openPending(profile),
          throwsA(isA<ManagedFsFailure>()),
        );
      } finally {
        unexpected?.close();
      }
      expect(contents(profile), before);
    },
  );

  for (final during in [false, true]) {
    test(
      'root appearance duringRetirement=$during refuses before any unplanned unlink',
      () async {
        await prepare();
        final e = recover();
        var callbacks = 0;
        if (!during) insertRoot();
        await expectLater(
          e.removeManagedFiles(
            retireScopes: (_) async {
              callbacks++;
              if (during) insertRoot();
            },
            afterUnlink: (_) async => fail('No root unlink is authorized'),
          ),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(callbacks, during ? 1 : 0);
        expect(File('$profile/identities/foreign-fixture').readAsBytesSync(), [
          9,
          8,
          7,
        ]);
        expect(File(plan()).existsSync(), isTrue);
        await expectLater(
          e.finish(
            verifyOtherDataAbsent: () async =>
                fail('Root absence is a prerequisite'),
          ),
          throwsA(isA<ManagedFsFailure>()),
        );
      },
    );
  }

  test(
    'a nonempty catalog cannot be paired with an empty deletion inventory',
    () async {
      await prepare();
      final raw = jsonDecode(File(plan()).readAsStringSync()) as Map;
      raw['catalog'] = ManagedIdentityCatalog([
        ManagedIdentityEntry(
          id: ManagedIdentityId('1' * 32),
          protection: StorageProtection.unencrypted,
        ),
      ]).encode();
      File(plan()).writeAsStringSync(jsonEncode(raw));
      final before = contents(profile);
      expect(
        () => ManagedRootErasure.openPending(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(contents(profile), before);
    },
  );

  test(
    'unreadable saved-entry metadata is retained and cannot be called an empty profile',
    () async {
      final store = RetirementSecretStore(), auth = RetirementAuthentication();
      final legacy = File('$profile/legacy-fixture')
        ..writeAsStringSync('synthetic legacy data');
      final key = 'false:xveil.quick.v1.$scope';
      store.values[key] = jsonEncode({'v': 99, 'unknown': 'synthetic'});
      await prepare();
      final e = recover();
      final r = QuickUnlockRetirement.forManagedErasure(e, store, auth);
      final before = Map.of(store.values);
      await expectLater(
        e.removeManagedFiles(retireScopes: (_) => r.retire()),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.values, before);
      expect(legacy.readAsStringSync(), 'synthetic legacy data');
      expect(File(plan()).existsSync(), isTrue);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );

  test('another profile cannot adopt an absent-root plan', () async {
    await prepare();
    final bytes = File(plan()).readAsBytesSync();
    final other = '${fixture.path}/other';
    expect(fs.createPrivateDirectory(other), isTrue);
    StorageProfileCoordinator.createOrOpen(other).close();
    final destination =
        '$other/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}';
    expect(fs.createPrivateDirectory(destination), isTrue);
    final copy = File('$destination/plan.json')..createSync(exclusive: true);
    fs.restrictNewFile(copy.path);
    copy.writeAsBytesSync(bytes);
    expect(
      () => ManagedRootErasure.openPending(other),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(copy.readAsBytesSync(), bytes);
    expect(Directory('$other/identities').existsSync(), isFalse);
  });

  test(
    'a published intent cannot be replaced through the original ordinary owner',
    () async {
      final owner = parent();
      await ManagedRootErasure.prepareAbsent(
        owner,
        unlockScopes: StorageUnlockScopes([scope]),
      );
      final bytes = File(plan()).readAsBytesSync();
      await expectLater(
        ManagedRootErasure.prepareAbsent(
          owner,
          unlockScopes: StorageUnlockScopes(['b' * 64]),
        ),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(File(plan()).readAsBytesSync(), bytes);
      owner.close();
      expect(
        () => StorageProfileCoordinator.openExisting(profile, exclusive: true),
        throwsA(isA<ManagedFsFailure>()),
      );
      final e = recover();
      expect(e.unlockScopes.ids, [scope]);
    },
  );
  test(
    'a released receipt cannot authorize a later absent-root intent when object IDs are reused',
    () async {
      final platform = _ReusedDirectoryIds();
      await prepare();
      final first = recover(platform: platform);
      await first.removeManagedFiles(retireScopes: (_) async {});
      await first.finish(verifyOtherDataAbsent: () async {});
      final oldReceipt = first.releaseCompleted();
      await prepare();
      final second = recover(platform: platform);
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(oldReceipt.authorizes(first.binding), isTrue);
      expect(oldReceipt.authorizes(second.binding), isFalse);
    },
  );
  for (final malformed in [
    'missing',
    'short',
    'long',
    'uppercase',
    'type',
    'oldVersion',
    'previousVersion',
  ]) {
    test(
      'a missing or malformed operation binding $malformed refuses without changing files',
      () async {
        await prepare();
        final raw = jsonDecode(File(plan()).readAsStringSync()) as Map;
        expect(raw['v'], 6);
        expect(raw['operation'], matches(RegExp(r'^[0-9a-f]{32}$')));
        switch (malformed) {
          case 'missing':
            raw.remove('operation');
          case 'short':
            raw['operation'] = 'a' * 31;
          case 'long':
            raw['operation'] = 'a' * 33;
          case 'uppercase':
            raw['operation'] = 'A' * 32;
          case 'type':
            raw['operation'] = 1;
          case 'previousVersion':
            raw['v'] = 5;
          case 'oldVersion':
            raw['v'] = 3;
            raw.remove('operation');
        }
        File(plan()).writeAsStringSync(jsonEncode(raw));
        final before = contents(profile);
        expect(
          () => ManagedRootErasure.openPending(profile),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(contents(profile), before);
        expect(Directory('$profile/identities').existsSync(), isFalse);
      },
    );
  }
}
