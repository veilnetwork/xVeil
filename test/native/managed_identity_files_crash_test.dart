@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';

void main() {
  test(
    'encrypted identity creation resumes after SIGKILL around publication and catalog commit',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      const fs = ManagedFsPlatform();
      final root = Directory.systemTemp.createTempSync(
        'xveil-managed-identity-crash-',
      );
      final id = ManagedIdentityId('1' * 32);
      try {
        for (final phase in ['before', 'after', 'registered']) {
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
              'test/native/managed_identity_files_writer.dart',
              fixture.path,
              phase,
            ],
            environment: {
              'TMPDIR': Platform.isMacOS
                  ? '/private/tmp/'
                  : Directory.systemTemp.path,
            },
          );
          final output = StringBuffer();
          final stdoutDone = child.stdout
              .transform(utf8.decoder)
              .forEach(output.write);
          final stderrDone = child.stderr
              .transform(utf8.decoder)
              .forEach(output.write);
          int? status;
          final finished = child.exitCode.then((code) => status = code);
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
              if (status != null) fail('Writer exited at $phase: $output');
              if (watch.elapsed > const Duration(seconds: 45)) {
                fail('Writer did not reach $phase: $output');
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
            await killGroup();
            await finished;
            expect(status, -9);
          } finally {
            if (status == null) {
              await killGroup();
              await finished;
            }
            await stdoutDone;
            await stderrDone;
          }
          final owner = ManagedDirectoryCatalog.openExisting(profile)!;
          try {
            expect(
              owner.snapshot().catalog.identities.length,
              phase == 'registered' ? 1 : 0,
            );
            final resumed = ManagedIdentityFiles.resumeEncrypted(
              owner,
              id: id,
              password: Uint8List.fromList(
                utf8.encode('fixture-crash-password'),
              ),
            );
            final keys = resumed.exportKeys();
            try {
              expect(
                resumed.get(1, Uint8List.fromList([1])),
                Uint8List.fromList([4, 5, 6]),
              );
              expect(owner.snapshot().catalog.identities.single.id, id);
              expect(owner.snapshot().revision, 1);
            } finally {
              resumed.close();
            }
            final cold = ManagedIdentityFiles.openWithKeys(
              owner,
              id: id,
              keys: keys,
            );
            try {
              expect(
                cold.get(1, Uint8List.fromList([1])),
                Uint8List.fromList([4, 5, 6]),
              );
            } finally {
              cold.close();
              keys.fillRange(0, keys.length, 0);
            }
          } finally {
            owner.close();
          }
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
