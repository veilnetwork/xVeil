@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/cold_profile_erasure_recovery.dart';
import 'package:xveil/data/storage/legacy_profile_preferences.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_profile_wipe.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/profile_prefs_store.dart';
import '../support/retirement_secret_store.dart';
import '../support/background_resource_backend.dart';
import '../support/erasure_writer_process.dart';

class _Source extends SharedPreferencesStorePlatform {
  _Source(this.values);
  final Map<String, Object> values;
  int removes = 0;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> remove(String key) async {
    removes++;
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> clear() async =>
      throw StateError('recovery must not clear unrelated preferences');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late String profile, legacy;
  late SharedPreferencesStorePlatform original;
  late _Source platform;
  late RetirementSecretStore secrets;
  late BackgroundResourceBackend background;
  final workers = <ManagedErasureWorker>[];
  final recoveries = <ColdProfileErasureRecovery>[];
  LegacyProfilePreferences source() => LegacyProfilePreferences(
    backend: platform,
    supportDirectory: fixture.path,
    profile: 'default',
    legacyPath: legacy,
  );
  Future<ManagedErasureWorker> prepare({
    bool application = true,
    bool managed = false,
  }) async {
    if (managed) {
      final root = ManagedDirectoryCatalog.createOrOpen(profile);
      try {
        final encrypted = ManagedIdentityFiles.createEncrypted(
          root,
          id: ManagedIdentityId('1' * 32),
          password: Uint8List.fromList('synthetic password'.codeUnits),
        );
        encrypted.close();
        final plain = ManagedIdentityFiles.createUnencrypted(
          root,
          id: ManagedIdentityId('2' * 32),
        );
        plain.close();
        final scopes = StorageUnlockScopes.forProfile(
          profile: 'default',
          legacyPath: legacy,
          // Match the directory published by the frontend router, including
          // its normalized directory URI. Raw fixture spelling is not a scope.
          managedPath: Directory(
            profile,
          ).absolute.uri.normalizePath().toFilePath(),
          identities: root.snapshot().catalog.identities.map(
            (entry) => entry.locator,
          ),
        );
        for (final scope in scopes.ids.skip(1)) {
          await QuickUnlockVault(
            secrets,
            scope,
            RetirementAuthentication(),
          ).configure(password: 'synthetic password', system: true);
        }
      } finally {
        root.close();
      }
    }
    final worker = application
        ? await ManagedErasureWorker.beginApplicationProfile(
            profileDirectory: profile,
            profileNamespace: 'default',
            legacyPath: legacy,
            request: ManagedProfileErasureRequest(),
          )
        : await ManagedErasureWorker.begin(
            profileDirectory: profile,
            profileNamespace: 'default',
            legacyPath: legacy,
            auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
          );
    workers.add(worker);
    return worker;
  }

  ColdProfileErasureRecovery recovery() {
    final value = ColdProfileErasureRecovery(
      source: source(),
      secretStore: secrets,
      authentication: RetirementAuthentication(),
      retireBackground: background.actions().retireForErasure,
    );
    recoveries.add(value);
    return value;
  }

  Future<QuickUnlockAbsenceWitness> terminal(
    ManagedErasureWorker worker, {
    bool nativeGone = true,
  }) async {
    final lease = worker.scopeLease;
    final vault = QuickUnlockRetirement.forWorker(
      lease,
      secrets,
      RetirementAuthentication(),
    );
    final oldSource = source();
    final prefs = LegacyProfilePreferencesRetirement.forWorker(
      worker,
      oldSource,
    );
    final witness = await vault.prepareAbsenceWitness();
    await worker.persistSavedEntryWitness(witness.encode());
    Future<void> retire() async {
      await vault.retire();
      await prefs.retire();
    }

    await worker.removeManagedFiles(retireScopes: retire);
    await worker.removeAuxiliaryFiles(retireScopes: retire);
    await worker.close();
    final actor = ManagedRootErasure.openPending(profile);
    try {
      await actor.finish(
        verifyOtherDataAbsent: () async {},
        afterStage: (stage) async {
          if (!nativeGone &&
              stage == ManagedErasureFinishStage.pendingRemoved) {
            throw StateError('synthetic restart');
          }
        },
      );
    } catch (error) {
      if (nativeGone) rethrow;
    } finally {
      actor.close();
    }
    // A cold process has fresh platform/vault objects, not the retired old
    // per-backend registries. Only persisted OS values are carried over.
    platform = _Source(Map.of(platform.values));
    SharedPreferencesStorePlatform.instance = platform;
    final next = RetirementSecretStore();
    next.values.addAll(secrets.values);
    secrets = next;
    return witness;
  }

  setUp(() async {
    original = SharedPreferencesStorePlatform.instance;
    fixture = Directory.systemTemp.createTempSync(
      'xveil-application-journal-crash-',
    );
    legacy = '${fixture.path}/xveil.store';
    profile = '${fixture.path}/visible-storage';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    File(
      legacy,
    ).writeAsStringSync('synthetic encrypted container', flush: true);
    const ManagedFsPlatform().restrictNewFile(legacy);
    platform = _Source({'flutter.locale': 'old'});
    SharedPreferencesStorePlatform.instance = platform;
    secrets = RetirementSecretStore();
    background = BackgroundResourceBackend();
    await QuickUnlockVault(
      secrets,
      source().scope,
      RetirementAuthentication(),
    ).configure(password: 'synthetic password', system: true);
  });
  tearDown(() async {
    for (final value in recoveries) {
      await value.close();
    }
    for (final worker in workers) {
      try {
        await worker.close();
      } catch (_) {}
    }
    recoveries.clear();
    workers.clear();
    final current = SharedPreferencesStorePlatform.instance;
    if (current is ProfilePreferencesStore) await current.releaseFile();
    SharedPreferencesStorePlatform.instance = original;
    CaptureResourceLifetime.resetForTesting();
    fixture.deleteSync(recursive: true);
  });

  test(
    'cold removing recovery creates journal before deletion and installs fresh preferences',
    () async {
      final worker = await prepare();
      await worker.close();
      final job = recovery();
      await job.resume();
      expect(File(legacy).existsSync(), isFalse);
      expect(secrets.values, isEmpty);
      expect(platform.values.containsKey('flutter.locale'), isFalse);
      expect(
        SharedPreferencesStorePlatform.instance,
        isA<ProfilePreferencesStore>(),
      );
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      expect(background.sealed, isFalse);
      final count = platform.removes;
      await job.resume();
      expect(platform.removes, count);
      await QuickUnlockVault(
        secrets,
        source().scope,
        RetirementAuthentication(),
      ).configure(password: 'synthetic new', system: true);
    },
  );

  test(
    'cold recovery handles mixed storage scopes and preserves another profile',
    () async {
      final otherBase = '${fixture.path}/profiles/other';
      Directory('${fixture.path}/profiles').createSync();
      expect(
        const ManagedFsPlatform().createPrivateDirectory(otherBase),
        isTrue,
      );
      final otherPath = '$otherBase/visible-storage';
      expect(
        const ManagedFsPlatform().createPrivateDirectory(otherPath),
        isTrue,
      );
      final other = ManagedDirectoryCatalog.createOrOpen(otherPath);
      try {
        final data = ManagedIdentityFiles.createUnencrypted(
          other,
          id: ManagedIdentityId('1' * 32),
        );
        try {
          data.commit([
            PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([9, 8, 7])),
          ]);
        } finally {
          data.close();
        }
      } finally {
        other.close();
      }
      final otherScope = StorageUnlockScopes.forProfile(
        profile: 'other',
        legacyPath: '$otherBase/xveil.store',
        managedPath: otherPath,
        identities: const [],
      ).ids.single;
      await QuickUnlockVault(
        secrets,
        otherScope,
        RetirementAuthentication(),
      ).configure(password: 'synthetic other password', system: true);
      final savedKeys = {
        for (final entry in secrets.values.entries)
          if (entry.key.contains(otherScope)) entry.key: entry.value,
      };
      Map<String, List<int>> payloads() => {
        for (final file in Directory(
          '$otherPath/identities',
        ).listSync(recursive: true).whereType<File>())
          file.path: file.readAsBytesSync(),
      };
      final before = payloads();
      expect(before, isNotEmpty);
      final worker = await prepare(managed: true);
      expect(worker.scopeLease.snapshot.unlockScopes.ids, hasLength(3));
      await worker.close();
      final job = recovery();
      await job.resume();
      expect(payloads(), before);
      expect(secrets.values, savedKeys);
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(File(legacy).existsSync(), isFalse);
    },
  );

