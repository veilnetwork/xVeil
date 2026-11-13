import 'dart:io';

import 'package:xveil/data/storage/managed_catalog_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

Never _wait() {
  while (true) {
    sleep(const Duration(milliseconds: 50));
  }
}

void main(List<String> args) {
  if (args.length != 2) exit(2);
  final root = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final phase = args[1];
  if (!root.startsWith('$temporary/xveil-catalog-crash-') ||
      !['before', 'after'].contains(phase)) {
    exit(3);
  }
  void mark() {
    File('$root/ready.pending')
      ..writeAsStringSync('$pid:$phase', flush: true)
      ..renameSync('$root/ready');
  }

  final connection = ManagedSqliteConnection.openUnencrypted('$root/catalog');
  final store = ManagedCatalogStore.openOwned(connection);
  if (phase == 'before') {
    connection.use(
      (db) => db.commitFilter = () {
        mark();
        _wait();
      },
    );
  }
  store.register(
    ManagedIdentityEntry(
      id: ManagedIdentityId('2' * 32),
      protection: StorageProtection.unencrypted,
    ),
  );
  mark();
  _wait();
}
