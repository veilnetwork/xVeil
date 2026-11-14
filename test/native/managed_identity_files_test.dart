@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

import 'support/managed_lease_process_probe.dart';

Uint8List b(String value) => Uint8List.fromList(utf8.encode(value));

enum _Cut { beforePublish, afterPublish, catalogBusy, afterRegister }

class _FactoryFault extends ManagedFsPlatform {
  _FactoryFault(this.cut);
  final _Cut cut;
  bool armed = false;
  ManagedSqliteConnection? blocker;
  @override
  bool publishDirectoryNoReplace(String source, String destination) {
    final identity = RegExp(r'[0-9a-f]{32}$').hasMatch(destination);
    if (armed && identity && cut == _Cut.beforePublish) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    final result = super.publishDirectoryNoReplace(source, destination);
    if (armed && identity && result && cut == _Cut.afterPublish) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    if (armed && identity && result && cut == _Cut.catalogBusy) {
      final path = File.fromUri(
        Directory(destination).parent.uri.resolve('catalog.sqlite3'),
      ).path;
      blocker = ManagedSqliteConnection.openUnencrypted(path);
      blocker!.use((db) => db.execute('BEGIN IMMEDIATE'));
    }
    return result;
  }

  @override
  ManagedPathWitness inspect(String path) {
    final result = super.inspect(path);
    if (armed &&
        cut == _Cut.afterRegister &&
        path.endsWith('catalog.sqlite3')) {
      final probe = ManagedSqliteConnection.openUnencrypted(path);
      try {
        final payload =
            probe.use(
                  (db) => db
                      .select('SELECT payload FROM managed_catalog')
                      .single['payload'],
                )
                as String;
        if (ManagedIdentityCatalog.decode(payload).identities.isNotEmpty) {
          throw const ManagedFsFailure(ManagedFsFailureKind.io);
        }
      } finally {
        probe.close();
      }
    }
    return result;
  }

  void disarm() {
    armed = false;
    blocker?.use((db) => db.execute('ROLLBACK'));
    blocker?.close();
    blocker = null;
  }
}

