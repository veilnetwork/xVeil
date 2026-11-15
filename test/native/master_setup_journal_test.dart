@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';
import '../support/erasure_writer_process.dart';
import 'support/master_setup_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in StorageProtection.values) {
    for (final phase in ['before-publication', 'prepared', 'child-known']) {
      test(
        'native master intent survives actual process death (${mode.name}/$phase)',
        () async {
          expect(ensureHiddenVolumeLoaded(), isTrue);
          final dir = Directory.systemTemp.createTempSync(
            'xveil-master-journal-',
          );
          final f = MasterSetupFixture(dir, mode);
          addTearDown(() => dir.deleteSync(recursive: true));
          await f.create();
          final request =
              jsonDecode(
                    File('${dir.path}/request-private.json').readAsStringSync(),
                  )
                  as Map;
          final keys = base64.decode(request['keys'] as String);
          final expected = MasterSetupIntent.decode(
            base64.decode(request['intent'] as String),
          );
          addTearDown(() {
            expected.destroy();
            keys.fillRange(0, keys.length, 0);
          });
          final initial = ManagedDirectoryCatalog.openExisting(f.profile)!;
          final catalog = initial.snapshot().catalog.encode();
          initial.close();
          await killErasureWriter(
            dir.path,
            phase,
            () {},
            script: 'test/native/master_setup_journal_writer.dart',
            writerArguments: [mode.name],
          );
          final owner = ManagedDirectoryCatalog.openExisting(f.profile)!;
          try {
            final storage = HiddenVolumeStorage.fromStore(f.openRoot(owner));
            try {
              final actualKeys = await storage.exportSpaceKeys();
              try {
                expect(actualKeys, keys);
              } finally {
                actualKeys.fillRange(0, actualKeys.length, 0);
              }
              if (phase == 'before-publication') {
                expect(
                  await storage.getSetting(kPendingMasterSetupSetting),
                  isNull,
                );
                expect(await MasterSetupJournal.read(storage, () {}), isNull);
                await MasterSetupJournal.prepare(
                  storage: storage,
                  intent: expected,
                  root: f.root,
                  keys: keys,
                  check: () {},
                );
              }
              expect(await storage.getSetting(kPendingMasterSetupSetting), '1');
              final actual = (await MasterSetupJournal.read(storage, () {}))!;
              try {
                expect(actual.same(expected, planOnly: true), isTrue);
                expect(actual.childKnown, phase == 'child-known');
                actual.validateOwner(f.root, keys);
                if (actual.childKnown) {
                  final roster = actual.copyRoster();
                  final childKeys = roster.last.spaceKeys;
                  final child = ManagedIdentityFiles.openWithKeys(
                    owner,
                    id: f.id('b'),
                    keys: childKeys,
                  );
                  try {
                    final exported = child.exportKeys();
                    try {
                      expect(exported, childKeys);
                    } finally {
                      exported.fillRange(0, exported.length, 0);
                    }
                  } finally {
                    child.close();
                  }
                  for (final row in roster) {
                    row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
                  }
                }
              } finally {
                actual.destroy();
              }
              expect(await storage.loadProfile(), isNull);
              expect(await storage.loadRoster(), isNull);
            } finally {
              await storage.close();
            }
            final source = HiddenVolumeStorage.fromStore(
              ManagedIdentityFiles.openUnencrypted(owner, id: f.id('c')),
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
            if (phase != 'child-known') {
              expect(owner.snapshot().catalog.encode(), catalog);
            }
          } finally {
            owner.close();
          }
        },
      );
    }
  }
}
