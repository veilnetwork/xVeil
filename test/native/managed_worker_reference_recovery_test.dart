@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _Abort implements Exception {}

class _Fixture {
  final directory = Directory.systemTemp.createTempSync(
    'xveil-worker-references-',
  );
  String get profile => '${directory.path}/profile';
  String get source => '${directory.path}/xveil.store';
  final oldKeys = <Uint8List>[];
  final newKeys = <Uint8List>[];
  final keys = <ManagedIdentityId, Uint8List>{};
  ManagedIdentityId id(int n) => ManagedIdentityId('$n' * 32);
  late ManagedDirectoryCatalog root;
  final routers = <ProfileStorageRouter>[];

  Future<void> create({required bool publish}) async {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    root = ManagedDirectoryCatalog.createOrOpen(profile);
    final child = hv.HvSpace.create(
      path: source,
      password: _bytes('child-fixture'),
      argon: hv.ArgonPreset.min,
    );
    try {
      child.commit([
        hv.HvWriteOpPut(
          namespace: 1,
          key: _bytes('fixture'),
          value: _bytes('payload'),
        ),
      ]);
      oldKeys.add(child.spaceKeys());
    } finally {
      child.close();
    }
    for (final n in [1, 2]) {
      final store = n == 1
          ? ManagedIdentityFiles.createEncrypted(
              root,
              id: id(n),
              password: _bytes('master-fixture'),
            )
          : ManagedIdentityFiles.createUnencrypted(root, id: id(n));
      keys[id(n)] = store.exportKeys();
      final facade = HiddenVolumeStorage.fromStore(store);
      try {
        await facade.saveRoster([
          RosterEntry(
            label: 'Child fixture',
            spaceKeys: oldKeys.single,
            anonymous: true,
          ),
        ]);
        await facade.putSetting('fixture-payload', 'master-$n');
      } finally {
        await facade.close();
      }
    }
    root.close();
    root = ManagedDirectoryCatalog.openExclusiveMaintenance(profile)!;
    try {
      await hv.compactKnownPreparedAsync(
        source,
        [_bytes('child-fixture')],
        dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
        repairMetadata: (staged) async {
          final child = hv.HvSpace.open(
            path: staged,
            password: _bytes('child-fixture'),
          );
          try {
            newKeys.add(child.spaceKeys());
          } finally {
            child.close();
          }
          await ManagedLegacyReferenceRepair.prepare(
            owner: root,
            authorizations: keys,
            changes: [(before: oldKeys.single, after: newKeys.single)],
          );
          if (!publish) throw _Abort();
        },
      );
    } on _Abort {
      if (publish) rethrow;
    } finally {
      root.close();
    }
    root = ManagedDirectoryCatalog.openExisting(profile)!;
  }

  Future<T> master<T>(
    int n,
    Future<T> Function(HiddenVolumeStorage) action,
  ) async {
    final store = ManagedIdentityFiles.openWithKeys(
      root,
      id: id(n),
      keys: keys[id(n)]!,
    );
    final facade = HiddenVolumeStorage.fromStore(store);
    try {
      return await action(facade);
    } finally {
      await facade.close();
    }
  }

  Future<WorkerKvLogStore> openWorker(int n, {bool byKeys = false}) => byKeys
      ? ManagedWorkerIdentity.openWithKeys(
          profileDirectory: profile,
          id: id(n),
          protection: n == 1
              ? StorageProtection.encrypted
              : StorageProtection.unencrypted,
          keys: keys[id(n)]!,
        )
      : n == 1
      ? ManagedWorkerIdentity.openEncrypted(
          profileDirectory: profile,
          id: id(n),
          password: _bytes('master-fixture'),
        )
      : ManagedWorkerIdentity.openUnencrypted(
          profileDirectory: profile,
          id: id(n),
        );

