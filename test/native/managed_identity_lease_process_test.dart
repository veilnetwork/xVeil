@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

import 'support/managed_lease_process_probe.dart';

void main() {
  test(
    'failed local connections do not release the lease to another process',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'xveil-identity-lease-process-',
      );
      final path = '${root.path}/identity';
      final entry = ManagedIdentityEntry(
        id: ManagedIdentityId('1' * 32),
        protection: StorageProtection.encrypted,
      );
      final owner = ManagedIdentityLease.initializeOwned(
        ManagedSqliteConnection.openUnencrypted(path, create: true),
        entry: entry,
      );
      try {
        expect(await probeManagedIdentityLease(path), 'busy');
        // Closing an unrelated raw POSIX fd could release per-process fcntl
        // locks. SQLite's packaged VFS must instead defer its failed contender
        // closes while this owner's lock remains held.
        for (var i = 0; i < 3; i++) {
          expect(
            () => ManagedIdentityLease.openOwned(
              ManagedSqliteConnection.openUnencrypted(path),
              expected: entry,
            ),
            throwsA(isA<ManagedSqliteFailure>()),
          );
        }
        owner.requireHeld();
        expect(await probeManagedIdentityLease(path), 'busy');
        // An independent same-process file reader must not silently remove
        // ownership of the identity, even when it does not use SQLite's VFS.
        File(path).openSync().closeSync();
        expect(await probeManagedIdentityLease(path), 'busy');
        File('$path.lock').openSync().closeSync();
        expect(await probeManagedIdentityLease(path), 'busy');
        owner.close();
        expect(await probeManagedIdentityLease(path), 'opened');
      } finally {
        owner.close();
        root.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
