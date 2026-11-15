@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

class _WorkFailed implements Exception {}

void _expectBusy(String profile) {
  StorageProfileCoordinator? competing;
  try {
    expect(
      () => competing = StorageProfileCoordinator.openExisting(
        profile,
        exclusive: true,
      ),
      throwsA(
        anyOf(
          isA<ManagedLeaseFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedLeaseFailureKind.busy,
          ),
          isA<ManagedSqliteFailure>().having((e) => e.sqliteCode, 'code', 5),
        ),
      ),
    );
  } finally {
    competing?.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path, profile;
  final files = <ManagedProfilePreferencesFile>[];
  Future<ManagedProfilePreferencesFile> open([String? target]) async {
    final file = await ManagedProfilePreferencesFile.open(target ?? path);
    files.add(file);
    return file;
  }

  StorageProfileCoordinator exclusive() =>
      StorageProfileCoordinator.openExisting(profile, exclusive: true)!;

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    directory = Directory.systemTemp.createTempSync('xveil-preference-scope-');
    path = '${directory.path}/xveil.prefs.json';
    profile = '${directory.path}/visible-storage';
  });
  tearDown(() async {
    for (final file in files) {
      await file.close();
    }
    files.clear();
    directory.deleteSync(recursive: true);
  });

  test('actual profile grant is released only for the accepted work', () async {
    final file = await open();
    expect(await file.write('before-fixture'), isTrue);
    _expectBusy(profile);
    expect(
      await ManagedProfilePreferencesFile.withProfileReleased(
        profile,
        () async {
          final owner = exclusive();
          try {
            owner.requireHeld(exclusive: true);
            return 42;
          } finally {
            owner.close();
          }
        },
      ),
      42,
    );
    _expectBusy(profile);
    expect(await file.read(), 'before-fixture');
    expect(await file.write('after-fixture'), isTrue);
  });

  test(
    'already opening actors are joined and all matching actors release',
    () async {
      // Bootstrap the permanent role first, as application startup does. This
      // case qualifies joining opens, not competing fresh-role initialization.
      await (await open()).close();
      final first = open(), second = open();
      await ManagedProfilePreferencesFile.withProfileReleased(
        profile,
        () async {
          final owner = exclusive();
          owner.requireHeld(exclusive: true);
          owner.close();
        },
      );
      expect(await (await first).write('two-actor-fixture'), isTrue);
      expect(await (await second).read(), 'two-actor-fixture');
      _expectBusy(profile);
    },
  );

  test(
    'reads and writes queue while new actors refuse until explicit retry',
    () async {
      final file = await open();
      expect(await file.write('before-fixture'), isTrue);
      final entered = Completer<void>(), release = Completer<void>();
      final scoped = ManagedProfilePreferencesFile.withProfileReleased(
        profile,
        () async {
          final owner = exclusive();
          try {
            entered.complete();
            await release.future;
            return 42;
          } finally {
            owner.close();
          }
        },
      );
      final scopeResult = expectLater(scoped, completion(42));
      await entered.future;
      final write = expectLater(
        file.write('queued-fixture'),
        completion(isTrue),
      );
      final read = expectLater(file.read(), completion('queued-fixture'));
      final opened = expectLater(
        open(),
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedWorkerFailureKind.busy,
          ),
        ),
      );
      try {
        expect(File(path).readAsStringSync(), 'before-fixture');
      } finally {
        release.complete();
        await scopeResult;
        await Future.wait([write, read, opened]);
      }
      expect(await (await open()).read(), 'queued-fixture');
      _expectBusy(profile);
    },
  );

  test(
    'a work failure preserves its error and restores ordinary file I/O',
    () async {
      final file = await open();
      final failure = _WorkFailed();
      await expectLater(
        ManagedProfilePreferencesFile.withProfileReleased(profile, () async {
          final owner = exclusive();
          try {
            throw failure;
          } finally {
            owner.close();
          }
        }),
        throwsA(same(failure)),
      );
      _expectBusy(profile);
      expect(await file.write('after-failed-work'), isTrue);
      final later = await open();
      expect(await later.read(), 'after-failed-work');
    },
  );

  test('close joins accepted work before releasing the actor', () async {
    final file = await open();
    final entered = Completer<void>(), release = Completer<void>();
    final scoped = ManagedProfilePreferencesFile.withProfileReleased(
      profile,
      () async {
        final owner = exclusive();
        try {
          entered.complete();
          await release.future;
        } finally {
          owner.close();
        }
      },
    );
    final result = expectLater(scoped, completes);
    await entered.future;
    final closing = file.close();
    release.complete();
    await result;
    await closing;
    final owner = exclusive();
    owner.close();
    await expectLater(file.read(), throwsStateError);
  });

  test(
    'a changed profile refuses restoration and old actors never recreate it',
    () async {
      final file = await open();
      expect(await file.write('preserved-fixture'), isTrue);
      final moved = '$profile.fixture-saved';
      await expectLater(
        ManagedProfilePreferencesFile.withProfileReleased(profile, () async {
          Directory(profile).renameSync(moved);
        }),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(Directory(profile).existsSync(), isFalse);
      await expectLater(
        file.write('must-not-write'),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      await expectLater(file.read(), throwsA(isA<ManagedWorkerFailure>()));
      expect(File(path).readAsStringSync(), 'preserved-fixture');
      expect(Directory(profile).existsSync(), isFalse);
      Directory(moved).renameSync(profile);
      await expectLater(file.read(), throwsA(isA<ManagedWorkerFailure>()));
    },
  );

  test('other profile actors remain held and usable', () async {
    await open();
    final otherBase = Directory('${directory.path}/other')..createSync();
    final other = await open('${otherBase.path}/xveil.prefs.json');
    await ManagedProfilePreferencesFile.withProfileReleased(profile, () async {
      final owner = exclusive();
      try {
        _expectBusy('${otherBase.path}/visible-storage');
        expect(await other.write('other-profile-fixture'), isTrue);
      } finally {
        owner.close();
      }
    });
    expect(await other.read(), 'other-profile-fixture');
  });

  test(
    'overlapping same-profile scopes refuse before entering more work',
    () async {
      final file = await open();
      var nested = false;
      await ManagedProfilePreferencesFile.withProfileReleased(
        profile,
        () async {
          await expectLater(
            ManagedProfilePreferencesFile.withProfileReleased(
              profile,
              () async {
                nested = true;
              },
            ),
            throwsA(
              isA<ManagedWorkerFailure>().having(
                (e) => e.kind,
                'kind',
                ManagedWorkerFailureKind.busy,
              ),
            ),
          );
          final owner = exclusive();
          owner.close();
        },
      );
      expect(nested, isFalse);
      expect(await file.write('after-overlap-refusal'), isTrue);
    },
  );
}
