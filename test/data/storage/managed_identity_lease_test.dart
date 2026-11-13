import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_identity_lease.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/domain/storage_protection.dart';

ManagedIdentityEntry _entry([
  StorageProtection protection = StorageProtection.encrypted,
]) => ManagedIdentityEntry(
  id: ManagedIdentityId('1' * 32),
  protection: protection,
);

String _attempt(String path) {
  try {
    final lease = ManagedIdentityLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(path),
      expected: _entry(),
    );
    lease.close();
    return 'opened';
  } on ManagedSqliteFailure catch (error) {
    if (error.sqliteCode == 5) return 'busy';
    rethrow;
  } on ManagedLeaseFailure catch (error) {
    if (error.kind == ManagedLeaseFailureKind.busy) return 'busy';
    rethrow;
  }
}

// Keep the send closure outside the test's context: an inline Isolate.run
// closure can capture its live native owners even when its body uses only path.
Future<String> _isolatedAttempt(String path) =>
    Isolate.run(() => _attempt(path));

void main() {
  late Directory root;
  final live = <ManagedIdentityLease>[];
  ManagedIdentityLease open(
    String name, {
    bool create = false,
    ManagedIdentityEntry? entry,
  }) {
    final connection = ManagedSqliteConnection.openUnencrypted(
      '${root.path}/$name',
      create: create,
    );
    final result = create
        ? ManagedIdentityLease.initializeOwned(
            connection,
            entry: entry ?? _entry(),
          )
        : ManagedIdentityLease.openOwned(
            connection,
            expected: entry ?? _entry(),
          );
    live.add(result);
    return result;
  }

  setUp(
    () => root = Directory.systemTemp.createTempSync('xveil-identity-lease-'),
  );
  tearDown(() {
    for (final lease in live) {
      lease.close();
    }
    live.clear();
    root.deleteSync(recursive: true);
  });

  test(
    'role metadata contains only the local locator and protection and cold-opens',
    () {
      for (final protection in [
        StorageProtection.encrypted,
        StorageProtection.unencrypted,
      ]) {
        final entry = _entry(protection);
        final created = open(protection.name, create: true, entry: entry);
        created.requireHeld();
        created.close();
        final snapshot = File(
          '${root.path}/${protection.name}',
        ).readAsBytesSync();
        final reader = ManagedSqliteConnection.openUnencrypted(
          '${root.path}/${protection.name}',
        );
        try {
          expect(
            reader.use(
              (db) => Map<String, Object?>.from(
                db.select('SELECT * FROM identity_role').single,
              ),
            ),
            {
              'id': 1,
              'identity': entry.id.value,
              'protection': protection.name,
            },
          );
        } finally {
          reader.close();
        }
        final reopened = open(protection.name, entry: entry);
        reopened.requireHeld();
        reopened.close();
        expect(
          File('${root.path}/${protection.name}').readAsBytesSync(),
          snapshot,
        );
      }
    },
  );

  test('failed same-process contenders never release the current owner', () {
    final owner = open('lease', create: true);
    for (var i = 0; i < 3; i++) {
      expect(_attempt('${root.path}/lease'), 'busy');
      owner.requireHeld();
    }
    owner.close();
    expect(_attempt('${root.path}/lease'), 'opened');
  });

  test(
    'another isolate using the packaged provider cannot share the identity',
    () async {
      final owner = open('lease', create: true);
      final path = '${root.path}/lease';
      expect(await _isolatedAttempt(path), 'busy');
      owner.requireHeld();
      owner.close();
      expect(await _isolatedAttempt(path), 'opened');
    },
  );

  test(
    'mode/id mismatch refuses, closes its connection, and preserves the role',
    () {
      open('lease', create: true).close();
      final snapshot = File('${root.path}/lease').readAsBytesSync();
      for (final expected in [
        _entry(StorageProtection.unencrypted),
        ManagedIdentityEntry(
          id: ManagedIdentityId('2' * 32),
          protection: StorageProtection.encrypted,
        ),
      ]) {
        final connection = ManagedSqliteConnection.openUnencrypted(
          '${root.path}/lease',
        );
        expect(
          () => ManagedIdentityLease.openOwned(connection, expected: expected),
          throwsA(
            isA<ManagedLeaseFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedLeaseFailureKind.mismatch,
            ),
          ),
        );
        expect(
          () => connection.use((db) => db.select('SELECT 1')),
          throwsA(isA<ManagedSqliteFailure>()),
        );
        expect(File('${root.path}/lease').readAsBytesSync(), snapshot);
      }
      open('lease').requireHeld();
    },
  );

  test('initialization never relabels an existing identity', () {
    open('lease', create: true).close();
    final snapshot = File('${root.path}/lease').readAsBytesSync();
    final connection = ManagedSqliteConnection.openUnencrypted(
      '${root.path}/lease',
    );
    expect(
      () => ManagedIdentityLease.initializeOwned(
        connection,
        entry: _entry(StorageProtection.unencrypted),
      ),
      throwsA(isA<ManagedLeaseFailure>()),
    );
    expect(File('${root.path}/lease').readAsBytesSync(), snapshot);
    open('lease').requireHeld();
  });

  test('malformed/future/hidden role state is refused without reset', () {
    final mutations = <String>[
      'PRAGMA user_version = 2',
      'PRAGMA application_id = 1',
      "UPDATE identity_role SET protection = 'hidden'",
      "UPDATE identity_role SET identity = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'",
      'DELETE FROM identity_role',
      'CREATE TABLE extra (value TEXT)',
    ];
    for (var i = 0; i < mutations.length; i++) {
      final name = 'invalid-$i';
      open(name, create: true).close();
      final connection = ManagedSqliteConnection.openUnencrypted(
        '${root.path}/$name',
      );
      connection.use((db) => db.execute(mutations[i]));
      connection.close();
      final snapshot = File('${root.path}/$name').readAsBytesSync();
      expect(() => open(name), throwsA(isA<ManagedLeaseFailure>()));
      expect(File('${root.path}/$name').readAsBytesSync(), snapshot);
    }
  });

  test('missing or nonempty lock markers refuse without recreating them', () {
    open('lease', create: true).close();
    final marker = File('${root.path}/lease.lock');
    final metadata = File('${root.path}/lease').readAsBytesSync();
    marker.deleteSync();
    expect(() => open('lease'), throwsA(isA<ManagedLeaseFailure>()));
    expect(marker.existsSync(), isFalse);
    marker.writeAsBytesSync([7], flush: true);
    expect(() => open('lease'), throwsA(isA<ManagedLeaseFailure>()));
    expect(marker.readAsBytesSync(), [7]);
    expect(File('${root.path}/lease').readAsBytesSync(), metadata);
  });

  test('released lease blocks use and safe errors omit locator/path', () {
    final owner = open('lease', create: true)..close();
    try {
      owner.requireHeld();
      fail('released lease was accepted');
    } on ManagedLeaseFailure catch (error) {
      expect(error.kind, ManagedLeaseFailureKind.closed);
      expect(error.toString(), isNot(contains(_entry().id.value)));
      expect(error.toString(), isNot(contains(root.path)));
    }
    owner.close();
  });
}
