@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

enum _Boundary {
  abort,
  publish,
  unknownSource,
  copiedIntent,
  malformedIntent,
  incompleteJournal,
  partialApply,
  callerMutation,
  selectedRecovery,
  syncRefusal,
}

class _Abort implements Exception {}

class _FaultFs extends ManagedFsPlatform {
  String? blockedDirectory;
  int sourceFlushRefusals = 0;
  @override
  void syncSourceDirectory(String path) {
    if (blockedDirectory == path) {
      sourceFlushRefusals++;
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    super.syncSourceDirectory(path);
  }

  @override
  void syncDirectory(String path) {
    if (blockedDirectory == path) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    super.syncDirectory(path);
  }
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _Fixture {
  final directory = Directory.systemTemp.createTempSync(
    'xveil-external-references-',
  );
  late ManagedDirectoryCatalog root;
  final fs = _FaultFs();
  bool initialized = false;
  final keys = <ManagedIdentityId, Uint8List>{};
  final old = <String, Uint8List>{};
  final changes = <LegacyCompactionKeyChange>[];
  String get profile => '${directory.path}/visible-storage';
  String get source => '${directory.path}/xveil.store';
  ManagedIdentityId id(int n) => ManagedIdentityId('$n' * 32);

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

  Future<void> create() async {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    root = ManagedDirectoryCatalog.createOrOpen(profile, fs: fs);
    initialized = true;
    HvKvLogStore(
      hv.HvSpace.create(
        path: source,
        password: _bytes('first'),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    for (final password in ['first', 'second']) {
      final space = password == 'first'
          ? hv.HvSpace.open(path: source, password: _bytes(password))
          : hv.HvSpace.addSpace(path: source, password: _bytes(password));
      try {
        space.commit([
          hv.HvWriteOpPut(
            namespace: 1,
            key: _bytes('payload'),
            value: _bytes(password),
          ),
        ]);
        old[password] = space.spaceKeys();
      } finally {
        space.close();
      }
    }
    for (final n in [1, 2, 3]) {
      final store = n == 1
          ? ManagedIdentityFiles.createEncrypted(
              root,
              id: id(n),
              password: _bytes('external master fixture'),
            )
          : ManagedIdentityFiles.createUnencrypted(root, id: id(n));
      keys[id(n)] = store.exportKeys();
      final facade = HiddenVolumeStorage.fromStore(store);
      try {
        if (n < 3) {
          await facade.saveRoster([
            for (final entry in old.entries)
              RosterEntry(
                label: entry.key,
                spaceKeys: entry.value,
                anonymous: true,
              ),
          ]);
        }
      } finally {
        await facade.close();
      }
    }
    for (final n in [1, 2]) {
      await master(n, (store) async {
        final rows = (await store.loadRoster())!;
        await store.saveRoster([
          ...rows,
          RosterEntry(
            label: 'owned',
            spaceKeys: keys[id(3)]!,
            storageLocator: ManagedStorageLocator(
              id: id(3),
              protection: StorageProtection.unencrypted,
            ),
          ),
        ]);
      });
    }
  }

  Map<String, String> publicInventory() => {
    for (final dir in [
      Directory(root.directory),
      Directory('$profile/${StorageProfileCoordinator.directoryName}'),
    ])
      for (final file in dir.listSync(followLinks: false))
        if (file is File)
          file.path.substring(directory.path.length): sha256
              .convert(file.readAsBytesSync())
              .toString(),
  };

  void exclusive() {
    root.close();
    root = ManagedDirectoryCatalog.openExclusiveMaintenance(profile, fs: fs)!;
  }

  Future<void> prepare(String staged, {bool mutateCaller = false}) async {
    for (final password in old.keys) {
      final space = hv.HvSpace.open(path: staged, password: _bytes(password));
      try {
        changes.add((
          before: Uint8List.fromList(old[password]!),
          after: space.spaceKeys(),
        ));
      } finally {
        space.close();
      }
    }
    if (!mutateCaller) {
      await ManagedLegacyReferenceRepair.prepare(
        owner: root,
        authorizations: keys,
        changes: changes,
      );
      return;
    }
    final borrowed = {
      for (final entry in keys.entries)
        entry.key: Uint8List.fromList(entry.value),
    };
    final borrowedChanges = [
      for (final value in changes)
        (
          before: Uint8List.fromList(value.before),
          after: Uint8List.fromList(value.after),
        ),
    ];
    final preparing = ManagedLegacyReferenceRepair.prepare(
      owner: root,
      authorizations: borrowed,
      changes: borrowedChanges,
    );
    expect(root.close, throwsA(isA<ManagedIdentityFailure>()));
    for (final value in borrowed.values) {
      value.fillRange(0, value.length, 0);
    }
    for (final value in borrowedChanges) {
      value.before.fillRange(0, value.before.length, 0);
      value.after.fillRange(0, value.after.length, 0);
    }
    await preparing;
  }

  Future<List<int>?> journal(int n) => master(
    n,
    (store) => store.loadFile(ManagedLegacyReferenceRepair.journalFile),
  );

  Future<void> expectUsable({required bool published}) async {
    for (final n in [1, 2]) {
      final rows = await master(n, (store) => store.loadRoster());
      expect(rows!.map((row) => row.label), ['first', 'second', 'owned']);
      for (final row in rows.take(2)) {
        expect(row.anonymous, isTrue);
        final expected = published
            ? changes
                  .singleWhere((c) => listEquals(c.before, old[row.label]!))
                  .after
            : old[row.label]!;
        expect(row.spaceKeys, expected);
        final space = hv.HvSpace.openWithKeys(
          path: source,
          keys: row.spaceKeys,
        );
        try {
          expect(space.get(1, _bytes('payload')), _bytes(row.label));
        } finally {
          space.close();
        }
      }
      expect(rows.last.spaceKeys, keys[id(3)]);
      expect(
        rows.last.storageLocator,
        ManagedStorageLocator(
          id: id(3),
          protection: StorageProtection.unencrypted,
        ),
      );
      expect(await journal(n), isNull);
    }
  }

  void close() {
    if (initialized) root.close();
    for (final value in keys.values) {
      value.fillRange(0, value.length, 0);
    }
    for (final change in changes) {
      change.before.fillRange(0, change.before.length, 0);
      change.after.fillRange(0, change.after.length, 0);
    }
    directory.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final phase in [
    'prepared',
    'published',
    'worker-prepared',
    'worker-published',
  ]) {
    test(
      'process death with private external journals: $phase',
      () async {
        final f = _Fixture();
        addTearDown(f.close);
        await f.create();
        final sourceBefore = File(f.source).readAsBytesSync();
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
          }),
          flush: true,
        );
        const ManagedFsPlatform().restrictNewFile(capabilities.path);
        f.root.close();
        final process = await Process.start('dart', [
          'run',
          File(
            'test/native/managed_legacy_reference_writer.dart',
          ).absolute.path,
          f.directory.path,
          phase,
        ]);
        final output = StringBuffer();
        final stdout = process.stdout
            .transform(utf8.decoder)
            .listen(output.write);
        final stderr = process.stderr
            .transform(utf8.decoder)
            .listen(output.write);
        int? exitCode;
        final terminal = process.exitCode.then((code) {
          exitCode = code;
          return code;
        });
        try {
          final ready = File('${f.directory.path}/ready');
          final watch = Stopwatch()..start();
          while (!ready.existsSync() &&
              exitCode == null &&
              watch.elapsed < const Duration(seconds: 90)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (!ready.existsSync() || exitCode != null) {
            throw StateError(
              'Owned writer did not reach the crash boundary; exit=$exitCode',
            );
          }
          final marker =
              jsonDecode(ready.readAsStringSync()) as Map<String, dynamic>;
          expect(marker, {'pid': process.pid, 'phase': phase});
          // The writer still owns the full profile, even at the boundary after
          // native source publication. No independent catalog reader may enter.
          ManagedDirectoryCatalog? competing;
          try {
            expect(
              () => competing = ManagedDirectoryCatalog.openExisting(f.profile),
              throwsA(
                anyOf(
                  isA<ManagedLeaseFailure>().having(
                    (e) => e.kind,
                    'kind',
                    ManagedLeaseFailureKind.busy,
                  ),
                  isA<ManagedSqliteFailure>().having(
                    (e) => e.sqliteCode,
                    'sqliteCode',
                    5,
                  ),
                ),
              ),
            );
          } finally {
            competing?.close();
          }
          if (phase.endsWith('prepared')) {
            hv.HvSpace? competingSource;
            try {
              expect(
                () => competingSource = hv.HvSpace.open(
                  path: f.source,
                  password: _bytes(f.old.keys.first),
                ),
                throwsA(
                  isA<hv.HvException>().having((e) => e.kind, 'kind', 'Busy'),
                ),
              );
            } finally {
              competingSource?.close();
            }
          }

          expect(process.kill(ProcessSignal.sigkill), isTrue);
          expect(await terminal, isNot(0));
        } finally {
          if (exitCode == null) {
            process.kill(ProcessSignal.sigkill);
            await terminal;
          }
          await stdout.cancel();
          await stderr.cancel();
          if (exitCode == null || exitCode == 0) {
            // Kept in the private fixture only; no keys/output in assertions.
            File(
              '${f.directory.path}/writer-output-private.log',
            ).writeAsStringSync(output.toString());
          }
        }
        f.exclusive();
        for (final password in f.old.keys) {
          final actual = hv.HvSpace.open(
            path: f.source,
            password: _bytes(password),
          );
          try {
            f.changes.add((
              before: Uint8List.fromList(f.old[password]!),
              after: actual.spaceKeys(),
            ));
          } finally {
            actual.close();
          }
        }
        if (phase.endsWith('prepared')) {
          expect(File(f.source).readAsBytesSync(), sourceBefore);
        }
        expect(await f.journal(1), isNotNull);
        expect(await f.journal(2), isNotNull);
        expect(
          await ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          phase.endsWith('published')
              ? LegacyReferenceRepairOutcome.publishedReplacement
              : LegacyReferenceRepairOutcome.retainedSource,
        );
        await f.expectUsable(published: phase.endsWith('published'));
      },
      skip: Platform.isWindows ? 'POSIX SIGKILL writer fixture' : false,
    );
  }

  for (final refusal in ['shared', 'incomplete', 'wrong', 'unreadableRoster']) {
    test(
      'external preparation refuses $refusal authority before journals',
      () async {
        final f = _Fixture();
        addTearDown(f.close);
        await f.create();
        if (refusal != 'shared') f.exclusive();
        final authorizations = Map<ManagedIdentityId, Uint8List>.of(f.keys);
        if (refusal == 'incomplete') authorizations.remove(f.id(3));
        if (refusal == 'wrong') authorizations[f.id(1)] = Uint8List(64);
        if (refusal == 'unreadableRoster') {
          final store = ManagedIdentityFiles.openWithKeys(
            f.root,
            id: f.id(2),
            keys: f.keys[f.id(2)]!,
          );
          try {
            store.commit([
              PutOp(Ns.settings, _bytes('master:roster'), _bytes('not json')),
            ]);
          } finally {
            store.close();
          }
        }
        final before = File(f.source).readAsBytesSync();
        await expectLater(
          ManagedLegacyReferenceRepair.prepare(
            owner: f.root,
            authorizations: authorizations,
            changes: [
              for (final (index, value) in f.old.values.indexed)
                (
                  before: value,
                  after: Uint8List(64)..fillRange(0, 64, index + 1),
                ),
            ],
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        for (final n in [1, 2, 3]) {
          expect(await f.journal(n), isNull);
        }
        expect(File(f.source).readAsBytesSync(), before);
      },
    );
  }

  for (final boundary in _Boundary.values) {
    test('external native reference recovery: ${boundary.name}', () async {
      final f = _Fixture();
      addTearDown(f.close);
      await f.create();
      f.exclusive();
      final publicBefore = f.publicInventory();
      final beforeSource = File(f.source).readAsBytesSync();
      final rewrite = hv.compactKnownPreparedAsync(
        f.source,
        [for (final password in f.old.keys) _bytes(password)],
        dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
        repairMetadata: (staged) async {
          await f.prepare(
            staged,
            mutateCaller: boundary == _Boundary.callerMutation,
          );
          expect(await f.journal(1), isNotNull);
          expect(await f.journal(2), isNotNull);
          for (final n in [1, 2]) {
            final rows = await f.master(n, (master) => master.loadRoster());
            expect(rows!.first.spaceKeys, f.old['first']);
          }
          if (boundary == _Boundary.abort ||
              boundary == _Boundary.copiedIntent) {
            throw _Abort();
          }
        },
      );
      if (boundary == _Boundary.abort || boundary == _Boundary.copiedIntent) {
        await expectLater(rewrite, throwsA(isA<_Abort>()));
        expect(File(f.source).readAsBytesSync(), beforeSource);
      } else {
        await rewrite;
      }

      if (boundary == _Boundary.unknownSource) {
        final retained = File(f.source).readAsBytesSync();
        final journals = [await f.journal(1), await f.journal(2)];
        final file = File(f.source).openSync(mode: FileMode.writeOnlyAppend);
        try {
          file.truncateSync(4096);
        } finally {
          file.closeSync();
        }
        await expectLater(
          ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        expect(await f.journal(1), journals[0]);
        expect(await f.journal(2), journals[1]);
        File(f.source).writeAsBytesSync(retained, flush: true);
      }
      if (boundary == _Boundary.copiedIntent) {
        final original = await f.journal(2);
        final foreign = await f.journal(1);
        await f.master(
          2,
          (master) => master.storeFile(
            ManagedLegacyReferenceRepair.journalFile,
            Uint8List.fromList(foreign!),
          ),
        );
        await expectLater(
          ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        expect(await f.journal(1), foreign);
        expect(await f.journal(2), foreign);
        await f.master(
          2,
          (master) => master.storeFile(
            ManagedLegacyReferenceRepair.journalFile,
            Uint8List.fromList(original!),
          ),
        );
      }
      if (boundary == _Boundary.malformedIntent) {
        final original = await f.journal(1);
        final other = await f.journal(2);
        final altered =
            jsonDecode(utf8.decode(original!)) as Map<String, dynamic>;
        altered['unrecognized'] = true;
        final corrupt = _bytes(jsonEncode(altered));
        await f.master(
          1,
          (master) => master.storeFile(
            ManagedLegacyReferenceRepair.journalFile,
            corrupt,
          ),
        );
        await expectLater(
          ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        expect(await f.journal(1), corrupt);
        expect(await f.journal(2), other);
        await f.master(
          1,
          (master) => master.storeFile(
            ManagedLegacyReferenceRepair.journalFile,
            Uint8List.fromList(original),
          ),
        );
      }
      if (boundary == _Boundary.incompleteJournal) {
        final original = await f.journal(1);
        final other = await f.journal(2);
        await f.master(1, (master) async {
          await master.deleteStoredFile(
            ManagedLegacyReferenceRepair.journalFile,
          );
          await master.storeFilePiece(
            ManagedLegacyReferenceRepair.journalFile,
            0,
            2,
            1024,
            2048,
            Uint8List(1024),
          );
          expect(
            await master.hasFile(ManagedLegacyReferenceRepair.journalFile),
            isFalse,
          );
          expect(
            await master.loadFile(ManagedLegacyReferenceRepair.journalFile),
            isNull,
          );
        });
        await expectLater(
          ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        expect(await f.journal(2), other);
        await f.master(1, (master) async {
          await master.deleteStoredFile(
            ManagedLegacyReferenceRepair.journalFile,
          );
          await master.storeFile(
            ManagedLegacyReferenceRepair.journalFile,
            Uint8List.fromList(original!),
          );
        });
      }
      if (boundary == _Boundary.partialApply) {
        // Simulates the durable save-before-journal-delete boundary, rather
        // than claiming an actual process crash occurred in this fixture.
        await f.master(1, (master) async {
          final rows = (await master.loadRoster())!;
          await master.saveRoster([
            for (final row in rows)
              if (row.storageLocator is LegacyStorageLocator)
                row.copyWith(
                  spaceKeys: f.changes
                      .singleWhere((c) => listEquals(c.before, row.spaceKeys))
                      .after,
                )
              else
                row,
          ]);
        });
      }
      if (boundary == _Boundary.syncRefusal) {
        final first = await f.journal(1), second = await f.journal(2);
        final previousRefusals = f.fs.sourceFlushRefusals;
        // Use the actual owner's canonical parent spelling on each platform;
        // URI directory paths may carry either kind of trailing separator.
        f.fs.blockedDirectory = Directory(f.root.profileDirectory).parent.path;
        await expectLater(
          ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        expect(f.fs.sourceFlushRefusals, previousRefusals + 1);
        expect(await f.journal(1), first);
        expect(await f.journal(2), second);
        for (final n in [1, 2]) {
          final rows = await f.master(n, (master) => master.loadRoster());
          expect(rows!.first.spaceKeys, f.old['first']);
        }
        f.fs.blockedDirectory = null;
      }
      if (boundary == _Boundary.selectedRecovery) {
        final other = await f.journal(2);
        expect(
          await ManagedLegacyReferenceRepair.resumeForIdentity(
            owner: f.root,
            identity: f.id(1),
            keys: f.keys[f.id(1)]!,
          ),
          LegacyReferenceRepairOutcome.publishedReplacement,
        );
        expect(await f.journal(1), isNull);
        expect(await f.journal(2), other);
        await expectLater(
          ManagedLegacyReferenceRepair.prepare(
            owner: f.root,
            authorizations: f.keys,
            changes: [
              for (final (index, change) in f.changes.indexed)
                (
                  before: change.after,
                  after: Uint8List(64)..fillRange(0, 64, 10 + index),
                ),
            ],
          ),
          throwsA(isA<LegacyReferenceRepairFailure>()),
        );
        expect(await f.journal(1), isNull);
        expect(await f.journal(2), other);
        final source = File(f.source).renameSync('${f.source}.held');
        try {
          expect(
            await ManagedLegacyReferenceRepair.resumeForIdentity(
              owner: f.root,
              identity: f.id(3),
              keys: f.keys[f.id(3)]!,
            ),
            LegacyReferenceRepairOutcome.none,
          );
          expect(File(f.source).existsSync(), isFalse);
        } finally {
          source.renameSync(f.source);
        }
      }
      final sourceBeforeProof = File(f.source).readAsBytesSync();
      final outcome = await ManagedLegacyReferenceRepair.resume(
        owner: f.root,
        authorizations: f.keys,
      );
      final published =
          boundary != _Boundary.abort && boundary != _Boundary.copiedIntent;
      expect(
        outcome,
        published
            ? LegacyReferenceRepairOutcome.publishedReplacement
            : LegacyReferenceRepairOutcome.retainedSource,
      );
      expect(File(f.source).readAsBytesSync(), sourceBeforeProof);
      expect(f.publicInventory(), publicBefore);
      await f.expectUsable(published: published);
      final source = File(f.source).renameSync('${f.source}.held');
      try {
        expect(
          await ManagedLegacyReferenceRepair.resume(
            owner: f.root,
            authorizations: f.keys,
          ),
          LegacyReferenceRepairOutcome.none,
        );
        expect(File(f.source).existsSync(), isFalse);
      } finally {
        source.renameSync(f.source);
      }
    });
  }
}
