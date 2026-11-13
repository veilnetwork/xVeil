import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

class _Pause extends ManagedFsPlatform {
  _Pause(this.fixture, this.phase);
  final String fixture;
  final String phase;
  bool armed = false;
  Never mark() {
    File('$fixture/ready.pending')
      ..writeAsStringSync('$pid:$phase', flush: true)
      ..renameSync('$fixture/ready');
    while (true) {
      sleep(const Duration(milliseconds: 50));
    }
  }

  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    final identity = RegExp(r'[0-9a-f]{32}$').hasMatch(destination);
    if (identity && phase == 'before') mark();
    final result = super.publishDirectoryNoReplace(source, destination);
    if (identity && phase == 'after') {
      if (!result) exit(4);
      super.syncDirectory(Directory(destination).parent.path);
      mark();
    }
    return result;
  }

  @override
  ManagedPathWitness inspect(String path) {
    final result = super.inspect(path);
    if (armed && phase == 'registered' && path.endsWith('catalog.sqlite3')) {
      final probe = ManagedSqliteConnection.openUnencrypted(path);
      var ready = false;
      try {
        final payload =
            probe.use(
                  (db) => db
                      .select('SELECT payload FROM managed_catalog')
                      .single['payload'],
                )
                as String;
        ready = ManagedIdentityCatalog.decode(payload).identities.isNotEmpty;
      } finally {
        probe.close();
      }
      if (ready) mark();
    }
    return result;
  }
}

void main(List<String> args) {
  if (args.length != 2) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final phase = args[1];
  if (!fixture.startsWith('$temporary/xveil-managed-identity-crash-') ||
      !['before', 'after', 'registered'].contains(phase)) {
    exit(3);
  }
  final pause = _Pause(fixture, phase);
  final owner = ManagedDirectoryCatalog.createOrOpen(
    '$fixture/profile',
    fs: pause,
  );
  pause.armed = true;
  ManagedIdentityFiles.createEncrypted(
    owner,
    id: ManagedIdentityId('1' * 32),
    password: Uint8List.fromList(utf8.encode('fixture-crash-password')),
    initial: [
      PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([4, 5, 6])),
    ],
  );
  exit(5); // Every allowed phase must pause before the operation returns.
}
