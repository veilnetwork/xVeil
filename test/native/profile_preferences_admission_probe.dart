import 'dart:convert';
import 'dart:io';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

void main(List<String> args) {
  if (args.length != 1) exit(2);
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final profile = Directory(args.single).resolveSymbolicLinksSync();
  if (!profile.startsWith(
        '$temporary${Platform.pathSeparator}xveil-prefs-startup-',
      ) ||
      Directory(profile).uri.pathSegments.where((p) => p.isNotEmpty).last !=
          'visible-storage') {
    exit(3);
  }
  try {
    final owner = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
    );
    if (owner == null) exit(4);
    owner.close();
    stdout.writeln(jsonEncode({'state': 'acquired'}));
  } on ManagedLeaseFailure catch (failure) {
    if (failure.kind != ManagedLeaseFailureKind.busy) exit(5);
    stdout.writeln(jsonEncode({'state': 'busy'}));
  } on ManagedSqliteFailure catch (failure) {
    if (failure.sqliteCode == null ||
        ![5, 6].contains(failure.sqliteCode! & 0xff)) {
      exit(6);
    }
    stdout.writeln(jsonEncode({'state': 'busy'}));
  }
}
