@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_catalog_store.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/data/storage/on_disk_blob_store.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
Matcher failKind(ManagedIdentityFailureKind kind) =>
    throwsA(isA<ManagedIdentityFailure>().having((e) => e.kind, 'kind', kind));

class _RemoveBeforeLease extends ManagedFsPlatform {
  ManagedIdentityEntry? armed;
  String? catalogPath;
  @override
  ManagedPathWitness inspect(String path) {
    final result = super.inspect(path);
    final entry = armed;
    if (entry != null && path.endsWith('identity.meta.lock')) {
      armed = null;
      final catalog = ManagedCatalogStore.openOwned(
        ManagedSqliteConnection.openUnencrypted(catalogPath!),
      );
      try {
        catalog.remove(entry);
      } finally {
        catalog.close();
      }
    }
    return result;
  }
}

void main() {
  late Directory fixture;
  late ManagedDirectoryCatalog root;
  final owned = <ManagedIdentityStore>[];
  const fs = ManagedFsPlatform();
  final id = ManagedIdentityId('1' * 32);
  final sibling = ManagedIdentityId('2' * 32);
  ManagedIdentityEntry entry(StorageProtection mode) =>
      ManagedIdentityEntry(id: id, protection: mode);
  ManagedIdentityStore create(StorageProtection mode) {
    final store = mode == StorageProtection.encrypted
        ? ManagedIdentityFiles.createEncrypted(
            root,
            id: id,
            password: b('fixture password'),
          )
        : ManagedIdentityFiles.createUnencrypted(root, id: id);
    owned.add(store);
    store.commit([PutOp(1, b('key'), b('value'))]);
    return store;
  }

  Map<String, String> snapshot(String path) => {
    for (final file in Directory(
      path,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      file.path.substring(path.length): sha256
          .convert(file.readAsBytesSync())
          .toString(),
  };
  Future<void> blobs() => OnDiskBlobStore(
    Directory(root.layout.blobDirectory(id)),
  ).storePiece('AbcdEFgh_123-xy9', Uint8List(32), 0, b('fixture piece'));
  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-erase-');
    expect(fs.createPrivateDirectory('${fixture.path}/profile'), isTrue);
    root = ManagedDirectoryCatalog.createOrOpen('${fixture.path}/profile');
  });
  tearDown(() {
    for (final store in owned) {
      store.close();
    }
    owned.clear();
    root.close();
    fixture.deleteSync(recursive: true);
  });

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      '${mode.name} whole deletion leaves sibling and hidden files byte-identical',
      () async {
        final store = create(mode);
        final keys = store.exportKeys();
        store.close();
        await blobs();
        final other = ManagedIdentityFiles.createUnencrypted(root, id: sibling);
        owned.add(other);
        other.commit([PutOp(1, b('sibling'), b('keep'))]);
        other.close();
        final hidden = File('${root.profileDirectory}/legacy.hv')
          ..writeAsBytesSync(List.filled(500, 77));
        root.select(entry(mode));
        final before = snapshot(root.layout.directory(sibling));
        await ManagedIdentityFiles.erase(root, entry: entry(mode), keys: keys);
        expect(
          keys,
          isNot(everyElement(0)),
          reason: 'borrowed roster keys stay intact',
        );
        expect(Directory(root.layout.directory(id)).existsSync(), isFalse);
        expect(root.snapshot().catalog.selectedId, isNull);
        expect(root.snapshot().catalog.identities.single.id, sibling);
        expect(snapshot(root.layout.directory(sibling)), before);
        expect(hidden.readAsBytesSync(), List.filled(500, 77));
        final revision = root.snapshot().revision;
        await ManagedIdentityFiles.erase(root, entry: entry(mode), keys: keys);
        expect(root.snapshot().revision, revision);
        keys.fillRange(0, keys.length, 0);
      },
    );
  }

  test('wrong encrypted password or keys never removes any byte', () async {
    create(StorageProtection.encrypted).close();
    await blobs();
    final before = snapshot(root.profileDirectory);
    for (final password in [true, false]) {
      await expectLater(
        ManagedIdentityFiles.erase(
          root,
          entry: entry(StorageProtection.encrypted),
          password: password ? b('wrong password') : null,
          keys: password ? null : Uint8List(64),
        ),
        failKind(ManagedIdentityFailureKind.authentication),
      );
      expect(snapshot(root.profileDirectory), before);
    }
  });

  test(
    'another live native owner blocks deletion until confirmed close',
    () async {
      final store = create(StorageProtection.unencrypted);
      final otherRoot = ManagedDirectoryCatalog.openExisting(
        root.profileDirectory,
      )!;
      try {
        await expectLater(
          ManagedIdentityFiles.erase(
            otherRoot,
            entry: entry(StorageProtection.unencrypted),
          ),
          failKind(ManagedIdentityFailureKind.busy),
        );
        expect(store.get(1, b('key')), b('value'));
        store.close();
        await ManagedIdentityFiles.erase(
          otherRoot,
          entry: entry(StorageProtection.unencrypted),
        );
      } finally {
        otherRoot.close();
      }
    },
  );

  test('unknown entries and symlinks refuse before first deletion', () async {
    create(StorageProtection.unencrypted).close();
    await blobs();
    final unknown = Directory('${root.layout.directory(id)}/foreign-empty')
      ..createSync();
    final before = snapshot(root.profileDirectory);
    await expectLater(
      ManagedIdentityFiles.erase(
        root,
        entry: entry(StorageProtection.unencrypted),
      ),
      failKind(ManagedIdentityFailureKind.ambiguous),
    );
    expect(snapshot(root.profileDirectory), before);
    expect(unknown.existsSync(), isTrue);
    unknown.deleteSync();
    if (!Platform.isWindows) {
      final target = File('${fixture.path}/target')
        ..writeAsBytesSync([1, 2, 3]);
      final link = Link('${root.layout.blobDirectory(id)}/link')
        ..createSync(target.path);
      await expectLater(
        ManagedIdentityFiles.erase(
          root,
          entry: entry(StorageProtection.unencrypted),
        ),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(target.readAsBytesSync(), [1, 2, 3]);
      expect(link.existsSync(), isTrue);
      link.deleteSync();
    }
  });

  test(
    'zero-byte private payload without a keybox is not metadata-only cleanup',
    () async {
      create(StorageProtection.encrypted).close();
      final path = root.layout.directory(id);
      File('$path/keybox.hv').deleteSync();
      File('$path/content.hv').writeAsBytesSync([]);
      File('$path/maintenance.hv').deleteSync();
      final before = snapshot(root.profileDirectory);
      await expectLater(
        ManagedIdentityFiles.erase(
          root,
          entry: entry(StorageProtection.encrypted),
        ),
        failKind(ManagedIdentityFailureKind.authentication),
      );
      expect(snapshot(root.profileDirectory), before);
    },
  );

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    for (final stage in ManagedEraseStage.values) {
      test('${mode.name} retry after failure at ${stage.name}', () async {
        create(mode).close();
        await blobs();
        var reached = false;
        await expectLater(
          ManagedIdentityFiles.debugErase(
            root,
            entry: entry(mode),
            password: mode == StorageProtection.encrypted
                ? b('fixture password')
                : null,
            observer: (at) async {
              if (at == stage) {
                reached = true;
                throw StateError('fixture interruption');
              }
            },
          ),
          failKind(ManagedIdentityFailureKind.backend),
        );
        expect(reached, isTrue);
        if (mode == StorageProtection.encrypted &&
            stage.index <= ManagedEraseStage.contentRemoved.index) {
          expect(
            File('${root.layout.directory(id)}/keybox.hv').existsSync(),
            isTrue,
          );
        }
        await ManagedIdentityFiles.erase(
          root,
          entry: entry(mode),
          password: mode == StorageProtection.encrypted
              ? b('fixture password')
              : null,
        );
        expect(Directory(root.layout.directory(id)).existsSync(), isFalse);
        expect(root.snapshot().catalog.identities, isEmpty);
      });
    }
  }

  test(
    'paused deletion retains lease and root; concurrent open/delete/close refuse',
    () async {
      create(StorageProtection.unencrypted).close();
      final reached = Completer<void>(), release = Completer<void>();
      final deleting = ManagedIdentityFiles.debugErase(
        root,
        entry: entry(StorageProtection.unencrypted),
        observer: (at) async {
          if (at == ManagedEraseStage.validated) {
            reached.complete();
            await release.future;
          }
        },
      );
      await reached.future;
      final other = ManagedDirectoryCatalog.openExisting(
        root.profileDirectory,
      )!;
      try {
        expect(
          () => ManagedIdentityFiles.openUnencrypted(other, id: id),
          failKind(ManagedIdentityFailureKind.busy),
        );
        expect(root.close, failKind(ManagedIdentityFailureKind.busy));
        await expectLater(
          ManagedIdentityFiles.erase(
            root,
            entry: entry(StorageProtection.unencrypted),
          ),
          failKind(ManagedIdentityFailureKind.busy),
        );
      } finally {
        release.complete();
        await deleting;
        other.close();
      }
      expect(Directory(root.layout.directory(id)).existsSync(), isFalse);
    },
  );

  test(
    'catalog worker erases off-isolate and snapshots mutable credentials',
    () async {
      final store = create(StorageProtection.encrypted);
      final keys = store.exportKeys();
      store.close();
      final worker = await ManagedCatalogWorker.open(root.profileDirectory);
      try {
        final deletion = worker.erase(
          entry(StorageProtection.encrypted),
          keys: keys,
        );
        keys.fillRange(0, keys.length, 0);
        final queuedSnapshot = worker.snapshot();
        final closing = worker.close();
        final result = await deletion;
        expect(result.catalog.identities, isEmpty);
        expect((await queuedSnapshot).snapshot.catalog.identities, isEmpty);
        await closing;
        expect(Directory(root.layout.directory(id)).existsSync(), isFalse);
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'stale catalog view cannot open payloads after its lease is acquired',
    () async {
      create(StorageProtection.unencrypted).close();
      root.close();
      final fault = _RemoveBeforeLease()
        ..catalogPath = '${root.directory}/catalog.sqlite3'
        ..armed = entry(StorageProtection.unencrypted);
      root = ManagedDirectoryCatalog.openExisting(
        root.profileDirectory,
        fs: fault,
      )!;
      ManagedIdentityStore? unexpected;
      try {
        expect(
          () => unexpected = ManagedIdentityFiles.openUnencrypted(root, id: id),
          failKind(ManagedIdentityFailureKind.missing),
        );
      } finally {
        unexpected?.close();
      }
      expect(fault.armed, isNull);
      expect(root.snapshot().catalog.identities, isEmpty);
      expect(
        File('${root.layout.directory(id)}/data.store').existsSync(),
        isTrue,
        reason: 'catalog metadata alone never authorizes payload deletion',
      );
      await ManagedIdentityFiles.erase(
        root,
        entry: entry(StorageProtection.unencrypted),
      );
    },
  );

  test('exhausted catalog refuses before deleting payloads', () async {
    create(StorageProtection.unencrypted).close();
    final connection = ManagedSqliteConnection.openUnencrypted(
      '${root.directory}/catalog.sqlite3',
    );
    try {
      connection.use(
        (db) => db.execute(
          'UPDATE managed_catalog SET revision = 9223372036854775807',
        ),
      );
    } finally {
      connection.close();
    }
    final before = snapshot(root.profileDirectory);
    await expectLater(
      ManagedIdentityFiles.erase(
        root,
        entry: entry(StorageProtection.unencrypted),
      ),
      throwsA(isA<ManagedCatalogFailure>()),
    );
    expect(snapshot(root.profileDirectory), before);
  });

  test(
    'metadata-only retry can finish after the role database was already removed',
    () async {
      create(StorageProtection.unencrypted).close();
      await expectLater(
        ManagedIdentityFiles.debugErase(
          root,
          entry: entry(StorageProtection.unencrypted),
          observer: (at) async {
            if (at == ManagedEraseStage.catalogRemoved) {
              throw StateError('fixture stop');
            }
          },
        ),
        failKind(ManagedIdentityFailureKind.backend),
      );
      File('${root.layout.directory(id)}/identity.meta').deleteSync();
      await ManagedIdentityFiles.erase(
        root,
        entry: entry(StorageProtection.unencrypted),
      );
      expect(Directory(root.layout.directory(id)).existsSync(), isFalse);
    },
  );
}
