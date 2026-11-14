@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/quick_unlock_vault.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import '../support/retirement_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fs = ManagedFsPlatform(), namespace = 'synthetic';
  late Directory fixture;
  late String profile, legacy;
  late RetirementSecretStore store;
  final authentication = RetirementAuthentication();
  final owners = <ManagedErasureWorker>[];
  Map<String, String> files() => {
    for (final f
        in fixture
            .listSync(recursive: true, followLinks: false)
            .whereType<File>())
      f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };
  String getPlan() =>
      '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}/plan.json';
  Future<ManagedErasureWorker> own(Future<ManagedErasureWorker> task) async {
    final worker = await task;
    owners.add(worker); // Includes unexpected success in omission controls.
    return worker;
  }

  Future<ManagedErasureWorker> begin(ManagedProfileErasureRequest request) =>
      own(
        ManagedErasureWorker.beginApplicationProfile(
          profileDirectory: profile,
          profileNamespace: namespace,
          legacyPath: legacy,
          request: request,
        ),
      );
  Future<QuickUnlockRetirement> remove(ManagedErasureWorker worker) async {
    final snapshot = await worker.snapshot();
    for (final scope in snapshot.unlockScopes.ids) {
      await QuickUnlockVault(
        store,
        scope,
        authentication,
      ).configure(password: 'synthetic password', system: true);
    }
    expect(store.values, isNotEmpty);
    final retirement = QuickUnlockRetirement.forWorker(
      worker.scopeLease,
      store,
      authentication,
    );
    await worker.removeManagedFiles(retireScopes: retirement.retire);
    await worker.removeAuxiliaryFiles(retireScopes: retirement.retire);
    expect(File(legacy).existsSync(), isFalse);
    expect(store.values, isEmpty);
    return retirement;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-application-erasure-');
    profile = '${fixture.path}/visible-storage';
    legacy = '${fixture.path}/legacy.hv';
    expect(fs.createPrivateDirectory(profile), isTrue);
    File(legacy).writeAsStringSync('synthetic owned legacy data');
    fs.restrictNewFile(legacy);
    store = RetirementSecretStore();
  });
  tearDown(() async {
    for (final owner in owners) {
      try {
        await owner.close();
      } catch (_) {}
    }
    owners.clear();
    fixture.deleteSync(recursive: true);
  });

  test('request recovery matches only the original application plan', () async {
    final request = ManagedProfileErasureRequest();
    final first = await begin(request);
    final snapshot = await first.snapshot();
    expect(snapshot.isApplicationProfile, isTrue);
    await first.close();
    final before = files();
    await expectLater(
      own(
        ManagedErasureWorker.recoverApplicationRequest(
          profile,
          ManagedProfileErasureRequest(),
        ),
      ),
      throwsA(isA<ManagedWorkerFailure>()),
    );
    expect(files(), before);
    final recovered = await own(
      ManagedErasureWorker.recoverApplicationRequest(profile, request),
    );
    expect(
      (await recovered.snapshot()).binding.sameOperation(snapshot.binding),
      isTrue,
    );
    expect(files(), before);
  });

  test(
    'all auxiliary roots do not promote an inventory operation to application cleanup',
    () async {
      final actor = await own(
        ManagedErasureWorker.begin(
          profileDirectory: profile,
          profileNamespace: namespace,
          legacyPath: legacy,
          auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
        ),
      );
      expect((await actor.snapshot()).isApplicationProfile, isFalse);
      await actor.close();
      final before = files();
      await expectLater(
        own(
          ManagedErasureWorker.recoverApplicationRequest(
            profile,
            ManagedProfileErasureRequest(),
          ),
        ),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files(), before);
    },
  );

  for (final partial in ['speech', 'translation']) {
    test(
      'application intent refuses partial $partial scope before publication',
      () async {
        final before = files();
        await expectLater(
          own(
            ManagedErasureWorker.beginApplicationProfile(
              profileDirectory: profile,
              profileNamespace: namespace,
              legacyPath: legacy,
              request: ManagedProfileErasureRequest(),
              auxiliary: ProfileErasureAuxiliaryTargets(
                legacyPath: legacy,
                speech: partial != 'speech',
                translation: partial != 'translation',
              ),
            ),
          ),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
        expect(files(), before);
      },
    );
  }

  test(
    'preparation recovery never republishes an absent completed intent',
    () async {
      final request = ManagedProfileErasureRequest();
      final worker = await begin(request);
      final retirement = await remove(worker);
      final proof = await worker.finish(
        verifyOtherDataAbsent: retirement.verifyAbsent,
      );
      retirement.admitFreshLifetime(proof);
      ManagedDirectoryCatalog.createOrOpen(profile).close();
      File(legacy).writeAsStringSync('synthetic fresh data');
      final before = files();
      await expectLater(
        own(ManagedErasureWorker.recoverApplicationRequest(profile, request)),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files(), before);
      expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
    },
  );

  test(
    'terminal retains application kind without a request or scope roster',
    () async {
      final request = ManagedProfileErasureRequest();
      final worker = await begin(request);
      final original = await worker.snapshot();
      final retirement = await remove(worker);
      await worker.close();
      final native = ManagedRootErasure.openPending(profile);
      try {
        await expectLater(
          native.finish(
            verifyOtherDataAbsent: retirement.verifyAbsent,
            afterStage: (stage) async {
              if (stage == ManagedErasureFinishStage.planRemoved) {
                throw StateError('synthetic terminal interruption');
              }
            },
          ),
          throwsStateError,
        );
      } finally {
        native.close();
      }
      final terminal = File(
        '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.completionName}',
      );
      final record = jsonDecode(terminal.readAsStringSync()) as Map;
      expect(record['v'], 4);
      expect(record['applicationProfile'], isTrue);
      for (final forbidden in [
        'operation',
        'unlockScopes',
        'catalog',
        'entries',
      ]) {
        expect(record.containsKey(forbidden), isFalse);
      }
      final before = files();
      await expectLater(
        own(ManagedErasureWorker.recoverApplicationRequest(profile, request)),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files(), before);
      final recovered = await own(ManagedErasureWorker.recover(profile));
      final snapshot = await recovered.snapshot();
      expect(snapshot.isApplicationProfile, isTrue);
      expect(snapshot.binding.sameOperation(original.binding), isTrue);
      expect(() => recovered.scopeLease, throwsA(isA<ManagedFsFailure>()));
      final proof = await recovered.finish(
        verifyOtherDataAbsent: () async =>
            fail('Terminal already carries its enclosing verification.'),
      );
      retirement.admitFreshLifetime(proof);
    },
  );

  test(
    'terminal kind cannot disagree with its still-present bound plan',
    () async {
      final worker = await own(
        ManagedErasureWorker.begin(
          profileDirectory: profile,
          profileNamespace: namespace,
          legacyPath: legacy,
          auxiliary: ProfileErasureAuxiliaryTargets(legacyPath: legacy),
        ),
      );
      final retirement = await remove(worker);
      await worker.close();
      final native = ManagedRootErasure.openPending(profile);
      try {
        await expectLater(
          native.finish(
            verifyOtherDataAbsent: retirement.verifyAbsent,
            afterStage: (stage) async {
              if (stage == ManagedErasureFinishStage.completionPublished) {
                throw StateError('synthetic terminal interruption');
              }
            },
          ),
          throwsStateError,
        );
      } finally {
        native.close();
      }
      final terminal = File(
        '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.completionName}',
      );
      final record = jsonDecode(terminal.readAsStringSync()) as Map;
      expect(record['applicationProfile'], isFalse);
      record['applicationProfile'] = true;
      terminal.writeAsStringSync(jsonEncode(record));
      final before = files();
      await expectLater(
        own(ManagedErasureWorker.recover(profile)),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(files(), before);
      expect(File(getPlan()).existsSync(), isTrue);
    },
  );

  for (final bad in [
    'missingKind',
    'numericKind',
    'nullKind',
    'previousVersion',
  ]) {
    test(
      'ambiguous $bad plan is preserved without upgrading its kind',
      () async {
        final first = await begin(ManagedProfileErasureRequest());
        await first.close();
        final plan = File(getPlan());
        final record = jsonDecode(plan.readAsStringSync()) as Map;
        switch (bad) {
          case 'missingKind':
            record.remove('applicationProfile');
          case 'numericKind':
            record['applicationProfile'] = 1;
          case 'nullKind':
            record['applicationProfile'] = null;
          case 'previousVersion':
            record['v'] = 5;
            record.remove('applicationProfile');
        }
        plan.writeAsStringSync(jsonEncode(record));
        final before = files();
        await expectLater(
          own(ManagedErasureWorker.recover(profile)),
          throwsA(isA<ManagedWorkerFailure>()),
        );
        expect(files(), before);
        expect(File(legacy).readAsStringSync(), 'synthetic owned legacy data');
      },
    );
  }
}
