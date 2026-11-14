@Timeout(Duration(minutes: 3))
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
import 'package:xveil/data/storage/on_disk_blob_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

class _PublicationFault extends ManagedFsPlatform {
  _PublicationFault(this.after);
  final bool after;
  bool published = false;
  @override
  bool publishDirectoryNoReplace(String from, String to) {
    if (to.endsWith('/${ManagedRootErasure.pendingName}') && !after) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    final result = super.publishDirectoryNoReplace(from, to);
    if (to.endsWith('/${ManagedRootErasure.pendingName}')) published = result;
    return result;
  }

  @override
  void syncDirectory(String path) {
    if (published) throw const ManagedFsFailure(ManagedFsFailureKind.io);
    super.syncDirectory(path);
  }
}

class _RawPublicationFailure extends ManagedFsPlatform {
  @override
  bool publishDirectoryNoReplace(String from, String to) {
    if (to.endsWith('/${ManagedRootErasure.pendingName}')) {
      throw FileSystemException('synthetic failure', to);
    }
    return super.publishDirectoryNoReplace(from, to);
  }
}

void main() {
  late Directory fixture;
  late String profile;
  final owners = <ManagedDirectoryCatalog>[];
  final erasures = <ManagedRootErasure>[];
  Uint8List b(String s) => Uint8List.fromList(s.codeUnits);
  Map<String, String> snapshot(String path) => {
    for (final f in Directory(
      path,
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      f.path.substring(path.length): sha256
          .convert(f.readAsBytesSync())
          .toString(),
  };
  ManagedDirectoryCatalog root({
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) {
    final owner = ManagedDirectoryCatalog.openExclusiveMaintenance(
      profile,
      fs: fs,
    )!;
    owners.add(owner);
    return owner;
  }

  ManagedRootErasure recovery() {
    final owner = ManagedRootErasure.openPending(profile);
    erasures.add(owner);
    return owner;
  }

  String getPlanPath() =>
      '$profile/${StorageProfileCoordinator.directoryName}/${ManagedRootErasure.pendingName}/plan.json';
  Future<void> prepare() async {
    final owner = root();
    await ManagedRootErasure.prepare(owner);
    owner.close();
  }

  Future<void> retire(ManagedIdentityCatalog catalog) async {
    expect(catalog.identities.map((e) => e.id.value).toSet(), {
      '1' * 32,
      '2' * 32,
    });
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('xveil-root-erasure-');
    profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    final owner = ManagedDirectoryCatalog.createOrOpen(profile);
    try {
      for (final id in ['1' * 32, '2' * 32]) {
        final store = ManagedIdentityFiles.createUnencrypted(
          owner,
          id: ManagedIdentityId(id),
        );
        try {
          store.commit([PutOp(1, b('synthetic key'), b('synthetic payload'))]);
        } finally {
          store.close();
        }
      }
    } finally {
      owner.close();
    }
  });
  tearDown(() {
    for (final e in erasures) {
      e.close();
    }
    erasures.clear();
    for (final o in owners) {
      o.close();
    }
    owners.clear();
    fixture.deleteSync(recursive: true);
  });

  test(
    'scope refusal preserves all payloads; retry removes only the planned root and retains recovery',
    () async {
      final legacy = File('$profile/legacy-fixture')
        ..writeAsStringSync('preserved hidden fixture');
      await OnDiskBlobStore(
        Directory('$profile/identities/${'1' * 32}/blobs'),
      ).storePiece(
        'AbcdEFgh_123-xy9',
        Uint8List(32),
        0,
        b('encrypted synthetic blob piece'),
      );
      final before = snapshot('$profile/identities');
      await prepare();
      expect(snapshot('$profile/identities'), before);
      final intent = recovery();
      await expectLater(
        intent.removeManagedFiles(
          retireScopes: (_) async {
            throw StateError('synthetic OS refusal');
          },
        ),
        throwsStateError,
      );
      expect(snapshot('$profile/identities'), before);
      final publicPlan =
          jsonDecode(File(getPlanPath()).readAsStringSync()) as Map;
      expect(publicPlan.keys.toSet(), {
        'v',
        'profile',
        'coordinator',
        'catalog',
        'entries',
      });
      expect(
        File(getPlanPath()).readAsStringSync(),
        isNot(contains('synthetic payload')),
      );
      await intent.removeManagedFiles(retireScopes: retire);
      expect(Directory('$profile/identities').existsSync(), isFalse);
      expect(File(getPlanPath()).existsSync(), isTrue);
      expect(legacy.readAsStringSync(), 'preserved hidden fixture');
      intent.close();
      expect(
        () => ManagedDirectoryCatalog.createOrOpen(profile),
        throwsA(
          isA<ManagedFsFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedFsFailureKind.erasurePending,
          ),
        ),
      );
      expect(
        () => ManagedDirectoryCatalog.openExisting(profile),
        throwsA(isA<ManagedFsFailure>()),
      );
      await expectLater(
        ManagedCatalogWorker.open(profile),
        throwsA(isA<ManagedWorkerFailure>()),
      );
      final resumed = recovery();
      await resumed.removeManagedFiles(retireScopes: retire);
    },
  );

  test(
    'prepare requires exclusive admission and rejects unknown content without publishing',
    () async {
      final shared = ManagedDirectoryCatalog.openExisting(profile)!;
      try {
        await expectLater(
          ManagedRootErasure.prepare(shared),
          throwsA(isA<ManagedLeaseFailure>()),
        );
      } finally {
        shared.close();
      }
      final owner = root();
      final foreign = File('${owner.directory}/unknown-fixture')
        ..writeAsBytesSync([9, 8, 7]);
      final before = snapshot(owner.directory);
      await expectLater(
        ManagedRootErasure.prepare(owner),
        throwsA(isA<ManagedFsFailure>()),
      );
      expect(snapshot(owner.directory), before);
      expect(foreign.readAsBytesSync(), [9, 8, 7]);
      expect(File(getPlanPath()).existsSync(), isFalse);
    },
  );

  test(
    'replacement is refused before the first unlink and original object can be restored',
    () async {
      await prepare();
      final path = '$profile/identities/${'1' * 32}/data.store';
      File(path).renameSync('$profile/saved-payload');
      File(path).writeAsBytesSync([8, 7, 6]);
      final before = snapshot('$profile/identities');
      expect(() => recovery(), throwsA(isA<ManagedFsFailure>()));
      expect(snapshot('$profile/identities'), before);
      File(path).deleteSync();
      File('$profile/saved-payload').renameSync(path);
      await recovery().removeManagedFiles(retireScopes: retire);
    },
  );

  test(
    'content inserted during scope cleanup refuses before any planned unlink',
    () async {
      await prepare();
      final intent = recovery();
      final before = snapshot('$profile/identities');
      final foreign = File('$profile/identities/${'1' * 32}/foreign-fixture');
      await expectLater(
        intent.removeManagedFiles(
          retireScopes: (_) async {
            foreign.writeAsBytesSync([3, 2, 1]);
          },
        ),
        throwsA(isA<ManagedFsFailure>()),
      );
      foreign.deleteSync();
      expect(snapshot('$profile/identities'), before);
      await intent.removeManagedFiles(retireScopes: retire);
    },
  );

  test(
    'accepted scope cleanup retains exclusive ownership and close cannot race it',
    () async {
      await prepare();
      final intent = recovery();
      final entered = Completer<void>(), release = Completer<void>();
      final operation = intent.removeManagedFiles(
        retireScopes: (_) async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      try {
        expect(() => intent.close(), throwsA(isA<ManagedLeaseFailure>()));
        await expectLater(
          intent.removeManagedFiles(retireScopes: retire),
          throwsA(isA<ManagedLeaseFailure>()),
        );
        expect(
          () => ManagedRootErasure.openPending(profile),
          throwsA(
            predicate(
              (Object? e) =>
                  e is ManagedLeaseFailure &&
                      e.kind == ManagedLeaseFailureKind.busy ||
                  e is ManagedSqliteFailure && e.sqliteCode == 5,
            ),
          ),
        );
      } finally {
        release.complete();
        await operation;
      }
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );

  test(
    'malformed, foreign and traversal plans are preserved without deleting payloads',
    () async {
      await prepare();
      final file = File(getPlanPath());
      final bytes = file.readAsBytesSync();
      final before = snapshot('$profile/identities');
      for (final change in <void Function(Map<String, dynamic>)>[
        (r) {
          r['v'] = 1.0;
        },
        (r) {
          r['unknown'] = true;
        },
        (r) {
          r['profile'] = 'foreign-profile';
        },
        (r) {
          r['coordinator'] = 'foreign-coordinator';
        },
        (r) {
          (r['entries'] as List)[1][0] = '../outside';
        },
        (r) {
          (r['entries'] as List).add((r['entries'] as List).first);
        },
        (r) {
          (r['entries'] as List).removeAt(0);
        },
        (r) {
          (r['entries'] as List)[1][1] = 'changed-object';
        },
      ]) {
        final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        change(raw);
        file.writeAsStringSync(jsonEncode(raw), flush: true);
        expect(() => recovery(), throwsA(isA<ManagedFsFailure>()));
        expect(snapshot('$profile/identities'), before);
      }
      file.writeAsBytesSync(List.filled(8 * 1024 * 1024 + 1, 0), flush: true);
      expect(() => recovery(), throwsA(isA<ManagedFsFailure>()));
      expect(snapshot('$profile/identities'), before);
      file.writeAsBytesSync(bytes, flush: true);
      await recovery().removeManagedFiles(retireScopes: retire);
    },
  );

  for (final after in [false, true]) {
    test(
      'publication failure after=$after leaves either no intent or recoverable durable refusal',
      () async {
        final owner = root(fs: _PublicationFault(after));
        final before = snapshot(owner.directory);
        await expectLater(
          ManagedRootErasure.prepare(owner),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(snapshot(owner.directory), before);
        owner.close();
        expect(File(getPlanPath()).existsSync(), after);
        if (after) {
          await recovery().removeManagedFiles(retireScopes: retire);
        } else {
          final ordinary = ManagedDirectoryCatalog.openExisting(profile)!;
          ordinary.close();
        }
      },
    );
  }

  test(
    'encrypted root is removed without decrypting payloads or persisting its password',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final owner = ManagedDirectoryCatalog.openExisting(profile)!;
      try {
        final store = ManagedIdentityFiles.createEncrypted(
          owner,
          id: ManagedIdentityId('3' * 32),
          password: b('only a synthetic erasure password'),
        );
        store.commit([PutOp(1, b('key'), b('encrypted fixture value'))]);
        store.close();
      } finally {
        owner.close();
      }
      await prepare();
      expect(
        File(getPlanPath()).readAsStringSync(),
        isNot(contains('synthetic erasure password')),
      );
      await recovery().removeManagedFiles(
        retireScopes: (catalog) async {
          expect(catalog.identities, hasLength(3));
        },
      );
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );

  test('raw filesystem publication failure exposes no local path', () async {
    final owner = root(fs: _RawPublicationFailure());
    final before = snapshot(owner.directory);
    await expectLater(
      ManagedRootErasure.prepare(owner),
      throwsA(
        isA<ManagedFsFailure>()
            .having((e) => e.kind, 'kind', ManagedFsFailureKind.io)
            .having(
              (e) => e.toString(),
              'safe diagnostic',
              isNot(contains(fixture.path)),
            ),
      ),
    );
    expect(snapshot(owner.directory), before);
    expect(File(getPlanPath()).existsSync(), isFalse);
  });

  test(
    'raw filesystem refusal after a late insertion preserves intent without exposing paths',
    () async {
      await prepare();
      final intent = recovery();
      final foreign = File(
        '$profile/identities/${'1' * 32}/unexpected-after-unlink',
      );
      await expectLater(
        intent.removeManagedFiles(
          retireScopes: retire,
          afterUnlink: (path) async {
            if (path == 'identities/${'1' * 32}/identity.meta.lock') {
              foreign.writeAsBytesSync([7, 8, 9]);
            }
          },
        ),
        throwsA(
          isA<ManagedFsFailure>()
              .having((e) => e.kind, 'kind', ManagedFsFailureKind.io)
              .having(
                (e) => e.toString(),
                'safe diagnostic',
                isNot(contains(fixture.path)),
              ),
        ),
      );
      expect(foreign.readAsBytesSync(), [7, 8, 9]);
      expect(File(getPlanPath()).existsSync(), isTrue);
      foreign.deleteSync();
      await intent.removeManagedFiles(retireScopes: retire);
      expect(Directory('$profile/identities').existsSync(), isFalse);
    },
  );
}