  test(
    'reentrant retirement joins the accepted cold recovery instead of opening another worker',
    () async {
      await (await prepare()).close();
      final actions = background.actions();
      late ColdProfileErasureRecovery job;
      var entered = false;
      Future<void>? joined;
      job = ColdProfileErasureRecovery(
        source: source(),
        secretStore: secrets,
        authentication: RetirementAuthentication(),
        retireBackground: () {
          if (!entered) {
            entered = true;
            joined = job.resume();
          }
          return actions.retireForErasure();
        },
      );
      recoveries.add(job);
      final accepted = job.resume();
      expect(identical(joined, accepted), isTrue);
      await accepted;
      expect(background.acquires, 1);
      expect(secrets.values, isEmpty);
    },
  );
  for (final nativeGone in [false, true]) {
    test(
      'cold ${nativeGone ? 'journal-only' : 'terminal'} recovery is read-only for OS records',
      () async {
        final worker = await prepare();
        final witness = await terminal(worker, nativeGone: nativeGone);
        final readsBefore = platform.removes;
        final job = recovery();
        await job.resume();
        expect(platform.removes, readsBefore);
        expect(secrets.values, isEmpty);
        expect(witness.protectedKeys, hasLength(1));
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
        expect(
          SharedPreferencesStorePlatform.instance,
          isA<ProfilePreferencesStore>(),
        );
      },
    );
  }
  test(
    'reappearing terminal credential is preserved and retry only verifies it',
    () async {
      final witness = await terminal(await prepare());
      final key = 'true:${witness.protectedKeys.single}';
      secrets.values[key] = 'synthetic new record';
      final before = Map.of(secrets.values);
      final job = recovery();
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(secrets.values, before);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
      secrets.values.remove(key);
      await job.resume();
      expect(secrets.values, isEmpty);
    },
  );

