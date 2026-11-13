@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_keybox.dart';
import 'package:xveil/data/storage/managed_store_tag.dart';
import 'package:xveil/data/storage/managed_reclaim_budget.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/storage_protection.dart';

import 'support/managed_lease_process_probe.dart';

Uint8List b(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  late Directory fixture;
  late String profile;
  final stores = <AsyncKvLogStore>[];
  final id = ManagedIdentityId('1' * 32);
  final second = ManagedIdentityId('2' * 32);
  const fs = ManagedFsPlatform();

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync(
      'xveil-managed-files-native-',
    );
    profile = '${fixture.path}/profile';
    expect(fs.createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    stores.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'worker creation snapshots mutable initial data and owns a real lease',
    () async {
      final key = b('fixture-key');
      final value = b('original-value');
      final operations = <KvLogOp>[PutOp(1, key, value)];
      final opening = ManagedWorkerIdentity.createUnencrypted(
        profileDirectory: profile,
        id: id,
        initial: operations,
      );
      key.fillRange(0, key.length, 0);
      value.fillRange(0, value.length, 0);
      operations.clear();
      final worker = await opening;
      stores.add(worker);
      expect(await worker.get(1, b('fixture-key')), b('original-value'));
      await worker.commit([
        AppendLogOp(5, 7, b('first')),
        AppendLogOp(5, 8, b('second')),
      ]);
      expect(
        await worker.readLogGroups(5, [
          (ids: [7, 8], maxBytes: 20),
        ]),
        [b('firstsecond')],
      );
      expect(await worker.commitSeq(), greaterThan(1));
      expect(await worker.commitRoots(), contains(await worker.commitSeq()));
      final layout = ManagedIdentityLayout(profile);
      expect(
        await probeManagedIdentityLease(
          layout.leasePath(id),
          protection: StorageProtection.unencrypted,
        ),
        'busy',
      );
      await worker.close();
      expect(
        await probeManagedIdentityLease(
          layout.leasePath(id),
          protection: StorageProtection.unencrypted,
        ),
        'opened',
      );
      final root = ManagedDirectoryCatalog.openExisting(profile)!;
      try {
        final reopened = ManagedIdentityFiles.openUnencrypted(root, id: id);
        try {
          expect(reopened.get(1, b('fixture-key')), b('original-value'));
          expect(reopened.readLog(5, 8), b('second'));
        } finally {
          reopened.close();
        }
      } finally {
        root.close();
      }
    },
  );

  test(
    'both real modes work through the domain facade and cold key reopen',
    () async {
      for (final protection in [
        StorageProtection.encrypted,
        StorageProtection.unencrypted,
      ]) {
        final localId = protection == StorageProtection.encrypted ? id : second;
        final password = b('synthetic-managed-password');
        final original = Uint8List.fromList(password);
        final worker = protection == StorageProtection.encrypted
            ? await ManagedWorkerIdentity.createEncrypted(
                profileDirectory: profile,
                id: localId,
                password: password,
              )
            : await ManagedWorkerIdentity.createUnencrypted(
                profileDirectory: profile,
                id: localId,
              );
        stores.add(worker);
        expect(password, original);
        final storage = HiddenVolumeStorage.fromAsyncStore(worker);
        await storage.saveProfile(
          UserProfile(displayName: 'Synthetic ${protection.name}'),
        );
        await storage.storeFile('fixture-file', b('managed fixture bytes'));
        final keys = await storage.exportSpaceKeys();
        final before = await worker.commitSeq();
        final rootHash = (await worker.commitRoots())[before];
        final report = await ManagedWorkerIdentity.reclaim(worker, force: true);
        expect(report.changed, protection == StorageProtection.encrypted);
        expect(await worker.commitSeq(), before + (report.changed ? 2 : 0));
        expect((await worker.commitRoots())[before], rootHash);
        expect(await worker.exportKeys(), keys);
        await storage.close();

        final reopened = HiddenVolumeStorage.async(
          ({required password, required create}) async =>
              protection == StorageProtection.encrypted
              ? ManagedWorkerIdentity.openEncrypted(
                  profileDirectory: profile,
                  id: localId,
                  password: password,
                )
              : ManagedWorkerIdentity.openUnencrypted(
                  profileDirectory: profile,
                  id: localId,
                ),
          keysOpener: (keys) => ManagedWorkerIdentity.openWithKeys(
            profileDirectory: profile,
            id: localId,
            protection: protection,
            keys: keys,
          ),
        );
        expect(await reopened.openWithKeys(keys), isTrue);
        expect(
          (await reopened.loadProfile())?.displayName,
          'Synthetic ${protection.name}',
        );
        expect(
          await reopened.loadFile('fixture-file'),
          b('managed fixture bytes'),
        );
        await reopened.close();
        expect(
          await reopened.open(password: 'synthetic-managed-password'),
          isTrue,
        );
        expect(
          (await reopened.loadProfile())?.displayName,
          'Synthetic ${protection.name}',
        );
        await reopened.close();
        keys.fillRange(0, keys.length, 0);
      }
    },
  );

  test(
    'failed credentials and mode selection preserve files and release failed opens',
    () async {
      final password = b('synthetic-managed-password');
      final encrypted = await ManagedWorkerIdentity.createEncrypted(
        profileDirectory: profile,
        id: id,
        password: password,
        initial: [PutOp(1, b('kept'), b('ciphertext fixture value'))],
      );
      stores.add(encrypted);
      final keys = await encrypted.exportKeys();
      await encrypted.close();
      final plain = await ManagedWorkerIdentity.createUnencrypted(
        profileDirectory: profile,
        id: second,
      );
      stores.add(plain);
      final plainKeys = await plain.exportKeys();
      await plain.close();
      final layout = ManagedIdentityLayout(profile);
      final paths = [
        layout.keyboxPath(id),
        layout.contentPath(id),
        layout.maintenancePath(id),
        layout.dataPath(second),
      ];
      final snapshots = {
        for (final path in paths) path: File(path).readAsBytesSync(),
      };
      Future<void> rejects(
        Future<WorkerKvLogStore> work,
        ManagedWorkerFailureKind kind,
      ) async {
        await expectLater(
          work,
          throwsA(
            isA<ManagedWorkerFailure>()
                .having((e) => e.kind, 'kind', kind)
                .having(
                  (e) => e.toString().contains(profile),
                  'path leak',
                  isFalse,
                )
                .having(
                  (e) => e.toString().contains(id.value),
                  'ID leak',
                  isFalse,
                ),
          ),
        );
      }

      await rejects(
        ManagedWorkerIdentity.openEncrypted(
          profileDirectory: profile,
          id: id,
          password: b('wrong-fixture'),
        ),
        ManagedWorkerFailureKind.authentication,
      );
      await rejects(
        ManagedWorkerIdentity.openWithKeys(
          profileDirectory: profile,
          id: id,
          protection: StorageProtection.encrypted,
          keys: Uint8List(64),
        ),
        ManagedWorkerFailureKind.authentication,
      );
      await rejects(
        ManagedWorkerIdentity.openUnencrypted(
          profileDirectory: profile,
          id: id,
        ),
        ManagedWorkerFailureKind.mode,
      );
      await rejects(
        ManagedWorkerIdentity.openWithKeys(
          profileDirectory: profile,
          id: second,
          protection: StorageProtection.encrypted,
          keys: plainKeys,
        ),
        ManagedWorkerFailureKind.mode,
      );
      for (final path in paths) {
        expect(File(path).readAsBytesSync(), snapshots[path]);
      }
      final pending = ManagedWorkerIdentity.openEncrypted(
        profileDirectory: profile,
        id: id,
        password: password,
      );
      password.fillRange(0, password.length, 0);
      final valid = await pending;
      stores.add(valid);
      expect(await valid.get(1, b('kept')), b('ciphertext fixture value'));
      await valid.close();
      keys.fillRange(0, keys.length, 0);
      plainKeys.fillRange(0, plainKeys.length, 0);
    },
  );

  test(
    'another worker cannot share an active identity; existing owner stays usable',
    () async {
      final worker = await ManagedWorkerIdentity.createUnencrypted(
        profileDirectory: profile,
        id: id,
      );
      stores.add(worker);
      final independent = await ManagedWorkerIdentity.createEncrypted(
        profileDirectory: profile,
        id: second,
        password: b('other synthetic password'),
        initial: [PutOp(1, b('owner'), b('independent-encrypted'))],
      );
      stores.add(independent);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          ManagedWorkerIdentity.openUnencrypted(
            profileDirectory: profile,
            id: id,
          ),
          throwsA(
            isA<ManagedWorkerFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedWorkerFailureKind.busy,
            ),
          ),
        );
      }
      await worker.commit([PutOp(1, b('owner'), b('still-active'))]);
      expect(await worker.get(1, b('owner')), b('still-active'));
      await worker.close();
      expect(await independent.get(1, b('owner')), b('independent-encrypted'));
      await independent.commit([
        PutOp(1, b('survivor'), b('after-peer-close')),
      ]);
      final successor = await ManagedWorkerIdentity.openUnencrypted(
        profileDirectory: profile,
        id: id,
      );
      stores.add(successor);
      expect(await successor.get(1, b('owner')), b('still-active'));
      await successor.close();
      expect(await independent.get(1, b('survivor')), b('after-peer-close'));
      await independent.close();
    },
  );

  test(
    'automatic worker check really shrinks a garbage-seeded encrypted file',
    () async {
      final created = await ManagedWorkerIdentity.createEncrypted(
        profileDirectory: profile,
        id: id,
        password: b('synthetic auto reclaim password'),
      );
      stores.add(created);
      final keys = await created.exportKeys();
      await created.close();
      final layout = ManagedIdentityLayout(profile);
      final keyboxBytes = File(layout.keyboxPath(id)).readAsBytesSync();
      // Construct a synthetic pre-existing bloated source, while every managed
      // owner is closed. No original application records/host anchor exist.
      final rawBox = hv.HvSpace.openWithKeys(
        path: layout.keyboxPath(id),
        keys: keys,
      )..cancelDeferredVacuum();
      final box = ManagedKeybox.openOwned(HvKvLogStore(rawBox), identity: id);
      final contentPassword = box.copyContentPassword();
      try {
        final source = HvKvLogStore(
          hv.HvSpace.open(
            path: layout.contentPath(id),
            password: contentPassword,
          )..cancelDeferredVacuum(),
        );
        late final ManagedStoreTag tag;
        try {
          tag = ManagedStoreTag.read(
            source,
            identity: id,
            role: ManagedStoreRole.content,
          );
        } finally {
          source.close();
        }
        final staged = '${layout.directory(id)}/fixture-bloated.hv';
        final bloated = hv.HvSpace.create(
          path: staged,
          password: contentPassword,
          argon: hv.ArgonPreset.defaults,
          initialGarbageChunks: 16384,
        );
        try {
          bloated.setPaddingPolicy(hv.PaddingPreset.none);
          HvKvLogStore(
            bloated,
          ).commit([tag.putOp(), PutOp(1, b('seed'), b('kept fixture data'))]);
        } finally {
          bloated.close();
        }
        File(staged).renameSync(layout.contentPath(id));
      } finally {
        contentPassword.fillRange(0, contentPassword.length, 0);
        box.close();
      }
      final beforeBytes = File(layout.contentPath(id)).lengthSync();
      expect(
        beforeBytes,
        greaterThanOrEqualTo(ManagedReclaimBudget.contentFloor),
      );
      final worker = await ManagedWorkerIdentity.openWithKeys(
        profileDirectory: profile,
        id: id,
        protection: StorageProtection.encrypted,
        keys: keys,
      );
      stores.add(worker);
      for (var i = 1; i <= 127; i++) {
        await worker.commit([PutOp(1, b('counter'), b('$i'))]);
      }
      final anchorSeq = await worker.commitSeq();
      final anchorRoot = (await worker.commitRoots())[anchorSeq];
      final committed = await worker.commit([PutOp(1, b('counter'), b('128'))]);
      expect(committed, anchorSeq + 1);
      // This read queues behind automatic maintenance and proves reattachment.
      expect(await worker.get(1, b('counter')), b('128'));
      expect(await worker.get(1, b('seed')), b('kept fixture data'));
      final afterBytes = File(layout.contentPath(id)).lengthSync();
      expect(afterBytes, lessThan(beforeBytes ~/ 2));
      expect(await worker.commitSeq(), committed + 2);
      expect(
        checkRollbackAnchor(
          anchorSeq: anchorSeq,
          anchorRoot: anchorRoot,
          currentSeq: await worker.commitSeq(),
          history: await worker.commitHistory(),
          roots: await worker.commitRoots(),
        ).verdict,
        AnchorVerdict.clean,
      );
      expect(await worker.hardeningWarning(), isNull);
      expect((await ManagedWorkerIdentity.reclaim(worker)).changed, isFalse);
      expect(await worker.exportKeys(), keys);
      expect(File(layout.keyboxPath(id)).readAsBytesSync(), keyboxBytes);
      await worker.close();
      final cold = await ManagedWorkerIdentity.openWithKeys(
        profileDirectory: profile,
        id: id,
        protection: StorageProtection.encrypted,
        keys: keys,
      );
      stores.add(cold);
      expect(await cold.get(1, b('counter')), b('128'));
      expect(await cold.get(1, b('seed')), b('kept fixture data'));
      await cold.close();
      keys.fillRange(0, keys.length, 0);
    },
  );

  test(
    'missing and hidden requests cannot bootstrap a plaintext fallback',
    () async {
      await expectLater(
        ManagedWorkerIdentity.openUnencrypted(
          profileDirectory: profile,
          id: id,
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
      expect(
        () => ManagedWorkerIdentity.openWithKeys(
          profileDirectory: profile,
          id: id,
          protection: StorageProtection.hidden,
          keys: Uint8List(64),
        ),
        throwsArgumentError,
      );
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );

  test(
    'explicit resume is idempotent and reserved namespace errors stay bounded',
    () async {
      final password = b('synthetic-managed-password');
      final initial = await ManagedWorkerIdentity.createEncrypted(
        profileDirectory: profile,
        id: id,
        password: password,
      );
      stores.add(initial);
      final keys = await initial.exportKeys();
      await initial.close();
      final resumed = await ManagedWorkerIdentity.resumeEncrypted(
        profileDirectory: profile,
        id: id,
        password: password,
      );
      stores.add(resumed);
      final before = await resumed.commitSeq();
      await expectLater(
        resumed.commit([
          PutOp(1, b('atomic'), b('must not commit')),
          PutOp(254, b('role'), b('forbidden')),
        ]),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      expect(await resumed.commitSeq(), before);
      expect(await resumed.get(1, b('atomic')), isNull);
      expect(await resumed.exportKeys(), keys);
      await resumed.close();
      final root = ManagedDirectoryCatalog.openExisting(profile)!;
      try {
        expect(root.snapshot().revision, 1);
        expect(root.snapshot().catalog.identities.length, 1);
      } finally {
        root.close();
      }
      keys.fillRange(0, keys.length, 0);
    },
  );
}
