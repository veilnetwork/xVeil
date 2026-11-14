import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';

void main() {
  late Directory fixture;
  late String profile;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-erasure-admission-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() => fixture.deleteSync(recursive: true));
  Matcher pending() => throwsA(
    isA<ManagedFsFailure>().having(
      (e) => e.kind.name,
      'kind',
      'erasurePending',
    ),
  );

  for (final markerName in ['erasure-pending', 'erasure-complete.json']) {
    for (final hasRoot in [false, true]) {
      test('$markerName refuses ordinary admission with root=$hasRoot', () {
        if (hasRoot) {
          ManagedDirectoryCatalog.createOrOpen(profile).close();
        } else {
          StorageProfileCoordinator.createOrOpen(profile).close();
        }
        final marker =
            '$profile/${StorageProfileCoordinator.directoryName}/$markerName';
        File(marker).writeAsBytesSync([1, 2, 3]);
        for (final open in <void Function()>[
          () {
            StorageProfileCoordinator.openExisting(profile)?.close();
          },
          () {
            StorageProfileCoordinator.createOrOpen(profile).close();
          },
          () {
            ManagedDirectoryCatalog.openExisting(profile)?.close();
          },
          () {
            ManagedDirectoryCatalog.openExclusiveMaintenance(profile)?.close();
          },
          () {
            ManagedDirectoryCatalog.createOrOpen(profile).close();
          },
        ]) {
          expect(open, pending());
        }
        expect(File(marker).readAsBytesSync(), [1, 2, 3]);
        expect(Directory('$profile/identities').existsSync(), hasRoot);
      });
    }

    test(
      'a linked $markerName refuses admission without reading outside bytes',
      () {
        StorageProfileCoordinator.createOrOpen(profile).close();
        final outside = File('${fixture.path}/outside')
          ..writeAsBytesSync([9, 8, 7]);
        Link(
          '$profile/${StorageProfileCoordinator.directoryName}/$markerName',
        ).createSync(outside.path);
        expect(
          () => StorageProfileCoordinator.createOrOpen(profile),
          pending(),
        );
        expect(() => ManagedDirectoryCatalog.openExisting(profile), pending());
        expect(outside.readAsBytesSync(), [9, 8, 7]);
      },
      skip: Platform.isWindows,
    );
  }
}
