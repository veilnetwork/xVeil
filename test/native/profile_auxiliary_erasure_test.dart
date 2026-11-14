@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/data/storage/profile_preferences.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/profile_model_layout.dart';
import '../support/retirement_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fs = ManagedFsPlatform(), ns = 'synthetic-auxiliary-profile';
  late Directory fixture;
  late String profile, legacy;
  late RetirementSecretStore store;
  final auth = RetirementAuthentication();
  final workers = <ManagedErasureWorker>[];
  final actors = <ManagedRootErasure>[];
  final id = ManagedIdentityId('1' * 32);
  final locator = ManagedStorageLocator(
    id: id,
    protection: StorageProtection.unencrypted,
  );
  String path(String relative) => '${fixture.path}/$relative';
  File file(String relative) {
    final f = File(path(relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('synthetic $relative bytes');
    return f;
  }

  Map<String, String> contents() => {
    for (final f
        in fixture
            .listSync(recursive: true, followLinks: false)
            .whereType<File>())
      f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };
  String planPath() =>
      '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}/plan.json';
  ProfileErasureAuxiliaryTargets targets({String? legacyPath}) =>
      ProfileErasureAuxiliaryTargets(legacyPath: legacyPath ?? legacy);
  Future<ManagedErasureWorker> begin({
    bool releaseGate = false,
    SendPort? checkpoint,
  }) async {
    final worker = releaseGate
        ? await ManagedErasureWorker.beginWithReleaseGateForTesting(
            profileDirectory: profile,
            profileNamespace: ns,
            legacyPath: legacy,
            auxiliary: targets(),
            afterNativeRelease: checkpoint!,
          )
        : await ManagedErasureWorker.begin(
            profileDirectory: profile,
            profileNamespace: ns,
            legacyPath: legacy,
            auxiliary: targets(),
          );
    workers.add(worker);
    return worker;
  }

  QuickUnlockRetirement retirement(ManagedErasureWorker worker) =>
      QuickUnlockRetirement.forWorker(worker.scopeLease, store, auth);
  Future<ManagedErasureWorker> recover() async {
    final w = await ManagedErasureWorker.recover(profile);
    workers.add(w);
    return w;
  }

  Future<ManagedErasureWorker> reconcile(ManagedErasureBinding binding) async {
    final w = await ManagedErasureWorker.reconcile(profile, binding);
    workers.add(w);
    return w;
  }

  setUp(() async {
    fixture = Directory.systemTemp.createTempSync('xveil-auxiliary-erasure-');
    profile = path('visible-storage');
    legacy = path('xveil.store');
    expect(fs.createPrivateDirectory(profile), isTrue);
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      ManagedIdentityFiles.createUnencrypted(root, id: id).close();
    } finally {
      root.close();
    }
    for (final name in [
      'xveil.store',
      'xveil.prefs.json',
      'xveil.prefs.json.tmp',
      '.xveil.store.hv-rotate.${'a' * 16}.tmp',
      'blobs/${'a' * 16}/p0',
      'blobs/${'a' * 16}/p1.tmp',
      ProfileModelLayout.speechFile,
      '${ProfileModelLayout.speechFile}.part',
      '.incoming-speech/${ProfileModelLayout.speechFile}',
      for (final prefix in ['ru-en', '.incoming-de-en', '.replacing-fr-en'])
        for (final name in ProfileModelLayout.translationFiles)
          'translate/$prefix/$name',
      'translate/ru-en/model.bin.part',
      'translate/.github-downloads/${'b' * 16}-ru-en.veiltranslate.part',
      'keep.txt',
      'profiles/unrelated/xveil.store',
      'profiles/unrelated/xveil.prefs.json',
    ]) {
      file(name);
    }
    store = RetirementSecretStore();
    final scopes = StorageUnlockScopes.forProfile(
      profile: ns,
      legacyPath: legacy,
      managedPath: Directory(profile).absolute.uri.normalizePath().toFilePath(),
      identities: [locator],
    );
    for (final scope in scopes.ids) {
      await QuickUnlockVault(
        store,
        scope,
        auth,
      ).configure(password: 'synthetic credential', system: true);
    }
  });
  tearDown(() async {
    for (final w in workers) {
      try {
        await w.close();
      } catch (_) {}
    }
    for (final a in actors) {
      a.close();
    }
    workers.clear();
    actors.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'auxiliary and OS scope paths must use the same original spelling',
    () async {
      final before = contents();
      await expectLater(
        ManagedErasureWorker.begin(
          profileDirectory: profile,
          profileNamespace: ns,
          legacyPath: legacy,
          auxiliary: targets(legacyPath: '${fixture.path}/./xveil.store'),
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(contents(), before);
      expect(File(planPath()).existsSync(), isFalse);
    },
  );

  test(
    'durable auxiliary inventory survives owner restart and retires exact OS scopes',
    () async {
      final w = await begin(), r = retirement(workers.last);
      final view = await w.snapshot();
      final raw = jsonDecode(File(planPath()).readAsStringSync()) as Map;
      expect(
        File(planPath()).readAsStringSync(),
        isNot(contains(fixture.path)),
      );
      expect(raw['v'], 6);
      expect(raw['applicationProfile'], isFalse);
      expect((raw['auxiliary'] as Map)['entries'], isNotEmpty);
      expect(
        ((raw['auxiliary'] as Map)['scope'] as Map)['preferences'],
        isTrue,
      );
      await w.removeManagedFiles(retireScopes: r.retire);
      expect(store.values, isEmpty);
      var verificationCalls = 0;
      await expectLater(
        w.finish(
          verifyOtherDataAbsent: () async {
            verificationCalls++;
          },
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(verificationCalls, 0);
      await w.close();
      final resumed = await recover();
      await resumed.removeAuxiliaryFiles(retireScopes: r.retire);
      final release = await resumed.finish(
        verifyOtherDataAbsent: r.verifyAbsent,
      );
      expect(release.authorizes(view.binding), isTrue);
      r.admitFreshLifetime(release);
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(
        fixture
            .listSync()
            .map((e) => e.uri.pathSegments.where((v) => v.isNotEmpty).last)
            .toSet(),
        {'visible-storage', 'keep.txt', 'profiles'},
      );
      expect(File(path('profiles/unrelated/xveil.store')).existsSync(), isTrue);
    },
  );

  test(
    'auxiliary erasure removes preferences and preserves unrelated preferences',
    () async {
      final w = await begin(), r = retirement(workers.last);
      await w.removeManagedFiles(retireScopes: r.retire);
      await w.removeAuxiliaryFiles(retireScopes: r.retire);
      await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
      for (final name in ['xveil.prefs.json', 'xveil.prefs.json.tmp']) {
        expect(File(path(name)).existsSync(), isFalse, reason: name);
      }
      expect(
        File(path('profiles/unrelated/xveil.prefs.json')).readAsStringSync(),
        'synthetic profiles/unrelated/xveil.prefs.json bytes',
      );
    },
  );

  test(
    'accepted real preference writes drain before inventory and cannot recreate erased files',
    () async {
      final original = SharedPreferencesStorePlatform.instance;
      final backend = await ProfilePreferencesStore.load(
        path('xveil.prefs.json'),
      );
      SharedPreferencesStorePlatform.instance = backend;
      final owner = ProfilePreferencesLifetime.current();
      try {
        final prefs = await owner.preferences;
        final saves = [
          prefs.setString('synthetic.choice', 'one'),
          prefs.setBool('synthetic.flag', true),
        ];
        await owner.retire();
        expect(await Future.wait(saves), [true, true]);
        final pointer = file('xveil.profile');
        final w = await begin(), r = retirement(workers.last);
        await w.removeManagedFiles(retireScopes: r.retire);
        await w.removeAuxiliaryFiles(
          retireScopes: () async {
            await owner.retire();
            await r.retire();
          },
        );
        await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
        await expectLater(prefs.setString('late', 'value'), throwsStateError);
        for (final name in ['xveil.prefs.json', 'xveil.prefs.json.tmp']) {
          expect(File(path(name)).existsSync(), isFalse);
        }
        expect(pointer.readAsStringSync(), 'synthetic xveil.profile bytes');
        expect(
          File(path('profiles/unrelated/xveil.prefs.json')).existsSync(),
          isTrue,
        );
      } finally {
        await owner.retire();
        SharedPreferencesStorePlatform.instance = original;
      }
    },
  );

  test(
    'refused auxiliary retirement preserves the whole captured tree',
    () async {
      final w = await begin();
      final before = contents();
      await expectLater(
        w.removeAuxiliaryFiles(
          retireScopes: () async {
            throw StateError('synthetic refusal');
          },
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(contents(), before);
      final r = retirement(w);
      await w.removeAuxiliaryFiles(retireScopes: r.retire);
      await w.removeManagedFiles(retireScopes: r.retire);
      await w.finish(verifyOtherDataAbsent: r.verifyAbsent);
    },
  );

  for (final mutation in [
    'replace',
    'grow',
    'new-rewrite',
    'foreign-child',
    'symlink',
    'replace-preferences',
    'grow-preferences',
    'new-preference-temporary',
  ]) {
    test(
      'changed auxiliary $mutation refuses before OS side effects and preserves all files',
      () async {
        if (mutation == 'new-preference-temporary') {
          File(path('xveil.prefs.json.tmp')).deleteSync();
        }
        final w = await begin();
        switch (mutation) {
          case 'replace-preferences':
            File(
              path('xveil.prefs.json'),
            ).renameSync(path('preserved-old-prefs'));
            file('xveil.prefs.json');
          case 'grow-preferences':
            File(
              path('xveil.prefs.json'),
            ).writeAsStringSync('changed preferences');
          case 'new-preference-temporary':
            file('xveil.prefs.json.tmp');
          case 'replace':
            File(legacy).renameSync(path('preserved-old-container'));
            file('xveil.store');
          case 'grow':
            File(legacy).writeAsStringSync('changed size');
          case 'new-rewrite':
            file('.xveil.store.hv-compact.${'c' * 16}.tmp');
          case 'foreign-child':
            file('translate/ru-en/unrecognized-file');
          case 'symlink':
            Directory(path('blobs')).renameSync(path('preserved-blobs'));
            Link(path('blobs')).createSync(path('profiles/unrelated'));
        }
        final before = contents();
        var calls = 0;
        await expectLater(
          w.removeAuxiliaryFiles(
            retireScopes: () async {
              calls++;
            },
          ),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        expect(calls, 0);
        expect(contents(), before);
      },
      skip: Platform.isWindows && mutation == 'symlink'
          ? 'POSIX symlink fixture'
          : false,
    );
  }

  test(
    'unknown original model content refuses preparation without publishing an intent',
    () async {
      file('translate/ru-en/unrecognized-file');
      final before = contents();
      await expectLater(begin(), throwsA(isA<ManagedWorkerFailure>()));
      expect(contents(), before);
      expect(File(planPath()).existsSync(), isFalse);
    },
  );

  for (final invalid in ['directory', 'link']) {
    test(
      'a preference $invalid refuses capture without touching either profile',
      () async {
        final prefs = File(path('xveil.prefs.json'));
        prefs.deleteSync();
        final sibling = File(path('profiles/unrelated/xveil.prefs.json'));
        if (invalid == 'directory') {
          Directory(prefs.path).createSync();
        } else {
          Link(prefs.path).createSync(sibling.path);
        }
        final before = contents();
        await expectLater(begin(), throwsA(isA<ManagedWorkerFailure>()));
        expect(contents(), before);
        expect(File(planPath()).existsSync(), isFalse);
        expect(
          FileSystemEntity.typeSync(prefs.path, followLinks: false),
          invalid == 'directory'
              ? FileSystemEntityType.directory
              : FileSystemEntityType.link,
        );
        expect(
          sibling.readAsStringSync(),
          'synthetic profiles/unrelated/xveil.prefs.json bytes',
        );
      },
      skip: Platform.isWindows && invalid == 'link'
          ? 'POSIX symlink fixture'
          : false,
    );
  }

  for (final bad in [
    'base',
    'traversal',
    'duplicate',
    'extra',
    'old-version',
    'missing-preferences',
    'disabled-preferences',
    'invalid-preferences',
  ]) {
    test(
      'malformed auxiliary $bad is preserved on explicit recovery',
      () async {
        final w = await begin();
        await w.close();
        final raw = jsonDecode(File(planPath()).readAsStringSync()) as Map;
        final auxiliary = raw['auxiliary'] as Map;
        switch (bad) {
          case 'base':
            (auxiliary['scope'] as Map)['base'] = path('profiles/unrelated');
          case 'traversal':
            ((auxiliary['entries'] as List).first as List)[0] = '../unrelated';
          case 'duplicate':
            (auxiliary['entries'] as List).add(
              (auxiliary['entries'] as List).first,
            );
          case 'extra':
            auxiliary['ignored'] = true;
          case 'old-version':
            raw['v'] = 5;
            raw.remove('applicationProfile');
          case 'missing-preferences':
            (auxiliary['scope'] as Map).remove('preferences');
          case 'disabled-preferences':
            (auxiliary['scope'] as Map)['preferences'] = false;
          case 'invalid-preferences':
            (auxiliary['scope'] as Map)['preferences'] = 'true';
        }
        File(planPath()).writeAsStringSync(jsonEncode(raw), flush: true);
        final before = contents();
        await expectLater(recover(), throwsA(isA<ManagedWorkerFailure>()));
        expect(contents(), before);
      },
    );
  }

  for (final replacement in [
    'xveil.store',
    'xveil.prefs.json',
    'xveil.prefs.json.tmp',
  ]) {
    test(
      'terminal-only recovery refuses newly appearing auxiliary data without deleting it ($replacement)',
      () async {
        final w = await begin(), r = retirement(workers.last);
        await w.removeManagedFiles(retireScopes: r.retire);
        await w.removeAuxiliaryFiles(retireScopes: r.retire);
        await w.close();
        final actor = ManagedRootErasure.openPending(profile);
        actors.add(actor);
        await expectLater(
          actor.finish(
            verifyOtherDataAbsent: r.verifyAbsent,
            afterStage: (stage) async {
              if (stage == ManagedErasureFinishStage.planRemoved) {
                final text = File(
                  '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.completionName}',
                ).readAsStringSync();
                for (final value in [
                  fixture.path,
                  'catalog',
                  'unlockScopes',
                  'entries',
                  'synthetic credential',
                  id.value,
                ]) {
                  expect(text, isNot(contains(value)));
                }
                throw StateError('synthetic terminal cut');
              }
            },
          ),
          throwsStateError,
        );
        actor.close();
        expect(File(planPath()).existsSync(), isFalse);
        file(replacement);
        final before = contents();
        await expectLater(recover(), throwsA(isA<ManagedWorkerFailure>()));
        expect(contents(), before);
        File(path(replacement)).deleteSync();
        final resumed = await recover();
        await resumed.finish(verifyOtherDataAbsent: r.verifyAbsent);
      },
    );
  }

  for (final replacement in [
    'xveil.store',
    'xveil.prefs.json',
    'xveil.prefs.json.tmp',
  ]) {
    test(
      'release rechecks auxiliary absence after finalization before closing its grant ($replacement)',
      () async {
        final w = await begin(), r = retirement(workers.last);
        await w.removeManagedFiles(retireScopes: r.retire);
        await w.removeAuxiliaryFiles(retireScopes: r.retire);
        await w.close();
        final actor = ManagedRootErasure.openPending(profile);
        actors.add(actor);
        await actor.finish(verifyOtherDataAbsent: r.verifyAbsent);
        final fresh = file(replacement);
        try {
          expect(actor.releaseCompleted, throwsA(isA<ManagedFsFailure>()));
          expect(fresh.readAsStringSync(), 'synthetic $replacement bytes');
        } finally {
          fresh.deleteSync();
        }
        final receipt = actor.releaseCompleted();
        r.admitFreshLifetime(receipt);
      },
    );
  }

  for (final replacement in [
    'xveil.store',
    'xveil.prefs.json',
    'xveil.prefs.json.tmp',
  ]) {
    test(
      'lost-release reconciliation retains auxiliary absence checks in the opaque binding ($replacement)',
      () async {
        final checkpoint = ReceivePort();
        addTearDown(checkpoint.close);
        final w = await begin(
              releaseGate: true,
              checkpoint: checkpoint.sendPort,
            ),
            r = retirement(workers.last);
        final binding = (await w.snapshot()).binding;
        await w.removeManagedFiles(retireScopes: r.retire);
        await w.removeAuxiliaryFiles(retireScopes: r.retire);
        final result = w
            .finish(verifyOtherDataAbsent: r.verifyAbsent)
            .then<Object?>((v) => v, onError: (Object e) => e);
        await checkpoint.first;
        w.killReleasedWorkerForTesting();
        expect(await result, isA<ManagedWorkerFailure>());
        file(replacement);
        final before = contents();
        await expectLater(
          reconcile(binding),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        expect(contents(), before);
        File(path(replacement)).deleteSync();
        final recovered = await reconcile(binding);
        final receipt = await recovered.finish(
          verifyOtherDataAbsent: r.verifyAbsent,
        );
        expect(receipt.authorizes(binding), isTrue);
        r.admitFreshLifetime(receipt);
      },
    );
  }
}
