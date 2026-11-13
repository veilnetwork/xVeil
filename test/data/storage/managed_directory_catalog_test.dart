import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/managed_catalog_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

class _BeforePublish extends ManagedFsPlatform {
  _BeforePublish(this.action);
  final void Function(String source, String destination) action;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    action(source, destination);
    return super.publishDirectoryNoReplace(source, destination);
  }
}

class _AfterPublish extends ManagedFsPlatform {
  bool published = false;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    published = super.publishDirectoryNoReplace(source, destination);
    return published;
  }

  @override
  void syncDirectory(String path) {
    if (published) throw const ManagedFsFailure(ManagedFsFailureKind.io);
    super.syncDirectory(path);
  }
}

void main() {
  const fs = ManagedFsPlatform();
  late Directory temporary;
  late Directory profile;
  final live = <ManagedDirectoryCatalog>[];

  ManagedDirectoryCatalog create({ManagedFsPlatform platform = fs}) {
    final owner = ManagedDirectoryCatalog.createOrOpen(
      profile.path,
      fs: platform,
    );
    live.add(owner);
    return owner;
  }

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('xveil-managed-files-');
    profile = Directory('${temporary.path}/profile');
    expect(fs.createPrivateDirectory(profile.path), isTrue);
  });
  tearDown(() {
    for (final owner in live) {
      owner.close();
    }
    live.clear();
    temporary.deleteSync(recursive: true);
  });

  test(
    'whole-directory bootstrap publishes a private complete catalog and reopens',
    () {
      final legacy = File('${profile.path}/legacy-fixture')
        ..writeAsStringSync('untouched');
      expect(ManagedDirectoryCatalog.openExisting(profile.path), isNull);
      expect(Directory('${profile.path}/identities').existsSync(), isFalse);
      final owner = create();
      expect(owner.snapshot().revision, 0);
      expect(owner.snapshot().catalog.identities, isEmpty);
      expect(fs.inspect(owner.directory).ownerOnly, isTrue);
      expect(fs.inspect(owner.layout.catalogPath).ownerOnly, isTrue);
      expect(Directory(profile.path).listSync().length, 2);
      owner.close();
      final reopened = ManagedDirectoryCatalog.openExisting(profile.path)!;
      live.add(reopened);
      expect(reopened.snapshot().revision, 0);
      expect(legacy.readAsStringSync(), 'untouched');
    },
  );

  test(
    'missing catalog in an existing root never initializes over identity data',
    () {
      final root = Directory('${profile.path}/identities');
      fs.createPrivateDirectory(root.path);
      final identity = Directory('${root.path}/${'1' * 32}');
      fs.createPrivateDirectory(identity.path);
      final bytes = File('${identity.path}/content.hv')
        ..writeAsBytesSync([9, 8, 7]);
      for (final open in [
        () => ManagedDirectoryCatalog.createOrOpen(profile.path),
        () => ManagedDirectoryCatalog.openExisting(profile.path),
      ]) {
        expect(
          open,
          throwsA(
            isA<ManagedFsFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedFsFailureKind.missingCatalog,
            ),
          ),
        );
        expect(File('${root.path}/catalog.sqlite3').existsSync(), isFalse);
        expect(bytes.readAsBytesSync(), [9, 8, 7]);
      }
    },
  );

  test('root and catalog links cannot redirect initialization or opening', () {
    final outside = Directory('${temporary.path}/outside');
    fs.createPrivateDirectory(outside.path);
    final sentinel = File('${outside.path}/sentinel')
      ..writeAsStringSync('preserved');
    final root = Link('${profile.path}/identities')..createSync(outside.path);
    expect(() => create(), throwsA(isA<ManagedFsFailure>()));
    expect(outside.listSync().length, 1);
    expect(() => fs.inspect('${root.path}/'), throwsA(isA<ManagedFsFailure>()));
    expect(sentinel.readAsStringSync(), 'preserved');
    root.deleteSync();
    final owner = create()..close();
    final catalog = File(owner.layout.catalogPath);
    final previous = catalog.readAsBytesSync();
    catalog.renameSync('${outside.path}/saved-catalog');
    final link = Link(catalog.path)
      ..createSync('${outside.path}/saved-catalog');
    expect(
      () => ManagedDirectoryCatalog.openExisting(profile.path),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(File('${outside.path}/saved-catalog').readAsBytesSync(), previous);
    expect(link.targetSync(), '${outside.path}/saved-catalog');
  });

  test(
    'SQLite recovery sidecar links are refused before opening the catalog',
    () {
      final owner = create()..close();
      final sentinel = File('${temporary.path}/outside-fixture')
        ..writeAsBytesSync([1, 3, 5, 7]);
      final before = File(owner.layout.catalogPath).readAsBytesSync();
      for (final suffix in ['-journal', '-wal', '-shm']) {
        final planted = Link('${owner.layout.catalogPath}$suffix')
          ..createSync(sentinel.path);
        try {
          expect(() => create(), throwsA(isA<ManagedFsFailure>()));
          expect(sentinel.readAsBytesSync(), [1, 3, 5, 7]);
          expect(File(owner.layout.catalogPath).readAsBytesSync(), before);
          expect(planted.targetSync(), sentinel.path);
        } finally {
          planted.deleteSync();
        }
      }
      expect(create().snapshot().revision, 0);
    },
    skip: Platform.isWindows,
  );

  test(
    'corrupt catalog is preserved instead of being replaced by an empty one',
    () {
      final owner = create()..close();
      final file = File(owner.layout.catalogPath);
      file.writeAsBytesSync([9, 8, 7, 6], flush: true);
      final previous = file.readAsBytesSync();
      expect(() => create(), throwsA(isA<ManagedSqliteFailure>()));
      expect(file.readAsBytesSync(), previous);
    },
  );

  test(
    'replaced root invalidates an open owner before reading its retired catalog',
    () {
      final original = create();
      Directory(original.directory).renameSync('${profile.path}/retired');
      final replacement = create();
      expect(
        () => original.snapshot(),
        throwsA(
          isA<ManagedFsFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedFsFailureKind.changed,
          ),
        ),
      );
      expect(replacement.snapshot().revision, 0);
    },
  );

  test('another creator wins without either catalog being overwritten', () {
    final id = ManagedIdentityId('7' * 32);
    final fsWithCompetitor = _BeforePublish((_, destination) {
      final winner = ManagedDirectoryCatalog.createOrOpen(profile.path)
        ..close();
      final store = ManagedCatalogStore.openOwned(
        ManagedSqliteConnection.openUnencrypted(winner.layout.catalogPath),
      );
      try {
        store.register(
          ManagedIdentityEntry(id: id, protection: StorageProtection.encrypted),
        );
      } finally {
        store.close();
      }
    });
    final loser = create(platform: fsWithCompetitor);
    expect(loser.snapshot().revision, 1);
    expect(loser.snapshot().catalog.identities.single.id, id);
    expect(
      profile.listSync().length,
      1,
      reason: 'only the published winner remains',
    );
  });

  test('failure before publication removes only the exact owned bootstrap', () {
    final sentinel = File('${profile.path}/sentinel')
      ..writeAsStringSync('preserved');
    expect(
      () => create(
        platform: _BeforePublish((_, _) {
          throw const ManagedFsFailure(ManagedFsFailureKind.io);
        }),
      ),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(profile.listSync().map((entry) => entry.path), [sentinel.path]);
    expect(sentinel.readAsStringSync(), 'preserved');
  });

  test('failure after publication leaves a readable catalog for retry', () {
    expect(
      () => create(platform: _AfterPublish()),
      throwsA(isA<ManagedFsFailure>()),
    );
    expect(create().snapshot().revision, 0);
    expect(profile.listSync().length, 1);
  });

  test('cleanup refuses a replacement directory and unexpected content', () {
    String? replacement;
    final platform = _BeforePublish((source, _) {
      Directory(source).renameSync('$source-retained');
      fs.createPrivateDirectory(source);
      File('$source/sentinel').writeAsStringSync('foreign-object');
      replacement = source;
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    });
    expect(() => create(platform: platform), throwsA(isA<ManagedFsFailure>()));
    expect(File('$replacement/sentinel').readAsStringSync(), 'foreign-object');
    expect(File('$replacement-retained/catalog.sqlite3').existsSync(), isTrue);
    expect(Directory('${profile.path}/identities').existsSync(), isFalse);
  });

  test('unpublished siblings are neither adopted nor automatically swept', () {
    final pending = Directory(
      '${profile.path}/.identities-${'4' * 32}.pending',
    );
    fs.createPrivateDirectory(pending.path);
    final marker = File('${pending.path}/sentinel')..writeAsStringSync('keep');
    final owner = create();
    expect(owner.snapshot().catalog.identities, isEmpty);
    expect(marker.readAsStringSync(), 'keep');
    expect(profile.listSync().length, 2);
  });

  test(
    'unsafe ancestor and world-readable catalog are refused without repair',
    () {
      final unsafe = Directory('${temporary.path}/unsafe');
      fs.createPrivateDirectory(unsafe.path);
      final nested = Directory('${unsafe.path}/profile');
      fs.createPrivateDirectory(nested.path);
      expect(posixChmod(unsafe.path, 0x1ff), 0);
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(nested.path),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(nested.listSync(), isEmpty);
      final owner = create()..close();
      final bytes = File(owner.layout.catalogPath).readAsBytesSync();
      expect(posixChmod(owner.layout.catalogPath, 0x1a4), 0);
      expect(() => create(), throwsA(isA<ManagedFsFailure>()));
      expect(File(owner.layout.catalogPath).readAsBytesSync(), bytes);
      expect(posixLstat(owner.layout.catalogPath)!.permissions, 0x1a4);
    },
    skip: Platform.isWindows,
  );

  test(
    'Darwin extended allow ACL is refused even if mode remains 0700',
    () async {
      final result = await Process.run('/bin/chmod', [
        '+a',
        'everyone allow read',
        profile.path,
      ]);
      expect(result.exitCode, 0);
      try {
        expect(posixLstat(profile.path)!.permissions, 0x1c0);
        expect(() => create(), throwsA(isA<ManagedFsFailure>()));
        expect(profile.listSync(), isEmpty);
      } finally {
        final cleared = await Process.run('/bin/chmod', ['-N', profile.path]);
        expect(cleared.exitCode, 0);
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'Darwin deny-only ACL remains usable without ignoring foreign allow grants',
    () async {
      final applied = await Process.run('/bin/chmod', [
        '+a',
        'everyone deny delete',
        profile.path,
      ]);
      expect(applied.exitCode, 0);
      try {
        final owner = create();
        expect(owner.snapshot().revision, 0);
      } finally {
        final cleared = await Process.run('/bin/chmod', ['-N', profile.path]);
        expect(cleared.exitCode, 0);
      }
    },
    skip: !Platform.isMacOS,
  );
}
