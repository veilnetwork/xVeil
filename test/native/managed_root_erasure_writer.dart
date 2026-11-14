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
  String get selected =>
      phase.startsWith('absent-') ? phase.substring(7) : phase;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    if (destination.endsWith('/${ManagedRootErasure.pendingName}')) {
      if (selected == 'beforeIntent') mark(fixture, phase);
      final result = super.publishDirectoryNoReplace(source, destination);
      if (!result) exit(4);
      super.syncDirectory(Directory(destination).parent.path);
      if (selected == 'afterIntent') mark(fixture, phase);
      return result;
    }
    return super.publishDirectoryNoReplace(source, destination);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync(),
      requested = args[1];
  final absent = requested.startsWith('absent-');
  final phase = absent ? requested.substring(7) : requested;
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!fixture.startsWith('$temporary/xveil-root-erasure-crash-') ||
      ![
        'beforeIntent',
        'afterIntent',
        if (absent) 'afterRetirement' else ...['afterCatalog', 'afterRoot'],
        ...ManagedErasureFinishStage.values.map((stage) => stage.name),
      ].contains(phase)) {
    exit(3);
  }
  final profile = '$fixture/profile';
  if (absent) {
    final owner = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
      fs: _Cut(fixture, requested),
    )!;
    await ManagedRootErasure.prepareAbsent(
      owner,
      unlockScopes: StorageUnlockScopes(['a' * 64]),
    );
    owner.close();
  } else {
    final root = ManagedDirectoryCatalog.openExclusiveMaintenance(
      profile,
      fs: _Cut(fixture, requested),
    )!;
    await ManagedRootErasure.prepare(
      root,
      unlockScopes: StorageUnlockScopes(['a' * 64, 'b' * 64]),
    );
    root.close();
  }
  final erasure = ManagedRootErasure.openPending(profile);
  await erasure.removeManagedFiles(
    retireScopes: (catalog) async {
      if (catalog.identities.length != (absent ? 0 : 2)) exit(5);
      File(
        '$fixture/scopes-retired',
      ).writeAsStringSync('verified synthetic scopes', flush: true);
    },
    afterUnlink: (path) async {
      if (phase == 'afterCatalog' && path == 'identities/catalog.sqlite3' ||
          phase == 'afterRoot' && path == 'identities') {
        mark(fixture, requested);
      }
    },
  );
  if (absent && phase == 'afterRetirement') mark(fixture, requested);
  if (ManagedErasureFinishStage.values.any((stage) => stage.name == phase)) {
    await erasure.finish(
      verifyOtherDataAbsent: () async {
        if (absent) File('$profile/legacy-fixture').deleteSync();
        File('$fixture/other-verified').writeAsStringSync(
          'verified synthetic enclosing obligations',
          flush: true,
        );
      },
      afterStage: (stage) async {
        if (stage.name == phase) mark(fixture, requested);
      },
    );
  }
  erasure.close();
  exit(6); // Every requested barrier must be reached, never silent success.
}
