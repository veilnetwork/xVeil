@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_storage.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_protection.dart';

void main() {
  late Directory fixture;
  late String profile;
  final owned = <ManagedIdentityStorage>[];
  final encrypted = ManagedIdentityEntry(
    id: ManagedIdentityId('a' * 32),
    protection: StorageProtection.encrypted,
  );
  final plain = ManagedIdentityEntry(
    id: ManagedIdentityId('b' * 32),
    protection: StorageProtection.unencrypted,
  );
  ManagedIdentityStorage binding(
    ManagedIdentityEntry entry, {
    bool create = false,
  }) {
    final result = create
        ? ManagedIdentityStorage.forCreation(
            profileDirectory: profile,
            entry: entry,
          )
        : ManagedIdentityStorage.existing(
            profileDirectory: profile,
            entry: entry,
          );
    owned.add(result);
    return result;
  }

  Map<String, String> diskSnapshot() => {
    for (final file in Directory(
      profile,
    ).listSync(recursive: true).whereType<File>())
      file.path.substring(profile.length): sha256
          .convert(file.readAsBytesSync())
          .toString(),
  };
  Matcher failure(ManagedWorkerFailureKind kind) =>
      throwsA(isA<ManagedWorkerFailure>().having((e) => e.kind, 'kind', kind));

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-managed-domain-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final item in owned) {
      await item.storage.close();
    }
    owned.clear();
    fixture.deleteSync(recursive: true);
  });

  for (final entry in [encrypted, plain]) {
    test(
      '${entry.protection.name} domain creation, key and password reopen',
      () async {
        final created = binding(entry, create: true);
        expect(
          await created.storage.open(
            password: 'synthetic password',
            createIfMissing: true,
          ),
          isTrue,
        );
        await created.storage.saveProfile(
          const UserProfile(displayName: 'Synthetic owner'),
        );
        await created.storage.putSetting('fixture', 'kept');
        await created.storage.storeFile(
          'fixture-file',
          Uint8List.fromList([1, 2, 3]),
        );
        final keys = await created.storage.exportSpaceKeys();
        final copy = Uint8List.fromList(keys);
        final anchor = await created.storage.readCommitAnchor();
        expect(anchor, isNotNull);
        await created.reclaim(force: true);
        await created.storage.close();
        expect(await created.storage.openWithKeys(keys), isTrue);
        expect(
          keys,
          copy,
          reason: 'caller-owned vault keys must survive reopen',
        );
        expect(
          (await created.storage.loadProfile())?.displayName,
          'Synthetic owner',
        );
        expect(await created.storage.loadFile('fixture-file'), [1, 2, 3]);
        expect(await created.storage.getSetting('fixture'), 'kept');
        await created.storage.close();
        final cold = binding(entry);
        expect(await cold.storage.open(password: 'synthetic password'), isTrue);
        expect(await cold.storage.getSetting('fixture'), 'kept');
        keys.fillRange(0, keys.length, 0);
        copy.fillRange(0, copy.length, 0);
      },
    );
  }

  test(
    'creation is explicit and cannot adopt or overwrite an existing identity',
    () async {
      final created = binding(plain, create: true);
      await expectLater(
        created.storage.open(password: ''),
        failure(ManagedWorkerFailureKind.mode),
      );
      await expectLater(
        created.storage.openWithKeys(Uint8List(64)),
        failure(ManagedWorkerFailureKind.mode),
      );
      expect(Directory(profile).listSync(), isEmpty);
      expect(
        await created.storage.open(password: '', createIfMissing: true),
        isTrue,
      );
      await created.storage.putSetting('kept', 'original');
      await created.storage.close();
      final before = diskSnapshot();
      final duplicate = binding(plain, create: true);
      await expectLater(
        duplicate.storage.open(password: '', createIfMissing: true),
        failure(ManagedWorkerFailureKind.exists),
      );
      expect(diskSnapshot(), before);
      final existing = binding(plain);
      await expectLater(
        existing.storage.open(password: '', createIfMissing: true),
        failure(ManagedWorkerFailureKind.mode),
      );
      expect(diskSnapshot(), before);
      expect(await existing.storage.open(password: ''), isTrue);
      expect(await existing.storage.getSetting('kept'), 'original');
    },
  );

  test('missing and wrong-mode selections do not manufacture data', () async {
    final missing = binding(encrypted);
    await expectLater(
      missing.storage.open(password: 'synthetic password'),
      failure(ManagedWorkerFailureKind.missing),
    );
    expect(Directory(profile).listSync(), isEmpty);
    final created = binding(encrypted, create: true);
    expect(
      await created.storage.open(
        password: 'synthetic password',
        createIfMissing: true,
      ),
      isTrue,
    );
    await created.storage.putSetting('fixture', 'encrypted value');
    await created.storage.close();
    final before = diskSnapshot();
    final wrong = binding(
      ManagedIdentityEntry(
        id: encrypted.id,
        protection: StorageProtection.unencrypted,
      ),
    );
    await expectLater(
      wrong.storage.open(password: ''),
      failure(ManagedWorkerFailureKind.mode),
    );
    expect(diskSnapshot(), before);
    expect(
      File(ManagedIdentityLayout(profile).dataPath(encrypted.id)).existsSync(),
      isFalse,
    );
  });

  test(
    'credential failures remain false without plaintext or replacement fallback',
    () async {
      final created = binding(encrypted, create: true);
      expect(
        await created.storage.open(
          password: 'synthetic password',
          createIfMissing: true,
        ),
        isTrue,
      );
      await created.storage.putSetting('fixture', 'encrypted value');
      await created.storage.close();
      final before = diskSnapshot();
      final existing = binding(encrypted);
      expect(await existing.storage.open(password: 'wrong password'), isFalse);
      expect(await existing.storage.openWithKeys(Uint8List(64)), isFalse);
      expect(existing.storage.isOpen, isFalse);
      expect(diskSnapshot(), before);
      expect(
        await existing.storage.open(password: 'synthetic password'),
        isTrue,
      );
      expect(await existing.storage.getSetting('fixture'), 'encrypted value');
    },
  );

  test(
    'two active identities own separate blobs and erasure preserves the sibling',
    () async {
      final first = binding(encrypted, create: true);
      final second = binding(plain, create: true);
      for (final item in [first, second]) {
        expect(
          await item.storage.open(
            password: 'same synthetic password',
            createIfMissing: true,
          ),
          isTrue,
        );
      }
      final one = Uint8List(kMaxStoredFileBytes + 1)
        ..fillRange(0, kMaxStoredFileBytes + 1, 11);
      final two = Uint8List(kMaxStoredFileBytes + 1)
        ..fillRange(0, kMaxStoredFileBytes + 1, 22);
      for (final (item, bytes) in [(first, one), (second, two)]) {
        await item.storage.storeFilePiece(
          'same-file-id',
          0,
          1,
          bytes.length,
          bytes.length,
          bytes,
        );
      }
      final layout = ManagedIdentityLayout(profile);
      final firstRoot = Directory(layout.blobDirectory(encrypted.id));
      final secondRoot = Directory(layout.blobDirectory(plain.id));
      expect(firstRoot.listSync(), hasLength(1));
      expect(secondRoot.listSync(), hasLength(1));
      final siblingBefore = {
        for (final file
            in secondRoot.listSync(recursive: true).whereType<File>())
          file.path: sha256.convert(file.readAsBytesSync()).toString(),
      };
      expect(await first.storage.loadFile('same-file-id'), one);
      expect(await second.storage.loadFile('same-file-id'), two);
      await first.storage.eraseSpace();
      expect(await first.storage.getSetting('fixture'), isNull);
      expect(await first.storage.hasFile('same-file-id'), isFalse);
      expect(firstRoot.listSync(), isEmpty);
      expect({
        for (final file
            in secondRoot.listSync(recursive: true).whereType<File>())
          file.path: sha256.convert(file.readAsBytesSync()).toString(),
      }, siblingBefore);
      expect(await second.storage.loadFile('same-file-id'), two);
      await second.storage.close();
      expect(
        await second.storage.open(password: 'ignored plaintext password'),
        isTrue,
      );
      expect(await second.storage.loadFile('same-file-id'), two);
      final data = File(layout.dataPath(plain.id)).readAsBytesSync();
      expect(utf8.decode(data.sublist(0, 15)), 'SQLite format 3');
    },
  );

  test(
    'closed facade rejects maintenance and never acquires a hidden owner',
    () async {
      final existing = binding(plain);
      expect(
        () => existing.reclaim(force: true),
        failure(ManagedWorkerFailureKind.closed),
      );
      expect(Directory(profile).listSync(), isEmpty);
      expect(File('$profile/xveil.store').existsSync(), isFalse);
    },
  );
}
