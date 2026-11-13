import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_catalog_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

ManagedIdentityEntry entry(int number, [StorageProtection? protection]) =>
    ManagedIdentityEntry(
      id: ManagedIdentityId(number.toRadixString(16).padLeft(32, '0')),
      protection: protection ?? StorageProtection.encrypted,
    );

Matcher failure(ManagedCatalogFailureKind kind) =>
    isA<ManagedCatalogFailure>().having((error) => error.kind, 'kind', kind);

void main() {
  late Directory temp;
  final live = <ManagedCatalogStore>[];

  ManagedSqliteConnection connect(String name, {bool create = false}) =>
      ManagedSqliteConnection.openUnencrypted(
        '${temp.path}/$name',
        create: create,
      );

  ManagedCatalogStore open(String name, {bool create = false}) {
    final connection = connect(name, create: create);
    final store = create
        ? ManagedCatalogStore.initializeOwned(connection)
        : ManagedCatalogStore.openOwned(connection);
    live.add(store);
    return store;
  }

  void mutate(String name, void Function(ManagedSqliteConnection) action) {
    final connection = connect(name);
    try {
      action(connection);
    } finally {
      connection.close();
    }
  }

  setUp(() => temp = Directory.systemTemp.createTempSync('managed-catalog-'));
  tearDown(() {
    for (final store in live) {
      store.close();
    }
    live.clear();
    temp.deleteSync(recursive: true);
  });

  test('visible catalog reopens; idempotent retry does not add a revision', () {
    final store = open('catalog', create: true);
    expect(store.snapshot().catalog.identities, isEmpty);
    expect(store.snapshot().revision, 0);
    expect(store.register(entry(1)).revision, 1);
    expect(store.register(entry(2, StorageProtection.unencrypted)).revision, 2);
    store.close();
    final before = File('${temp.path}/catalog').readAsBytesSync();
    final reopened = open('catalog');
    final retried = reopened.register(entry(1));
    expect(retried.revision, 2);
    expect(
      retried.catalog.encode(),
      ManagedIdentityCatalog([
        entry(1),
        entry(2, StorageProtection.unencrypted),
      ]).encode(),
    );
    reopened.close();
    expect(File('${temp.path}/catalog').readAsBytesSync(), before);
    mutate('catalog', (connection) {
      final payload =
          connection.use(
                (db) => db
                    .select('SELECT payload FROM managed_catalog')
                    .single['payload'],
              )
              as String;
      expect(jsonDecode(payload), {
        'version': 1,
        'identities': [
          {'id': entry(1).id.value, 'protection': 'encrypted'},
          {'id': entry(2).id.value, 'protection': 'unencrypted'},
        ],
      });
    });
  });

  test(
    'independent owners reload under the write lock instead of losing updates',
    () {
      final first = open('catalog', create: true);
      final second = open('catalog');
      // Both callers have read the same old snapshot before either mutation.
      expect(first.snapshot().revision, 0);
      expect(second.snapshot().revision, 0);
      first.register(entry(1));
      second.register(entry(2));
      expect(first.snapshot().catalog.identities.map((e) => e.id), [
        entry(1).id,
        entry(2).id,
      ]);

      final blocker = connect('catalog');
      try {
        blocker.use((db) => db.execute('BEGIN IMMEDIATE'));
        expect(
          () => second.register(entry(3)),
          throwsA(
            isA<ManagedSqliteFailure>().having(
              (error) => error.sqliteCode,
              'busy code',
              5,
            ),
          ),
        );
        expect(first.snapshot().revision, 2);
        blocker.use((db) => db.execute('ROLLBACK'));
      } finally {
        blocker.close();
      }
      expect(second.register(entry(3)).revision, 3);
      first.close();
      second.close();
      expect(open('catalog').snapshot().catalog.identities.map((e) => e.id), [
        entry(1).id,
        entry(2).id,
        entry(3).id,
      ]);
    },
  );

  test('failed native commit leaves both catalog and revision unchanged', () {
    final connection = connect('catalog', create: true);
    final store = ManagedCatalogStore.initializeOwned(connection);
    live.add(store);
    // Native SQLite commit hook rejects the real production transaction.
    connection.use((db) => db.commitFilter = () => false);
    expect(
      () => store.register(entry(1)),
      throwsA(isA<ManagedSqliteFailure>()),
    );
    connection.use((db) => db.commitFilter = null);
    expect(store.snapshot().revision, 0);
    expect(store.snapshot().catalog.identities, isEmpty);
    final independent = open('catalog');
    expect(independent.snapshot().catalog.identities, isEmpty);
    expect(store.register(entry(1)).revision, 1);
    expect(independent.snapshot().catalog.identities.single.id, entry(1).id);
  });

  test(
    'mode conflicts, count limit and revision overflow never mutate the catalog',
    () {
      final store = open('catalog', create: true);
      store.register(entry(1));
      expect(
        () => store.register(entry(1, StorageProtection.unencrypted)),
        throwsA(failure(ManagedCatalogFailureKind.conflict)),
      );
      expect(store.snapshot().revision, 1);
      for (var i = 2; i <= ManagedIdentityCatalog.maxIdentities; i++) {
        store.register(entry(i));
      }
      expect(
        () => store.register(entry(129)),
        throwsA(failure(ManagedCatalogFailureKind.full)),
      );
      expect(store.snapshot().revision, 128);
      expect(store.snapshot().catalog.identities.length, 128);
      store.close();

      final exhausted = open('exhausted', create: true)..close();
      mutate(
        'exhausted',
        (connection) => connection.use((db) {
          db.execute(
            'UPDATE managed_catalog SET revision = 9223372036854775807',
          );
        }),
      );
      // Reopen does not wrap or reset the counter.
      final last = open('exhausted');
      expect(
        () => last.register(entry(1)),
        throwsA(failure(ManagedCatalogFailureKind.exhausted)),
      );
      expect(last.snapshot().catalog.identities, isEmpty);
      exhausted.close();
    },
  );

  test(
    'corrupt, hidden, credential-bearing and oversized payloads fail closed',
    () {
      final invalid = <Object?>[
        '{',
        jsonEncode({
          'version': 1,
          'identities': [
            {'id': entry(1).id.value, 'protection': 'hidden'},
          ],
        }),
        jsonEncode({
          'version': 1,
          'identities': [],
          'password': 'fixture-only',
        }),
        'x' * (ManagedIdentityCatalog.maxEncodedBytes + 1),
        null,
      ];
      for (var i = 0; i < invalid.length; i++) {
        final name = 'invalid-$i';
        open(name, create: true).close();
        mutate(
          name,
          (connection) => connection.use((db) {
            if (invalid[i] == null) {
              db.execute('DELETE FROM managed_catalog');
            } else {
              db.execute('UPDATE managed_catalog SET payload = ?', [
                invalid[i],
              ]);
            }
          }),
        );
        final snapshot = File('${temp.path}/$name').readAsBytesSync();
        final connection = connect(name);
        expect(
          () => ManagedCatalogStore.openOwned(connection),
          throwsA(failure(ManagedCatalogFailureKind.invalid)),
        );
        expect(
          () => connection.use((db) => db.select('SELECT 1')),
          throwsA(isA<ManagedSqliteFailure>()),
        );
        expect(File('${temp.path}/$name').readAsBytesSync(), snapshot);
      }
    },
  );

  test(
    'foreign or future schemas are preserved and never initialized over',
    () {
      final mutations = <void Function(ManagedSqliteConnection)>[
        (c) => c.use((db) => db.execute('PRAGMA user_version = 2')),
        (c) => c.use((db) => db.execute('PRAGMA application_id = 1')),
        (c) =>
            c.use((db) => db.execute('CREATE TABLE foreign_data (value TEXT)')),
      ];
      for (var i = 0; i < mutations.length; i++) {
        final name = 'foreign-$i';
        open(name, create: true).close();
        mutate(name, mutations[i]);
        final before = File('${temp.path}/$name').readAsBytesSync();
        for (final initialize in [true, false]) {
          final connection = connect(name);
          expect(
            () => initialize
                ? ManagedCatalogStore.initializeOwned(connection)
                : ManagedCatalogStore.openOwned(connection),
            throwsA(failure(ManagedCatalogFailureKind.invalid)),
          );
          expect(File('${temp.path}/$name').readAsBytesSync(), before);
        }
      }
      final original = open('valid', create: true)..register(entry(7));
      original.close();
      final before = File('${temp.path}/valid').readAsBytesSync();
      expect(
        () => ManagedCatalogStore.initializeOwned(connect('valid')),
        throwsA(failure(ManagedCatalogFailureKind.invalid)),
      );
      expect(File('${temp.path}/valid').readAsBytesSync(), before);
      expect(
        open('valid').snapshot().catalog.identities.single.id,
        entry(7).id,
      );
    },
  );

  test('close blocks access and errors contain no public locator or paths', () {
    final store = open('catalog', create: true);
    store.register(entry(1));
    try {
      store.register(entry(1, StorageProtection.unencrypted));
      fail('conflict was accepted');
    } on ManagedCatalogFailure catch (error) {
      expect(error.toString(), isNot(contains(entry(1).id.value)));
      expect(error.toString(), isNot(contains(temp.path)));
    }
    store.close();
    expect(
      () => store.snapshot(),
      throwsA(failure(ManagedCatalogFailureKind.closed)),
    );
    expect(
      () => store.register(entry(2)),
      throwsA(failure(ManagedCatalogFailureKind.closed)),
    );
  });
}
