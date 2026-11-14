@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Future<void> _killErasureWriter(
  String fixture,
  String phase,
  void Function() beforeKill,
) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      'test/native/managed_root_erasure_writer.dart',
      fixture,
      phase,
    ],
    environment: {'TMPDIR': '/private/tmp/'},
  );
  final output = StringBuffer();
  final stdoutDone = child.stdout.transform(utf8.decoder).forEach(output.write);
  final stderrDone = child.stderr.transform(utf8.decoder).forEach(output.write);
  int? status;
  final exit = child.exitCode.then((value) => status = value);
  Future<void> killGroup() async {
    final killed = await Process.run('python3', [
      '-c',
      'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
      '${child.pid}',
    ]);
    expect(killed.exitCode, 0);
  }

  try {
    final marker = File('$fixture/ready');
    final watch = Stopwatch()..start();
    while (!marker.existsSync()) {
      if (status != null) fail('Writer exited before $phase: $output');
      if (watch.elapsed > const Duration(seconds: 45)) {
        fail('Writer did not reach $phase: $output');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final ready = marker.readAsStringSync().split(':');
    expect(ready.length, 2);
    expect(ready.last, phase);
    final group = await Process.run('python3', [
      '-c',
      'import os,sys; print(os.getpgid(int(sys.argv[1])))',
      ready.first,
    ]);
    expect(group.exitCode, 0);
    expect(group.stdout.toString().trim(), '${child.pid}');
    expect(status, isNull);
    beforeKill();
    await killGroup();
    await exit;
    expect(status, -9);
  } finally {
    if (status == null) {
      await killGroup();
      await exit;
    }
    await stdoutDone;
    await stderrDone;
  }
}

void main() {
  test(
    'SIGKILL at four intent/deletion boundaries permits exact managed-root recovery',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'xveil-root-erasure-crash-',
      );
      const fs = ManagedFsPlatform();
      try {
        for (final phase in [
          'beforeIntent',
          'afterIntent',
          'afterCatalog',
          'afterRoot',
        ]) {
          final fixture = Directory('${temporary.path}/$phase')..createSync();
          final profile = '${fixture.path}/profile';
          expect(fs.createPrivateDirectory(profile), isTrue);
          final owner = ManagedDirectoryCatalog.createOrOpen(profile);
          try {
            for (final id in ['1' * 32, '2' * 32]) {
              final store = ManagedIdentityFiles.createUnencrypted(
                owner,
                id: ManagedIdentityId(id),
              );
              try {
                store.commit([
                  PutOp(
                    1,
                    Uint8List.fromList([1]),
                    Uint8List.fromList([9, 8, 7]),
                  ),
                ]);
              } finally {
                store.close();
              }
            }
          } finally {
            owner.close();
          }
          final sentinel = File('$profile/legacy-fixture')
            ..writeAsStringSync('preserve');
          final before = {
            for (final f in Directory(
              '$profile/identities',
            ).listSync(recursive: true).whereType<File>())
              f.path: sha256.convert(f.readAsBytesSync()).toString(),
          };
          await _killErasureWriter(fixture.path, phase, () {});
          if (phase == 'beforeIntent') {
            final current = {
              for (final f in Directory(
                '$profile/identities',
              ).listSync(recursive: true).whereType<File>())
                f.path: sha256.convert(f.readAsBytesSync()).toString(),
            };
            expect(current, before);
            final ordinary = ManagedDirectoryCatalog.openExisting(profile)!;
            ordinary.close();
            expect(
              Directory(
                '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}',
              ).existsSync(),
              isFalse,
            );
            final retry = ManagedDirectoryCatalog.openExclusiveMaintenance(
              profile,
            )!;
            try {
              await ManagedRootErasure.prepare(retry);
            } finally {
              retry.close();
            }
          } else {
            expect(
              () => ManagedDirectoryCatalog.openExisting(profile),
              throwsA(
                isA<ManagedFsFailure>().having(
                  (e) => e.kind,
                  'kind',
                  ManagedFsFailureKind.erasurePending,
                ),
              ),
            );
            if (phase == 'afterCatalog') {
              expect(
                File('$profile/identities/catalog.sqlite3').existsSync(),
                isFalse,
              );
            }
            if (phase == 'afterRoot') {
              expect(Directory('$profile/identities').existsSync(), isFalse);
            }
          }
          final erasure = ManagedRootErasure.openPending(profile);
          var retired = 0;
          try {
            expect(erasure.catalog.identities.map((e) => e.id.value).toSet(), {
              '1' * 32,
              '2' * 32,
            });
            await erasure.removeManagedFiles(
              retireScopes: (catalog) async {
                expect(catalog.identities, hasLength(2));
                retired++;
              },
            );
          } finally {
            erasure.close();
          }
          expect(retired, 1);
          expect(Directory('$profile/identities').existsSync(), isFalse);
          expect(sentinel.readAsStringSync(), 'preserve');
          expect(
            File(
              '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}/plan.json',
            ).existsSync(),
            isTrue,
          );
        }
      } finally {
        temporary.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
