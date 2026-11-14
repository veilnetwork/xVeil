import 'dart:io';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

Never mark(String fixture, String phase) {
  File('$fixture/ready.pending')
    ..writeAsStringSync('$pid:$phase', flush: true)
    ..renameSync('$fixture/ready');
  while (true) {
    sleep(const Duration(milliseconds: 50));
  }
}

class _Cut extends ManagedFsPlatform {
  _Cut(this.fixture, this.phase);
  final String fixture, phase;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    if (destination.endsWith('/${ManagedRootErasure.pendingName}')) {
      if (phase == 'beforeIntent') mark(fixture, phase);
      final result = super.publishDirectoryNoReplace(source, destination);
      if (!result) exit(4);
      super.syncDirectory(Directory(destination).parent.path);
      if (phase == 'afterIntent') mark(fixture, phase);
      return result;
    }
    return super.publishDirectoryNoReplace(source, destination);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync(),
      phase = args[1];
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!fixture.startsWith('$temporary/xveil-root-erasure-crash-') ||
      ![
        'beforeIntent',
        'afterIntent',
        'afterCatalog',
        'afterRoot',
      ].contains(phase)) {
    exit(3);
  }
  final profile = '$fixture/profile';
  final root = ManagedDirectoryCatalog.openExclusiveMaintenance(
    profile,
    fs: _Cut(fixture, phase),
  )!;
  await ManagedRootErasure.prepare(
    root,
    unlockScopes: StorageUnlockScopes(['a' * 64, 'b' * 64]),
  );
  root.close();
  final erasure = ManagedRootErasure.openPending(profile);
  await erasure.removeManagedFiles(
    retireScopes: (catalog) async {
      if (catalog.identities.length != 2) exit(5);
      File(
        '$fixture/scopes-retired',
      ).writeAsStringSync('verified synthetic scopes', flush: true);
    },
    afterUnlink: (path) async {
      if (phase == 'afterCatalog' && path == 'identities/catalog.sqlite3' ||
          phase == 'afterRoot' && path == 'identities') {
        mark(fixture, phase);
      }
    },
  );
  erasure.close();
  exit(6); // Every requested barrier must be reached, never silent success.
}
