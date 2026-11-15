@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_setup.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'support/master_setup_fixture.dart';

void wipe(List<RosterEntry> rows) {
  for (final row in rows) {
    row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in StorageProtection.values) {
    test(
      'actual large roster append and cold read preserve original rows (${mode.name})',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final dir = Directory.systemTemp.createTempSync(
          'xveil-master-journal-',
        );
        final fixture = MasterSetupFixture(dir, mode, append: true);
        await fixture.create();
        addTearDown(() => dir.deleteSync(recursive: true));
        final owner = ManagedDirectoryCatalog.openExisting(fixture.profile)!;
        final keys = <Uint8List>[];
        MasterSetupIntent? intent, ready;
        List<RosterEntry>? base;
        try {
          var parent = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
          final rootKeys = await parent.exportSpaceKeys();
          keys.add(rootKeys);
          try {
            base = (await parent.loadRosterForMaintenance())!;
            base.addAll(
              List.generate(
                127,
                (i) => RosterEntry(
                  label: 'existing $i:${'Ж' * 800}',
                  spaceKeys: Uint8List(64)..fillRange(0, 64, i + 2),
                  anonymous: i.isEven,
                ),
              ),
            );
            await parent.saveRoster(base);
            await parent.putSetting('master-extra', 'preserve settings');
            await parent.storeFile(
              'master-extra-file',
              Uint8List.fromList([7, 8, 9]),
            );
            expect(
              utf8.encode(jsonEncode(base.map((r) => r.label).toList())).length,
              greaterThan(48 * 3800),
            );
            intent = MasterSetupIntent.create(
              root: fixture.root,
              keys: rootKeys,
              base: base,
              childLocator: fixture.child,
              childLabel: 'new child',
              append: true,
            );
            final bytes = intent.encode();
            try {
              expect(bytes.length, lessThan(16 * 1024));
            } finally {
              bytes.fillRange(0, bytes.length, 0);
            }
            await MasterSetupJournal.prepare(
              storage: parent,
              intent: intent,
              root: fixture.root,
              keys: rootKeys,
              check: () {},
            );
          } finally {
            await parent.close();
          }
          final raw = ManagedIdentityFiles.createEncrypted(
            owner,
            id: fixture.id('b'),
            password: fixture.childPassword,
          );
          final childKeys = raw.exportKeys();
          keys.add(childKeys);
          raw.close();
          parent = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
          try {
            ready = await MasterSetupJournal.attachChild(
              storage: parent,
              intent: intent,
              childKeys: childKeys,
              root: fixture.root,
              keys: rootKeys,
              check: () {},
            );
            final read = (await MasterSetupJournal.read(parent, () {}))!;
            try {
              expect(read.same(ready), isTrue);
            } finally {
              read.destroy();
            }
          } finally {
            await parent.close();
          }
          final child = HiddenVolumeStorage.fromStore(
            ManagedIdentityFiles.openWithKeys(
              owner,
              id: fixture.id('b'),
              keys: childKeys,
            ),
          );
          late MasterSetupChildProof proof;
          try {
            proof = await MasterSetupJournal.initializeChild(
              storage: child,
              intent: ready,
              child: fixture.child,
              childKeys: childKeys,
              check: () {},
            );
          } finally {
            await child.close();
          }
          parent = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
          try {
            await MasterSetupJournal.publishAndFinish(
              storage: parent,
              intent: ready,
              childProof: proof,
              root: fixture.root,
              keys: rootKeys,
              check: () {},
            );
          } finally {
            await parent.close();
          }
          // Actual native cold reopen, rather than the preceding facade's cache.
          parent = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
          try {
            expect(await parent.getSetting(kPendingMasterSetupSetting), '0');
            expect(
              await parent.getSetting('master-extra'),
              'preserve settings',
            );
            final extra = await parent.loadFile('master-extra-file');
            try {
              expect(extra, [7, 8, 9]);
            } finally {
              extra?.fillRange(0, extra.length, 0);
            }
            final full = (await parent.loadRosterForMaintenance())!;
            try {
              expect(full.length, base.length + 1);
              for (var i = 0; i < base.length; i++) {
                expect(full[i].label, base[i].label);
                expect(full[i].spaceKeys, base[i].spaceKeys);
                expect(full[i].anonymous, base[i].anonymous);
                expect(full[i].storageLocator, base[i].storageLocator);
              }
              expect(full.last.spaceKeys, childKeys);
              expect(full.last.storageLocator, fixture.child);
            } finally {
              wipe(full);
            }
          } finally {
            await parent.close();
          }
          final source = HiddenVolumeStorage.fromStore(
            ManagedIdentityFiles.openUnencrypted(owner, id: fixture.id('c')),
          );
          try {
            expect(
              (await source.loadProfile())!.displayName,
              'original identity',
            );
            expect(await source.getSetting('fixture'), 'original payload');
          } finally {
            await source.close();
          }
        } finally {
          intent?.destroy();
          ready?.destroy();
          if (base != null) wipe(base);
          for (final key in keys) {
            key.fillRange(0, key.length, 0);
          }
          owner.close();
        }
      },
    );
  }
}
