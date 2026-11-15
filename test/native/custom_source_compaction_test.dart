@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/profile_storage_bootstrap.dart';
import 'package:xveil/data/storage/profile_storage_router.dart';
import 'package:xveil/data/storage/profile_storage_router_owner.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';
import '../support/erasure_writer_process.dart';
import 'support/compaction_profile_fixture.dart';

String digest(File file) => sha256.convert(file.readAsBytesSync()).toString();
Future<File> shadow(CompactionProfileFixture f) async {
  final file = File('${f.directory.path}/xveil.store');
  file.createSync(exclusive: true);
  const ManagedFsPlatform().restrictNewFile(file.path);
  file.writeAsBytesSync(File(f.source).readAsBytesSync(), flush: true);
  expect(
    hv.verifySpaceKeys(path: file.path, keys: f.old['child-fixture']!),
    isTrue,
  );
  return file;
}

Future<ProfileStorageRouter> route(
  CompactionProfileFixture f, {
  bool bound = true,
}) => ProfileStorageRouter.open(
  profileDirectory: f.profile,
  legacyPath: bound ? f.source : null,
  legacyFactory: () => HiddenVolumeStorage.async(
    workerSpaceOpener(f.source),
    keysOpener: workerKeysSpaceOpener(f.source),
  ),
);

