@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

void main() {
  test(
    'SIGKILL cannot publish a managed root with an uninitialized catalog',
    () async {
      const fs = ManagedFsPlatform();
      final root = await Directory.systemTemp.createTemp(
        'xveil-managed-bootstrap-',
      );
      try {
        for (final phase in ['before', 'after']) {
          final fixture = Directory('${root.path}/$phase')..createSync();
          final profile = '${fixture.path}/profile';
          expect(fs.createPrivateDirectory(profile), isTrue);
          final child = await Process.start(
            'python3',
            [
              '-c',
              'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
              'dart',
              'run',
              'test/native/managed_directory_bootstrap_writer.dart',
              fixture.path,
              phase,
            ],
            environment: {'TMPDIR': '/private/tmp/'},
          );
          final output = StringBuffer();
          final stdoutDone = child.stdout
              .transform(utf8.decoder)
              .forEach(output.write);
          final stderrDone = child.stderr
              .transform(utf8.decoder)
              .forEach(output.write);
          int? status;
          final exit = child.exitCode.then((value) => status = value);
          Future<void> killGroup() async {
            final result = await Process.run('python3', [
              '-c',
              'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
              '${child.pid}',
            ]);
            expect(result.exitCode, 0);
          }

          try {
            final marker = File('${fixture.path}/ready');
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
          final existing = ManagedDirectoryCatalog.openExisting(profile);
          if (phase == 'before') {
            expect(existing, isNull);
            final pending = Directory(profile).listSync().single;
            expect(pending, isA<Directory>());
            final previous = File(
              '${pending.path}/catalog.sqlite3',
            ).readAsBytesSync();
            final next = ManagedDirectoryCatalog.createOrOpen(profile);
            try {
              expect(next.snapshot().revision, 0);
              expect(next.snapshot().catalog.identities, isEmpty);
              expect(
                File('${pending.path}/catalog.sqlite3').readAsBytesSync(),
                previous,
              );
              expect(Directory(profile).listSync().length, 2);
            } finally {
              next.close();
            }
          } else {
            expect(existing, isNotNull);
            try {
              expect(existing!.snapshot().revision, 0);
              expect(existing.snapshot().catalog.identities, isEmpty);
            } finally {
              existing?.close();
            }
            expect(Directory(profile).listSync().length, 1);
          }
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
