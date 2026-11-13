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

  test('native cipher reopens the exact value; disk contains no plaintext', () {
    final path = '${temp.path}/encrypted.store';
    final created = ManagedSqliteConnection.openEncrypted(
      path,
      key: key,
      salt: salt,
      create: true,
    );
    try {
      created.use((db) {
        db.execute('CREATE TABLE fixture (value TEXT NOT NULL)');
        db.execute('INSERT INTO fixture VALUES (?)', [marker]);
      });
    } finally {
      created.close();
    }
    final snapshot = File(path).readAsBytesSync();
    expect(snapshot.sublist(0, 16), salt);
    expect(latin1.decode(snapshot).contains(marker), isFalse);
    final opened = ManagedSqliteConnection.openEncrypted(
      path,
      key: key,
      salt: salt,
    );
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

  test('wrong key and wrong mode preserve the encrypted file unchanged', () {
    final path = '${temp.path}/encrypted.store';
    final created = ManagedSqliteConnection.openEncrypted(
      path,
      key: key,
      salt: salt,
      create: true,
    );
    created.use((db) => db.execute('CREATE TABLE fixture (value TEXT)'));
    created.close();
    final snapshot = File(path).readAsBytesSync();
    for (final open in [
      () => ManagedSqliteConnection.openEncrypted(
        path,
        key: Uint8List(32),
        salt: salt,
      ),
      () => ManagedSqliteConnection.openUnencrypted(path),
      () => ManagedSqliteConnection.openUnencrypted(path, create: true),
    ]) {
      expect(open, throwsA(isA<ManagedSqliteFailure>()));
      expect(File(path).readAsBytesSync(), snapshot);
    }
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
