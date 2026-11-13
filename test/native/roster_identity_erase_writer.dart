import 'dart:io';

import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/roster_identity_erase.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/pending_identity_erase.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

class _PauseMaster implements Storage {
  _PauseMaster(this.inner, this.mark);
  final Storage inner;
  final void Function(String) mark;
  @override
  Future<String?> getSetting(String key) => inner.getSetting(key);
  @override
  Future<void> putSetting(String key, String value) async {
    await inner.putSetting(key, value);
    if (key == kPendingIdentityErase) mark(value.isEmpty ? 'clear' : 'intent');
  }

  @override
  Future<List<RosterEntry>?> loadRoster() => inner.loadRoster();
  @override
  Future<void> saveRoster(List<RosterEntry> rows) async {
    await inner.saveRoster(rows);
    mark('roster');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused fixture port');
}

Future<void> main(List<String> args) async {
  if (args.length != 3) exit(2);
  final fixture = Directory(args[0]).resolveSymbolicLinksSync();
  final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
  final phase = args[1];
  final mode = switch (args[2]) {
    'encrypted' => StorageProtection.encrypted,
    'unencrypted' => StorageProtection.unencrypted,
    _ => throw ArgumentError('invalid fixture mode'),
  };
  if (!fixture.startsWith('$temporary/xveil-roster-erase-crash-') ||
      !['intent', 'child', 'roster', 'clear'].contains(phase)) {
    exit(3);
  }
  void mark(String at) {
    if (at != phase) return;
    File('$fixture/ready.pending')
      ..writeAsStringSync('$pid:$phase', flush: true)
      ..renameSync('$fixture/ready');
    while (true) {
      sleep(const Duration(milliseconds: 50));
    }
  }

  final profile = '$fixture/profile';
  final parent = ManagedIdentityStorage.existing(
    profileDirectory: profile,
    entry: ManagedIdentityEntry(
      id: ManagedIdentityId('9' * 32),
      protection: mode,
    ),
  );
  if (!await parent.storage.open(
    password: mode == StorageProtection.encrypted
        ? 'fixture parent password'
        : '',
  )) {
    exit(4);
  }
  final keys = await parent.storage.exportSpaceKeys();
  final roster = (await parent.storage.loadRoster())!;
  final catalog = ManagedDirectoryCatalog.openExisting(profile)!;
  await RosterIdentityErase.start(
    master: _PauseMaster(parent.storage, mark),
    root: parent.entry.locator,
    masterKeys: keys,
    roster: roster,
    target: roster.last,
    check: () {},
    retainRoster: (_) {},
    erase: (entry) async {
      await ManagedIdentityFiles.erase(
        catalog,
        entry: ManagedIdentityEntry.fromLocator(
          entry.storageLocator as ManagedStorageLocator,
        ),
        keys: entry.spaceKeys,
      );
      mark('child');
    },
  );
  exit(5); // A valid requested phase must have paused before returning.
}
