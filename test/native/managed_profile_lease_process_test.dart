@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';
import 'support/profile_lease_process.dart';

String attempt(String path) {
  try {
    final lease = ManagedProfileLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(path),
      exclusive: true,
    );
    lease.close();
    return 'opened';
  } on ManagedLeaseFailure catch (e) {
    if (e.kind == ManagedLeaseFailureKind.busy) return 'busy';
    rethrow;
  } on ManagedSqliteFailure catch (e) {
    if (e.sqliteCode == 5) return 'busy';
    rethrow;
  }
}

void main() {
  late Directory temp;
  late String profile, role;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('xveil-profile-lease-');
    profile = '${temp.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    ManagedDirectoryCatalog.createOrOpen(profile).close();
    role = '$profile/identities/${ManagedProfileLease.fileName}';
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'independent processes retain shared/exclusive ownership despite unrelated fd closes',
    () async {
      final child = await ProfileLeaseProcess.start(role);
      try {
        expect(await child.ask('take-shared'), 'opened');
        expect(attempt(role), 'busy');
        for (var i = 0; i < 3; i++) {
          File(role).openSync().closeSync();
          File('$role.lock').openSync().closeSync();
          expect(attempt(role), 'busy');
        }
        expect(await child.ask('close'), 'closed');
        final exclusive = ManagedProfileLease.openOwned(
          ManagedSqliteConnection.openUnencrypted(role),
          exclusive: true,
        );
        try {
          expect(await child.ask('take-root'), 'busy');
          File(role).openSync().closeSync();
          File('$role.lock').openSync().closeSync();
          expect(await child.ask('take-shared'), 'busy');
          exclusive.requireHeld(exclusive: true);
        } finally {
          exclusive.close();
        }
        expect(await child.ask('take-root'), 'opened');
        expect(attempt(role), 'busy');
        expect(await child.ask('close'), 'closed');
        expect(attempt(role), 'opened');
      } finally {
        await child.dispose();
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );

  for (final mode in ['take-root', 'take-exclusive']) {
    test(
      'SIGKILL of $mode releases its native profile lease',
      () async {
        final child = await ProfileLeaseProcess.start(role);
        try {
          expect(await child.ask(mode), 'opened');
          expect(attempt(role), 'busy');
          await child.kill();
          expect(attempt(role), 'opened');
        } finally {
          await child.dispose();
        }
      },
      skip: !(Platform.isMacOS || Platform.isLinux),
    );
  }

  for (final protection in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      '${protection.name} data worker retains the profile lease until confirmed close',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final root = ManagedDirectoryCatalog.openExisting(profile)!;
        final id = ManagedIdentityId('a' * 32);
        final password = Uint8List.fromList(
          'synthetic profile lease password'.codeUnits,
        );
        try {
          final data = protection == StorageProtection.encrypted
              ? ManagedIdentityFiles.createEncrypted(
                  root,
                  id: id,
                  password: password,
                )
              : ManagedIdentityFiles.createUnencrypted(root, id: id);
          data.close();
        } finally {
          root.close();
        }
        final worker = protection == StorageProtection.encrypted
            ? await ManagedWorkerIdentity.openEncrypted(
                profileDirectory: profile,
                id: id,
                password: password,
              )
            : await ManagedWorkerIdentity.openUnencrypted(
                profileDirectory: profile,
                id: id,
              );
        try {
          expect(attempt(role), 'busy');
        } finally {
          await worker.close();
          password.fillRange(0, password.length, 0);
        }
        expect(attempt(role), 'opened');
        final catalog = await ManagedCatalogWorker.open(profile);
        try {
          expect(attempt(role), 'busy');
        } finally {
          await catalog.close();
        }
        expect(attempt(role), 'opened');
      },
    );
  }
}
