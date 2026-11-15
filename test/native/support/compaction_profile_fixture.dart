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
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class CompactionProfileFixture {
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

  /// A real interrupted prepare: visible intents survive, original hidden
  /// generation stays at its source name, and the prepared replacement aborts.
  Future<void> seedRetainedSourceIntents() async {
    final root = ManagedDirectoryCatalog.openExclusiveMaintenance(profile)!;
    hv.HvPreparedCompaction? plan;
    final changes = <LegacyCompactionKeyChange>[];
    final passwords = [for (final value in old.keys) _bytes(value)];
    try {
      plan = hv.HvPreparedCompaction.prepare(source, passwords);
      for (final entry in old.entries) {
        final space = hv.HvSpace.open(
          path: plan.stagedPath,
          password: _bytes(entry.key),
        );
        try {
          changes.add((
            before: Uint8List.fromList(entry.value),
            after: space.spaceKeys(),
          ));
        } finally {
          space.close();
        }
      }
      await ManagedLegacyReferenceRepair.prepare(
        owner: root,
        authorizations: keys,
        changes: changes,
      );
      for (final id in keys.keys) {
        final storage = HiddenVolumeStorage.fromStore(
          ManagedIdentityFiles.openWithKeys(root, id: id, keys: keys[id]!),
        );
        try {
          expect(
            await storage.loadFile(ManagedLegacyReferenceRepair.journalFile),
            isNotNull,
          );
        } finally {
          await storage.close();
        }
      }
    } finally {
      plan?.close();
      root.close();
      for (final password in passwords) {
        password.fillRange(0, password.length, 0);
      }
      for (final change in changes) {
        change.before.fillRange(0, change.before.length, 0);
        change.after.fillRange(0, change.after.length, 0);
      }
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
