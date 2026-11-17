@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/storage_locator.dart';

import 'mixed_identity_session_crash_writer.dart' as fixture;

void main() {
  test(
    'ACKed concurrent ingress survives process death in all three storage modes',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final root = Directory.systemTemp.createTempSync(
        'xveil-mixed-session-crash-',
      );
      final child = await Process.start(
        'python3',
        [
          '-c',
          'import os,sys; os.setsid(); os.execvp(sys.argv[1],sys.argv[1:])',
          'flutter',
          'test',
          '--no-pub',
          '--concurrency=1',
          '--reporter=expanded',
          'test/native/mixed_identity_session_crash_writer.dart',
        ],
        environment: {
          'TMPDIR': Platform.isMacOS
              ? '/private/tmp/'
              : Directory.systemTemp.path,
          'XVEIL_MIXED_CRASH_FIXTURE': root.path,
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
        final killed = await Process.run('python3', [
          '-c',
          'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
          '${child.pid}',
        ]);
        expect(killed.exitCode, 0);
      }

      Future<void> awaitGroupExit() async {
        // Reaping the launcher is not evidence that its tester/native workers
        // have exited. Wait for the actual process group to disappear before
        // attempting the first cold open; no arbitrary unlock retry or sleep.
        final release = Stopwatch()..start();
        while (true) {
          final gone = await Process.run('python3', [
            '-c',
            'import os,sys\n'
                'try: os.killpg(int(sys.argv[1]),0)\n'
                'except ProcessLookupError: sys.exit(0)\n'
                'sys.exit(1)',
            '${child.pid}',
          ]);
          if (gone.exitCode == 0) break;
          expect(gone.exitCode, 1);
          if (release.elapsed > const Duration(seconds: 15)) {
            fail('Killed fixture process group remains live');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      try {
        final ready = File('${root.path}/ready');
        final watch = Stopwatch()..start();
        while (!ready.existsSync()) {
          if (status != null) {
            fail('Writer exited before ACK checkpoint: $output');
          }
          if (watch.elapsed > const Duration(seconds: 70)) {
            fail('Writer missed ACK checkpoint: $output');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(status, isNull);
        final proof = jsonDecode(ready.readAsStringSync()) as Map;
        final group = await Process.run('python3', [
          '-c',
          'import os,sys; print(os.getpgid(int(sys.argv[1])))',
          '${proof['pid']}',
        ]);
        expect(group.exitCode, 0);
        expect(group.stdout.toString().trim(), '${child.pid}');
        final expectedIds = List.generate(
          fixture.messageCount,
          (i) => 'fixture-$i',
        )..sort();
        expect(proof['acks'], {
          for (final label in ['hidden', 'encrypted', 'unencrypted'])
            label: expectedIds,
        });
        await killGroup();
        await finished;
        expect(status, -9);
        await stdoutDone;
        await stderrDone;
        await awaitGroupExit();

        final profile = '${root.path}/profile';
        final path = '$profile/legacy.hv';
        HiddenVolumeStorage hidden() => HiddenVolumeStorage(
          hvSpaceOpener(
            path,
            argon: hv.ArgonPreset.min,
            paddingPreset: hv.PaddingPreset.none,
          ),
          keysOpener: hvKeysSpaceOpener(path),
        );
        final master = hidden();
        try {
          expect(await master.open(password: fixture.masterPassword), isTrue);
          final rows = await master.loadRosterForMaintenance();
          expect(rows, hasLength(3));
          await master.close();
          try {
            expect(rows!.map((r) => r.label), [
              'hidden',
              'encrypted',
              'unencrypted',
            ]);
            for (final row in rows) {
              final Storage storage = switch (row.storageLocator) {
                ManagedStorageLocator locator =>
                  ManagedIdentityStorage.existing(
                    profileDirectory: profile,
                    entry: ManagedIdentityEntry.fromLocator(locator),
                  ).storage,
                LegacyStorageLocator() => hidden(),
              };
              try {
                expect(await storage.openWithKeys(row.spaceKeys), isTrue);
                expect((await storage.loadProfile())!.displayName, row.label);
                final messages = await storage.loadMessages(
                  fixture.fixtureNode(7).hex,
                );
                expect(messages, hasLength(fixture.messageCount));
                expect(
                  {for (final m in messages) m.id: m.body},
                  {
                    for (var i = 0; i < fixture.messageCount; i++)
                      'fixture-$i': 'for ${row.label} $i',
                  },
                );
                await storage.putSetting('after-crash', row.label);
                await storage.close();
                expect(await storage.openWithKeys(row.spaceKeys), isTrue);
                expect(await storage.getSetting('after-crash'), row.label);
              } finally {
                await storage.close();
              }
            }
          } finally {
            for (final row in rows ?? []) {
              row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
            }
          }
        } finally {
          await master.close();
        }
      } finally {
        if (status == null) {
          await killGroup();
          await finished;
        }
        await stdoutDone;
        await stderrDone;
        await awaitGroupExit();
        root.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
