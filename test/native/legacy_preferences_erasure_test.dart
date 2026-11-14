@Timeout(Duration(minutes: 3))
library;

import 'dart:async' show Completer;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/app_profile.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/profile_preferences_bootstrap.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import 'package:xveil/data/storage/legacy_profile_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late SharedPreferencesStorePlatform original;
  late _Source source;
  final stores = <ProfilePreferencesStore>[];
  final workers = <ManagedErasureWorker>[];
  String getProfile(String name) =>
      name == 'default' ? support.path : '${support.path}/profiles/$name';
  String managed(String name) => '${getProfile(name)}/visible-storage';
  Future<void> blockSibling([String profile = 'decoy']) async {
    Directory(getProfile(profile)).createSync(recursive: true);
    StorageProfileCoordinator.forPreferences(getProfile(profile)).close();
    final gate = StorageProfileCoordinator.openExisting(
      managed(profile),
      exclusive: true,
    )!;
    try {
      await ManagedRootErasure.prepareAbsent(
        gate,
        unlockScopes: StorageUnlockScopes(['a' * 64]),
      );
    } finally {
      gate.close();
    }
  }

  Future<ProfilePreferencesBootstrap> boot([String? profile]) async {
    final result = await bootstrapProfilePreferences(
      supportDir: () async => support.path,
      args: profile == null ? const [] : ['--profile', profile],
      environment: const {},
      managedStorage: true,
    );
    stores.add(
      SharedPreferencesStorePlatform.instance as ProfilePreferencesStore,
    );
    return result;
  }

  Future<
    ({
      LegacyProfilePreferences source,
      ManagedErasureWorker worker,
      LegacyProfilePreferencesRetirement retirement,
    })
  >
  prepare() async {
    await blockSibling();
    final initial = await boot();
    await stores.last.releaseFile();
    final legacy = '${support.path}/xveil.store';
    final worker = await ManagedErasureWorker.begin(
      profileDirectory: managed('default'),
      profileNamespace: 'default',
      legacyPath: legacy,
      auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
    );
    workers.add(worker);
    return (
      source: initial.legacyPreferences!,
      worker: worker,
      retirement: LegacyProfilePreferencesRetirement.forWorker(
        worker,
        initial.legacyPreferences!,
      ),
    );
  }

  Future<ManagedErasureRelease> finish(
    ManagedErasureWorker worker,
    LegacyProfilePreferencesRetirement retirement,
  ) async {
    await worker.removeManagedFiles(retireScopes: retirement.retire);
    await worker.removeAuxiliaryFiles(retireScopes: retirement.retire);
    return worker.finish(verifyOtherDataAbsent: retirement.verifyAbsent);
  }

  setUp(() {
    support = Directory.systemTemp.createTempSync('xveil-legacy-pref-erasure-');
    original = SharedPreferencesStorePlatform.instance;
    source = _Source({'flutter.locale': 'old', 'flutter.locale.decoy': 'de'});
    SharedPreferencesStorePlatform.instance = source;
  });
  tearDown(() async {
    for (final store in stores) {
      await store.releaseFile();
    }
    for (final worker in workers) {
      await worker.close();
    }
    stores.clear();
    workers.clear();
    SharedPreferencesStorePlatform.instance = original;
    support.deleteSync(recursive: true);
  });

  test(
    'a retained legacy copy cannot resurrect preferences after a complete profile wipe',
    () async {
      await blockSibling();
      final initial = await boot();
      expect(initial.legacyPreferences, same(stores.last.legacyPreferences));
      expect((await source.getAll())['flutter.locale'], 'old');
      await stores.last.releaseFile();
      final legacy = '${support.path}/xveil.store';
      final worker = await ManagedErasureWorker.begin(
        profileDirectory: managed('default'),
        profileNamespace: 'default',
        legacyPath: legacy,
        auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
      );
      workers.add(worker);
      final retirement = LegacyProfilePreferencesRetirement.forWorker(
        worker,
        initial.legacyPreferences!,
      );
      await worker.removeManagedFiles(retireScopes: retirement.retire);
      await worker.removeAuxiliaryFiles(retireScopes: retirement.retire);
      final receipt = await worker.finish(
        verifyOtherDataAbsent: retirement.verifyAbsent,
      );
      retirement.admitFreshLifetime(receipt);
      expect(File('${support.path}/xveil.prefs.json').existsSync(), isFalse);
      // Simulate cold startup with the original platform preference source.
      SharedPreferencesStorePlatform.instance = source;
      await boot();
      expect((await stores.last.getAll())['flutter.locale'], isNull);
      expect((await source.getAll())['flutter.locale.decoy'], 'de');
    },
  );
  test(
    'wrong namespace and closed worker refuse before reading or deleting platform data',
    () async {
      final prepared = await prepare();
      final wrong = LegacyProfilePreferences(
        backend: source,
        supportDirectory: support.path,
        profile: 'decoy',
        legacyPath: '${getProfile('decoy')}/xveil.store',
      );
      final reads = source.reads;
      expect(
        () => LegacyProfilePreferencesRetirement.forWorker(
          prepared.worker,
          wrong,
        ),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(source.reads, reads);
      expect(source.removes, isEmpty);
      await prepared.worker.close();
      expect(
        () => LegacyProfilePreferencesRetirement.forWorker(
          prepared.worker,
          prepared.source,
        ),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(source.reads, reads);
      expect(source.removes, isEmpty);
    },
  );

  test(
    'root-only erasure does not authorize platform preference removal',
    () async {
      await blockSibling();
      final initial = await boot();
      await stores.last.releaseFile();
      final worker = await ManagedErasureWorker.begin(
        profileDirectory: managed('default'),
        profileNamespace: 'default',
        legacyPath: '${support.path}/xveil.store',
      );
      workers.add(worker);
      expect((await worker.snapshot()).erasesProfilePreferences, isFalse);
      final before = source.reads;
      expect(
        () => LegacyProfilePreferencesRetirement.forWorker(
          worker,
          initial.legacyPreferences!,
        ),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(source.reads, before);
      expect(source.removes, isEmpty);
      expect(File('${support.path}/xveil.prefs.json').existsSync(), isTrue);
    },
  );

  test(
    'only the selected namespace is removed using the longest known profile suffix',
    () async {
      Directory('${support.path}/profiles/a').createSync(recursive: true);
      Directory('${support.path}/profiles/x.a').createSync(recursive: true);
      await source.setValue('String', 'flutter.preference.a', 'a');
      await source.setValue('String', 'flutter.preference.x.a', 'xa');
      await source.setValue(
        'String',
        'flutter.${AppProfiles.activePref}',
        'default',
      );
      final prepared = await prepare();
      // Model a failed old-system removal, not a new file preference write.
      await source.setValue('String', 'flutter.preference.a', 'a');
      await source.setValue('String', 'flutter.preference.x.a', 'xa');
      await source.setValue(
        'String',
        'flutter.${AppProfiles.activePref}',
        'default',
      );
      await prepared.worker.snapshot();
      await prepared.retirement.retire();
      expect(await source.getAll(), {
        'flutter.locale.decoy': 'de',
        'flutter.preference.a': 'a',
        'flutter.preference.x.a': 'xa',
        'flutter.${AppProfiles.activePref}': 'default',
      });
      expect(source.removes, ['flutter.locale']);
    },
  );

  test(
    'named profile cleanup preserves default data and longer dotted namespaces',
    () async {
      await blockSibling('default');
      Directory(getProfile('x.a')).createSync(recursive: true);
      await source.setValue('String', 'flutter.preference.a', 'a');
      await source.setValue('String', 'flutter.preference.x.a', 'xa');
      final initial = await boot('a');
      final sibling = File('${getProfile('x.a')}/xveil.prefs.json');
      final preserved = sibling.readAsStringSync();
      await stores.last.releaseFile();
      final legacy = '${getProfile('a')}/xveil.store';
      final worker = await ManagedErasureWorker.begin(
        profileDirectory: managed('a'),
        profileNamespace: 'a',
        legacyPath: legacy,
        auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
      );
      workers.add(worker);
      final retirement = LegacyProfilePreferencesRetirement.forWorker(
        worker,
        initial.legacyPreferences!,
      );
      final receipt = await finish(worker, retirement);
      retirement.admitFreshLifetime(receipt);
      expect(source.removes, ['flutter.preference.a']);
      final remaining = await source.getAll();
      expect(remaining['flutter.locale'], 'old');
      expect(remaining['flutter.preference.x.a'], 'xa');
      expect(sibling.readAsStringSync(), preserved);
      SharedPreferencesStorePlatform.instance = source;
      await boot('a');
      expect((await stores.last.getAll())['flutter.preference'], isNull);
    },
  );

  test(
    'failed removal blocks file erasure and can be retried without touching siblings',
    () async {
      final prepared = await prepare();
      final file = File('${support.path}/xveil.prefs.json'),
          before = File('${support.path}/xveil.prefs.json').readAsStringSync();
      source.failKey = 'flutter.locale';
      await expectLater(
        prepared.worker.removeManagedFiles(
          retireScopes: prepared.retirement.retire,
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(file.readAsStringSync(), before);
      expect((await source.getAll())['flutter.locale'], 'old');
      await expectLater(
        prepared.retirement.verifyAbsent(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      source.failKey = null;
      final receipt = await finish(prepared.worker, prepared.retirement);
      prepared.retirement.admitFreshLifetime(receipt);
      expect(await source.getAll(), {'flutter.locale.decoy': 'de'});
    },
  );

  test(
    'false acknowledgement after removal is not mistaken for successful retirement',
    () async {
      final prepared = await prepare();
      source.falseAfterApply = true;
      source.failKey = 'flutter.locale';
      await expectLater(
        prepared.retirement.retire(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect((await source.getAll()).containsKey('flutter.locale'), isFalse);
      await expectLater(
        prepared.retirement.verifyAbsent(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      source.failKey = null;
      await prepared.retirement.retire();
      expect(source.removes, ['flutter.locale', 'flutter.locale']);
      await prepared.retirement.verifyAbsent();
    },
  );

  test(
    'read-only verification preserves newly appearing data and refuses finalization',
    () async {
      final prepared = await prepare();
      await prepared.worker.removeManagedFiles(
        retireScopes: prepared.retirement.retire,
      );
      await prepared.worker.removeAuxiliaryFiles(
        retireScopes: prepared.retirement.retire,
      );
      await source.setValue('String', 'flutter.new', 'preserve');
      final before = source.removes.length;
      await expectLater(
        prepared.worker.finish(
          verifyOtherDataAbsent: prepared.retirement.verifyAbsent,
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(source.removes.length, before);
      expect((await source.getAll())['flutter.new'], 'preserve');
      expect(
        File(
          '${managed('default')}/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.completionName}',
        ).existsSync(),
        isFalse,
      );
      // Explicitly resume the same authorized erasure, rather than deleting in verify.
      await prepared.retirement.retire();
      final receipt = await prepared.worker.finish(
        verifyOtherDataAbsent: prepared.retirement.verifyAbsent,
      );
      prepared.retirement.admitFreshLifetime(receipt);
    },
  );

  test(
    'source read failure and an unreadable profile roster fail closed',
    () async {
      final prepared = await prepare();
      source.readFailure = true;
      await expectLater(
        prepared.retirement.retire(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(source.removes, isEmpty);
      source.readFailure = false;
      Directory(
        '${support.path}/profiles',
      ).renameSync('${support.path}/preserved-profiles');
      File('${support.path}/profiles').writeAsStringSync('not a directory');
      await expectLater(
        prepared.retirement.retire(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(source.removes, isEmpty);
      expect((await source.getAll())['flutter.locale.decoy'], 'de');
    },
  );

  test(
    'worker close joins accepted source cleanup and recovery re-verifies it',
    () async {
      final prepared = await prepare();
      final gate = source.removeGate = Completer<bool>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(true);
      });
      final removal = prepared.worker.removeManagedFiles(
        retireScopes: prepared.retirement.retire,
      );
      final outcome = removal.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await source.removeStarted.future;
      var closed = false;
      final closing = prepared.worker.close().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      await expectLater(
        prepared.source.verifyAbsent(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      gate.complete(true);
      expect(await outcome, isA<ManagedWorkerFailure>());
      await closing;
      expect(File('${support.path}/xveil.prefs.json').existsSync(), isTrue);
      SharedPreferencesStorePlatform.instance = source;
      final startup = await bootstrapProfilePreferences(
        supportDir: () async => support.path,
        args: const [],
        environment: const {},
        managedStorage: true,
      );
      expect(startup.erasurePending, isTrue);
      expect(startup.legacyPreferences, isNotNull);
      final resumed = await ManagedErasureWorker.recover(managed('default'));
      workers.add(resumed);
      final retirement = LegacyProfilePreferencesRetirement.forWorker(
        resumed,
        startup.legacyPreferences!,
      );
      final receipt = await finish(resumed, retirement);
      retirement.admitFreshLifetime(receipt);
    },
  );

  test(
    'receipt belongs to its exact operation and old owners cannot erase fresh state',
    () async {
      final prepared = await prepare();
      final receipt = await finish(prepared.worker, prepared.retirement);
      final second = await ManagedErasureWorker.begin(
        profileDirectory: managed('default'),
        profileNamespace: 'default',
        legacyPath: '${support.path}/xveil.store',
        auxiliary: ProfileErasureAuxiliaryTargets(
          legacyPath: '${support.path}/xveil.store',
        ),
      );
      workers.add(second);
      final other = LegacyProfilePreferencesRetirement.forWorker(
        second,
        prepared.source,
      );
      expect(
        () => prepared.retirement.admitFreshLifetime(receipt),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      final secondReceipt = await finish(second, other);
      expect(
        () => prepared.retirement.admitFreshLifetime(secondReceipt),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(
        () => other.admitFreshLifetime(receipt),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      other.admitFreshLifetime(secondReceipt);
      await source.setValue('String', 'flutter.fresh', 'preserve');
      await expectLater(
        prepared.retirement.retire(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      await expectLater(
        prepared.source.verifyAbsent(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect((await source.getAll())['flutter.fresh'], 'preserve');
    },
  );

  test(
    'fresh source installation requires release and cannot be repeated by an old owner',
    () async {
      final prepared = await prepare();
      final receipt = await finish(prepared.worker, prepared.retirement);
      var installs = 0;
      final entered = Completer<void>(), release = Completer<void>();
      Future<int> install(SharedPreferencesStorePlatform backend) async {
        installs++;
        expect(backend, same(source));
        entered.complete();
        await release.future;
        return installs;
      }

      await expectLater(
        prepared.retirement.bootstrapFresh(receipt, install),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(installs, 0);
      prepared.retirement.admitFreshLifetime(receipt);
      final installing = prepared.retirement.bootstrapFresh(receipt, install);
      await entered.future;
      await expectLater(
        prepared.retirement.bootstrapFresh(receipt, install),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      release.complete();
      expect(await installing, 1);
      await expectLater(
        prepared.retirement.bootstrapFresh(receipt, install),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(installs, 1);
    },
  );

  test(
    'pending startup retains the original source without granting cleanup',
    () async {
      await blockSibling();
      final profile = managed('default');
      StorageProfileCoordinator.forPreferences(support.path).close();
      final gate = StorageProfileCoordinator.openExisting(
        profile,
        exclusive: true,
      )!;
      try {
        await ManagedRootErasure.prepareAbsent(
          gate,
          unlockScopes: StorageUnlockScopes(['a' * 64]),
        );
      } finally {
        gate.close();
      }
      final pending = await bootstrapProfilePreferences(
        supportDir: () async => support.path,
        args: const [],
        environment: const {},
        managedStorage: true,
      );
      expect(pending.erasurePending, isTrue);
      expect(pending.legacyPreferences, isNotNull);
      expect(SharedPreferencesStorePlatform.instance, same(source));
      final before = source.removes.length;
      await expectLater(
        pending.legacyPreferences!.verifyAbsent(),
        throwsA(isA<LegacyProfilePreferencesFailure>()),
      );
      expect(source.removes.length, before);
      expect((await source.getAll())['flutter.locale'], 'old');
    },
  );
}

class _Source extends InMemorySharedPreferencesStore {
  _Source(super.data) : super.withData();
  int reads = 0;
  final removes = <String>[];
  String? failKey;
  bool falseAfterApply = false, readFailure = false;
  Completer<bool>? removeGate;
  final removeStarted = Completer<void>();
  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    if (readFailure) throw StateError('synthetic private platform detail');
    return super.getAll();
  }

  @override
  Future<bool> remove(String key) async {
    removes.add(key);
    if (!removeStarted.isCompleted) removeStarted.complete();
    if (removeGate case final gate?) {
      if (!await gate.future) return false;
    }
    if (key == failKey) {
      if (falseAfterApply) await super.remove(key);
      return false;
    }
    return super.remove(key);
  }
}