  Future<Storage> select(int n) async {
    final router = await ProfileStorageRouter.open(
      profileDirectory: profile,
      legacyFactory: () => HiddenVolumeStorage.async(workerSpaceOpener(source)),
    );
    routers.add(router);
    await router.select(
      ManagedStorageLocator(
        id: id(n),
        protection: n == 1
            ? StorageProtection.encrypted
            : StorageProtection.unencrypted,
      ),
    );
    return router.storage;
  }

  Future<Storage> open(int n, {bool byKeys = false}) async {
    final storage = await select(n);
    final opened = byKeys
        ? await storage.openWithKeys(keys[id(n)]!)
        : await storage.open(password: n == 1 ? 'master-fixture' : '');
    expect(opened, isTrue);
    return storage;
  }

  void releaseRoot() => root.close();
  void reopenRoot() {
    root = ManagedDirectoryCatalog.openExisting(profile)!;
  }

  Future<void> dispose() async {
    for (final router in routers) {
      await router.close();
    }
    root.close();
    for (final bytes in [...oldKeys, ...newKeys, ...keys.values]) {
      bytes.fillRange(0, bytes.length, 0);
    }
    directory.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final publish in [false, true]) {
    for (final n in [1, 2]) {
      test(
        'ordinary worker resolves pending references (publish=$publish master=$n)',
        () async {
          final f = _Fixture();
          await f.create(publish: publish);
          addTearDown(f.dispose);
          final other = n == 1 ? 2 : 1;
          final otherIntent = await f.master(
            other,
            (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
          );
          expect(otherIntent, isNotNull);
          f.releaseRoot();
          final facade = await f.open(n) as HiddenVolumeStorage;
          try {
            final rows = (await facade.loadRosterForMaintenance())!;
            expect(rows, hasLength(1));
            expect(
              rows.single.spaceKeys,
              publish ? f.newKeys.single : f.oldKeys.single,
            );
            expect(rows.single.label, 'Child fixture');
            expect(rows.single.anonymous, isTrue);
            expect(await facade.getSetting('fixture-payload'), 'master-$n');
            expect(
              await facade.loadFile(ManagedLegacyReferenceRepair.journalFile),
              isNull,
            );
          } finally {
            await facade.close();
          }
          f.reopenRoot();
          expect(
            await f.master(
              other,
              (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
            ),
            otherIntent,
          );
          final child = hv.HvSpace.openWithKeys(
            path: f.source,
            keys: publish ? f.newKeys.single : f.oldKeys.single,
          );
          try {
            expect(child.get(1, _bytes('fixture')), _bytes('payload'));
          } finally {
            child.close();
          }
        },
      );
    }
  }

  for (final byKeys in [false, true]) {
    test(
      'ordinary worker refuses malformed private intent (keys=$byKeys)',
      () async {
        final f = _Fixture();
        await f.create(publish: true);
        addTearDown(f.dispose);
        final corrupt = _bytes('unreadable fixture intent');
        await f.master(
          1,
          (s) => s.storeFile(ManagedLegacyReferenceRepair.journalFile, corrupt),
        );
        f.releaseRoot();
        Storage? admitted;
        try {
          await expectLater(
            f.open(1, byKeys: byKeys).then((worker) => admitted = worker),
            throwsA(isA<ManagedWorkerFailure>()),
          );
        } finally {
          await admitted?.close();
          f.reopenRoot();
        }
        expect(
          await f.master(
            1,
            (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
          ),
          corrupt,
        );
        expect(
          (await f.master(
            1,
            (s) => s.loadRosterForMaintenance(),
          ))!.single.spaceKeys,
          f.oldKeys.single,
        );
      },
    );
  }

  for (final n in [1, 2]) {
    test('ordinary key reopen repairs the selected master $n', () async {
      final f = _Fixture();
      await f.create(publish: true);
      addTearDown(f.dispose);
      f.releaseRoot();
      final facade = await f.open(n, byKeys: true) as HiddenVolumeStorage;
      expect(
        (await facade.loadRosterForMaintenance())!.single.spaceKeys,
        f.newKeys.single,
      );
      expect(
        await facade.loadFile(ManagedLegacyReferenceRepair.journalFile),
        isNull,
      );
      await facade.close();
    });
  }

  test('a worker alone refuses to hand off a root needing recovery', () async {
    final f = _Fixture();
    await f.create(publish: true);
    addTearDown(f.dispose);
    final intent = await f.master(
      1,
      (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
    );
    f.releaseRoot();
    WorkerKvLogStore? admitted;
    try {
      await expectLater(
        f.openWorker(1).then((worker) => admitted = worker),
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (e) => e.kind.name,
            'kind',
            'recoveryRequired',
          ),
        ),
      );
    } finally {
      await admitted?.close();
    }
    f.reopenRoot();
    expect(
      await f.master(
        1,
        (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
      ),
      intent,
    );
  });

  test('wrong password cannot inspect or consume a recovery intent', () async {
    final f = _Fixture();
    await f.create(publish: true);
    addTearDown(f.dispose);
    final intent = await f.master(
      1,
      (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
    );
    f.releaseRoot();
    final storage = await f.select(1);
    expect(await storage.open(password: 'wrong-fixture'), isFalse);
    expect(storage.isOpen, isFalse);
    f.reopenRoot();
    expect(
      await f.master(
        1,
        (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
      ),
      intent,
    );
  });

  test(
    'live profile owner refuses recovery and release permits retry',
    () async {
      final f = _Fixture();
      await f.create(publish: true);
      addTearDown(f.dispose);
      final intent = await f.master(
        1,
        (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
      );
      final storage = await f.select(1);
      await expectLater(
        storage.open(password: 'master-fixture'),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(storage.isOpen, isFalse);
      expect(
        await f.master(
          1,
          (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
        ),
        intent,
      );
      f.releaseRoot();
      expect(await storage.open(password: 'master-fixture'), isTrue);
      expect(
        (await (storage as HiddenVolumeStorage).loadRosterForMaintenance())!
            .single
            .spaceKeys,
        f.newKeys.single,
      );
      await storage.close();
    },
  );

  test('an unjournaled selected root never needs the hidden source', () async {
    final f = _Fixture();
    await f.create(publish: false);
    addTearDown(f.dispose);
    await f.master(
      1,
        (s) => s.deleteStoredFile(ManagedLegacyReferenceRepair.journalFile),
    );
    final otherIntent = await f.master(
      2,
      (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
    );
    f.releaseRoot();
    await File(f.source).rename('${f.source}.fixture-saved');
    final storage = await f.open(1);
    expect(await storage.getSetting('fixture-payload'), 'master-1');
    expect(await File(f.source).exists(), isFalse);
    await storage.close();
    f.reopenRoot();
    expect(
      await f.master(
        2,
        (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
      ),
      otherIntent,
    );
  });

  test(
    'missing source preserves the intent and a later retry can recover',
    () async {
      final f = _Fixture();
      await f.create(publish: true);
      addTearDown(f.dispose);
      final intent = await f.master(
        1,
        (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
      );
      f.releaseRoot();
      final saved = await File(f.source).rename('${f.source}.fixture-saved');
      final storage = await f.select(1);
      await expectLater(
        storage.open(password: 'master-fixture'),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(storage.isOpen, isFalse);
      expect(await File(f.source).exists(), isFalse);
      f.reopenRoot();
      expect(
        await f.master(
          1,
          (s) => s.loadFile(ManagedLegacyReferenceRepair.journalFile),
        ),
        intent,
      );
      f.releaseRoot();
      await saved.rename(f.source);
      expect(await storage.open(password: 'master-fixture'), isTrue);
      expect(
        (await (storage as HiddenVolumeStorage).loadRosterForMaintenance())!
            .single
            .spaceKeys,
        f.newKeys.single,
      );
      await storage.close();
    },
  );
}
