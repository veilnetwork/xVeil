import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

void main() {
  late Directory temp;
  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final salt = Uint8List.fromList(List.generate(16, (i) => i + 97));
  const marker = 'managed-store-fixture-not-a-real-secret-42';

  setUp(() => temp = Directory.systemTemp.createTempSync('managed-sqlite-'));
  tearDown(() => temp.deleteSync(recursive: true));

  Matcher getUnsupportedProtection() => isA<ManagedSqliteFailure>().having(
    (error) => error.kind,
    'kind',
    ManagedSqliteFailureKind.unsupportedProtection,
  );

  test('encrypted requests never create or modify a database', () {
    final absent = '${temp.path}/must-not-exist';
    expect(
      () => ManagedSqliteConnection.openEncrypted(
        absent,
        key: key,
        salt: salt,
        create: true,
      ),
      throwsA(getUnsupportedProtection()),
    );
    expect(FileSystemEntity.typeSync(absent), FileSystemEntityType.notFound);

    final path = '${temp.path}/plain.store';
    final created = ManagedSqliteConnection.openUnencrypted(path, create: true);
    created.use((db) {
      db.execute('CREATE TABLE fixture (value TEXT NOT NULL)');
      db.execute('INSERT INTO fixture VALUES (?)', [marker]);
    });
    created.close();
    final snapshot = File(path).readAsBytesSync();
    for (final create in [false, true]) {
      expect(
        () => ManagedSqliteConnection.openEncrypted(
          path,
          key: key,
          salt: salt,
          create: create,
        ),
        throwsA(getUnsupportedProtection()),
      );
      expect(File(path).readAsBytesSync(), snapshot);
    }
    final reopened = ManagedSqliteConnection.openUnencrypted(path);
    try {
      expect(
        reopened.use(
          (db) => db.select('SELECT value FROM fixture').single['value'],
        ),
        marker,
      );
    } finally {
      reopened.close();
    }
  });

  test('create refuses existing files, directories and symbolic links', () {
    final path = '${temp.path}/existing.store';
    final created = ManagedSqliteConnection.openUnencrypted(path, create: true);
    created.use((db) => db.execute('CREATE TABLE fixture (value TEXT)'));
    created.close();
    final snapshot = File(path).readAsBytesSync();
    final directory = Directory('${temp.path}/directory')..createSync();
    final link = Link('${temp.path}/link')..createSync(path);
    final dangling = Link('${temp.path}/dangling')
      ..createSync('${temp.path}/absent');
    for (final target in [path, directory.path, link.path, dangling.path]) {
      expect(
        () => ManagedSqliteConnection.openUnencrypted(target, create: true),
        throwsA(isA<ManagedSqliteFailure>()),
      );
    }
    for (final target in [directory.path, link.path, dangling.path]) {
      expect(
        () => ManagedSqliteConnection.openUnencrypted(target),
        throwsA(isA<ManagedSqliteFailure>()),
      );
    }
    expect(File(path).readAsBytesSync(), snapshot);
    expect(link.targetSync(), path);
    expect(dangling.targetSync(), '${temp.path}/absent');
    expect(File('${temp.path}/absent').existsSync(), isFalse);
  });

  test('open without create never recreates a missing database', () {
    final path = '${temp.path}/missing';
    expect(
      () => ManagedSqliteConnection.openUnencrypted(path),
      throwsA(isA<ManagedSqliteFailure>()),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('unencrypted is genuinely plaintext and is reopened explicitly', () {
    final path = '${temp.path}/plain.store';
    final created = ManagedSqliteConnection.openUnencrypted(path, create: true);
    created.use((db) {
      db.execute('CREATE TABLE fixture (value TEXT NOT NULL)');
      db.execute('INSERT INTO fixture VALUES (?)', [marker]);
    });
    created.close();
    expect(
      latin1.decode(File(path).readAsBytesSync()).contains(marker),
      isTrue,
    );
    final opened = ManagedSqliteConnection.openUnencrypted(path);
    try {
      expect(
        opened.use(
          (db) => db.select('SELECT value FROM fixture').single['value'],
        ),
        marker,
      );
    } finally {
      opened.close();
    }
  });

  test('database errors omit statement, bound values and local paths', () {
    final path = '${temp.path}/plain.store';
    final created = ManagedSqliteConnection.openUnencrypted(path, create: true);
    try {
      created.use(
        (db) => db.execute('CREATE TABLE fixture (value TEXT UNIQUE)'),
      );
      created.use(
        (db) => db.execute('INSERT INTO fixture VALUES (?)', [marker]),
      );
      try {
        created.use(
          (db) => db.execute('INSERT INTO fixture VALUES (?)', [marker]),
        );
        fail('unique constraint was not enforced');
      } on ManagedSqliteFailure catch (error) {
        expect(error.sqliteCode, isNotNull);
        expect(error.toString(), isNot(contains(marker)));
        expect(error.toString(), isNot(contains('INSERT')));
        expect(error.toString(), isNot(contains(temp.path)));
      }
    } finally {
      created.close();
    }
    expect(
      () => created.use((db) => db.select('SELECT 1')),
      throwsA(isA<ManagedSqliteFailure>()),
    );
  });
}
