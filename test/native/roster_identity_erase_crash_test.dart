@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/roster_identity_erase.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/pending_identity_erase.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

Future<void> _killAt(
  String fixture,
  String phase,
  StorageProtection mode,
) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      'test/native/roster_identity_erase_writer.dart',
      fixture,
      phase,
      mode.name,
    ],
    environment: {'TMPDIR': '/private/tmp/'},
  );
  final output = StringBuffer();
  final stdoutDone = child.stdout.transform(utf8.decoder).forEach(output.write);
  final stderrDone = child.stderr.transform(utf8.decoder).forEach(output.write);
  int? status;
  final finished = child.exitCode.then((code) => status = code);
  Future<void> kill() async {
    final result = await Process.run('python3', [
      '-c',
      'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
      '${child.pid}',
    ]);
    expect(result.exitCode, 0);
  }

  try {
    final marker = File('$fixture/ready');
    final watch = Stopwatch()..start();
    while (!marker.existsSync()) {
      if (status != null) fail('Writer exited: $output');
      if (watch.elapsed > const Duration(seconds: 45)) {
        fail('Writer did not reach stage: $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final ready = marker.readAsStringSync().split(':');
    expect(ready.length, 2);
    expect(ready.last, phase);
    expect(status, isNull);
    final group = await Process.run('python3', [
      '-c',
      'import os,sys; print(os.getpgid(int(sys.argv[1])))',
      ready.first,
    ]);
    expect(group.exitCode, 0);
    expect(group.stdout.toString().trim(), '${child.pid}');
    await kill();
    await finished;
    expect(status, -9);
  } finally {
    if (status == null) {
      await kill();
      await finished;
    }
    await stdoutDone;
    await stderrDone;
  }
}

void main() {
  test(
    'real parent journal resumes after SIGKILL at each durable boundary',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final temporary = Directory.systemTemp.createTempSync(
        'xveil-roster-erase-crash-',
      );
      try {
        for (final mode in [
          StorageProtection.encrypted,
          StorageProtection.unencrypted,
        ]) {
          for (final phase in ['intent', 'child', 'roster', 'clear']) {
            final fixture = Directory('${temporary.path}/${mode.name}-$phase')
              ..createSync();
            final profile = '${fixture.path}/profile';
            expect(
              const ManagedFsPlatform().createPrivateDirectory(profile),
              isTrue,
            );
            final parentEntry = ManagedIdentityEntry(
              id: ManagedIdentityId('9' * 32),
              protection: mode,
            );
            final childEntry = ManagedIdentityEntry(
              id: ManagedIdentityId('2' * 32),
              protection: StorageProtection.encrypted,
            );
            final survivorEntry = ManagedIdentityEntry(
              id: ManagedIdentityId('1' * 32),
              protection: StorageProtection.unencrypted,
            );
            final password = mode == StorageProtection.encrypted
                ? 'fixture parent password'
                : '';
            final parent = ManagedIdentityStorage.forCreation(
              profileDirectory: profile,
              entry: parentEntry,
            );
            final child = ManagedIdentityStorage.forCreation(
              profileDirectory: profile,
              entry: childEntry,
            );
            final survivor = ManagedIdentityStorage.forCreation(
              profileDirectory: profile,
              entry: survivorEntry,
            );
            final ownedKeys = <Uint8List>[];
            try {
              final entries = <RosterEntry>[];
              for (final (host, label, secret) in [
                (survivor, 'keep', ''),
                (child, 'remove', 'fixture child password'),
              ]) {
                expect(
                  await host.storage.open(
                    password: secret,
                    createIfMissing: true,
                  ),
                  isTrue,
                );
                await host.storage.saveProfile(UserProfile(displayName: label));
                await host.storage.putSetting('fixture', label);
                final keys = await host.storage.exportSpaceKeys();
                ownedKeys.add(keys);
                entries.add(
                  RosterEntry(
                    label: label,
                    spaceKeys: keys,
                    storageLocator: host.entry.locator,
                  ),
                );
                await host.storage.close();
              }
              expect(
                await parent.storage.open(
                  password: password,
                  createIfMissing: true,
                ),
                isTrue,
              );
              await parent.storage.saveRoster(entries);
              await parent.storage.putSetting('parent-fixture', 'preserved');
              await parent.storage.close();
              await _killAt(fixture.path, phase, mode);
              final cold = ManagedIdentityStorage.existing(
                profileDirectory: profile,
                entry: parentEntry,
              );
              try {
                expect(await cold.storage.open(password: password), isTrue);
                final rootKeys = await cold.storage.exportSpaceKeys();
                ownedKeys.add(rootKeys);
                final roster = (await cold.storage.loadRoster())!;
                ownedKeys.addAll(roster.map((e) => e.spaceKeys));
                expect(
                  roster.length,
                  ['roster', 'clear'].contains(phase) ? 1 : 2,
                );
                final catalog = ManagedDirectoryCatalog.openExisting(profile)!;
                try {
                  final result = await RosterIdentityErase.resume(
                    master: cold.storage,
                    root: parentEntry.locator,
                    masterKeys: rootKeys,
                    roster: roster,
                    check: () {},
                    retainRoster: (rows) =>
                        ownedKeys.addAll(rows.map((e) => e.spaceKeys)),
                    erase: (entry) => ManagedIdentityFiles.erase(
                      catalog,
                      entry: ManagedIdentityEntry.fromLocator(
                        entry.storageLocator as ManagedStorageLocator,
                      ),
                      keys: entry.spaceKeys,
                    ),
                  );
                  expect(result.single.label, 'keep');
                  expect(
                    await cold.storage.getSetting(kPendingIdentityErase),
                    '',
                  );
                  expect(
                    await cold.storage.getSetting('parent-fixture'),
                    'preserved',
                  );
                  expect(
                    Directory(
                      catalog.layout.directory(childEntry.id),
                    ).existsSync(),
                    isFalse,
                  );
                } finally {
                  catalog.close();
                }
              } finally {
                await cold.storage.close();
              }
              expect(await survivor.storage.open(password: ''), isTrue);
              expect(await survivor.storage.getSetting('fixture'), 'keep');
            } finally {
              await parent.storage.close();
              await child.storage.close();
              await survivor.storage.close();
              for (final key in ownedKeys) {
                key.fillRange(0, key.length, 0);
              }
            }
          }
        }
      } finally {
        temporary.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