  for (final orphan in [false, true]) {
    test(
      'cold removing recovery retains erased metadata addresses: orphan=$orphan',
      () async {
        final worker = await prepare();
        final oldSource = source();
        final vault = QuickUnlockRetirement.forWorker(
          worker.scopeLease,
          secrets,
          RetirementAuthentication(),
        );
        final oldPrefs = LegacyProfilePreferencesRetirement.forWorker(
          worker,
          oldSource,
        );
        final saved = await vault.prepareAbsenceWitness();
        expect(saved.protectedKeys, hasLength(1));
        await worker.persistSavedEntryWitness(saved.encode());
        await vault.retire();
        await oldPrefs.retire();
        await worker.close();
        platform = _Source(Map.of(platform.values));
        SharedPreferencesStorePlatform.instance = platform;
        secrets = RetirementSecretStore();
        final key = 'true:${saved.protectedKeys.single}';
        if (orphan) secrets.values[key] = 'synthetic orphan credential';
        final job = recovery();
        if (orphan) {
          await expectLater(
            job.resume(),
            throwsA(isA<ManagedProfileWipeFailure>()),
          );
          expect(secrets.values[key], 'synthetic orphan credential');
          expect(
            File(legacy).readAsStringSync(),
            'synthetic encrypted container',
          );
          secrets.values.remove(
            key,
          ); // Explicit fixture resolution, not recovery deletion.
        }
        await job.resume();
        expect(secrets.values, isEmpty);
        expect(File(legacy).existsSync(), isFalse);
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      },
    );
  }

