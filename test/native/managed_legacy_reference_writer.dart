import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/domain/storage_locator.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || !ensureHiddenVolumeLoaded()) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!fixture.startsWith('$temporary/xveil-external-references-') ||
      ![
        'prepared',
        'published',
        'worker-prepared',
        'worker-published',
      ].contains(args[1])) {
    exit(3);
  }
  final body =
      jsonDecode(File('$fixture/capabilities-private.json').readAsStringSync())
          as Map<String, dynamic>;
  final keys = <ManagedIdentityId, Uint8List>{
    for (final entry in (body['masters'] as Map<String, dynamic>).entries)
      ManagedIdentityId(entry.key): base64.decode(entry.value as String),
  };
  final old = <String, Uint8List>{
    for (final entry in (body['legacy'] as Map<String, dynamic>).entries)
      entry.key: base64.decode(entry.value as String),
  };
  final owner = ManagedDirectoryCatalog.openExclusiveMaintenance(
    '$fixture/visible-storage',
  )!;
  Future<void> waitForKill() async {
    final stage = File('$fixture/ready.pending');
    stage.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': args[1]}),
      flush: true,
    );
    stage.renameSync('$fixture/ready');
    // A real event source keeps the VM alive at this owned crash boundary.
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> repair(String staged) async {
    final changes = <LegacyCompactionKeyChange>[];
    try {
      for (final entry in old.entries) {
        final space = hv.HvSpace.open(
          path: staged,
          password: Uint8List.fromList(utf8.encode(entry.key)),
        );
        try {
          changes.add((
            before: Uint8List.fromList(entry.value),
            after: space.spaceKeys(),
          ));
        } finally {
          space.close();
        }
      }
      await ManagedLegacyReferenceRepair.prepare(
        owner: owner,
        authorizations: keys,
        changes: changes,
      );
      if (args[1].endsWith('prepared')) await waitForKill();
    } finally {
      for (final change in changes) {
        change.before.fillRange(0, change.before.length, 0);
        change.after.fillRange(0, change.after.length, 0);
      }
    }
  }

  final credentials = [
    for (final password in old.keys) Uint8List.fromList(utf8.encode(password)),
  ];
  try {
    if (args[1].startsWith('worker-')) {
      final plan = hv.HvPreparedCompaction.prepare(
        '$fixture/xveil.store',
        credentials,
      );
      try {
        await repair(plan.stagedPath);
        plan.commit();
      } finally {
        plan.close();
      }
    } else {
      await hv.compactKnownPreparedAsync(
        '$fixture/xveil.store',
        credentials,
        dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
        repairMetadata: repair,
      );
    }
    await waitForKill();
  } finally {
    for (final password in credentials) {
      password.fillRange(0, password.length, 0);
    }
    owner.close();
    for (final key in keys.values) {
      key.fillRange(0, key.length, 0);
    }
    for (final key in old.values) {
      key.fillRange(0, key.length, 0);
    }
  }
}
