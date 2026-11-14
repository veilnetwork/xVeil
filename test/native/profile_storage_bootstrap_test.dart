@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/storage_unlock_scope.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_bootstrap.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';

/// Publish after the hint computed false, before real native admission.
class _PublishAfterInspection extends ManagedFsPlatform {
  _PublishAfterInspection(this.coordinator);
  final String coordinator;
  int reads = 0, publications = 0;
  @override
  ManagedPathWitness inspect(String path) {
    final result = super.inspect(path);
    if (path == coordinator && ++reads == 2) {
      Directory('$coordinator/${ManagedRootErasure.pendingName}').createSync();
      publications++;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fs = ManagedFsPlatform();
  late Directory fixture;
  late String profile, coordinator;
  var factoryCalls = 0;
  final owners = <ProfileStorageRouterOwner>[];
  final erasures = <ManagedRootErasure>[];
  HiddenVolumeStorage legacy() {
    factoryCalls++;
    return HiddenVolumeStorage(
      ({required password, required create}) => FakeKvLogStore(),
    );
  }

  Map<String, String> contents() => {
    for (final f
        in fixture
            .listSync(recursive: true, followLinks: false)
            .whereType<File>())
      f.path: sha256.convert(f.readAsBytesSync()).toString(),
  };
  Future<void> prepare() async {
    final gate = StorageProfileCoordinator.createOrOpen(
      profile,
      exclusive: true,
    );
    try {
      await ManagedRootErasure.prepareAbsent(
        gate,
        unlockScopes: StorageUnlockScopes(['a' * 64]),
      );
    } finally {
      gate.close();
    }
  }

  Future<ManagedProfileBootstrap> boot({
    ManagedFsPlatform platform = fs,
  }) async {
    final result = await bootstrapManagedProfile(
      profileDirectory: profile,
      legacyFactory: legacy,
      inspectionFs: platform,
    );
    if (result.owner case final owner?) owners.add(owner);
    return result;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-profile-bootstrap-');
    profile = '${fixture.path}/profile';
    coordinator = '$profile/${StorageProfileCoordinator.directoryName}';
    expect(fs.createPrivateDirectory(profile), isTrue);
    factoryCalls = 0;
  });
  tearDown(() async {
    for (final owner in owners) {
      await owner.close();
    }
    for (final erasure in erasures) {
      erasure.close();
    }
    owners.clear();
    erasures.clear();
    fixture.deleteSync(recursive: true);
  });
  test('read-only hint creates no role, root or data facade', () {
    expect(StorageProfileCoordinator.hasErasureIntent(profile), isFalse);
    expect(Directory(profile).listSync(), isEmpty);
    expect(factoryCalls, 0);
  });
  for (final name in [
    ManagedRootErasure.pendingName,
    ManagedRootErasure.completionName,
  ]) {
    for (final kind in ['file', 'directory', 'dangling-link']) {
      test(
        'any $kind at $name preserves data and selects recovery',
        () async {
          StorageProfileCoordinator.createOrOpen(profile).close();
          final marker = '$coordinator/$name';
          switch (kind) {
            case 'file':
              File(marker).writeAsStringSync('synthetic malformed intent');
            case 'directory':
              Directory(marker).createSync();
            case 'dangling-link':
              Link(marker).createSync('${fixture.path}/absent-target');
          }
          final before = contents();
          final result = await boot();
          expect(result.erasurePending, isTrue);
          expect(result.owner, isNull);
          expect(factoryCalls, 0);
          expect(contents(), before);
          expect(
            FileSystemEntity.typeSync(marker, followLinks: false),
            isNot(FileSystemEntityType.notFound),
          );
          expect(Directory('$profile/identities').existsSync(), isFalse);
        },
        skip: Platform.isWindows && kind == 'dangling-link'
            ? 'POSIX symlink fixture'
            : false,
      );
    }
  }
  test(
    'real absent-root intent and terminal-only state both refuse ordinary startup',
    () async {
      await prepare();
      expect((await boot()).erasurePending, isTrue);
      final actor = ManagedRootErasure.openPending(profile);
      erasures.add(actor);
      await actor.removeManagedFiles(retireScopes: (_) async {});
      await expectLater(
        actor.finish(
          verifyOtherDataAbsent: () async {},
          afterStage: (stage) async {
            if (stage == ManagedErasureFinishStage.pendingRemoved) {
              throw StateError('synthetic terminal boundary');
            }
          },
        ),
        throwsStateError,
      );
      actor.close();
      expect(
        Directory(
          '$coordinator/${ManagedRootErasure.pendingName}',
        ).existsSync(),
        isFalse,
      );
      expect(
        File('$coordinator/${ManagedRootErasure.completionName}').existsSync(),
        isTrue,
      );
      final before = contents();
      expect((await boot()).erasurePending, isTrue);
      expect(contents(), before);
      expect(factoryCalls, 0);
    },
  );
  test(
    'actual finalization admits a fresh router without creating identities',
    () async {
      await prepare();
      final actor = ManagedRootErasure.openPending(profile);
      erasures.add(actor);
      await actor.removeManagedFiles(retireScopes: (_) async {});
      await actor.finish(verifyOtherDataAbsent: () async {});
      actor.releaseCompleted();
      final result = await boot();
      expect(result.erasurePending, isFalse);
      expect(result.owner, isNotNull);
      expect(factoryCalls, 1);
      expect(result.owner!.router.catalog.identities, isEmpty);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );
  test(
    'publication after a false hint is caught by real native admission',
    () async {
      StorageProfileCoordinator.createOrOpen(profile).close();
      final platform = _PublishAfterInspection(coordinator);
      final result = await boot(platform: platform);
      expect(platform.publications, 1);
      expect(result.erasurePending, isTrue);
      expect(result.owner, isNull);
      expect(factoryCalls, 0);
    },
  );
  test(
    'foreign coordinator link is refused rather than selecting a fake store',
    () async {
      final other = Directory('${fixture.path}/foreign')..createSync();
      File('${other.path}/keep').writeAsStringSync('synthetic unrelated data');
      Link(coordinator).createSync(other.path);
      final before = contents();
      await expectLater(boot(), throwsA(isA<ManagedFsFailure>()));
      expect(factoryCalls, 0);
      expect(contents(), before);
    },
    skip: Platform.isWindows ? 'POSIX symlink fixture' : false,
  );
}
