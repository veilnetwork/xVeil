import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || !ensureHiddenVolumeLoaded()) exit(2);
  final root = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  if (!root.startsWith('$temporary/xveil-managed-reclaim-crash-')) exit(3);
  final stage = ManagedReclaimStage.values.singleWhere(
    (s) => s.name == args[1],
  );
  final owner = ManagedDirectoryCatalog.openExisting('$root/profile')!;
  final store = ManagedIdentityFiles.openWithPassword(
    owner,
    id: ManagedIdentityId('1' * 32),
    password: Uint8List.fromList(
      utf8.encode('synthetic crash reclaim password'),
    ),
  );
  try {
    await store.debugReclaim((observed) async {
      if (observed != stage) return;
      final marker = File('$root/ready.pending');
      marker.writeAsStringSync('$pid:${stage.name}', flush: true);
      marker.renameSync('$root/ready');
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    throw StateError('requested reclaim stage was not observed');
  } finally {
    store.close();
    owner.close();
  }
}
