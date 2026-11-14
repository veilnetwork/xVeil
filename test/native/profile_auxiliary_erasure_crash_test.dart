@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/domain/profile_model_layout.dart';
import '../support/erasure_writer_process.dart';

void main() {
  test(
    'SIGKILL during auxiliary deletion and terminal cleanup preserves exact recovery authority',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'xveil-aux-erasure-crash-',
      );
      try {
        for (final phase in [
          'afterPiece',
          'afterPreferences',
          'afterAuxiliary',
          'planRemoved',
          'completionRemoved',
        ]) {
          final fixture = Directory('${temporary.path}/$phase')..createSync();
          final profile = '${fixture.path}/visible-storage';
          expect(
            const ManagedFsPlatform().createPrivateDirectory(profile),
            isTrue,
          );
          StorageProfileCoordinator.createOrOpen(profile).close();
          for (final name in [
            'xveil.store',
            'xveil.prefs.json',
            'xveil.prefs.json.tmp',
            'os-credentials.fixture',
            'blobs/${'a' * 16}/p0',
            ProfileModelLayout.speechFile,
            'translate/ru-en/model.bin',
            'keep.txt',
          ]) {
            final f = File('${fixture.path}/$name');
            f.parent.createSync(recursive: true);
            f.writeAsStringSync('synthetic $name bytes');
          }
          final role = '$profile/${StorageProfileCoordinator.directoryName}';
          await killErasureWriter(
            fixture.path,
            phase,
            () {
              expect(
                File('${fixture.path}/os-credentials.fixture').existsSync(),
                isFalse,
              );
              expect(
                File('${fixture.path}/keep.txt').readAsStringSync(),
                'synthetic keep.txt bytes',
              );
              if (phase == 'afterPiece' || phase == 'afterPreferences') {
                expect(
                  File('${fixture.path}/xveil.store').existsSync(),
                  isTrue,
                );
                if (phase == 'afterPiece') {
                  expect(
                    File('${fixture.path}/blobs/${'a' * 16}/p0').existsSync(),
                    isFalse,
                  );
                }
              } else {
                expect(
                  File('${fixture.path}/xveil.store').existsSync(),
                  isFalse,
                );
              }
              if (phase == 'afterPreferences') {
                expect(
                  File('${fixture.path}/xveil.prefs.json').existsSync(),
                  isFalse,
                );
                expect(
                  File('${fixture.path}/xveil.prefs.json.tmp').existsSync(),
                  isTrue,
                );
              }
              if (phase == 'planRemoved') {
                expect(
                  File(
                    '$role/${ManagedRootErasure.pendingName}/plan.json',
                  ).existsSync(),
                  isFalse,
                );
                expect(
                  File(
                    '$role/${ManagedRootErasure.completionName}',
                  ).existsSync(),
                  isTrue,
                );
              }
            },
            script: 'test/native/profile_auxiliary_erasure_writer.dart',
          );
          if (phase == 'completionRemoved') {
            final gate = StorageProfileCoordinator.openExisting(
              profile,
              exclusive: true,
            )!;
            gate.close();
          } else {
            if (phase == 'planRemoved') {
              final fresh = File('${fixture.path}/xveil.prefs.json')
                ..writeAsStringSync('new, unowned data');
              expect(
                () => ManagedRootErasure.openPending(profile),
                throwsA(isA<ManagedFsFailure>()),
              );
              expect(fresh.readAsStringSync(), 'new, unowned data');
              fresh.deleteSync(); // Test-created replacement only.
            }
            final erasure = ManagedRootErasure.openPending(profile);
            try {
              if (erasure.phase == ManagedRootErasurePhase.removing) {
                await erasure.removeManagedFiles(
                  retireScopes: (_) async {
                    expect(
                      File(
                        '${fixture.path}/os-credentials.fixture',
                      ).existsSync(),
                      isFalse,
                    );
                  },
                );
                await erasure.removeAuxiliaryFiles(
                  retireScopes: () async {
                    expect(
                      File(
                        '${fixture.path}/os-credentials.fixture',
                      ).existsSync(),
                      isFalse,
                    );
                  },
                );
              }
              await erasure.finish(
                verifyOtherDataAbsent: () async {
                  expect(
                    File('${fixture.path}/os-credentials.fixture').existsSync(),
                    isFalse,
                  );
                },
              );
              erasure.releaseCompleted();
            } finally {
              erasure.close();
            }
          }
          for (final name in [
            'xveil.store',
            'xveil.prefs.json',
            'xveil.prefs.json.tmp',
            'blobs',
            ProfileModelLayout.speechFile,
            'translate',
          ]) {
            expect(
              FileSystemEntity.typeSync(
                '${fixture.path}/$name',
                followLinks: false,
              ),
              FileSystemEntityType.notFound,
            );
          }
          expect(
            File('${fixture.path}/keep.txt').readAsStringSync(),
            'synthetic keep.txt bytes',
          );
          expect(
            File('$role/${ManagedRootErasure.completionName}').existsSync(),
            isFalse,
          );
          expect(
            Directory('$role/${ManagedRootErasure.pendingName}').existsSync(),
            isFalse,
          );
          expect(
            FileSystemEntity.typeSync(
              '$profile/identities',
              followLinks: false,
            ),
            FileSystemEntityType.notFound,
          );
        }
      } finally {
        temporary.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'POSIX SIGKILL and process-group qualification'
        : false,
  );
}
