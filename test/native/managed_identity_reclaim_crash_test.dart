@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

Uint8List body(int seed) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(1024, (_) => random.nextInt(256)));
}

void main() {
  test(
    'SIGKILL across content and maintenance publication preserves keys, records and host anchors',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-managed-reclaim-crash-',
      );
      final id = ManagedIdentityId('1' * 32);
      const fs = ManagedFsPlatform();
      try {
        for (final cut in ManagedReclaimStage.values) {
          final location = Directory('${fixture.path}/${cut.name}')
            ..createSync();
          final profile = '${location.path}/profile';
          expect(fs.createPrivateDirectory(profile), isTrue);
          final originalRoot = ManagedDirectoryCatalog.createOrOpen(profile);
          final original = ManagedIdentityFiles.createEncrypted(
            originalRoot,
            id: id,
            password: Uint8List.fromList(
              utf8.encode('synthetic crash reclaim password'),
            ),
          );
          for (var i = 0; i < 40; i++) {
            original.commit([AppendLogOp(Ns.fileChunks, i % 4 + 1, body(i))]);
          }
          final seq = original.commitSeq(),
              hash = original.commitRoots()[original.commitSeq()]!;
          final keys = original.exportKeys();
          original.close();
          final keybox = File(
            originalRoot.layout.keyboxPath(id),
          ).readAsBytesSync();
          originalRoot.close();

          final child = await Process.start(
            'python3',
            [
              '-c',
              'import os,sys; os.setsid(); os.execvp(sys.argv[1],sys.argv[1:])',
              'dart',
              'run',
              'test/native/managed_identity_reclaim_writer.dart',
              location.path,
              cut.name,
            ],
            environment: {'TMPDIR': '/private/tmp/'},
          );
          final output = StringBuffer();
          final out = child.stdout
              .transform(utf8.decoder)
              .forEach(output.write);
          final err = child.stderr
              .transform(utf8.decoder)
              .forEach(output.write);
          int? status;
          final exit = child.exitCode.then((value) => status = value);
          Future<void> kill() async {
            final result = await Process.run('python3', [
              '-c',
              'import os,signal,sys; os.killpg(int(sys.argv[1]),signal.SIGKILL)',
              '${child.pid}',
            ]);
            expect(result.exitCode, 0);
          }

          try {
            final marker = File('${location.path}/ready');
            final watch = Stopwatch()..start();
            while (!marker.existsSync()) {
              if (status != null) {
                fail('writer exited before ${cut.name}: $output');
              }
              if (watch.elapsed > const Duration(seconds: 45)) {
                fail('writer missed ${cut.name}: $output');
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            final fields = marker.readAsStringSync().split(':');
            expect(fields.length, 2);
            expect(fields.last, cut.name);
            expect(status, isNull);
            final group = await Process.run('python3', [
              '-c',
              'import os,sys; print(os.getpgid(int(sys.argv[1])))',
              fields.first,
            ]);
            expect(group.exitCode, 0);
            expect(group.stdout.toString().trim(), '${child.pid}');
            final contender = ManagedDirectoryCatalog.openExisting(profile)!;
            try {
              expect(
                () => ManagedIdentityFiles.openWithKeys(
                  contender,
                  id: id,
                  keys: keys,
                ),
                throwsA(
                  isA<ManagedIdentityFailure>().having(
                    (e) => e.kind,
                    'kind',
                    ManagedIdentityFailureKind.busy,
                  ),
                ),
              );
            } finally {
              contender.close();
            }
            await kill();
            await exit;
            expect(status, -9);
          } finally {
            if (status == null) {
              await kill();
              await exit;
            }
            await out;
            await err;
          }
          final coldRoot = ManagedDirectoryCatalog.openExisting(profile)!;
          try {
            final cold = ManagedIdentityFiles.openWithKeys(
              coldRoot,
              id: id,
              keys: keys,
            );
            try {
              final expected =
                  seq +
                  ((cut == ManagedReclaimStage.contentDetached ||
                          cut == ManagedReclaimStage.contentPrepared)
                      ? 1
                      : 2);
              expect(cold.commitSeq(), expected);
              expect(cold.exportKeys(), keys);
              for (var i = 36; i < 40; i++) {
                expect(cold.readLog(Ns.fileChunks, i % 4 + 1), body(i));
              }
              expect(
                checkRollbackAnchor(
                  anchorSeq: seq,
                  anchorRoot: hash,
                  currentSeq: cold.commitSeq(),
                  history: cold.commitHistory(),
                  roots: cold.commitRoots(),
                ).verdict,
                AnchorVerdict.clean,
              );
              expect(
                cold.commit([
                  PutOp(1, Uint8List.fromList([8]), Uint8List.fromList([9])),
                ]),
                expected + 1,
              );
              expect(
                File(coldRoot.layout.keyboxPath(id)).readAsBytesSync(),
                keybox,
              );
            } finally {
              cold.close();
            }
          } finally {
            coldRoot.close();
            keys.fillRange(0, keys.length, 0);
          }
        }
      } finally {
        fixture.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
