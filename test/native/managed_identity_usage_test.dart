@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/on_disk_blob_store.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List b(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory fixture;
  late ManagedDirectoryCatalog root;
  final stores = <ManagedIdentityStore>[];
  final id = ManagedIdentityId('1' * 32);
  const fs = ManagedFsPlatform();
  ManagedIdentityStore create(StorageProtection mode) {
    final store = mode == StorageProtection.encrypted
        ? ManagedIdentityFiles.createEncrypted(
            root,
            id: id,
            password: b('synthetic password'),
          )
        : ManagedIdentityFiles.createUnencrypted(root, id: id);
    stores.add(store);
    store.commit([PutOp(1, b('key'), b('value'))]);
    return store;
  }

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-usage-');
    final profile = '${fixture.path}/profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
    root = ManagedDirectoryCatalog.createOrOpen(profile);
  });
  tearDown(() {
    for (final store in stores) {
      store.close();
    }
    stores.clear();
    root.close();
    fixture.deleteSync(recursive: true);
  });

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      '${mode.name} inventory counts real pieces and excludes siblings/catalog/legacy',
      () async {
        final store = create(mode);
        final sibling = ManagedIdentityFiles.createUnencrypted(
          root,
          id: ManagedIdentityId('2' * 32),
        );
        stores.add(sibling);
        sibling.commit([PutOp(1, b('sibling'), Uint8List(512))]);
        File(
          '${root.profileDirectory}/legacy.hv',
        ).writeAsBytesSync(Uint8List(3000));
        final directory = root.layout.directory(id);
        final blobRoot = Directory(root.layout.blobDirectory(id));
        final blobStore = OnDiskBlobStore(blobRoot);
        await blobStore.storePiece(
          'AbcdEFgh_123-xy9',
          Uint8List(32),
          0,
          Uint8List(123),
        );
        File(
          '${blobRoot.path}/AbcdEFgh_123-xy9/p1.tmp',
        ).writeAsBytesSync(Uint8List(7));
        final usage = await store.storageUsage();
        final actual = Directory(
          directory,
        ).listSync(recursive: true).whereType<File>().toList();
        expect(
          usage.totalBytes,
          actual.fold<int>(0, (sum, file) => sum + file.lengthSync()),
        );
        expect(usage.files, actual.length);
        expect(usage.blobBytes, 123 + 16 + 7);
        expect(usage.dataBytes, greaterThan(0));
        expect(usage.metadataBytes, greaterThan(0));
        expect(usage.otherBytes, 0);
        expect(usage.unrecognizedEntries, 0);
        expect(sibling.get(1, b('sibling')), Uint8List(512));
        expect(store.get(1, b('key')), b('value'));
      },
    );
  }

  test(
    'unknown bytes and empty directories are counted but never adopted',
    () async {
      final store = create(StorageProtection.unencrypted);
      File('${root.layout.directory(id)}/foreign').writeAsBytesSync([1, 2, 3]);
      Directory('${root.layout.directory(id)}/foreign-empty').createSync();
      final usage = await store.storageUsage();
      expect(usage.otherBytes, 3);
      expect(usage.unrecognizedEntries, 2);
      expect(File('${root.layout.directory(id)}/foreign').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'a lease cannot close or mutate halfway through an asynchronous walk',
    () async {
      final store = create(StorageProtection.unencrypted);
      final pending = store.storageUsage();
      final busy = throwsA(
        isA<ManagedIdentityFailure>().having(
          (e) => e.kind,
          'kind',
          ManagedIdentityFailureKind.busy,
        ),
      );
      expect(store.close, busy);
      expect(() => store.commit([PutOp(1, b('key'), b('changed'))]), busy);
      await expectLater(store.storageUsage(), busy);
      expect((await pending).totalBytes, greaterThan(0));
      expect(store.get(1, b('key')), b('value'));
      store.close();
      await expectLater(
        store.storageUsage(),
        throwsA(isA<ManagedIdentityFailure>()),
      );
    },
  );

  test(
    'missing required file never becomes a successful partial size',
    () async {
      final store = create(StorageProtection.unencrypted);
      final original = File('${root.layout.directory(id)}/data.store');
      final moved = original.renameSync('${fixture.path}/saved-store');
      try {
        await expectLater(
          store.storageUsage(),
          throwsA(isA<ManagedFsFailure>()),
        );
      } finally {
        moved.renameSync(original.path);
      }
      expect((await store.storageUsage()).dataBytes, greaterThan(0));
    },
    skip: Platform.isWindows
        ? 'open SQLite file rename is refused on Windows'
        : false,
  );

  test(
    'symlink into another identity is refused without reading/removing its target',
    () async {
      final store = create(StorageProtection.unencrypted);
      final outside = File('${fixture.path}/outside')
        ..writeAsBytesSync([9, 8, 7]);
      final link = Link('${root.layout.blobDirectory(id)}/link')
        ..createSync(outside.path);
      try {
        await expectLater(
          store.storageUsage(),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(outside.readAsBytesSync(), [9, 8, 7]);
        expect(store.get(1, b('key')), b('value'));
      } finally {
        link.deleteSync();
      }
      expect((await store.storageUsage()).unrecognizedEntries, 0);
    },
    skip: Platform.isWindows ? 'requires symlink privilege' : false,
  );

  test(
    'worker exposes owned accounting and remains usable after an inventory error',
    () async {
      final store = create(StorageProtection.unencrypted);
      store.close();
      final worker = await ManagedWorkerIdentity.openUnencrypted(
        profileDirectory: root.profileDirectory,
        id: id,
      );
      final path = '${root.layout.blobDirectory(id)}/link';
      try {
        expect((await worker.storageUsage())!.dataBytes, greaterThan(0));
        if (!Platform.isWindows) {
          Link(path).createSync('${fixture.path}/absent');
          await expectLater(
            worker.storageUsage(),
            throwsA(isA<ManagedWorkerFailure>()),
          );
          Link(path).deleteSync();
        }
        expect(await worker.get(1, b('key')), b('value'));
        expect((await worker.storageUsage())!.unrecognizedEntries, 0);
      } finally {
        if (Link(path).existsSync()) Link(path).deleteSync();
        await worker.close();
      }
    },
  );
}