void main() {
  late Directory temporary;
  late Directory profile;
  late ManagedDirectoryCatalog owner;
  final live = <ManagedIdentityStore>[];
  const fs = ManagedFsPlatform();
  final a = ManagedIdentityId('1' * 32);
  final c = ManagedIdentityId('2' * 32);

  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    temporary = Directory.systemTemp.createTempSync(
      'xveil-managed-files-native-',
    );
    profile = Directory('${temporary.path}/profile');
    expect(fs.createPrivateDirectory(profile.path), isTrue);
    owner = ManagedDirectoryCatalog.createOrOpen(profile.path);
  });
  tearDown(() {
    for (final store in live) {
      store.close();
    }
    live.clear();
    owner.close();
    temporary.deleteSync(recursive: true);
  });

  test(
    'real encrypted and plaintext files publish separately and cold-open by keys/password',
    () {
      const secret = 'encrypted-fixture-value-not-user-data';
      const plainText = 'plaintext-fixture-value-not-user-data';
      final password = b('fixture-user-password');
      final beforePassword = Uint8List.fromList(password);
      final encrypted = ManagedIdentityFiles.createEncrypted(
        owner,
        id: a,
        password: password,
        initial: [
          PutOp(1, b('value'), b(secret)),
          AppendLogOp(5, 1, b('log-entry')),
        ],
      );
      live.add(encrypted);
      final plain = ManagedIdentityFiles.createUnencrypted(
        owner,
        id: c,
        initial: [PutOp(1, b('value'), b(plainText))],
      );
      live.add(plain);
      expect(password, beforePassword);
      expect(encrypted.entry.protection, StorageProtection.encrypted);
      expect(plain.entry.protection, StorageProtection.unencrypted);
      expect(owner.snapshot().catalog.identities.map((e) => e.id), [a, c]);
      expect(encrypted.get(1, b('value')), b(secret));
      expect(plain.get(1, b('value')), b(plainText));
      expect(encrypted, isA<SyncLogGroupReader>());
      expect(plain, isNot(isA<SyncLogGroupReader>()));
      expect(
        (encrypted as SyncLogGroupReader).readLogGroups(5, [
          (ids: [1], maxBytes: 1024),
        ]),
        [b('log-entry')],
      );
      final keys = encrypted.exportKeys();
      final plainKeys = plain.exportKeys();
      expect(keys.length, 64);
      expect(plainKeys.length, 64);
      final last = encrypted.commitSeq();
      expect(encrypted.commitRoots().containsKey(last), isTrue);
      expect(() => owner.close(), throwsA(isA<ManagedIdentityFailure>()));
      encrypted.close();
      plain.close();
      final header = hv.headerInfo(owner.layout.keyboxPath(a));
      expect(
        (header.argonMCostKib, header.argonTCost, header.argonPCost),
        (256 * 1024, 4, 4),
      );

      for (final path in [
        owner.layout.keyboxPath(a),
        owner.layout.contentPath(a),
        owner.layout.maintenancePath(a),
      ]) {
        expect(
          latin1.decode(File(path).readAsBytesSync()).contains(secret),
          isFalse,
        );
        expect(fs.inspect(path).ownerOnly, isTrue);
      }
      expect(
        latin1
            .decode(File(owner.layout.dataPath(c)).readAsBytesSync())
            .contains(plainText),
        isTrue,
      );
      final reopened = ManagedIdentityFiles.openWithKeys(
        owner,
        id: a,
        keys: keys,
      );
      live.add(reopened);
      expect(reopened.get(1, b('value')), b(secret));
      expect(reopened.exportKeys(), keys);
      expect(reopened.commitSeq(), last);
      reopened.close();
      final passwordOpen = ManagedIdentityFiles.openWithPassword(
        owner,
        id: a,
        password: password,
      );
      live.add(passwordOpen);
      expect(passwordOpen.get(1, b('value')), b(secret));
      passwordOpen.close();
      final publicOpen = ManagedIdentityFiles.openWithKeys(
        owner,
        id: c,
        keys: plainKeys,
      );
      live.add(publicOpen);
      expect(publicOpen.get(1, b('value')), b(plainText));
      publicOpen.close();
      keys.fillRange(0, keys.length, 0);
      plainKeys.fillRange(0, plainKeys.length, 0);
    },
  );

  test(
    'a live identity cannot open twice and root close cannot forget its lease',
    () async {
      final store = ManagedIdentityFiles.createUnencrypted(owner, id: a);
      live.add(store);
      expect(
        () => ManagedIdentityFiles.openUnencrypted(owner, id: a),
        throwsA(
          isA<ManagedIdentityFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedIdentityFailureKind.busy,
          ),
        ),
      );
      final other = ManagedDirectoryCatalog.openExisting(profile.path)!;
      try {
        expect(
          () => ManagedIdentityFiles.openUnencrypted(other, id: a),
          throwsA(
            isA<ManagedIdentityFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedIdentityFailureKind.busy,
            ),
          ),
        );
        expect(() => owner.close(), throwsA(isA<ManagedIdentityFailure>()));
        expect(
          await probeManagedIdentityLease(
            owner.layout.leasePath(a),
            protection: StorageProtection.unencrypted,
          ),
          'busy',
        );
        store.commit([PutOp(1, b('value'), b('still-live'))]);
        store.close();
        final reopened = ManagedIdentityFiles.openUnencrypted(other, id: a);
        try {
          expect(reopened.get(1, b('value')), b('still-live'));
        } finally {
          reopened.close();
        }
      } finally {
        other.close();
      }
    },
  );
  test('wrong credentials/modes never initialize or downgrade a store', () {
    final encrypted = ManagedIdentityFiles.createEncrypted(
      owner,
      id: a,
      password: b('fixture-correct-password'),
    );
    live.add(encrypted);
    encrypted.close();
    final plain = ManagedIdentityFiles.createUnencrypted(owner, id: c);
    live.add(plain);
    plain.close();
    final paths = [
      owner.layout.keyboxPath(a),
      owner.layout.contentPath(a),
      owner.layout.maintenancePath(a),
      owner.layout.dataPath(c),
    ];
    final before = {
      for (final path in paths) path: File(path).readAsBytesSync(),
    };
    for (final action in [
      () => ManagedIdentityFiles.openWithPassword(
        owner,
        id: a,
        password: b('wrong-fixture-password'),
      ),
      () =>
          ManagedIdentityFiles.openWithKeys(owner, id: a, keys: Uint8List(64)),
      () => ManagedIdentityFiles.openUnencrypted(owner, id: a),
      () => ManagedIdentityFiles.openWithPassword(
        owner,
        id: c,
        password: b('not-a-plaintext-password'),
      ),
      () =>
          ManagedIdentityFiles.openWithKeys(owner, id: c, keys: Uint8List(64)),
      () => ManagedIdentityFiles.createUnencrypted(owner, id: a),
    ]) {
      expect(action, throwsA(isA<ManagedIdentityFailure>()));
      for (final path in paths) {
        expect(File(path).readAsBytesSync(), before[path]);
      }
    }
    final afterFailure = ManagedIdentityFiles.openWithPassword(
      owner,
      id: a,
      password: b('fixture-correct-password'),
    );
    live.add(afterFailure);
    afterFailure.close();
    expect(owner.snapshot().catalog.identities.length, 2);
  });

  test('foreign keybox is rejected even with its valid outer keys', () {
    final first = ManagedIdentityFiles.createEncrypted(
      owner,
      id: a,
      password: b('fixture-first-password'),
      initial: [PutOp(1, b('value'), b('first'))],
    );
    final second = ManagedIdentityFiles.createEncrypted(
      owner,
      id: c,
      password: b('fixture-second-password'),
      initial: [PutOp(1, b('value'), b('second'))],
    );
    live.addAll([first, second]);
    final firstKeys = first.exportKeys();
    final secondKeys = second.exportKeys();
    first.close();
    second.close();
    void swap() {
      final one = File(owner.layout.keyboxPath(a));
      final two = File(owner.layout.keyboxPath(c));
      final temporary = '${one.path}.swap';
      one.renameSync(temporary);
      two.renameSync(one.path);
      File(temporary).renameSync(two.path);
    }

    swap();
    final paths = [
      owner.layout.keyboxPath(a),
      owner.layout.contentPath(a),
      owner.layout.maintenancePath(a),
      owner.layout.keyboxPath(c),
      owner.layout.contentPath(c),
      owner.layout.maintenancePath(c),
    ];
    final previous = {
      for (final path in paths) path: File(path).readAsBytesSync(),
    };
    expect(
      () => ManagedIdentityFiles.openWithKeys(owner, id: a, keys: secondKeys),
      throwsA(isA<ManagedIdentityFailure>()),
    );
    for (final path in paths) {
      expect(File(path).readAsBytesSync(), previous[path]);
    }
    swap();
    final valid = ManagedIdentityFiles.openWithKeys(
      owner,
      id: a,
      keys: firstKeys,
    );
    live.add(valid);
    expect(valid.get(1, b('value')), b('first'));
    valid.close();
    firstKeys.fillRange(0, firstKeys.length, 0);
    secondKeys.fillRange(0, secondKeys.length, 0);
  });

  test(
    'per-identity payload links are refused before SQLite can open them',
    () {
      final created = ManagedIdentityFiles.createUnencrypted(
        owner,
        id: a,
        initial: [PutOp(1, b('value'), b('preserved'))],
      );
      live.add(created);
      created.close();
      final path = owner.layout.dataPath(a);
      final outside = File(
        path,
      ).renameSync('${temporary.path}/outside-fixture');
      final original = outside.readAsBytesSync();
      final link = Link(path)..createSync(outside.path);
      try {
        expect(
          () => ManagedIdentityFiles.openUnencrypted(owner, id: a),
          throwsA(isA<ManagedFsFailure>()),
        );
        expect(outside.readAsBytesSync(), original);
        expect(link.targetSync(), outside.path);
      } finally {
        link.deleteSync();
        outside.renameSync(path);
      }
      final valid = ManagedIdentityFiles.openUnencrypted(owner, id: a);
      live.add(valid);
      expect(valid.get(1, b('value')), b('preserved'));
      valid.close();
    },
    skip: Platform.isWindows,
  );

  test(
    'interrupted publication/registration resumes exact data without duplicate entries',
    () {
      owner.close();
      for (final cut in _Cut.values) {
        final directory = Directory('${temporary.path}/case-${cut.name}');
        fs.createPrivateDirectory(directory.path);
        final fault = _FactoryFault(cut);
        final current = ManagedDirectoryCatalog.createOrOpen(
          directory.path,
          fs: fault,
        );
        fault.armed = true;
        try {
          expect(
            () => ManagedIdentityFiles.createUnencrypted(
              current,
              id: a,
              initial: [PutOp(1, b('value'), b('preserved-${cut.name}'))],
            ),
            throwsA(
              anyOf(isA<ManagedFsFailure>(), isA<ManagedIdentityFailure>()),
            ),
          );
          fault.disarm();
          final known = current.snapshot();
          expect(
            known.catalog.identities.length,
            cut == _Cut.afterRegister ? 1 : 0,
          );
          if (cut != _Cut.afterRegister) {
            expect(
              () => ManagedIdentityFiles.openUnencrypted(current, id: a),
              throwsA(isA<ManagedIdentityFailure>()),
            );
          }
          final resumed = ManagedIdentityFiles.resumeUnencrypted(
            current,
            id: a,
          );
          try {
            expect(resumed.get(1, b('value')), b('preserved-${cut.name}'));
            expect(current.snapshot().catalog.identities.single.id, a);
            expect(current.snapshot().revision, 1);
          } finally {
            resumed.close();
          }
          final again = ManagedIdentityFiles.resumeUnencrypted(current, id: a);
          again.close();
          expect(current.snapshot().revision, 1);
        } finally {
          fault.disarm();
          current.close();
        }
      }
    },
  );
  test(
    'invalid creation and duplicate IDs do not create or overwrite files',
    () {
      Map<String, Object> snapshot() => {
        for (final item in Directory(owner.directory).listSync(followLinks: false))
          File(item.path).uri.pathSegments.last: item is File
              ? item.readAsBytesSync() : item.runtimeType.toString(),
      };
      final beforeInvalidCreation = snapshot();
      expect(
        () => ManagedIdentityFiles.createEncrypted(
          owner,
          id: a,
          password: Uint8List(0),
        ),
        throwsA(
          isA<ManagedIdentityFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedIdentityFailureKind.authentication,
          ),
        ),
      );
      expect(snapshot(), beforeInvalidCreation);
      expect(owner.snapshot().catalog.identities, isEmpty);
      final original = ManagedIdentityFiles.createUnencrypted(
        owner,
        id: a,
        initial: [PutOp(1, b('value'), b('original'))],
      );
      live.add(original);
      original.close();
      final bytes = File(owner.layout.dataPath(a)).readAsBytesSync();
      expect(
        () => ManagedIdentityFiles.createUnencrypted(
          owner,
          id: a,
          initial: [PutOp(1, b('value'), b('must-not-apply'))],
        ),
        throwsA(isA<ManagedIdentityFailure>()),
      );
      expect(File(owner.layout.dataPath(a)).readAsBytesSync(), bytes);
      expect(
        () => ManagedIdentityFiles.openUnencrypted(owner, id: c),
        throwsA(isA<ManagedIdentityFailure>()),
      );
      expect(Directory(owner.layout.directory(c)).existsSync(), isFalse);
      expect(owner.snapshot().revision, 1);
    },
  );

  test(
    'ambiguous recovery preserves both copies and ordinary opening still works',
    () {
      final original = ManagedIdentityFiles.createUnencrypted(
        owner,
        id: a,
        initial: [PutOp(1, b('value'), b('final-copy'))],
      );
      live.add(original);
      original.close();
      final pending = Directory.fromUri(
        Directory(owner.directory).uri.resolve('.identity-${a.value}.pending'),
      );
      expect(fs.createPrivateDirectory(pending.path), isTrue);
      final marker = File('${pending.path}/sentinel')
        ..writeAsStringSync('retained');
      expect(
        () => ManagedIdentityFiles.resumeUnencrypted(owner, id: a),
        throwsA(
          isA<ManagedIdentityFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedIdentityFailureKind.ambiguous,
          ),
        ),
      );
      expect(marker.readAsStringSync(), 'retained');
      final opened = ManagedIdentityFiles.openUnencrypted(owner, id: a);
      live.add(opened);
      expect(opened.get(1, b('value')), b('final-copy'));
      opened.close();
      expect(owner.snapshot().revision, 1);
    },
  );
}
