@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'support/profile_lease_process.dart';

bool _busy(Object? e) =>
    e is ManagedLeaseFailure && e.kind == ManagedLeaseFailureKind.busy ||
    e is ManagedSqliteFailure && e.sqliteCode == 5;

void main() {
  late Directory fixture;
  late String profile, role;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-profile-lease-');
    profile = '${fixture.path}/profile';
    role = '$profile/identities/${ManagedProfileLease.fileName}';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test(
    'independent exclusive admission blocks first root creation with no root present',
    () async {
      final child = await ProfileLeaseProcess.start(role);
      try {
        expect(await child.ask('take-profile-exclusive'), 'opened');
        expect(
          () => ManagedDirectoryCatalog.createOrOpen(profile),
          throwsA(predicate(_busy)),
        );
        expect(Directory('$profile/identities').existsSync(), isFalse);
        expect(await child.ask('close'), 'closed');
        final root = ManagedDirectoryCatalog.createOrOpen(profile);
        try {
          expect(root.snapshot().revision, 0);
        } finally {
          root.close();
        }
      } finally {
        await child.dispose();
      }
    },
  );

  test(
    'all independent shared owners must close before profile exclusion',
    () async {
      final gate = StorageProfileCoordinator.createOrOpen(profile);
      final child = await ProfileLeaseProcess.start(role);
      try {
        expect(await child.ask('take-profile-shared'), 'opened');
        gate.close();
        expect(
          () =>
              StorageProfileCoordinator.openExisting(profile, exclusive: true),
          throwsA(predicate(_busy)),
        );
        // Closing unrelated file descriptors must not release the child's flock.
        final path =
            '$profile/${StorageProfileCoordinator.directoryName}/${ManagedProfileLease.fileName}';
        File(path).openSync().closeSync();
        File('$path.lock').openSync().closeSync();
        expect(
          () =>
              StorageProfileCoordinator.openExisting(profile, exclusive: true),
          throwsA(predicate(_busy)),
        );
        expect(await child.ask('close'), 'closed');
        final exclusive = StorageProfileCoordinator.openExisting(
          profile,
          exclusive: true,
        )!;
        try {
          exclusive.requireHeld(exclusive: true);
          expect(await child.ask('create-root'), 'busy');
          expect(Directory('$profile/identities').existsSync(), isFalse);
        } finally {
          exclusive.close();
        }
        expect(await child.ask('create-root'), 'opened');
      } finally {
        gate.close();
        await child.dispose();
      }
    },
  );

  for (final mode in [
    'take-profile-shared',
    'take-profile-exclusive',
    'create-root',
  ]) {
    test(
      'SIGKILL releases $mode ownership without replacing permanent role',
      () async {
        final child = await ProfileLeaseProcess.start(role);
        try {
          expect(await child.ask(mode), 'opened');
          final path =
              '$profile/${StorageProfileCoordinator.directoryName}/${ManagedProfileLease.fileName}';
          final before = File(path).readAsBytesSync();
          expect(
            () => StorageProfileCoordinator.openExisting(
              profile,
              exclusive: true,
            ),
            throwsA(predicate(_busy)),
          );
          await child.kill();
          final exclusive = StorageProfileCoordinator.openExisting(
            profile,
            exclusive: true,
          )!;
          try {
            exclusive.requireHeld(exclusive: true);
            expect(File(path).readAsBytesSync(), before);
          } finally {
            exclusive.close();
          }
        } finally {
          await child.dispose();
        }
      },
    );
  }

  test(
    'an absent-root catalog worker retains profile admission until confirmed close',
    () async {
      final child = await ProfileLeaseProcess.start(role);
      final worker = await ManagedCatalogWorker.open(profile);
      try {
        final snapshot = await worker.snapshot();
        expect(snapshot.exists, isFalse);
        expect(snapshot.snapshot.catalog.identities, isEmpty);
        expect(Directory('$profile/identities').existsSync(), isFalse);
        expect(await child.ask('take-profile-exclusive'), 'busy');
        await worker.close();
        expect(await child.ask('take-profile-exclusive'), 'opened');
        expect(Directory('$profile/identities').existsSync(), isFalse);
      } finally {
        await worker.close();
        await child.dispose();
      }
    },
  );
}
