@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/master_setup_journal.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/storage_initialization.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'package:xveil/domain/storage_setup.dart';
import '../support/erasure_writer_process.dart';
import 'support/master_setup_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in StorageProtection.values) {
    for (final phase in [
      'child-profile-staged',
      'roster-published',
      'completed',
    ]) {
      test(
        'native master completion after process death (${mode.name}/$phase)',
        () async {
          expect(ensureHiddenVolumeLoaded(), isTrue);
          final dir = Directory.systemTemp.createTempSync(
            'xveil-master-journal-',
          );
          final fixture = MasterSetupFixture(dir, mode);
          addTearDown(() => dir.deleteSync(recursive: true));
          await fixture.create();
          final request =
              jsonDecode(
                    File('${dir.path}/request-private.json').readAsStringSync(),
                  )
                  as Map;
          final rootKeys = base64.decode(request['keys'] as String);
          final base = MasterSetupIntent.decode(
            base64.decode(request['intent'] as String),
          );
          MasterSetupIntent? ready;
          Uint8List? childKeys;
          addTearDown(() {
            rootKeys.fillRange(0, rootKeys.length, 0);
            childKeys?.fillRange(0, childKeys.length, 0);
            base.destroy();
            ready?.destroy();
          });
          await killErasureWriter(
            dir.path,
            phase,
            () {},
            script: 'test/native/master_setup_journal_writer.dart',
            writerArguments: [mode.name],
          );
          final owner = ManagedDirectoryCatalog.openExisting(fixture.profile)!;
          try {
            final catalog = owner.snapshot().catalog.encode();
          final rawChild = ManagedIdentityFiles.openWithPassword(
              owner,
              id: fixture.id('b'),
              password: fixture.childPassword,
            );
            childKeys = rawChild.exportKeys();
            ready = base.withChildKeys(childKeys);
            final child = HiddenVolumeStorage.fromStore(rawChild);
            late MasterSetupChildProof proof;
            try {
              expect(
                await child.loadProfile(),
                UserProfile(displayName: ready.childLabel),
              );
              expect(
                await child.getSetting(kPendingIdentitySetupSetting),
                phase == 'child-profile-staged' ? '1' : '0',
              );
              proof = await MasterSetupJournal.initializeChild(
                storage: child,
                intent: ready,
                child: ready.childLocator,
                childKeys: childKeys,
                check: () {},
              );
              expect(await child.getSetting(kPendingIdentitySetupSetting), '0');
            } finally {
              await child.close();
            }
            var master = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
            try {
              expect(
                await master.getSetting(kPendingMasterSetupSetting),
                phase == 'completed' ? '0' : '1',
              );
              final roster = await master.loadRoster();
              try {
                expect(
                  roster?.map((r) => r.label).toList(),
                  phase == 'child-profile-staged'
                      ? isNull
                      : ['original identity', ready.childLabel],
                );
              } finally {
                for (final row in roster ?? []) {
                  row.spaceKeys.fillRange(0, 64, 0);
                }
              }
              if (phase != 'completed') {
                final pending = (await MasterSetupJournal.read(master, () {}))!;
                try {
                  expect(pending.same(ready), isTrue);
                } finally {
                  pending.destroy();
                }
              }
              await MasterSetupJournal.publishAndFinish(
                storage: master,
                intent: ready,
                childProof: proof,
                root: fixture.root,
                keys: rootKeys,
                check: () {},
              );
            } finally {
              await master.close();
            }
            // A second cold native open must see both the full roster and its
            // non-replayable completion receipt, never a mixed pair.
            master = HiddenVolumeStorage.fromStore(fixture.openRoot(owner));
            try {
              expect(await master.getSetting(kPendingMasterSetupSetting), '0');
              final rows = (await master.loadRoster())!;
              try {
                expect(rows.map((r) => r.label), [
                  'original identity',
                  ready.childLabel,
                ]);
                expect(rows.last.spaceKeys, childKeys);
                expect(rows.last.storageLocator, ready.childLocator);
                expect(await master.loadProfile(), isNull);
                final bytes = (await master.loadFile(kMasterSetupJournalFile))!;
                try {
                  expect(jsonDecode(utf8.decode(bytes)), {
                    'v': 1,
                    'complete': true,
                    'digest': isA<String>(),
                  });
                } finally {
                  bytes.fillRange(0, bytes.length, 0);
                }
                // Legitimate later removal is never reversed by an old retry.
                await master.saveRoster([rows.first]);
                await MasterSetupJournal.publishAndFinish(
                  storage: master,
                  intent: ready,
                  childProof: proof,
                  root: fixture.root,
                  keys: rootKeys,
                  check: () {},
                );
                final remaining = (await master.loadRoster())!;
                try {
                  expect(remaining.single.label, 'original identity');
                } finally {
                  for (final row in remaining) {
                    row.spaceKeys.fillRange(0, 64, 0);
                  }
                }
              } finally {
                for (final row in rows) {
                  row.spaceKeys.fillRange(0, 64, 0);
                }
              }
            } finally {
              await master.close();
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
            expect(owner.snapshot().catalog.encode(), catalog);
          } finally {
            owner.close();
          }
        },
      );
    }
  }
}
