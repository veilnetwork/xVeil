@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/storage_protection.dart';

Future<void> _killAt(String fixture, StorageProtection mode) async {
  final child = await Process.start(
    'python3',
    [
      '-c',
      'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])',
      'dart',
      'run',
      'test/native/managed_identity_erase_review_writer.dart',
      fixture,
      mode.name,
    ],
    environment: {'TMPDIR': '/private/tmp/'},
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
    expect(ready.last, 'unknownRemoved');
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
  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      '${mode.name}: SIGKILL during approved unknown removal requires fresh consent',
      () async {
        expect(ensureHiddenVolumeLoaded(), isTrue);
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-review-crash-',
        );
        final profile = '${fixture.path}/profile';
        const fs = ManagedFsPlatform();
        expect(fs.createPrivateDirectory(profile), isTrue);
        ManagedDirectoryCatalog? owner = ManagedDirectoryCatalog.createOrOpen(
          profile,
        );
        final id = ManagedIdentityId('1' * 32),
            sibling = ManagedIdentityId('2' * 32);
        final entry = ManagedIdentityEntry(id: id, protection: mode);
        Uint8List? keys;
        Map<String, String> snapshot(String path) => {
          for (final file in Directory(
            path,
          ).listSync(recursive: true, followLinks: false).whereType<File>())
            file.path.substring(path.length): sha256
                .convert(file.readAsBytesSync())
                .toString(),
        };
        try {
          final store = mode == StorageProtection.encrypted
              ? ManagedIdentityFiles.createEncrypted(
                  owner,
                  id: id,
                  password: Uint8List.fromList(
                    utf8.encode('fixture crash password'),
                  ),
                )
              : ManagedIdentityFiles.createUnencrypted(owner, id: id);
          keys = store.exportKeys();
          store.close();
          final other = ManagedIdentityFiles.createUnencrypted(
            owner,
            id: sibling,
          );
          other.close();
          final target = owner.layout.directory(id),
              otherPath = owner.layout.directory(sibling);
          final siblingBefore = snapshot(otherPath);
          final legacy = File('$profile/legacy.hv')
            ..writeAsStringSync('preserve fixture');
          for (var i = 0; i < 3; i++) {
            File('$target/unknown-$i').writeAsStringSync('orphan-$i');
          }
          owner.close();
          owner = null;
          await _killAt(fixture.path, mode);
          owner = ManagedDirectoryCatalog.openExisting(profile)!;
          final remaining = Directory(target)
              .listSync()
              .whereType<File>()
              .where((f) => f.uri.pathSegments.last.startsWith('unknown-'))
              .toList();
          expect(remaining, hasLength(2));
          expect(
            File(
              '$target/${mode == StorageProtection.encrypted ? 'keybox.hv' : 'data.store'}',
            ).existsSync(),
            isTrue,
          );
          final before = snapshot(target);
          await expectLater(
            ManagedIdentityFiles.erase(owner, entry: entry, keys: keys),
            throwsA(isA<ManagedIdentityFailure>()),
          );
          expect(snapshot(target), before);
          final fresh = await ManagedIdentityFiles.reviewErasure(
            owner,
            entry: entry,
            keys: keys,
          );
          expect(fresh.files, 2);
          await ManagedIdentityFiles.erase(
            owner,
            entry: entry,
            keys: keys,
            review: fresh,
          );
          expect(Directory(target).existsSync(), isFalse);
          expect(snapshot(otherPath), siblingBefore);
          expect(legacy.readAsStringSync(), 'preserve fixture');
        } finally {
          keys?.fillRange(0, keys.length, 0);
          owner?.close();
          fixture.deleteSync(recursive: true);
        }
      },
      skip: !(Platform.isMacOS || Platform.isLinux),
    );
  }
}
