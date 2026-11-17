@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_catalog_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

void main() {
  test(
    'catalog registration survives SIGKILL before and after native commit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xveil-catalog-crash-',
      );
      final initial = ManagedIdentityEntry(
        id: ManagedIdentityId('1' * 32),
        protection: StorageProtection.encrypted,
      );
      final next = ManagedIdentityEntry(
        id: ManagedIdentityId('2' * 32),
        protection: StorageProtection.unencrypted,
      );
      final seed = ManagedCatalogStore.initializeOwned(
        ManagedSqliteConnection.openUnencrypted(
          '${root.path}/seed',
          create: true,
        ),
      );
      try {
        seed.register(initial);
      } finally {
        seed.close();
      }
      try {
        for (final phase in ['before', 'after']) {
          final fixture = Directory('${root.path}/$phase')..createSync();
          File('${root.path}/seed').copySync('${fixture.path}/catalog');
          // The group contains only this owned Dart runner and its writer. Native
          // asset hooks may use an intermediate runner, so verify group ownership
          // rather than assuming the script's PID equals Process.pid.
          final child = await Process.start(
            'python3',
            [
              '-c',
              'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
              'dart',
              'run',
              'test/native/managed_catalog_writer.dart',
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
          final exit = child.exitCode.then((value) => status = value);
          Future<void> killGroup() async {
            final killed = await Process.run('python3', [
              '-c',
              'import os,signal,sys; '
                  'os.killpg(int(sys.argv[1]),signal.SIGKILL)',
              '${child.pid}',
            ]);
            expect(killed.exitCode, 0);
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
            expect(status, isNull);
            final owned = await Process.run('python3', [
              '-c',
              'import os,sys; print(os.getpgid(int(sys.argv[1])))',
              ready.first,
            ]);
            expect(owned.exitCode, 0);
            expect(owned.stdout.toString().trim(), '${child.pid}');
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
          final reopened = ManagedCatalogStore.openOwned(
            ManagedSqliteConnection.openUnencrypted('${fixture.path}/catalog'),
          );
          try {
            final state = reopened.snapshot();
            expect(state.revision, phase == 'before' ? 1 : 2);
            expect(state.catalog.identities.map((e) => e.id), [
              initial.id,
              if (phase == 'after') next.id,
            ]);
            // Retrying the response lost by the killed writer never adds a copy.
            expect(reopened.register(next).revision, 2);
            expect(reopened.snapshot().catalog.identities.map((e) => e.id), [
              initial.id,
              next.id,
            ]);
          } finally {
            reopened.close();
          }
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