Future<Map<String, dynamic>> journal(
  CompactionProfileFixture f,
  int n, {
  Map<String, dynamic> Function(Map<String, dynamic>)? rewrite,
}) async {
  final root = ManagedDirectoryCatalog.openExisting(f.profile)!;
  final storage = HiddenVolumeStorage.fromStore(
    ManagedIdentityFiles.openWithKeys(
      root,
      id: f.id(n),
      keys: f.keys[f.id(n)]!,
    ),
  );
  try {
    final bytes = await storage.loadFile(
      ManagedLegacyReferenceRepair.journalFile,
    );
    expect(bytes, isNotNull);
    final value = jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;
    if (rewrite != null) {
      await storage.storeFile(
        ManagedLegacyReferenceRepair.journalFile,
        Uint8List.fromList(utf8.encode(jsonEncode(rewrite(value)))),
      );
    }
    return value;
  } finally {
    await storage.close();
    root.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    test(
      'custom source publication retains Windows durability admission',
      () {},
      skip: 'Windows source-name durability remains unqualified',
    );
    return;
  }
  test(
    'bound custom source publishes while a same-key default shadow stays unchanged',
    () async {
      final f = CompactionProfileFixture(sourceName: 'архив #100%.hv');
      await f.create();
      addTearDown(f.dispose);
      final decoy = await shadow(f), before = digest(File(f.source));
      final decoyBefore = digest(decoy);
      final initial = await route(f);
      await initial.select(const LegacyStorageLocator());
      final owner = ProfileStorageRouterOwner(initial, reopen: () => route(f));
      f.owners.add(owner);
      final result = await owner.compactLegacy(
        legacyPath: f.source,
        authorizations: f.authorizations(),
        credentials: f.credentials(),
        plaintextApproved: {f.id(2)},
        beforePublication: () async {},
      );
      expect(
        result.recovery,
        LegacyReferenceRepairOutcome.publishedReplacement,
      );
      expect(digest(File(f.source)), isNot(before));
      expect(digest(decoy), decoyBefore);
      await owner.close();
      await f.verify(published: true);
    },
  );
  test(
    'ordinary custom-bound managed open does not create an absent hidden source',
    () async {
      final f = CompactionProfileFixture(sourceName: 'absent #%.hv');
      await f.create();
      addTearDown(f.dispose);
      File(f.source).deleteSync();
      final router = await route(f);
      f.owners.add(ProfileStorageRouterOwner(router, reopen: () => route(f)));
      await router.select(
        ManagedStorageLocator(
          id: f.id(1),
          protection: StorageProtection.encrypted,
        ),
      );
      expect(await router.storage.open(password: 'visible-fixture'), isTrue);
      await router.storage.putSetting('without-hidden-source', 'retained');
      expect(
        await router.storage.getSetting('without-hidden-source'),
        'retained',
      );
      expect(File(f.source).existsSync(), isFalse);
      expect(File('${f.directory.path}/xveil.store').existsSync(), isFalse);
    },
  );
  test(
    'wrong configured source cannot consume a custom private journal',
    () async {
      final f = CompactionProfileFixture(sourceName: 'other #%.hv');
      await f.create();
      addTearDown(f.dispose);
      final decoy = await shadow(f);
      final sourceBefore = digest(File(f.source)), decoyBefore = digest(decoy);
      await f.seedRetainedSourceIntents();
      final original = await journal(f, 1);
      expect(original['v'], 2);
      expect(original['source'], f.sourceName);
      final wrong = await route(f, bound: false);
      await wrong.select(
        ManagedStorageLocator(
          id: f.id(1),
          protection: StorageProtection.encrypted,
        ),
      );
      await expectLater(
        wrong.storage.open(password: 'visible-fixture'),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      await wrong.close();
      expect(await journal(f, 1), original);
      expect(digest(File(f.source)), sourceBefore);
      expect(digest(decoy), decoyBefore);
      final correct = await route(f);
      await correct.select(
        ManagedStorageLocator(
          id: f.id(1),
          protection: StorageProtection.encrypted,
        ),
      );
      expect(await correct.storage.open(password: 'visible-fixture'), isTrue);
      await correct.close();
      final root = ManagedDirectoryCatalog.openExclusiveMaintenance(f.profile)!;
      try {
        await ManagedLegacyReferenceRepair.resume(
          owner: root,
          authorizations: f.authorizations(),
          sourceName: f.sourceName,
        );
      } finally {
        root.close();
      }
      await f.verify(published: false);
      expect(digest(decoy), decoyBefore);
    },
  );
  test(
    'v1 journal remains recoverable only as the default source binding',
    () async {
      final f = CompactionProfileFixture();
      await f.create();
      addTearDown(f.dispose);
      await f.seedRetainedSourceIntents();
      await journal(
        f,
        1,
        rewrite: (v) => Map<String, dynamic>.of(v)
          ..remove('source')
          ..['v'] = 1,
      );
      final root = ManagedDirectoryCatalog.openExclusiveMaintenance(f.profile)!;
      try {
        expect(
          await ManagedLegacyReferenceRepair.resume(
            owner: root,
            authorizations: f.authorizations(),
          ),
          LegacyReferenceRepairOutcome.retainedSource,
        );
      } finally {
        root.close();
      }
      await f.verify(published: false);
    },
  );
  for (final invalid in [
    null,
    42,
    '../outside.hv',
    'sub/file.hv',
    'file.hv:stream',
  ]) {
    test(
      'malformed private source binding is retained (case ${invalid.runtimeType}:${invalid.toString().length})',
      () async {
        final f = CompactionProfileFixture(sourceName: 'private.hv');
        await f.create();
        addTearDown(f.dispose);
        await f.seedRetainedSourceIntents();
        final before = await journal(
          f,
          1,
          rewrite: (v) => Map<String, dynamic>.of(v)..['source'] = invalid,
        );
        final stored = await journal(f, 1);
        final sourceBefore = digest(File(f.source));
        final root = ManagedDirectoryCatalog.openExclusiveMaintenance(
          f.profile,
        )!;
        try {
          await expectLater(
            ManagedLegacyReferenceRepair.resume(
              owner: root,
              authorizations: f.authorizations(),
              sourceName: f.sourceName,
            ),
            throwsA(isA<LegacyReferenceRepairFailure>()),
          );
        } finally {
          root.close();
        }
        expect(await journal(f, 1), stored);
        expect(digest(File(f.source)), sourceBefore);
        expect(before['source'], f.sourceName);
      },
    );
  }
  test(
    'router owner rejects a replacement with another source binding',
    () async {
      final f = CompactionProfileFixture();
      await f.create();
      addTearDown(f.dispose);
      var bound = f.source;
      Future<ProfileStorageRouter> opening() => ProfileStorageRouter.open(
        profileDirectory: f.profile,
        legacyPath: bound,
        legacyFactory: () =>
            HiddenVolumeStorage.async(workerSpaceOpener(bound)),
      );
      final owner = ProfileStorageRouterOwner(await opening(), reopen: opening);
      f.owners.add(owner);
      await owner.suspend();
      bound = '${f.directory.path}/other.hv';
      await expectLater(owner.reopen(), throwsStateError);
      expect(owner.isAvailable, isFalse);
      bound = f.source;
      await owner.reopen();
      expect(owner.isAvailable, isTrue);
      await owner.close();
    },
  );
  for (final phase in ['prepared', 'published-unrepaired', 'reply-pending']) {
    test(
      'cold selected recovery binds custom source after actual process death ($phase)',
      () async {
        final f = CompactionProfileFixture(sourceName: 'cold #%.hv');
        await f.create();
        addTearDown(f.dispose);
        final decoy = await shadow(f), decoyBefore = digest(decoy);
        final cap = File('${f.directory.path}/capabilities-private.json')
          ..createSync(exclusive: true);
        const ManagedFsPlatform().restrictNewFile(cap.path);
        cap.writeAsStringSync(
          jsonEncode({
            'sourceName': f.sourceName,
            'masters': {
              for (final e in f.keys.entries)
                e.key.value: base64.encode(e.value),
            },
            'legacy': {
              for (final e in f.old.entries) e.key: base64.encode(e.value),
            },
            'plaintext': [f.id(2).value],
          }),
          flush: true,
        );
        await killErasureWriter(
          f.directory.path,
          phase,
          () {},
          script: 'test/native/managed_legacy_compaction_worker_writer.dart',
        );
        // Ordinary bootstrap and selected authenticated open, not a direct repair seam.
        final boot = await bootstrapManagedProfile(
          profileDirectory: f.profile,
          legacyPath: f.source,
          legacyFactory: () =>
              HiddenVolumeStorage.async(workerSpaceOpener(f.source)),
        );
        expect(boot.erasurePending, isFalse);
        final owner = boot.owner!;
        f.owners.add(owner);
        for (final n in [1, 2]) {
          await owner.router.select(
            ManagedStorageLocator(
              id: f.id(n),
              protection: n == 1
                  ? StorageProtection.encrypted
                  : StorageProtection.unencrypted,
            ),
          );
          expect(
            await owner.router.storage.open(
              password: n == 1 ? 'visible-fixture' : '',
            ),
            isTrue,
          );
        }
        await owner.close();
        await f.verify(published: phase != 'prepared');
        expect(digest(decoy), decoyBefore);
      },
    );
  }
}
