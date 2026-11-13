@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/identity_erase_review.dart';
import 'package:xveil/domain/storage_protection.dart';

Uint8List b(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  final id = ManagedIdentityId('1' * 32), sibling = ManagedIdentityId('2' * 32);
  late Directory fixture;
  late ManagedDirectoryCatalog owner;
  late ManagedIdentityEntry entry;
  late Uint8List keys;
  final stores = <ManagedIdentityStore>[];
  const fs = ManagedFsPlatform();
  String getPath() => owner.layout.directory(id);
  Map<String, String> snapshot(String path) => {
    for (final file in Directory(
      path,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      file.path.substring(path.length): sha256
          .convert(file.readAsBytesSync())
          .toString(),
  };
  void create(StorageProtection mode) {
    entry = ManagedIdentityEntry(id: id, protection: mode);
    final store = mode == StorageProtection.encrypted
        ? ManagedIdentityFiles.createEncrypted(
            owner,
            id: id,
            password: b('fixture password'),
          )
        : ManagedIdentityFiles.createUnencrypted(owner, id: id);
    stores.add(store);
    keys = store.exportKeys();
    store.close();
  }

  Future<IdentityEraseReview> review() =>
      ManagedIdentityFiles.reviewErasure(owner, entry: entry, keys: keys);
  Future<void> erase(IdentityEraseReview consent) => ManagedIdentityFiles.erase(
    owner,
    entry: entry,
    keys: keys,
    review: consent,
  );
  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-erase-review-');
    expect(fs.createPrivateDirectory('${fixture.path}/profile'), isTrue);
    owner = ManagedDirectoryCatalog.createOrOpen('${fixture.path}/profile');
  });
  tearDown(() {
    for (final store in stores) {
      store.close();
    }
    stores.clear();
    keys.fillRange(0, keys.length, 0);
    owner.close();
    fixture.deleteSync(recursive: true);
  });

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      '${mode.name}: authenticated review deletes unknown entries only with explicit consent',
      () async {
        create(mode);
        final other = ManagedIdentityFiles.createUnencrypted(
          owner,
          id: sibling,
        );
        stores.add(other);
        other.close();
        final hidden = File('${owner.profileDirectory}/legacy.hv')
          ..writeAsStringSync('keep hidden fixture');
        final siblingBefore = snapshot(owner.layout.directory(sibling));
        final base = getPath();
        final folder = Directory('$base/orphan ?#%')..createSync();
        File('${folder.path}/part ?#%.txt').writeAsBytesSync([1, 2, 3]);
        File('$base/empty').createSync();
        final blob = Directory('$base/blobs/AbcdEFgh_123-xy9')..createSync();
        File('${blob.path}/p0').writeAsBytesSync([4]);
        File('${blob.path}/extra').writeAsBytesSync([5, 6]);
        final before = snapshot(base);
        await expectLater(
          ManagedIdentityFiles.erase(owner, entry: entry, keys: keys),
          throwsA(isA<ManagedIdentityFailure>()),
        );
        final consent = await review();
        expect(consent.files, 3);
        expect(consent.directories, 1);
        expect(consent.bytes, 5);
        expect(snapshot(base), before); // Review and refusal are read-only.
        final released = mode == StorageProtection.encrypted
            ? ManagedIdentityFiles.openWithKeys(owner, id: id, keys: keys)
            : ManagedIdentityFiles.openUnencrypted(owner, id: id);
        stores.add(released);
        released.close(); // No lease held awaiting consent.
        await erase(consent);
        expect(Directory(base).existsSync(), isFalse);
        expect(snapshot(owner.layout.directory(sibling)), siblingBefore);
        expect(hidden.readAsStringSync(), 'keep hidden fixture');
        expect(owner.snapshot().catalog.identities.map((e) => e.id), [sibling]);
      },
    );

    for (final mutation in [
      'added',
      'removed',
      'length',
      'mtime',
      'replacement',
      'parent',
      'forged-count',
    ]) {
      test(
        '${mode.name}: $mutation invalidates approval before any deletion',
        () async {
          create(mode);
          final dir = Directory('${getPath()}/unknown')..createSync();
          final file = File('${dir.path}/one')..writeAsStringSync('same');
          final consent = await review();
          var supplied = consent;
          switch (mutation) {
            case 'added':
              File('${dir.path}/new').writeAsStringSync('new');
            case 'removed':
              file.deleteSync();
            case 'length':
              file.writeAsStringSync('different');
            case 'mtime':
              file.setLastModifiedSync(DateTime.utc(2000));
            case 'replacement':
              file.renameSync('${fixture.path}/old-file');
              File(file.path).writeAsStringSync('same');
            case 'parent':
              dir.renameSync('${fixture.path}/old-dir');
              Directory(dir.path).createSync();
              File(file.path).writeAsStringSync('same');
            case 'forged-count':
              supplied = IdentityEraseReview(
                token: consent.token,
                files: 999,
                directories: consent.directories,
                bytes: consent.bytes,
              );
          }
          final before = snapshot(getPath());
          await expectLater(
            erase(supplied),
            throwsA(isA<ManagedIdentityFailure>()),
          );
          expect(snapshot(getPath()), before);
          // Stale approval is consumed. A fresh explicit review succeeds.
          await expectLater(
            erase(consent),
            throwsA(isA<ManagedIdentityFailure>()),
          );
          expect(snapshot(getPath()), before);
          await erase(await review());
          expect(Directory(getPath()).existsSync(), isFalse);
        },
      );
    }

    test(
      '${mode.name}: live owner, wrong credentials, missing authenticator and symlink refuse',
      () async {
        create(mode);
        final foreign = File('${getPath()}/foreign')
          ..writeAsStringSync('preserve');
        final live = mode == StorageProtection.encrypted
            ? ManagedIdentityFiles.openWithKeys(owner, id: id, keys: keys)
            : ManagedIdentityFiles.openUnencrypted(owner, id: id);
        stores.add(live);
        await expectLater(review(), throwsA(isA<ManagedIdentityFailure>()));
        live.close();
        await expectLater(
          ManagedIdentityFiles.reviewErasure(
            owner,
            entry: entry,
            keys: Uint8List(64),
          ),
          throwsA(isA<ManagedIdentityFailure>()),
        );
        final outside = File('${fixture.path}/outside')
          ..writeAsStringSync('outside');
        Link('${getPath()}/link').createSync(outside.path);
        await expectLater(review(), throwsA(isA<ManagedFsFailure>()));
        expect(outside.readAsStringSync(), 'outside');
        Link('${getPath()}/link').deleteSync();
        if (mode == StorageProtection.encrypted) {
          File(
            '${getPath()}/keybox.hv',
          ).renameSync('${fixture.path}/saved-keybox');
          await expectLater(review(), throwsA(isA<ManagedIdentityFailure>()));
        }
        expect(foreign.readAsStringSync(), 'preserve');
      },
    );
  }

  test(
    'review is scoped to actor and exact target; newer review invalidates older one',
    () async {
      create(StorageProtection.unencrypted);
      File('${getPath()}/unknown').writeAsStringSync('keep');
      final old = await review(), current = await review();
      await expectLater(erase(old), throwsA(isA<ManagedIdentityFailure>()));
      final other = ManagedIdentityFiles.createUnencrypted(owner, id: sibling);
      stores.add(other);
      final otherKeys = other.exportKeys();
      other.close();
      final extra = File('${owner.layout.directory(sibling)}/unknown')
        ..writeAsStringSync('sibling');
      await expectLater(
        ManagedIdentityFiles.erase(
          owner,
          entry: ManagedIdentityEntry(
            id: sibling,
            protection: StorageProtection.unencrypted,
          ),
          keys: otherKeys,
          review: current,
        ),
        throwsA(isA<ManagedIdentityFailure>()),
      );
      expect(extra.readAsStringSync(), 'sibling');
      otherKeys.fillRange(0, otherKeys.length, 0);
      final next = await review();
      final path = owner.profileDirectory;
      owner.close();
      owner = ManagedDirectoryCatalog.openExisting(path)!;
      await expectLater(erase(next), throwsA(isA<ManagedIdentityFailure>()));
      await erase(await review());
    },
  );

  test(
    'worker snapshots credentials and returns only counts and opaque consent',
    () async {
      create(StorageProtection.encrypted);
      final path = getPath(), profile = owner.profileDirectory;
      File('$path/unrecognized').writeAsStringSync('orphan');
      owner.close();
      final worker = await ManagedCatalogWorker.open(profile);
      final borrowed = Uint8List.fromList(keys);
      try {
        final pending = worker.reviewErasure(entry, borrowed);
        borrowed.fillRange(0, borrowed.length, 0);
        final consent = await pending;
        expect(consent.files, 1);
        expect(consent.bytes, 6);
        expect(keys.any((b) => b != 0), isTrue);
        await worker.erase(entry, keys: keys, review: consent);
        expect(Directory(path).existsSync(), isFalse);
      } finally {
        await worker.close();
        owner = ManagedDirectoryCatalog.openExisting(profile)!;
      }
    },
  );

  test(
    'oversized review refuses without truncating or removing content',
    () async {
      create(StorageProtection.unencrypted);
      for (var i = 0; i < 4097; i++) {
        File('${getPath()}/unknown-$i').createSync();
      }
      await expectLater(review(), throwsA(isA<ManagedIdentityFailure>()));
      expect(
        Directory(getPath())
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('/unknown-'))
            .length,
        4097,
      );
    },
  );
  test('missing target review never removes its catalog reference', () async {
    create(StorageProtection.unencrypted);
    final path = getPath(), saved = '${fixture.path}/preserved-target';
    final before = owner.snapshot();
    Directory(path).renameSync(saved);
    try {
      Object? failure;
      try {
        await review();
      } catch (error) {
        failure = error;
      }
      expect(owner.snapshot().revision, before.revision);
      expect(owner.snapshot().catalog.identities.map((e) => e.id), [id]);
      expect(
        failure,
        isA<ManagedIdentityFailure>().having(
          (e) => e.kind,
          'kind',
          ManagedIdentityFailureKind.missing,
        ),
      );
    } finally {
      Directory(saved).renameSync(path);
    }
  });

  test(
    'review with no unknown entries cannot fall through to ordinary erasure',
    () async {
      create(StorageProtection.unencrypted);
      final before = snapshot(getPath()), revision = owner.snapshot().revision;
      await expectLater(review(), throwsA(isA<ManagedIdentityFailure>()));
      expect(snapshot(getPath()), before);
      expect(owner.snapshot().revision, revision);
      expect(owner.snapshot().catalog.identities.single.id, id);
    },
  );

  test('confirmation cannot succeed against an absent catalog actor', () async {
    create(StorageProtection.unencrypted);
    final profile = '${fixture.path}/empty-profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
    final worker = await ManagedCatalogWorker.open(profile);
    try {
      await expectLater(
        worker.erase(
          entry,
          keys: keys,
          review: const IdentityEraseReview(
            token: 'synthetic-consent',
            files: 1,
            directories: 0,
            bytes: 0,
          ),
        ),
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedWorkerFailureKind.missing,
          ),
        ),
      );
      expect(Directory('$profile/identities').existsSync(), isFalse);
    } finally {
      await worker.close();
    }
  });
}
