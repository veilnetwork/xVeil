@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/compaction_roster_remap.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import '../support/erasure_writer_process.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _Fixture {
  final directory = Directory.systemTemp.createTempSync(
    'xveil-compaction-worker-',
  );
  String get profile => '${directory.path}/visible-storage';
  String get source => '${directory.path}/xveil.store';
  ManagedIdentityId id(int n) => ManagedIdentityId('$n' * 32);
  final keys = <ManagedIdentityId, Uint8List>{};
  final old = <String, Uint8List>{};
  final workers = <ManagedLegacyCompactionWorker>[];
  final owners = <ProfileStorageRouterOwner>[];
  final preferences = <ManagedProfilePreferencesFile>[];
  final payload = Uint8List.fromList(List.generate(70000, (i) => i % 251));

  Future<void> create() async {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      for (final n in [1, 2]) {
        final store = n == 1
            ? ManagedIdentityFiles.createEncrypted(
                root,
                id: id(n),
                password: _bytes('visible-fixture'),
              )
            : ManagedIdentityFiles.createUnencrypted(root, id: id(n));
        try {
          keys[id(n)] = store.exportKeys();
        } finally {
          store.close();
        }
      }
      for (final password in ['child-fixture', 'master-fixture']) {
        final raw = password == 'child-fixture'
            ? hv.HvSpace.create(
                path: source,
                password: _bytes(password),
                argon: hv.ArgonPreset.min,
              )
            : hv.HvSpace.addSpace(path: source, password: _bytes(password));
        final storage = HiddenVolumeStorage.fromStore(HvKvLogStore(raw));
        try {
          old[password] = raw.spaceKeys();
          await storage.storeFile('fixture-body', payload);
          if (password == 'master-fixture') {
            await storage.saveRoster([
              RosterEntry(
                label: 'Child fixture',
                spaceKeys: old['child-fixture']!,
              ),
              RosterEntry(
                label: 'Owned fixture',
                spaceKeys: keys[id(2)]!,
                storageLocator: ManagedStorageLocator(
                  id: id(2),
                  protection: StorageProtection.unencrypted,
                ),
              ),
            ]);
          }
        } finally {
          await storage.close();
        }
      }
      for (final n in [1, 2]) {
        final storage = HiddenVolumeStorage.fromStore(
          ManagedIdentityFiles.openWithKeys(
            root,
            id: id(n),
            keys: keys[id(n)]!,
          ),
        );
        try {
          await storage.putSetting('fixture-payload', 'visible-$n');
          await storage.saveRoster([
            for (final entry in old.entries)
              RosterEntry(
                label: entry.key,
                spaceKeys: entry.value,
                anonymous: true,
              ),
          ]);
        } finally {
          await storage.close();
        }
      }
    } finally {
      root.close();
    }
  }

  List<CompactionCredential> credentials() => [
    for (final entry in old.entries)
      (
        password: _bytes(entry.key),
        oldSpaceKeys: Uint8List.fromList(entry.value),
      ),
  ];
  Map<ManagedIdentityId, Uint8List> authorizations() => {
    for (final entry in keys.entries)
      entry.key: Uint8List.fromList(entry.value),
  };

  Future<ManagedLegacyCompactionWorker> open({
    Map<ManagedIdentityId, Uint8List>? auth,
    List<CompactionCredential>? keep,
    Set<ManagedIdentityId>? approved,
  }) async {
    final worker = await ManagedLegacyCompactionWorker.open(
      profileDirectory: profile,
      authorizations: auth ?? authorizations(),
      credentials: keep ?? credentials(),
      plaintextApproved: approved ?? {id(2)},
    );
    workers.add(worker);
    return worker;
  }

  Future<void> verify({required bool published}) async {
    final current = <String, Uint8List>{};
    for (final password in old.keys) {
      final raw = hv.HvSpace.open(path: source, password: _bytes(password));
      final storage = HiddenVolumeStorage.fromStore(HvKvLogStore(raw));
      try {
        current[password] = raw.spaceKeys();
        expect(
          current[password],
          published ? isNot(old[password]) : equals(old[password]),
        );
        expect(await storage.loadFile('fixture-body'), payload);
        if (password == 'master-fixture') {
          final rows = (await storage.loadRosterForMaintenance())!;
          expect(rows.first.spaceKeys, current['child-fixture']);
          expect(rows.last.spaceKeys, keys[id(2)]);
          expect(
            rows.last.storageLocator,
            ManagedStorageLocator(
              id: id(2),
              protection: StorageProtection.unencrypted,
            ),
          );
        }
      } finally {
        await storage.close();
      }
    }
    final root = ManagedDirectoryCatalog.openExisting(profile)!;
    try {
      for (final n in [1, 2]) {
        final storage = HiddenVolumeStorage.fromStore(
          ManagedIdentityFiles.openWithKeys(
            root,
            id: id(n),
            keys: keys[id(n)]!,
          ),
        );
        try {
          final rows = (await storage.loadRosterForMaintenance())!;
          expect(rows, hasLength(2));
          for (final row in rows) {
            expect(row.spaceKeys, current[row.label]);
            expect(row.anonymous, isTrue);
          }
          expect(await storage.getSetting('fixture-payload'), 'visible-$n');
          expect(
            await storage.loadFile(ManagedLegacyReferenceRepair.journalFile),
            isNull,
          );
        } finally {
          await storage.close();
        }
      }
    } finally {
      root.close();
    }
  }

  Future<void> dispose() async {
    for (final owner in owners) {
      await owner.close();
    }
    for (final preference in preferences) {
      await preference.close();
    }
    for (final worker in workers) {
      await worker.close();
    }
    for (final value in [...keys.values, ...old.values]) {
      value.fillRange(0, value.length, 0);
    }
    directory.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    test(
      'mixed compaction waits for a durable-source recovery barrier',
      () {},
      skip: 'Windows source-name durability remains unqualified',
    );
    return;
  }
  test(
    'one worker repairs hidden and external rosters before finishing',
    () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      final worker = await f.open();
      var authorized = false;
      final result = await worker.run(
        beforePublication: () async {
          authorized = true;
        },
      );
      expect(authorized, isTrue);
      expect(result.before, greaterThan(0));
      expect(result.after, greaterThan(0));
      expect(
        result.recovery,
        LegacyReferenceRepairOutcome.publishedReplacement,
      );
      await worker.close();
      await f.verify(published: true);
    },
  );

  test(
    'publication refusal aborts and restores private intents against original source',
    () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      final before = File(f.source).readAsBytesSync();
      final worker = await f.open();
      final refusal = StateError('fixture lifecycle ended');
      await expectLater(
        worker.run(
          beforePublication: () async {
            throw refusal;
          },
        ),
        throwsA(same(refusal)),
      );
      await worker.close();
      expect(File(f.source).readAsBytesSync(), before);
      await f.verify(published: false);
    },
  );

  for (final missing in [
    'visible',
    'plaintext',
    'hidden',
    'key-map',
    'visible-key',
  ]) {
    test('incomplete $missing admission never reaches publication', () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      final before = File(f.source).readAsBytesSync();
      final auth = f.authorizations(), keep = f.credentials();
      if (missing == 'visible') auth.remove(f.id(1));
      if (missing == 'visible-key') auth[f.id(1)]![0] ^= 1;
      if (missing == 'hidden') keep.removeAt(0);
      if (missing == 'key-map') keep[0].oldSpaceKeys[0] ^= 1;
      final worker = await f.open(
        auth: auth,
        keep: keep,
        approved: missing == 'plaintext' ? {} : null,
      );
      var authorized = false;
      await expectLater(
        worker.run(
          beforePublication: () async {
            authorized = true;
          },
        ),
        throwsA(
          isA<ManagedLegacyCompactionFailure>().having(
            (e) => e.mayHaveApplied,
            'mayHaveApplied',
            isFalse,
          ),
        ),
      );
      expect(authorized, isFalse);
      await worker.close();
      expect(File(f.source).readAsBytesSync(), before);
      await f.verify(published: false);
    });
  }

  for (final beforeReady in [false, true]) {
    test(
      'caller buffers stay owned by caller across open (early=$beforeReady)',
      () async {
        final f = _Fixture();
        await f.create();
        addTearDown(f.dispose);
        final auth = f.authorizations();
        // The public credential contract accepts ordinary lists too.
        final keep = [
          for (final entry in f.credentials())
            (
              password: entry.password.toList(),
              oldSpaceKeys: entry.oldSpaceKeys.toList(),
            ),
        ];
        final approved = {f.id(2)};
        final originalPassword = List<int>.of(keep.first.password);
        final opening = f.open(auth: auth, keep: keep, approved: approved);
        void discard() {
          for (final key in auth.values) {
            key.fillRange(0, key.length, 0);
          }
          for (final entry in keep) {
            entry.password.fillRange(0, entry.password.length, 0);
            entry.oldSpaceKeys.fillRange(0, entry.oldSpaceKeys.length, 0);
          }
          approved.clear();
        }

        if (beforeReady) discard();
        final worker = await opening;
        if (!beforeReady) {
          expect(keep.first.password, originalPassword);
          discard();
        }
        await worker.run(beforePublication: () async {});
        await worker.close();
        await f.verify(published: true);
      },
    );
  }

  test(
    'run is one-shot and close joins an accepted publication check',
    () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      final worker = await f.open();
      final entered = Completer<void>(), release = Completer<void>();
      final operation = worker.run(
        beforePublication: () async {
          entered.complete();
          await release.future;
        },
      );
      final completed = expectLater(operation, completes);
      await entered.future;
      final closing = worker.close();
      try {
        await expectLater(
          worker.run(beforePublication: () async {}),
          throwsA(isA<ManagedWorkerFailure>()),
        );
      } finally {
        release.complete();
        await completed;
        await closing;
      }
      await f.verify(published: true);
    },
  );

  if (!Platform.isWindows) {
    test(
      'visible publication warning retains mayHaveApplied and repaired references',
      () async {
        final f = _Fixture();
        await f.create();
        addTearDown(f.dispose);
        final link = await Process.run('/bin/ln', [
          f.source,
          '${f.source}.fixture-alias',
        ]);
        expect(link.exitCode, 0);
        final worker = await f.open();
        await expectLater(
          worker.run(beforePublication: () async {}),
          throwsA(
            isA<ManagedLegacyCompactionFailure>()
                .having((e) => e.mayHaveApplied, 'mayHaveApplied', isTrue)
                .having(
                  (e) => e.warning,
                  'publication warning',
                  ManagedLegacyPublicationWarning.aliasesNotRevoked,
                )
                .having(
                  (e) => e.recovery,
                  'recovery',
                  LegacyReferenceRepairOutcome.publishedReplacement,
                ),
          ),
        );
        await worker.close();
        await f.verify(published: true);
      },
    );
  }

  for (final phase in ['prepared', 'reply-pending']) {
    test(
      'SIGKILL at $phase preserves exact data and recoverable references',
      () async {
        final f = _Fixture();
        await f.create();
        addTearDown(f.dispose);
        final before = File(f.source).readAsBytesSync();
        final capabilities = File(
          '${f.directory.path}/capabilities-private.json',
        );
        capabilities.writeAsStringSync(
          jsonEncode({
            'masters': {
              for (final entry in f.keys.entries)
                entry.key.value: base64.encode(entry.value),
            },
            'legacy': {
              for (final entry in f.old.entries)
                entry.key: base64.encode(entry.value),
            },
            'plaintext': [f.id(2).value],
          }),
          flush: true,
        );
        final permissions = await Process.run('/bin/chmod', [
          '600',
          capabilities.path,
        ]);
        expect(permissions.exitCode, 0);
        await killErasureWriter(
          f.directory.path,
          phase,
          () {
            // The worker still holds full-profile ownership even after commit.
            // A lost answer must never be interpreted as successful release.
            expect(
              () {
                final unexpected = ManagedDirectoryCatalog.openExisting(
                  f.profile,
                );
                unexpected?.close();
              },
              throwsA(
                predicate(
                  (error) =>
                      error is ManagedLeaseFailure &&
                          error.kind == ManagedLeaseFailureKind.busy ||
                      error is ManagedSqliteFailure &&
                          [5, 6].contains((error.sqliteCode ?? 0) & 0xff),
                ),
              ),
            );
          },
          script: 'test/native/managed_legacy_compaction_worker_writer.dart',
        );
        if (phase == 'prepared') {
          expect(File(f.source).readAsBytesSync(), before);
        }
        final root = ManagedDirectoryCatalog.openExclusiveMaintenance(
          f.profile,
        )!;
        try {
          final recovered = await ManagedLegacyReferenceRepair.resume(
            owner: root,
            authorizations: f.authorizations(),
          );
          expect(
            recovered,
            phase == 'prepared'
                ? LegacyReferenceRepairOutcome.retainedSource
                : LegacyReferenceRepairOutcome.none,
          );
        } finally {
          root.close();
        }
        await f.verify(published: phase == 'reply-pending');
      },
    );
  }

  test(
    'profile owner coordinates preferences and restores access and view',
    () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      final preference = await ManagedProfilePreferencesFile.open(
        '${f.directory.path}/xveil.prefs.json',
      );
      f.preferences.add(preference);
      expect(await preference.write('preserved-preferences'), isTrue);
      Future<ProfileStorageRouter> route() => ProfileStorageRouter.open(
        profileDirectory: f.profile,
        legacyFactory: () =>
            HiddenVolumeStorage.async(workerSpaceOpener(f.source)),
      );
      final router = await route();
      final access = ManagedStorageLocator(
        id: f.id(1),
        protection: StorageProtection.encrypted,
      );
      await router.select(access);
      await router.rememberAccess();
      await router.select(const LegacyStorageLocator(), access: false);
      final oldView = router.storage;
      final owner = ProfileStorageRouterOwner(router, reopen: route);
      f.owners.add(owner);
      final auth = f.authorizations(), keep = f.credentials();
      final approved = {f.id(2)};
      final compacting = owner.compactLegacy(
        legacyPath: f.source,
        authorizations: auth,
        credentials: keep,
        plaintextApproved: approved,
        beforePublication: () async {},
      );
      for (final key in auth.values) {
        key.fillRange(0, key.length, 0);
      }
      for (final entry in keep) {
        entry.password.fillRange(0, entry.password.length, 0);
        entry.oldSpaceKeys.fillRange(0, entry.oldSpaceKeys.length, 0);
      }
      approved.clear();
      final result = await compacting;
      expect(
        result.recovery,
        LegacyReferenceRepairOutcome.publishedReplacement,
      );
      expect(owner.router.location, const LegacyStorageLocator());
      expect(owner.router.access, access);
      expect(identical(owner.router.storage, oldView), isFalse);
      expect(await preference.read(), 'preserved-preferences');
      expect(await preference.write('after-compaction'), isTrue);
      expect(
        await owner.router.storage.open(password: 'master-fixture'),
        isTrue,
      );
      expect(await owner.router.storage.loadFile('fixture-body'), f.payload);
      await owner.close();
      await f.verify(published: true);
    },
  );

  test(
    'closing the profile during publication check aborts and joins native work',
    () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      final before = File(f.source).readAsBytesSync();
      Future<ProfileStorageRouter> route() => ProfileStorageRouter.open(
        profileDirectory: f.profile,
        legacyFactory: () =>
            HiddenVolumeStorage.async(workerSpaceOpener(f.source)),
      );
      final owner = ProfileStorageRouterOwner(await route(), reopen: route);
      f.owners.add(owner);
      final entered = Completer<void>(), release = Completer<void>();
      final operation = owner.compactLegacy(
        legacyPath: f.source,
        authorizations: f.authorizations(),
        credentials: f.credentials(),
        plaintextApproved: {f.id(2)},
        beforePublication: () async {
          entered.complete();
          await release.future;
        },
      );
      final refused = expectLater(operation, throwsStateError);
      await entered.future;
      final closing = owner.close();
      release.complete();
      await refused;
      await closing;
      expect(File(f.source).readAsBytesSync(), before);
      await f.verify(published: false);
    },
  );

  test(
    'profile owner refuses a different source name before suspension',
    () async {
      final f = _Fixture();
      await f.create();
      addTearDown(f.dispose);
      Future<ProfileStorageRouter> route() => ProfileStorageRouter.open(
        profileDirectory: f.profile,
        legacyFactory: () =>
            HiddenVolumeStorage.async(workerSpaceOpener(f.source)),
      );
      final router = await route();
      final owner = ProfileStorageRouterOwner(router, reopen: route);
      f.owners.add(owner);
      await expectLater(
        owner.compactLegacy(
          legacyPath: '${f.source}.other',
          authorizations: f.authorizations(),
          credentials: f.credentials(),
          plaintextApproved: {f.id(2)},
          beforePublication: () async {},
        ),
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedWorkerFailureKind.mode,
          ),
        ),
      );
      expect(owner.router, same(router));
      await owner.close();
      await f.verify(published: false);
    },
  );
}
