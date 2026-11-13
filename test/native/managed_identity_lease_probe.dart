import 'dart:io';

import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

void main(List<String> args) {
  if (args.length != 2) exit(2);
  final path = File(args.first).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!path.startsWith('$temporary/xveil-identity-lease-process-') &&
      !path.startsWith('$temporary/xveil-managed-files-native-')) {
    exit(3);
  }
  final protection = switch (args[1]) {
    'encrypted' => StorageProtection.encrypted,
    'unencrypted' => StorageProtection.unencrypted,
    _ => throw StateError('Invalid fixture mode'),
  };
  try {
    final lease = ManagedIdentityLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(path),
      expected: ManagedIdentityEntry(
        id: ManagedIdentityId('1' * 32),
        protection: protection,
      ),
    );
    lease.requireHeld();
    lease.close();
    stdout.writeln('XVEIL_LEASE_RESULT:opened');
  } on ManagedSqliteFailure catch (error) {
    if (error.sqliteCode != 5) exit(4);
    stdout.writeln('XVEIL_LEASE_RESULT:busy');
  } on ManagedLeaseFailure catch (error) {
    if (error.kind != ManagedLeaseFailureKind.busy) exit(6);
    stdout.writeln('XVEIL_LEASE_RESULT:busy');
  }
}
