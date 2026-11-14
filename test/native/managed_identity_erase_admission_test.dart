@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/domain/identity_erase_review.dart';
import 'package:xveil/domain/storage_protection.dart';

void main() {
  late Directory fixture;
  late String profile;
  final workers = <ManagedCatalogWorker>[];
  final id = ManagedIdentityId('1' * 32), sibling = ManagedIdentityId('2' * 32);
  Uint8List b(String s) => Uint8List.fromList(s.codeUnits);
  Matcher kind(ManagedWorkerFailureKind expected) => throwsA(
    isA<ManagedWorkerFailure>().having((e) => e.kind, 'kind', expected),
  );
  Map<String, String> snapshot(String path) => {
    for (final file in Directory(
      path,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      file.path.substring(path.length): sha256
          .convert(file.readAsBytesSync())
          .toString(),
  };
  Future<ManagedCatalogWorker> worker() async {
    final result = await ManagedCatalogWorker.open(profile);
    workers.add(result);
    return result;
  }

  Uint8List create(StorageProtection mode) {
    final root = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      final store = mode == StorageProtection.encrypted
          ? ManagedIdentityFiles.createEncrypted(
              root,
              id: id,
              password: b('synthetic erasure password'),
            )
          : ManagedIdentityFiles.createUnencrypted(root, id: id);
      late Uint8List keys;
      try {
        store.commit([PutOp(1, b('key'), b('fixture payload'))]);
        keys = store.exportKeys();
      } finally {
        store.close();
      }
      final other = ManagedIdentityFiles.createUnencrypted(root, id: sibling);
      try {
        other.commit([PutOp(1, b('sibling key'), b('keep sibling'))]);
      } finally {
        other.close();
      }
      return keys;
    } finally {
      root.close();
    }
  }

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-identity-admission-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
  });
  tearDown(() async {
    for (final w in workers) {
      await w.close();
    }
    workers.clear();
    fixture.deleteSync(recursive: true);
  });

  for (final mode in [
    StorageProtection.encrypted,
    StorageProtection.unencrypted,
  ]) {
    test(
      '${mode.name}: authentication precedes OS admission and refusal preserves payloads/catalog',
      () async {
        final keys = create(mode),
            entry = ManagedIdentityEntry(id: id, protection: mode);
        final path = ManagedIdentityLayout(profile).directory(id);
        final before = snapshot(path),
            otherBefore = snapshot(
              ManagedIdentityLayout(profile).directory(sibling),
            );
        final actor = await worker();
        var calls = 0;
        try {
          await expectLater(
            actor.erase(
              entry,
              keys: Uint8List(64),
              beforeErase: () async {
                calls++;
              },
            ),
            kind(ManagedWorkerFailureKind.authentication),
          );
          expect(calls, 0);
          expect(snapshot(path), before);
          await expectLater(
            actor.erase(
              entry,
              keys: keys,
              beforeErase: () async {
                calls++;
                throw StateError('synthetic private OS refusal');
              },
            ),
            kind(ManagedWorkerFailureKind.backend),
          );
          expect(calls, 1);
          expect(snapshot(path), before);
          expect(
            (await actor.snapshot()).snapshot.catalog.identities,
            hasLength(2),
          );
          await actor.erase(
            entry,
            keys: keys,
            beforeErase: () async {
              calls++;
            },
          );
          expect(calls, 2);
          expect(Directory(path).existsSync(), isFalse);
          expect(
            snapshot(ManagedIdentityLayout(profile).directory(sibling)),
            otherBefore,
          );
        } finally {
          keys.fillRange(0, keys.length, 0);
        }
      },
    );
    test(
      '${mode.name}: accepted UI admission retains native role and queued close until acknowledged',
      () async {
        final keys = create(mode),
            entry = ManagedIdentityEntry(id: id, protection: mode);
        final path = ManagedIdentityLayout(profile).directory(id),
            before = snapshot(ManagedIdentityLayout(profile).directory(id));
        final actor = await worker(),
            entered = Completer<void>(),
            release = Completer<void>();
        final deleting = actor.erase(
          entry,
          keys: keys,
          beforeErase: () async {
            entered.complete();
            await release.future;
          },
        );
        await entered.future;
        final other = ManagedDirectoryCatalog.openExisting(profile)!;
        var closed = false;
        final closing = actor.close().then((_) => closed = true);
        try {
          expect(snapshot(path), before);
          expect(
            () => ManagedIdentityFiles.openWithKeys(other, id: id, keys: keys),
            throwsA(
              isA<ManagedIdentityFailure>().having(
                (e) => e.kind,
                'kind',
                ManagedIdentityFailureKind.busy,
              ),
            ),
          );
          await Future<void>(() {});
          expect(closed, isFalse);
        } finally {
          release.complete();
          await deleting;
          await closing;
          other.close();
          keys.fillRange(0, keys.length, 0);
        }
        expect(closed, isTrue);
        expect(Directory(path).existsSync(), isFalse);
      },
    );
    test(
      '${mode.name}: read-only/invalid review cannot invoke cleanup and refusal leaves approved unknown entries',
      () async {
        final keys = create(mode),
            entry = ManagedIdentityEntry(id: id, protection: mode);
        final path = ManagedIdentityLayout(profile).directory(id);
        final foreign = File('$path/approved-fixture')
          ..writeAsBytesSync([8, 9, 10]);
        final before = snapshot(path), actor = await worker();
        var calls = 0;
        try {
          await expectLater(
            actor.erase(
              entry,
              keys: keys,
              beforeErase: () async {
                calls++;
              },
            ),
            kind(ManagedWorkerFailureKind.ambiguous),
          );
          expect(calls, 0);
          final review = await actor.reviewErasure(entry, keys);
          expect(review.files, 1);
          expect(snapshot(path), before);
          await expectLater(
            actor.erase(
              entry,
              keys: keys,
              review: IdentityEraseReview(
                token: 'synthetic-other-token',
                files: review.files,
                directories: review.directories,
                bytes: review.bytes,
              ),
              beforeErase: () async {
                calls++;
              },
            ),
            kind(ManagedWorkerFailureKind.ambiguous),
          );
          expect(calls, 0);
          await expectLater(
            actor.erase(
              entry,
              keys: keys,
              review: review,
              beforeErase: () async {
                calls++;
                throw StateError('synthetic refusal');
              },
            ),
            kind(ManagedWorkerFailureKind.backend),
          );
          expect(calls, 1);
          expect(snapshot(path), before);
          expect(foreign.readAsBytesSync(), [8, 9, 10]);
          final fresh = await actor.reviewErasure(entry, keys);
          await actor.erase(
            entry,
            keys: keys,
            review: fresh,
            beforeErase: () async {
              calls++;
            },
          );
          expect(calls, 2);
          expect(Directory(path).existsSync(), isFalse);
        } finally {
          keys.fillRange(0, keys.length, 0);
        }
      },
    );
  }
  test(
    'absent-root retry cleans its explicit OS scope without manufacturing a catalog',
    () async {
      final actor = await worker(),
          entry = ManagedIdentityEntry(
            id: id,
            protection: StorageProtection.encrypted,
          );
      var calls = 0;
      final result = await actor.erase(
        entry,
        beforeErase: () async {
          calls++;
        },
      );
      expect(calls, 1);
      expect(result.catalog.identities, isEmpty);
      expect(Directory('$profile/identities').existsSync(), isFalse);
      await expectLater(
        actor.erase(
          entry,
          review: const IdentityEraseReview(
            token: 'synthetic',
            files: 0,
            directories: 0,
            bytes: 0,
          ),
          beforeErase: () async {
            calls++;
          },
        ),
        kind(ManagedWorkerFailureKind.missing),
      );
      expect(calls, 1);
      await expectLater(
        actor.erase(
          entry,
          beforeErase: () async {
            calls++;
            throw StateError('synthetic refusal');
          },
        ),
        kind(ManagedWorkerFailureKind.backend),
      );
      expect(calls, 2);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );
}
