import 'dart:convert';
import 'dart:io';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) exit(2);
  final path = File(args.single).absolute.path;
  final temp = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!path.startsWith('$temp/xveil-profile-lease-') ||
      !path.endsWith('/identities/${ManagedProfileLease.fileName}')) {
    exit(3);
  }
  final profile = File(path).parent.parent.path;
  Object? held;
  void release() {
    if (held case final ManagedProfileLease lease) lease.close();
    if (held case final ManagedDirectoryCatalog root) root.close();
    held = null;
  }

  stdout.writeln('XVEIL_PROFILE_READY');
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final input = line.split(' ');
      if (input.length != 2 || int.tryParse(input[0]) == null) exit(4);
      final command = input[1];
      var result = 'invalid';
      try {
        if (command == 'close' || command == 'exit') {
          release();
          result = 'closed';
        } else if (held != null) {
          result = 'occupied';
        } else if (command == 'take-root') {
          held = ManagedDirectoryCatalog.openExisting(profile);
          result = held == null ? 'absent' : 'opened';
        } else if (command == 'take-exclusive') {
          held = ManagedDirectoryCatalog.openExclusiveMaintenance(profile);
          (held as ManagedDirectoryCatalog?)?.requireExclusiveMaintenance();
          result = held == null ? 'absent' : 'opened';
        } else if (command == 'take-shared') {
          held = ManagedProfileLease.openOwned(
            ManagedSqliteConnection.openUnencrypted(path),
          );
          result = 'opened';
        }
      } on ManagedLeaseFailure catch (e) {
        result = e.kind == ManagedLeaseFailureKind.busy ? 'busy' : 'invalid';
      } on ManagedSqliteFailure catch (e) {
        result = e.sqliteCode == 5 ? 'busy' : 'invalid';
      }
      stdout.writeln('XVEIL_PROFILE_LEASE:${input[0]}:$result');
      if (command == 'exit') return;
    }
  } finally {
    release();
  }
}
