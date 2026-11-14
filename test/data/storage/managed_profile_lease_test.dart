import 'dart:io';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

bool busy(Object e) =>
    e is ManagedLeaseFailure && e.kind == ManagedLeaseFailureKind.busy ||
    e is ManagedSqliteFailure && e.sqliteCode == 5;
String attempt(String path, bool exclusive) {
  try {
    final lease = ManagedProfileLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(path),
      exclusive: exclusive,
    );
    lease.close();
    return 'opened';
  } catch (e) {
    if (busy(e)) return 'busy';
    rethrow;
  }
}

Future<String> isolatedAttempt(String path, bool exclusive) =>
    Isolate.run(() => attempt(path, exclusive));

void main() {
  const fs = ManagedFsPlatform();
  late Directory temp;
  late String profile, role;
  final live = <ManagedProfileLease>[];
  final roots = <ManagedDirectoryCatalog>[];
  ManagedDirectoryCatalog create() {
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    roots.add(root);
    return root;
  }

  ManagedProfileLease open({bool exclusive = false}) {
    final lease = ManagedProfileLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(role),
      exclusive: exclusive,
    );
    live.add(lease);
    return lease;
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xveil-profile-lease-');
    profile = '${temp.path}/profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
    role = '$profile/identities/${ManagedProfileLease.fileName}';
  });
  tearDown(() {
    for (final lease in live.reversed) {
      lease.close();
    }
    for (final root in roots.reversed) {
      root.close();
    }
    live.clear();
    roots.clear();
    temp.deleteSync(recursive: true);
  });

  test(
    'bootstrap publishes immutable public profile role with no identity data',
    () {
      final root = create();
      root.close();
      final before = File(role).readAsBytesSync();
      final read = ManagedSqliteConnection.openUnencrypted(role);
      try {
        expect(
          read.use((db) => db.select('SELECT * FROM profile_role').single),
          {'id': 1, 'role': 'xveil-managed-profile-v1'},
        );
      } finally {
        read.close();
      }
      final shared = open();
      shared.requireHeld();
      expect(
        () => shared.requireHeld(exclusive: true),
        throwsA(isA<ManagedLeaseFailure>()),
      );
      shared.close();
      final exclusive = open(exclusive: true);
      exclusive.requireHeld(exclusive: true);
      exclusive.close();
      exclusive.close();
      expect(File(role).readAsBytesSync(), before);
      expect(File('$role.lock').readAsBytesSync(), isEmpty);
    },
  );

  test(
    'all shared owners must close before exclusive admission, including another isolate',
    () async {
      create().close();
      final first = open(), second = open();
      expect(await isolatedAttempt(role, false), 'opened');
      expect(await isolatedAttempt(role, true), 'busy');
      first.close();
      expect(attempt(role, true), 'busy');
      second.close();
      final exclusive = open(exclusive: true);
      expect(await isolatedAttempt(role, false), 'busy');
      expect(await isolatedAttempt(role, true), 'busy');
      exclusive.close();
      expect(await isolatedAttempt(role, false), 'opened');
    },
  );

  test(
    'catalog actors keep profile shared while allowing ordinary catalog/data writes',
    () {
      final first = create();
      final second = ManagedDirectoryCatalog.openExisting(profile)!;
      roots.add(second);
      expect(attempt(role, true), 'busy');
      final entry = ManagedIdentityEntry(
        id: ManagedIdentityId('a' * 32),
        protection: StorageProtection.unencrypted,
      );
      final data = ManagedIdentityFiles.createUnencrypted(first, id: entry.id);
      try {
        expect(second.snapshot().catalog.identities.single.id, entry.id);
        expect(() => first.close(), throwsA(isA<ManagedIdentityFailure>()));
        expect(attempt(role, true), 'busy');
      } finally {
        data.close();
      }
      first.close();
      expect(attempt(role, true), 'busy');
      second.close();
      expect(attempt(role, true), 'opened');
    },
  );

  test(
    'exclusive admission blocks root readers/creators without touching legacy files',
    () {
      final root = create()..close();
      final legacy = File('$profile/legacy.hv')..writeAsBytesSync([9, 8, 7]);
      final catalog = File(root.layout.catalogPath).readAsBytesSync();
      final exclusive = open(exclusive: true);
      for (final action in [
        () => ManagedDirectoryCatalog.openExisting(profile),
        create,
      ]) {
        expect(action, throwsA(predicate<Object>(busy)));
        exclusive.requireHeld(exclusive: true);
      }
      expect(File(root.layout.catalogPath).readAsBytesSync(), catalog);
      expect(legacy.readAsBytesSync(), [9, 8, 7]);
      final other = '${temp.path}/other';
      expect(fs.createPrivateDirectory(other), isTrue);
      final unaffected = ManagedDirectoryCatalog.createOrOpen(other);
      unaffected.close();
    },
  );

  for (final change in ['application', 'version', 'role', 'extra']) {
    test('foreign $change metadata is preserved rather than relabeled', () {
      create().close();
      final writer = ManagedSqliteConnection.openUnencrypted(role);
      try {
        writer.use((db) {
          switch (change) {
            case 'application':
              db.execute('PRAGMA application_id = 7');
            case 'version':
              db.execute('PRAGMA user_version = 2');
            case 'role':
              db.execute("UPDATE profile_role SET role = 'foreign'");
            case 'extra':
              db.execute('CREATE TABLE foreign_role (value TEXT)');
          }
        });
      } finally {
        writer.close();
      }
      final before = File(role).readAsBytesSync();
      expect(open, throwsA(isA<ManagedLeaseFailure>()));
      expect(File(role).readAsBytesSync(), before);
    });
  }

  test('exclusive maintenance is explicit and creates no absent root', () {
    expect(ManagedDirectoryCatalog.openExclusiveMaintenance(profile), isNull);
    expect(Directory(profile).listSync(), isEmpty);
    final shared = create();
    expect(
      shared.requireExclusiveMaintenance,
      throwsA(isA<ManagedLeaseFailure>()),
    );
    expect(
      () => ManagedDirectoryCatalog.openExclusiveMaintenance(profile),
      throwsA(predicate<Object>(busy)),
    );
    shared.close();
    final exclusive = ManagedDirectoryCatalog.openExclusiveMaintenance(
      profile,
    )!;
    roots.add(exclusive);
    exclusive.requireExclusiveMaintenance();
    expect(create, throwsA(predicate<Object>(busy)));
    exclusive.close();
    expect(create().snapshot().catalog.identities, isEmpty);
  });

  test(
    'an older QA root missing its lease is preserved without implicit upgrade',
    () {
      final root = create()..close();
      final before = File(root.layout.catalogPath).readAsBytesSync();
      File(role).renameSync('${temp.path}/retained-role');
      File('$role.lock').renameSync('${temp.path}/retained-lock');
      expect(
        () => ManagedDirectoryCatalog.openExisting(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(File(role).existsSync(), isFalse);
      expect(File(root.layout.catalogPath).readAsBytesSync(), before);
    },
  );

  test(
    'replaced role/lock paths invalidate live actors before catalog use',
    () {
      final root = create();
      final path = '$role.lock';
      File(path).renameSync('${temp.path}/original-lock');
      File(path).createSync();
      fs.restrictNewFile(path);
      expect(root.snapshot, throwsA(isA<ManagedFsFailure>()));
      root.close();
    },
    skip: Platform.isWindows,
  );

  test(
    'SQLite sidecar and role links refuse without following outside the root',
    () {
      final root = create()..close();
      final sentinel = File('${temp.path}/outside')
        ..writeAsBytesSync([1, 3, 5]);
      for (final suffix in ['-journal', '-wal', '-shm']) {
        final link = Link('$role$suffix')..createSync(sentinel.path);
        try {
          expect(create, throwsA(isA<ManagedFsFailure>()));
        } finally {
          link.deleteSync();
        }
      }
      final original = File(role)..renameSync('${temp.path}/saved-role');
      final link = Link(original.path)..createSync(sentinel.path);
      try {
        expect(create, throwsA(isA<ManagedFsFailure>()));
      } finally {
        link.deleteSync();
      }
      expect(sentinel.readAsBytesSync(), [1, 3, 5]);
      expect(File(root.layout.catalogPath).existsSync(), isTrue);
    },
    skip: Platform.isWindows,
  );
}
