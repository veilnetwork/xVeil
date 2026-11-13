import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/storage_protection.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final stage = ManagedEraseStage.values.where((s) => s.name == args[1]).single;
  final mode = switch (args[2]) {
    'encrypted' => StorageProtection.encrypted,
    'unencrypted' => StorageProtection.unencrypted,
    _ => throw ArgumentError('unknown fixture mode'),
  };
  if (!fixture.startsWith('$temporary/xveil-managed-erase-crash-')) exit(3);
  final root = ManagedDirectoryCatalog.openExisting('$fixture/profile')!;
  await ManagedIdentityFiles.debugErase(
    root,
    entry: ManagedIdentityEntry(
      id: ManagedIdentityId('1' * 32),
      protection: mode,
    ),
    password: mode == StorageProtection.encrypted
        ? Uint8List.fromList(utf8.encode('fixture crash password'))
        : null,
    observer: (at) async {
      if (at != stage) return;
      File('$fixture/ready.pending')
        ..writeAsStringSync('$pid:${stage.name}', flush: true)
        ..renameSync('$fixture/ready');
      while (true) {
        sleep(const Duration(milliseconds: 50));
      }
    },
  );
  exit(4); // Every valid phase must pause before returning.
}
