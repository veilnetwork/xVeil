import 'dart:convert';
import 'dart:io';
import 'package:xveil/core/saved_entry_addresses.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';

Never mark(String fixture, String phase) {
  File('$fixture/ready.pending').writeAsStringSync('$pid:$phase', flush: true);
  File('$fixture/ready.pending').renameSync('$fixture/ready');
  while (true) {
    sleep(const Duration(milliseconds: 50));
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2 ||
      !['published', 'terminal', 'terminalPublished'].contains(args[1])) {
    exit(2);
  }
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  if (!fixture.startsWith(
    '${Directory.systemTemp.resolveSymbolicLinksSync()}/xveil-application-journal-crash-',
  )) {
    exit(3);
  }
  final phase = args[1];
  final actor = ManagedRootErasure.openPending('$fixture/profile');
  final records = SavedEntryAddresses(
    scopes: StorageUnlockScopes(['a' * 64, 'b' * 64]),
    protectedKeys: ['xveil.quick.v1.${'a' * 64}.bio.synthetic'],
  );
  actor.persistSavedEntryWitness(records.encode());
  if (phase == 'published') mark(fixture, phase);
  Future<void> retire() async {
    final file = File('$fixture/synthetic-os.json');
    final state = jsonDecode(file.readAsStringSync()) as Map;
    state.clear();
    file.writeAsStringSync(jsonEncode(state), flush: true);
  }

  await actor.removeManagedFiles(retireScopes: (_) => retire());
  await actor.removeAuxiliaryFiles(retireScopes: retire);
  await actor.finish(
    verifyOtherDataAbsent: () async {
      if ((jsonDecode(File('$fixture/synthetic-os.json').readAsStringSync())
              as Map)
          .isNotEmpty) {
        exit(4);
      }
    },
    afterStage: (stage) async {
      if (phase == 'terminalPublished' &&
          stage == ManagedErasureFinishStage.completionPublished) {
        mark(fixture, phase);
      }
    },
  );
  mark(fixture, phase); // Native plan/terminal gone; enclosing journal remains.
}
