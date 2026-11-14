import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

bool busy(Object? error) =>
    error is ManagedLeaseFailure &&
        error.kind == ManagedLeaseFailureKind.busy ||
    error is ManagedSqliteFailure && error.sqliteCode == 5;

class _BeforeParentPublish extends ManagedFsPlatform {
  _BeforeParentPublish(this.action);
  final void Function(String source) action;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    if (destination.endsWith('/${StorageProfileCoordinator.directoryName}')) {
      action(source);
    }
    return super.publishDirectoryNoReplace(source, destination);
  }
}

class _AfterParentPublish extends ManagedFsPlatform {
  bool published = false;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    final result = super.publishDirectoryNoReplace(source, destination);
    if (destination.endsWith('/${StorageProfileCoordinator.directoryName}')) {
      published = result;
    }
    return result;
  }

  @override
  void syncDirectory(String path) {
    if (published) throw const ManagedFsFailure(ManagedFsFailureKind.io);
    super.syncDirectory(path);
  }
}

void main() {
  late Directory fixture;
  late String profile;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-storage-coordinator-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  test('exclusive profile admission refuses a creator before root staging', () {
    final gate = StorageProfileCoordinator.createOrOpen(
      profile,
      exclusive: true,
    );
    ManagedDirectoryCatalog? unexpected;
    Object? refusal;
    try {
      try {
        unexpected = ManagedDirectoryCatalog.createOrOpen(profile);
      } catch (error) {
        refusal = error;
      }
      expect(
        busy(refusal),
        isTrue,
        reason:
            'root creation needs profile admission before its first path mutation',
      );
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(
        Directory(
          profile,
        ).listSync().map((e) => File(e.path).uri.pathSegments.last),
        [StorageProfileCoordinator.directoryName],
      );
      gate.requireHeld(exclusive: true);
    } finally {
      unexpected?.close();
      gate.close();
    }
  });

  test('a published root retains shared profile admission through close', () {
    StorageProfileCoordinator.createOrOpen(profile).close();
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    StorageProfileCoordinator? unexpected;
    Object? refusal;
    try {
      try {
        unexpected = StorageProfileCoordinator.openExisting(
          profile,
          exclusive: true,
        );
      } catch (error) {
        refusal = error;
      }
      expect(
        busy(refusal),
        isTrue,
        reason: 'a live root must exclude destructive profile admission',
      );
    } finally {
      unexpected?.close();
      root.close();
    }
    final granted = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
    )!;
    granted.requireHeld(exclusive: true);
    granted.close();
  });

  test('read-only probes create neither coordination nor a managed root', () {
    expect(StorageProfileCoordinator.openExisting(profile), isNull);
    expect(ManagedDirectoryCatalog.openExisting(profile), isNull);
    expect(Directory(profile).listSync(), isEmpty);
  });

  test('all shared grants must close before exclusive admission', () {
    final first = StorageProfileCoordinator.createOrOpen(profile);
    final second = StorageProfileCoordinator.createOrOpen(profile);
    try {
      expect(
        () => first.requireHeld(exclusive: true),
        throwsA(isA<ManagedLeaseFailure>()),
      );
      expect(
        () => StorageProfileCoordinator.openExisting(profile, exclusive: true),
        throwsA(predicate(busy)),
      );
      first.close();
      expect(
        () => StorageProfileCoordinator.openExisting(profile, exclusive: true),
        throwsA(predicate(busy)),
      );
      second.requireHeld();
    } finally {
      first.close();
      second.close();
    }
    final exclusive = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
    )!;
    try {
      exclusive.requireHeld(exclusive: true);
      expect(
        () => StorageProfileCoordinator.openExisting(profile),
        throwsA(predicate(busy)),
      );
    } finally {
      exclusive.close();
    }
    expect(() => exclusive.requireHeld(), throwsA(isA<ManagedLeaseFailure>()));
  });

  test('exclusive admission survives removal of the test-owned empty root', () {
    final root = ManagedDirectoryCatalog.createOrOpen(profile)..close();
    final gate = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
    )!;
    final role = File('${gate.directory}/${ManagedProfileLease.fileName}');
    final previous = role.readAsBytesSync();
    try {
      // Only this private synthetic fixture is removed, with no live owners.
      Directory(root.directory).deleteSync(recursive: true);
      gate.requireHeld(exclusive: true);
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(profile),
        throwsA(predicate(busy)),
      );
      expect(Directory(root.directory).existsSync(), isFalse);
      expect(role.readAsBytesSync(), previous);
    } finally {
      gate.close();
    }
    final fresh = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      expect(fresh.snapshot().revision, 0);
      expect(role.readAsBytesSync(), previous);
    } finally {
      fresh.close();
    }
  });

  test(
    'a losing profile bootstrap refuses adoption and leaves winner intact',
    () {
      List<int>? winnerBytes;
      final platform = _BeforeParentPublish((_) {
        final winner = StorageProfileCoordinator.createOrOpen(profile);
        try {
          winnerBytes = File(
            '${winner.directory}/${ManagedProfileLease.fileName}',
          ).readAsBytesSync();
        } finally {
          winner.close();
        }
      });
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(profile, fs: platform),
        throwsA(predicate(busy)),
      );
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(
        Directory(
          profile,
        ).listSync().map((e) => File(e.path).uri.pathSegments.last),
        [StorageProfileCoordinator.directoryName],
      );
      final retained = StorageProfileCoordinator.openExisting(profile)!;
      try {
        expect(
          File(
            '${retained.directory}/${ManagedProfileLease.fileName}',
          ).readAsBytesSync(),
          winnerBytes,
        );
      } finally {
        retained.close();
      }
    },
  );

  test('pre-publication failure removes only the exact owned parent stage', () {
    final sentinel = File('$profile/sentinel')..writeAsBytesSync([1, 2, 3]);
    expect(
      () => StorageProfileCoordinator.createOrOpen(
        profile,
        fs: _BeforeParentPublish((_) {
          throw const ManagedFsFailure(ManagedFsFailureKind.io);
        }),
      ),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(Directory(profile).listSync().map((e) => e.path), [sentinel.path]);
    expect(sentinel.readAsBytesSync(), [1, 2, 3]);
  });

  test('post-publication failure leaves a complete readable constant role', () {
    expect(
      () => StorageProfileCoordinator.createOrOpen(
        profile,
        fs: _AfterParentPublish(),
      ),
      throwsA(isA<ManagedFsFailure>()),
    );
    final gate = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
    )!;
    try {
      gate.requireHeld(exclusive: true);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    } finally {
      gate.close();
    }
  });

  test('replaced or populated staging paths are retained instead of swept', () {
    String? stage;
    expect(
      () => StorageProfileCoordinator.createOrOpen(
        profile,
        fs: _BeforeParentPublish((source) {
          stage = source;
          Directory(source).renameSync('$source-retained');
          const ManagedFsPlatform().createPrivateDirectory(source);
          File('$source/sentinel').writeAsBytesSync([4, 5, 6]);
          throw const ManagedFsFailure(ManagedFsFailureKind.io);
        }),
      ),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(File('$stage/sentinel').readAsBytesSync(), [4, 5, 6]);
    expect(
      File('$stage-retained/${ManagedProfileLease.fileName}').existsSync(),
      isTrue,
    );
    expect(
      Directory(
        '$profile/${StorageProfileCoordinator.directoryName}',
      ).existsSync(),
      isFalse,
    );
  });

  test('unknown pending parent bootstrap is neither adopted nor swept', () {
    final pending =
        '$profile/.${StorageProfileCoordinator.directoryName}-${'a' * 32}.pending';
    const ManagedFsPlatform().createPrivateDirectory(pending);
    final marker = File('$pending/sentinel')..writeAsBytesSync([7, 8, 9]);
    final gate = StorageProfileCoordinator.createOrOpen(profile);
    try {
      gate.requireHeld();
      expect(marker.readAsBytesSync(), [7, 8, 9]);
    } finally {
      gate.close();
    }
  });

  test('parent and root roles cannot be interchanged or relabelled', () {
    final root = ManagedDirectoryCatalog.createOrOpen(profile)..close();
    final parent = File(
      '$profile/${StorageProfileCoordinator.directoryName}/${ManagedProfileLease.fileName}',
    );
    final inner = File('${root.directory}/${ManagedProfileLease.fileName}');
    final parentBytes = parent.readAsBytesSync();
    final innerBytes = inner.readAsBytesSync();
    expect(parentBytes, isNot(innerBytes));
    parent.writeAsBytesSync(innerBytes, flush: true);
    expect(
      () => StorageProfileCoordinator.createOrOpen(profile),
      throwsA(isA<ManagedLeaseFailure>()),
    );
    expect(parent.readAsBytesSync(), innerBytes);
    parent.writeAsBytesSync(parentBytes, flush: true);
    inner.writeAsBytesSync(parentBytes, flush: true);
    expect(
      () => ManagedDirectoryCatalog.createOrOpen(profile),
      throwsA(isA<ManagedLeaseFailure>()),
    );
    expect(inner.readAsBytesSync(), parentBytes);
    final gate = StorageProfileCoordinator.openExisting(
      profile,
      exclusive: true,
    )!;
    gate.close();
  });

  test('constant role stores no catalog, locators, keys or credentials', () {
    final gate = StorageProfileCoordinator.createOrOpen(profile);
    try {
      expect(
        Directory(
          gate.directory,
        ).listSync().map((e) => File(e.path).uri.pathSegments.last).toSet(),
        {'profile.meta', 'profile.meta.lock'},
      );
      final connection = ManagedSqliteConnection.openUnencrypted(
        '${gate.directory}/profile.meta',
      );
      try {
        final role = connection.use(
          (db) => db.select('SELECT id,role FROM profile_role').single,
        );
        expect(role, {'id': 1, 'role': 'xveil-storage-lifetime-v1'});
      } finally {
        connection.close();
      }
      gate.requireHeld();
    } finally {
      gate.close();
    }
  });

  test('a replaced parent invalidates an already open managed root', () {
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      Directory(
        '$profile/${StorageProfileCoordinator.directoryName}',
      ).renameSync('$profile/retained-lifetime');
      StorageProfileCoordinator.createOrOpen(profile).close();
      expect(
        () => root.snapshot(),
        throwsA(
          isA<ManagedFsFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedFsFailureKind.changed,
          ),
        ),
      );
    } finally {
      root.close();
    }
  });

  test(
    'parent role links and SQLite sidecar links never touch outside bytes',
    () {
      final gate = StorageProfileCoordinator.createOrOpen(profile)..close();
      final role = '${gate.directory}/${ManagedProfileLease.fileName}';
      final outside = File('${fixture.path}/outside')
        ..writeAsBytesSync([9, 1, 9]);
      for (final suffix in ['-journal', '-wal', '-shm']) {
        final link = Link('$role$suffix')..createSync(outside.path);
        try {
          expect(
            () => StorageProfileCoordinator.openExisting(profile),
            throwsA(isA<ManagedFsFailure>()),
          );
          expect(outside.readAsBytesSync(), [9, 1, 9]);
        } finally {
          link.deleteSync();
        }
      }
      final previous = File(role).readAsBytesSync();
      File(role).renameSync('${fixture.path}/saved-role');
      Link(role).createSync('${fixture.path}/saved-role');
      expect(
        () => StorageProfileCoordinator.openExisting(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(File('${fixture.path}/saved-role').readAsBytesSync(), previous);
    },
    skip: Platform.isWindows,
  );

  test(
    'nonempty permanent lock is refused without truncating its contents',
    () {
      final gate = StorageProfileCoordinator.createOrOpen(profile)..close();
      final lock = File(
        '${gate.directory}/${ManagedProfileLease.fileName}.lock',
      )..writeAsBytesSync([8, 8]);
      expect(
        () => StorageProfileCoordinator.createOrOpen(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(lock.readAsBytesSync(), [8, 8]);
    },
  );
}
