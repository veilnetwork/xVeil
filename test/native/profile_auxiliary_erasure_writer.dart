import 'dart:io';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';

Never mark(String fixture, String phase) {
  File('$fixture/ready.pending')
    ..writeAsStringSync('$pid:$phase', flush: true)
    ..renameSync('$fixture/ready');
  while (true) {
    sleep(const Duration(milliseconds: 50));
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync(),
      phase = args[1];
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!fixture.startsWith('$temporary/xveil-aux-erasure-crash-') ||
      ![
        'afterPiece',
        'afterPreferences',
        'afterAuxiliary',
        'planRemoved',
        'completionRemoved',
      ].contains(phase)) {
    exit(3);
  }
  final profile = '$fixture/visible-storage';
  final gate = StorageProfileCoordinator.openExisting(
    profile,
    exclusive: true,
  )!;
  await ManagedRootErasure.prepareAbsent(
    gate,
    unlockScopes: StorageUnlockScopes(['a' * 64]),
    auxiliary: ProfileErasureAuxiliaryTargets(
      legacyPath: '$fixture/xveil.store',
    ),
  );
  gate.close();
  final erasure = ManagedRootErasure.openPending(profile);
  Future<void> retire() async {
    final record = File('$fixture/os-credentials.fixture');
    if (record.existsSync()) record.deleteSync();
    if (record.existsSync()) exit(5);
  }

  await erasure.removeManagedFiles(retireScopes: (_) => retire());
  await erasure.removeAuxiliaryFiles(
    retireScopes: retire,
    afterUnlink: (path) async {
      if (phase == 'afterPiece' && path.endsWith('/p0')) mark(fixture, phase);
      if (phase == 'afterPreferences' && path == 'xveil.prefs.json') {
        mark(fixture, phase);
      }
    },
  );
  if (phase == 'afterAuxiliary') mark(fixture, phase);
  await erasure.finish(
    verifyOtherDataAbsent: () async {
      if (File('$fixture/os-credentials.fixture').existsSync()) exit(6);
    },
    afterStage: (stage) async {
      if (stage.name == phase) mark(fixture, phase);
    },
  );
  erasure.close();
  exit(7); // Every requested barrier must be observed, never silent success.
}