  test(
    'a replaced platform backend refuses before any native resource or data operation',
    () async {
      await (await prepare()).close();
      final job = recovery();
      final selected = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _Source({
        'flutter.locale': 'unrelated',
      });
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(background.acquires, 0);
      expect(File(legacy).existsSync(), isTrue);
      SharedPreferencesStorePlatform.instance = selected;
      await job.resume();
      expect(File(legacy).existsSync(), isFalse);
    },
  );
  test(
    'unverified platform resources preserve container and OS records before deletion',
    () async {
      await (await prepare()).close();
      final before = Map.of(secrets.values);
      background.refuseAcquire = true;
      final job = recovery();
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(File(legacy).readAsStringSync(), 'synthetic encrypted container');
      expect(secrets.values, before);
      background.refuseAcquire = false;
      await job.resume();
      expect(secrets.values, isEmpty);
    },
  );
  test(
    'generic native inventory cannot become cold application cleanup',
    () async {
      await (await prepare(application: false)).close();
      final before = Map.of(secrets.values);
      final job = recovery();
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(secrets.values, before);
      expect(File(legacy).existsSync(), isTrue);
    },
  );
  test(
    'lost resource-release reply retries handoff without touching new profile data',
    () async {
      await (await prepare()).close();
      background.loseReleaseReply = true;
      final job = recovery();
      await expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      File(
        legacy,
      ).writeAsStringSync('synthetic newly created data', flush: true);
      final removes = platform.removes;
      await job.resume();
      expect(File(legacy).readAsStringSync(), 'synthetic newly created data');
      expect(platform.removes, removes);
      expect(background.sealed, isFalse);
    },
  );

  test(
    'cold journal-only owner retains read-only witnesses after a lost native release reply',
    () async {
      final witness = await terminal(await prepare());
      final gate = ReceivePort();
      addTearDown(gate.close);
      late ManagedErasureWorker selected;
      final job = ColdProfileErasureRecovery.withWorkerOpenerForTesting(
        source: source(),
        secretStore: secrets,
        authentication: RetirementAuthentication(),
        retireBackground: background.actions().retireForErasure,
        openWorker: (path, binding) async => selected = binding == null
            ? await ManagedErasureWorker.reconcileApplicationJournalWithReleaseGateForTesting(
                path,
                gate.sendPort,
              )
            : await ManagedErasureWorker.resumeBound(path, binding),
      );
      recoveries.add(job);
      final failed = expectLater(
        job.resume(),
        throwsA(isA<ManagedProfileWipeFailure>()),
      );
      expect(await gate.first, isA<SendPort>());
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      selected.killReleasedWorkerForTesting();
      await failed;
      final before = Map.of(secrets.values);
      await job.resume();
      expect(secrets.values, before);
      expect(witness.protectedKeys, hasLength(1));
      expect(
        SharedPreferencesStorePlatform.instance,
        isA<ProfilePreferencesStore>(),
      );
    },
  );

  for (final phase in ['published', 'terminalPublished', 'terminal']) {
    test(
      'cold application owner resumes actual process death at $phase',
      () async {
        final worker = await prepare();
        final addresses = await QuickUnlockRetirement.forWorker(
          worker.scopeLease,
          secrets,
          RetirementAuthentication(),
        ).prepareAbsenceWitness();
        await worker.close();
        File(
          '${fixture.path}/expected-records.json',
        ).writeAsStringSync(addresses.encode(), flush: true);
        File(
          '${fixture.path}/synthetic-os.json',
        ).writeAsStringSync(jsonEncode(secrets.values), flush: true);
        File(
          '${fixture.path}/legacy-os.json',
        ).writeAsStringSync(jsonEncode(platform.values), flush: true);
        await killErasureWriter(
          fixture.path,
          phase,
          () {
            expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
          },
          script: 'test/native/application_erasure_journal_writer.dart',
          writerArguments: const ['visible-storage'],
        );
        platform = _Source(
          (jsonDecode(File('${fixture.path}/legacy-os.json').readAsStringSync())
                  as Map)
              .cast<String, Object>(),
        );
        SharedPreferencesStorePlatform.instance = platform;
        secrets = RetirementSecretStore();
        secrets.values.addAll(
          (jsonDecode(
                    File(
                      '${fixture.path}/synthetic-os.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, String>(),
        );
        if (phase == 'published') expect(secrets.values, isNotEmpty);
        final job = recovery();
        await job.resume();
        expect(secrets.values, isEmpty);
        expect(File(legacy).existsSync(), isFalse);
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
        expect(
          SharedPreferencesStorePlatform.instance,
          isA<ProfilePreferencesStore>(),
        );
        expect(background.sealed, isFalse);
      },
    );
  }
}
