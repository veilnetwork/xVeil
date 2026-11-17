@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/on_disk_blob_store.dart';
import 'package:xveil/domain/storage_protection.dart';

Future<void> _killAt(
  String fixture,
  ManagedEraseStage stage,
  StorageProtection mode,
) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      'test/native/managed_identity_erase_writer.dart',
      fixture,
      stage.name,
      mode.name,
    ],
    environment: {
      'TMPDIR': Platform.isMacOS ? '/private/tmp/' : Directory.systemTemp.path,
    },
  );
  final output = StringBuffer();
  final stdoutDone = child.stdout.transform(utf8.decoder).forEach(output.write);
  final stderrDone = child.stderr.transform(utf8.decoder).forEach(output.write);
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
    expect(ready.last, stage.name);
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
}

void main() {
  test(
    'SIGKILL at each deletion phase resumes without touching a sibling or legacy file',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      const fs = ManagedFsPlatform();
      final temporary = Directory.systemTemp.createTempSync(
        'xveil-managed-erase-crash-',
      );
      final id = ManagedIdentityId('1' * 32),
          sibling = ManagedIdentityId('2' * 32);
      final password = Uint8List.fromList(
        utf8.encode('fixture crash password'),
      );
      Map<String, String> snapshot(String path) => {
        for (final file in Directory(
          path,
        ).listSync(recursive: true).whereType<File>())
          file.path.substring(path.length): sha256
              .convert(file.readAsBytesSync())
              .toString(),
      };
      try {
        for (final mode in [
          StorageProtection.encrypted,
          StorageProtection.unencrypted,
        ]) {
          for (final stage in ManagedEraseStage.values) {
            final fixture = Directory(
              '${temporary.path}/${mode.name}-${stage.name}',
            )..createSync();
            final profile = '${fixture.path}/profile';
            expect(fs.createPrivateDirectory(profile), isTrue);
            final initial = ManagedDirectoryCatalog.createOrOpen(profile);
            final store = mode == StorageProtection.encrypted
                ? ManagedIdentityFiles.createEncrypted(
                    initial,
                    id: id,
                    password: password,
                  )
                : ManagedIdentityFiles.createUnencrypted(initial, id: id);
            store.commit([
              PutOp(1, Uint8List.fromList([1]), Uint8List.fromList([2])),
            ]);
            store.close();
            await OnDiskBlobStore(
              Directory(initial.layout.blobDirectory(id)),
            ).storePiece('AbcdEFgh_123-xy9', Uint8List(32), 0, Uint8List(100));
            final other = ManagedIdentityFiles.createUnencrypted(
              initial,
              id: sibling,
            );
            other.commit([
              PutOp(1, Uint8List.fromList([3]), Uint8List.fromList([4])),
            ]);
            other.close();
            final layout = initial.layout;
            final siblingBefore = snapshot(layout.directory(sibling));
            final legacy = File('$profile/legacy.hv')
              ..writeAsBytesSync(List.filled(700, 77));
            initial.close();
            await _killAt(fixture.path, stage, mode);
            final reopened = ManagedDirectoryCatalog.openExisting(profile)!;
            try {
              expect(
                reopened.snapshot().catalog.identities.any((e) => e.id == id),
                stage.index < ManagedEraseStage.catalogRemoved.index,
              );
              await ManagedIdentityFiles.erase(
                reopened,
                entry: ManagedIdentityEntry(id: id, protection: mode),
                password: mode == StorageProtection.encrypted ? password : null,
              );
              expect(Directory(layout.directory(id)).existsSync(), isFalse);
              expect(reopened.snapshot().catalog.identities.single.id, sibling);
              expect(snapshot(layout.directory(sibling)), siblingBefore);
              expect(legacy.readAsBytesSync(), List.filled(700, 77));
              final revision = reopened.snapshot().revision;
              await ManagedIdentityFiles.erase(
                reopened,
                entry: ManagedIdentityEntry(id: id, protection: mode),
              );
              expect(reopened.snapshot().revision, revision);
            } finally {
              reopened.close();
            }
          }
        }
      } finally {
        password.fillRange(0, password.length, 0);
        temporary.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isMacOS || Platform.isLinux),
  );
}
