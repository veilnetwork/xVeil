@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/state/app_controller.dart';

class _Controller extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
}

class _IncompleteRepair implements Exception {}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Map<String, String> _snapshot(Directory root) => {
  for (final file in root.listSync(recursive: true, followLinks: false))
    if (file is File)
      file.path.substring(root.path.length): sha256
          .convert(file.readAsBytesSync())
          .toString(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final missingChild in [false, true]) {
    test(
      'prepared hidden rewrite preserves actual managed stores (missing=$missingChild)',
      () async {
        SharedPreferences.setMockInitialValues({});
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-mixed-compaction-',
        );
        addTearDown(() => fixture.deleteSync(recursive: true));
        final profile = '${fixture.path}/visible-storage';
        expect(
          const ManagedFsPlatform().createPrivateDirectory(profile),
          isTrue,
        );
        final root = ManagedDirectoryCatalog.createOrOpen(profile);
        addTearDown(root.close);
        final managedRows = <RosterEntry>[];
        for (final (mode, name) in [
          (StorageProtection.encrypted, '1'),
          (StorageProtection.unencrypted, '2'),
        ]) {
          final id = ManagedIdentityId(name * 32);
          final initial = [PutOp(1, _bytes('scope'), _bytes(mode.name))];
          final store = mode == StorageProtection.encrypted
              ? ManagedIdentityFiles.createEncrypted(
                  root,
                  id: id,
                  password: _bytes('independent fixture password'),
                  initial: initial,
                )
              : ManagedIdentityFiles.createUnencrypted(
                  root,
                  id: id,
                  initial: initial,
                );
          try {
            managedRows.add(
              RosterEntry(
                label: mode.name,
                spaceKeys: store.exportKeys(),
                storageLocator: ManagedStorageLocator(id: id, protection: mode),
                anonymous: true,
              ),
            );
          } finally {
            store.close();
          }
        }

        final path = '${fixture.path}/hidden.hv';
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: _bytes('child'),
            argon: hv.ArgonPreset.min,
          ),
        ).close();
        HiddenVolumeStorage facade(String selectedPath) =>
            HiddenVolumeStorage.async(
              workerSpaceOpener(selectedPath),
              keysOpener: workerKeysSpaceOpener(selectedPath),
            );
        final credentials = <({List<int> password, List<int> oldSpaceKeys})>[];
        final body = Uint8List.fromList(List.generate(70000, (i) => i % 251));
        final seed = facade(path);
        addTearDown(seed.close);
        for (final password in ['child', 'master', 'duress']) {
          try {
            expect(
              await seed.open(password: password, createIfMissing: true),
              isTrue,
            );
            if (password == 'child') {
              await seed.storeFile('fixture-body', body);
            } else {
              await seed.saveRoster([
                RosterEntry(
                  label: 'hidden child',
                  spaceKeys: Uint8List.fromList(credentials.first.oldSpaceKeys),
                ),
                ...managedRows,
                if (missingChild && password == 'duress')
                  RosterEntry(
                    label: 'unresolved hidden child',
                    spaceKeys: Uint8List(64)..fillRange(0, 64, 42),
                  ),
              ]);
            }
            credentials.add((
              password: _bytes(password),
              oldSpaceKeys: await seed.exportSpaceKeys(),
            ));
          } finally {
            await seed.close();
          }
        }

        final beforeHidden = File(path).readAsBytesSync();
        final beforeManaged = _snapshot(Directory(profile));
        final controller = _Controller();
        final providers = ProviderContainer(
          overrides: [appControllerProvider.overrideWith(() => controller)],
        );
        addTearDown(providers.dispose);
        providers.read(appControllerProvider);
        var repairCalls = 0;
        final rewrite = hv.compactKnownPreparedAsync(
          path,
          [for (final entry in credentials) Uint8List.fromList(entry.password)],
          dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
          repairMetadata: (stagedPath) async {
            repairCalls++;
            final staged = facade(stagedPath);
            try {
              final failed = await controller.remapRostersAfterCompaction(
                credentials,
                storageOverride: staged,
              );
              if (failed.isNotEmpty) throw _IncompleteRepair();
            } finally {
              await staged.close();
            }
          },
        );
        if (missingChild) {
          await expectLater(rewrite, throwsA(isA<_IncompleteRepair>()));
          expect(File(path).readAsBytesSync(), beforeHidden);
        } else {
          await rewrite;
          expect(File(path).readAsBytesSync(), isNot(beforeHidden));
        }
        expect(repairCalls, 1);
        expect(_snapshot(Directory(profile)), beforeManaged);

        for (final password in ['master', 'duress']) {
          expect(await seed.open(password: password), isTrue);
          final rows = (await seed.loadRoster())!;
          await seed.close();
          expect(rows.map((e) => e.label), [
            'hidden child',
            'encrypted',
            'unencrypted',
            if (missingChild && password == 'duress') 'unresolved hidden child',
          ]);
          final child = facade(path);
          try {
            expect(await child.openWithKeys(rows.first.spaceKeys), isTrue);
            expect(await child.loadFile('fixture-body'), body);
          } finally {
            await child.close();
          }
          for (var index = 0; index < managedRows.length; index++) {
            final row = rows[index + 1], original = managedRows[index];
            expect(row.storageLocator, original.storageLocator);
            expect(row.spaceKeys, original.spaceKeys);
            expect(row.anonymous, isTrue);
            final locator = row.storageLocator as ManagedStorageLocator;
            final owned = ManagedIdentityFiles.openWithKeys(
              root,
              id: locator.id,
              keys: row.spaceKeys,
            );
            try {
              expect(
                owned.get(1, _bytes('scope')),
                _bytes(locator.protection.name),
              );
              expect(owned.exportKeys(), original.spaceKeys);
            } finally {
              owned.close();
            }
          }
        }
      },
    );
  }
}
