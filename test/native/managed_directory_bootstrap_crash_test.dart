@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

bool _busy(Object? e) =>
    e is ManagedLeaseFailure && e.kind == ManagedLeaseFailureKind.busy ||
    e is ManagedSqliteFailure && e.sqliteCode == 5;
String _name(FileSystemEntity e) => File(e.path).uri.pathSegments.last;

Future<void> _killPausedWriter(
  String fixture,
  String phase,
  String scope,
  void Function() beforeKill,
) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      'test/native/managed_directory_bootstrap_writer.dart',
      fixture,
      phase,
      scope,
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
      if (status != null) fail('Writer exited before $scope/$phase: $output');
      if (watch.elapsed > const Duration(seconds: 45)) {
        fail('Writer did not reach $scope/$phase: $output');
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
  for (final scope in ['identities', StorageProfileCoordinator.directoryName]) {
    test(
      'SIGKILL before/after $scope publication preserves complete roles and ownership',
      () async {
        const fs = ManagedFsPlatform();
        final temporary = Directory.systemTemp.createTempSync(
          'xveil-managed-bootstrap-',
        );
        try {
          for (final phase in ['before', 'after']) {
            final fixture = Directory('${temporary.path}/$phase')..createSync();
            final profile = '${fixture.path}/profile';
            expect(fs.createPrivateDirectory(profile), isTrue);
            await _killPausedWriter(fixture.path, phase, scope, () {
              if (scope == 'identities') {
                // A creator owns parent admission even before identities exists.
                expect(
                  () => StorageProfileCoordinator.openExisting(
                    profile,
                    exclusive: true,
                  ),
                  throwsA(predicate(_busy)),
                );
              }
            });
            final published = Directory('$profile/$scope');
            final entries = Directory(profile).listSync();
            if (phase == 'before') {
              expect(published.existsSync(), isFalse);
              final pending = entries.singleWhere(
                (e) => RegExp(
                  '^\\.$scope-[0-9a-f]{32}\\.pending\$',
                ).hasMatch(_name(e)),
              );
              final before = {
                for (final file in Directory(
                  pending.path,
                ).listSync().whereType<File>())
                  _name(file): file.readAsBytesSync(),
              };
              expect(
                before.keys.toSet(),
                scope == 'identities'
                    ? {'catalog.sqlite3', 'profile.meta', 'profile.meta.lock'}
                    : {'profile.meta', 'profile.meta.lock'},
              );
              if (scope == 'identities') {
                expect(ManagedDirectoryCatalog.openExisting(profile), isNull);
                final next = ManagedDirectoryCatalog.createOrOpen(profile);
                try {
                  expect(next.snapshot().revision, 0);
                  expect(next.snapshot().catalog.identities, isEmpty);
                } finally {
                  next.close();
                }
              } else {
                expect(StorageProfileCoordinator.openExisting(profile), isNull);
                expect(Directory('$profile/identities').existsSync(), isFalse);
                StorageProfileCoordinator.createOrOpen(profile).close();
              }
              for (final entry in before.entries) {
                expect(
                  File('${pending.path}/${entry.key}').readAsBytesSync(),
                  entry.value,
                );
              }
              expect(Directory(profile).listSync().map(_name).toSet(), {
                _name(pending),
                StorageProfileCoordinator.directoryName,
                if (scope == 'identities') 'identities',
              });
            } else {
              expect(published.existsSync(), isTrue);
              if (scope == 'identities') {
                final existing = ManagedDirectoryCatalog.openExisting(profile)!;
                try {
                  expect(existing.snapshot().revision, 0);
                  expect(existing.snapshot().catalog.identities, isEmpty);
                } finally {
                  existing.close();
                }
              } else {
                expect(Directory('$profile/identities').existsSync(), isFalse);
              }
              expect(Directory(profile).listSync().map(_name).toSet(), {
                StorageProfileCoordinator.directoryName,
                if (scope == 'identities') 'identities',
              });
            }
            final gate = StorageProfileCoordinator.openExisting(
              profile,
              exclusive: true,
            )!;
            try {
              gate.requireHeld(exclusive: true);
            } finally {
              gate.close();
            }
          }
        } finally {
          temporary.deleteSync(recursive: true);
        }
      },
      skip: !(Platform.isMacOS || Platform.isLinux),
    );
  }
}
