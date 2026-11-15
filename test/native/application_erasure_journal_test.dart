@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import '../support/retirement_secret_store.dart';
import '../support/erasure_writer_process.dart';

class _Cut implements Exception {}

class _Fault extends ManagedFsPlatform {
  _Fault(this.point);
  final String point;
  bool enabled = true, seen = false;
  @override
  bool publishFileNoReplace(String source, String destination) {
    if (enabled &&
        point == 'publish' &&
        destination.endsWith(ManagedRootErasure.applicationJournalName)) {
      throw FileSystemException('synthetic private details', source);
    }
    return super.publishFileNoReplace(source, destination);
  }

  @override
  void syncDirectory(String path) {
    if (!path.endsWith('/${StorageProfileCoordinator.directoryName}')) {
      super.syncDirectory(path);
      return;
    }
    final exists = File(
      '$path/${ManagedRootErasure.applicationJournalName}',
    ).existsSync();
    if (enabled &&
        ((point == 'publishSync' && exists) ||
            (point == 'unlinkSync' && seen && !exists))) {
      throw FileSystemException('synthetic private details', path);
    }
    seen |= exists;
    super.syncDirectory(path);
  }
}

void main() {
  const fs = ManagedFsPlatform();
  late Directory fixture;
  late String profile, legacy;
  final actors = <ManagedRootErasure>[];
  final reconciliations = <ManagedErasureReconciliation>[];
  final faults = <_Fault>[];
  String journal() =>
      '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.applicationJournalName}';
  final scopes = StorageUnlockScopes(['a' * 64, 'b' * 64]);
  final witness = QuickUnlockAbsenceWitness(
    scopes: scopes,
    protectedKeys: ['xveil.quick.v1.${'a' * 64}.bio.synthetic'],
  );

  Future<ManagedRootErasure> prepare({
    ManagedFsPlatform platform = fs,
    bool application = true,
  }) async {
    final owner = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      final store = ManagedIdentityFiles.createUnencrypted(
        owner,
        id: ManagedIdentityId('1' * 32),
      );
      try {
        store.commit([
          PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([2, 3, 4])),
        ]);
      } finally {
        store.close();
      }
    } finally {
      owner.close();
    }
    final exclusive = ManagedDirectoryCatalog.openExclusiveMaintenance(
      profile,
    )!;
    try {
      await ManagedRootErasure.prepare(
        exclusive,
        unlockScopes: scopes,
        auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
        applicationRequest: application ? ManagedProfileErasureRequest() : null,
      );
    } finally {
      exclusive.close();
    }
    final actor = ManagedRootErasure.openPending(profile, fs: platform);
    actors.add(actor);
    return actor;
  }

  Map<String, List<int>> payloads() => {
    for (final file in Directory(
      '$profile/identities',
    ).listSync(recursive: true).whereType<File>())
      file.path: file.readAsBytesSync(),
  };
  Future<void> remove(ManagedRootErasure actor) async {
    await actor.removeManagedFiles(retireScopes: (_) async {});
    await actor.removeAuxiliaryFiles(retireScopes: () async {});
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync(
      'xveil-application-journal-crash-',
    );
    profile = '${fixture.path}/profile';
    legacy = '${fixture.path}/legacy.bin';
    expect(fs.createPrivateDirectory(profile), isTrue);
  });
  tearDown(() {
    for (final fault in faults) {
      fault.enabled = false;
    }
    for (final actor in actors) {
      try {
        if (actor.finalSyncPending &&
            actor.phase == ManagedRootErasurePhase.complete) {
          actor.releaseCompleted();
        } else {
          actor.close();
        }
      } catch (_) {}
    }
    for (final owner in reconciliations) {
      try {
        owner.close();
      } catch (_) {}
    }
    actors.clear();
    reconciliations.clear();
    faults.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'journal is durable, exact-operation bound and idempotent before deletion',
    () async {
      final actor = await prepare();
      final before = payloads();
      actor.persistSavedEntryWitness(witness.encode());
      final bytes = File(journal()).readAsBytesSync();
      final identity = fs.inspect(journal()).identity;
      expect(actor.snapshot().savedEntryWitness, witness.encode());
      expect(payloads(), before);
      actor.persistSavedEntryWitness(witness.encode());
      expect(File(journal()).readAsBytesSync(), bytes);
      expect(fs.inspect(journal()).identity, identity);
      final different = QuickUnlockAbsenceWitness(
        scopes: scopes,
        protectedKeys: [],
      );
      expect(
        () => actor.persistSavedEntryWitness(different.encode()),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(File(journal()).readAsBytesSync(), bytes);
      actor.close();
      final cold = ManagedRootErasure.openPending(profile);
      actors.add(cold);
      expect(cold.snapshot().savedEntryWitness, witness.encode());
      expect(payloads(), before);
    },
  );

  for (final point in ['publish', 'publishSync']) {
    test(
      '$point refuses acknowledgment and preserves native payload',
      () async {
        final fault = _Fault(point);
        faults.add(fault);
        final actor = await prepare(platform: fault);
        final before = payloads();
        expect(
          () => actor.persistSavedEntryWitness(witness.encode()),
          throwsA(
            isA<ManagedFsFailure>().having(
              (error) => error.toString(),
              'safe error',
              isNot(contains(fixture.path)),
            ),
          ),
        );
        expect(payloads(), before);
        final bytes = File(journal()).existsSync()
            ? File(journal()).readAsBytesSync()
            : null;
        fault.enabled = false;
        actor.persistSavedEntryWitness(witness.encode());
        if (bytes != null) expect(File(journal()).readAsBytesSync(), bytes);
        expect(payloads(), before);
      },
    );
  }

  test(
    'non-application operation and wrong scope set cannot publish recovery addresses',
    () async {
      final actor = await prepare(application: false);
      expect(
        () => actor.persistSavedEntryWitness(witness.encode()),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(File(journal()).existsSync(), isFalse);
    },
  );
  test('wrong scope set cannot publish or replace a journal', () async {
    final actor = await prepare();
    final before = payloads();
    final wrong = QuickUnlockAbsenceWitness(
      scopes: StorageUnlockScopes(['c' * 64]),
      protectedKeys: [],
    );
    expect(
      () => actor.persistSavedEntryWitness(wrong.encode()),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(File(journal()).existsSync(), isFalse);
    expect(payloads(), before);
  });

  test(
    'terminal recovery repeats read-only OS checks and preserves reappearing records',
    () async {
      final actor = await prepare();
      actor.persistSavedEntryWitness(witness.encode());
      await remove(actor);
      await expectLater(
        actor.finish(
          verifyOtherDataAbsent: () async {},
          afterStage: (stage) async {
            if (stage == ManagedErasureFinishStage.pendingRemoved) throw _Cut();
          },
        ),
        throwsA(isA<_Cut>()),
      );
      actor.close();
      final cold = ManagedRootErasure.openPending(profile);
      actors.add(cold);
      expect(cold.snapshot().savedEntryWitness, witness.encode());
      expect(() => cold.retirementSnapshot(), throwsA(isA<ManagedFsFailure>()));
      final store = RetirementSecretStore();
      store.values['true:${witness.protectedKeys.single}'] =
          'synthetic reappearing credential';
      final before = Map.of(store.values);
      final journalBytes = File(journal()).readAsBytesSync();
      await expectLater(
        cold.finish(verifyOtherDataAbsent: () => witness.verifyAbsent(store)),
        throwsA(isA<QuickUnlockRetirementFailure>()),
      );
      expect(store.values, before);
      expect(File(journal()).readAsBytesSync(), journalBytes);
      store.values.clear();
      await cold.finish(
        verifyOtherDataAbsent: () => witness.verifyAbsent(store),
      );
      expect(File(journal()).existsSync(), isTrue);
      cold.releaseCompleted();
      expect(File(journal()).existsSync(), isFalse);
    },
  );

  test(
    'journal-only worker exposes only read-only verification, then removes marker',
    () async {
      final actor = await prepare();
      actor.persistSavedEntryWitness(witness.encode());
      await remove(actor);
      await actor.finish(verifyOtherDataAbsent: () async {});
      actor.close();
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
      expect(
        StorageProfileCoordinator.hasErasureIntent(
          profile,
          includeApplicationJournal: false,
        ),
        isFalse,
      );
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      final cold = await ManagedErasureWorker.reconcileApplicationJournal(
        profile,
      );
      try {
        final snapshot = await cold.snapshot();
        expect(snapshot.savedEntryWitness, witness.encode());
        expect(() => cold.scopeLease, throwsA(isA<ManagedFsFailure>()));
        expect(
          () => cold.persistSavedEntryWitness(witness.encode()),
          throwsA(isA<ManagedFsFailure>()),
        );
        await expectLater(
          cold.removeManagedFiles(
            retireScopes: () async =>
                fail('read-only recovery must not retire scopes'),
          ),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        await cold.finish(
          verifyOtherDataAbsent: () => QuickUnlockAbsenceWitness.decode(
            snapshot.savedEntryWitness!,
          ).verifyAbsent(RetirementSecretStore()),
        );
      } finally {
        await cold.close();
      }
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
      final fresh = ManagedDirectoryCatalog.createOrOpen(profile);
      fresh.close();
    },
  );

  test(
    'failed journal unlink sync retains the exclusive owner and supports retry',
    () async {
      final fault = _Fault('unlinkSync');
      faults.add(fault);
      final actor = await prepare(platform: fault);
      actor.persistSavedEntryWitness(witness.encode());
      await remove(actor);
      await actor.finish(verifyOtherDataAbsent: () async {});
      expect(() => actor.releaseCompleted(), throwsA(isA<ManagedFsFailure>()));
      expect(actor.finalSyncPending, isTrue);
      expect(() => actor.close(), throwsA(isA<ManagedLeaseFailure>()));
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(profile),
        throwsA(anything),
      );
      fault.enabled = false;
      actor.releaseCompleted();
      final fresh = ManagedDirectoryCatalog.createOrOpen(profile);
      fresh.close();
    },
  );

  for (final malformed in ['truncated', 'binding', 'scope', 'symlink']) {
    test('$malformed journal refuses recovery without mutation', () async {
      final actor = await prepare();
      actor.persistSavedEntryWitness(witness.encode());
      await remove(actor);
      await actor.finish(verifyOtherDataAbsent: () async {});
      actor.close();
      final file = File(journal());
      if (malformed == 'truncated') {
        file.writeAsStringSync('{', flush: true);
      }
      if (malformed == 'binding' || malformed == 'scope') {
        final record =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if (malformed == 'binding') {
          (record['binding'] as Map)['profile'] = 'foreign';
        } else {
          record['records'] = jsonEncode({
            'v': 1,
            'scopes': [],
            'protected': [],
          });
        }
        file.writeAsStringSync(jsonEncode(record), flush: true);
      }
      if (malformed == 'symlink') {
        file.renameSync('${fixture.path}/outside.json');
        Link(journal()).createSync('${fixture.path}/outside.json');
      }
      final before = File(journal()).readAsBytesSync();
      expect(
        () => ManagedErasureReconciliation.openApplicationJournal(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(File(journal()).readAsBytesSync(), before);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
    });
  }

  for (final phase in ['published', 'terminal', 'terminalPublished']) {
    test(
      'actual SIGKILL at $phase retains recoverable addresses and ownership',
      () async {
        final actor = await prepare();
        actor.close();
        File('${fixture.path}/synthetic-os.json').writeAsStringSync(
          jsonEncode({
            'false:xveil.quick.v1.${scopes.ids.first}': 'synthetic metadata',
            'true:${witness.protectedKeys.single}': 'synthetic credential',
          }),
          flush: true,
        );
        await killErasureWriter(
          fixture.path,
          phase,
          () {
            expect(File(journal()).existsSync(), isTrue);
            expect(StorageProfileCoordinator.hasErasureIntent(profile), isTrue);
          },
          script: 'test/native/application_erasure_journal_writer.dart',
        );
        final os = RetirementSecretStore();
        os.values.addAll(
          (jsonDecode(
                    File(
                      '${fixture.path}/synthetic-os.json',
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast<String, String>(),
        );
        if (phase == 'terminal') {
          final cold = ManagedErasureReconciliation.openApplicationJournal(
            profile,
          );
          reconciliations.add(cold);
          expect(cold.snapshot().savedEntryWitness, witness.encode());
          await cold.verifyAndRelease(
            verifyOtherDataAbsent: () => witness.verifyAbsent(os),
          );
        } else {
          final cold = ManagedRootErasure.openPending(profile);
          actors.add(cold);
          expect(cold.snapshot().savedEntryWitness, witness.encode());
          if (phase == 'published') {
            expect(os.values, isNotEmpty);
            os.values.clear();
            await remove(cold);
          } else {
            expect(os.values, isEmpty);
          }
          await cold.finish(
            verifyOtherDataAbsent: () => witness.verifyAbsent(os),
          );
          cold.releaseCompleted();
        }
        expect(File(journal()).existsSync(), isFalse);
      },
    );
  }
}
