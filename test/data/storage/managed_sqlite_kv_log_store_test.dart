import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/data/storage/plain_sqlite_kv_log_store.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late Directory temp;
  final keys = Uint8List.fromList(List.generate(64, (i) => i + 1));
  final salt = Uint8List.fromList(List.generate(16, (i) => i + 97));
  final live = <PlainSqliteKvLogStore>[];

  PlainSqliteKvLogStore open(String name, {bool create = false}) {
    final path = '${temp.path}/$name';
    final connection = ManagedSqliteConnection.openUnencrypted(
      path,
      create: create,
    );
    final store = PlainSqliteKvLogStore(
      connection,
      keys: keys,
      initialize: create,
    );
    live.add(store);
    return store;
  }

  setUp(() => temp = Directory.systemTemp.createTempSync('managed-sqlite-kv-'));
  tearDown(() {
    for (final store in live) {
      store.close();
    }
    live.clear();
    temp.deleteSync(recursive: true);
  });

  test('plaintext KV/log state and anchors survive connection reopen', () {
    var store = open('identity', create: true);
    expect(
      store.commit([
        PutOp(1, bytes('profile'), bytes('fixture-profile')),
        AppendLogOp(3, 7, bytes('first')),
        AppendLogOp(3, 9, bytes('last')),
      ]),
      1,
    );
    store.commit([
      AppendLogOp(3, 7, bytes('edited')),
      DeleteLogOp(3, 9),
      PutOp(1, bytes('delivered'), bytes('yes')),
    ]);
    final roots = store.commitRoots();
    store.close();
    store = open('identity');
    expect(store.get(1, bytes('profile')), bytes('fixture-profile'));
    expect(store.get(1, bytes('delivered')), bytes('yes'));
    expect(store.readLog(3, 7), bytes('edited'));
    expect(store.readLog(3, 9), isNull);
    expect(
      store
          .iterLogRange(namespace: 3, start: 7, end: 8, limit: 1)
          .map((r) => r.logId),
      [7],
    );
    expect(store.commitSeq(), 2);
    expect(store.commitRoots(), roots);
    store.scrub();
    expect(store.commitRoots(), roots);
  });

  test(
    'a failed COMMIT rolls back payloads and the durable anchor together',
    () {
      final store = open('identity', create: true);
      store.commit([PutOp(1, bytes('profile'), bytes('before'))]);
      final roots = store.commitRoots();
      final reader = sqlite3.open(
        '${temp.path}/identity',
        mode: OpenMode.readOnly,
      );
      try {
        reader.execute('BEGIN');
        reader.select('SELECT value FROM store_kv');
        expect(
          () => store.commit([
            PutOp(1, bytes('profile'), bytes('must-not-commit')),
            AppendLogOp(3, 1, bytes('must-not-commit')),
          ]),
          throwsA(isA<ManagedSqliteFailure>()),
        );
        reader.execute('ROLLBACK');
      } finally {
        reader.close();
      }
      expect(store.get(1, bytes('profile')), bytes('before'));
      expect(store.readLog(3, 1), isNull);
      expect(store.commitSeq(), 1);
      expect(store.commitRoots(), roots);
      store.close();
      final cold = open('identity');
      expect(cold.commitSeq(), 1);
      expect(cold.get(1, bytes('profile')), bytes('before'));
      expect(cold.readLog(3, 1), isNull);
    },
  );

  test(
    'overwrites remain bounded and namespace deletion shrinks only its own store',
    () {
      final a = open('a', create: true);
      final b = open('b', create: true);
      b.commit([PutOp(1, bytes('profile'), bytes('untouched-sibling'))]);
      final siblingSnapshot = File('${temp.path}/b').readAsBytesSync();
      final payload = Uint8List.fromList(
        List.generate(64 * 1024, (i) => i & 255),
      );
      a.commit([for (var i = 1; i <= 32; i++) AppendLogOp(3, i, payload)]);
      final initial = File('${temp.path}/a').lengthSync();
      var peak = initial;
      for (var round = 0; round < 64; round++) {
        payload[0] = round;
        a.commit([for (var i = 1; i <= 32; i++) AppendLogOp(3, i, payload)]);
        final size = File('${temp.path}/a').lengthSync();
        if (size > peak) peak = size;
      }
      // A fixed live set may add bounded anchor/index pages, not a new copy of
      // its 2 MiB payload on each of 64 rewrites. This is a size oracle, not time.
      expect(peak, lessThan(initial + 256 * 1024));
      expect(a.eraseNamespace(3), 32);
      expect(a.count(3), 0);
      expect(File('${temp.path}/a').lengthSync(), lessThan(initial ~/ 4));
      expect(File('${temp.path}/b').readAsBytesSync(), siblingSnapshot);
      expect(b.get(1, bytes('profile')), bytes('untouched-sibling'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'branch roots distinguish forks and retained history stays bounded',
    () {
      var a = open('a', create: true);
      a.commit([PutOp(1, bytes('profile'), bytes('before-fork'))]);
      a.close();
      File('${temp.path}/a').copySync('${temp.path}/b');
      a = open('a');
      final b = open('b');
      a.commit([PutOp(1, bytes('profile'), bytes('branch-a'))]);
      b.commit([PutOp(1, bytes('profile'), bytes('branch-b'))]);
      expect(a.commitSeq(), b.commitSeq());
      expect(a.commitRoots()[2], isNot(b.commitRoots()[2]));
      for (var i = 0; i < anchorHorizon + 2; i++) {
        a.commit([PutOp(1, bytes('counter'), bytes('$i'))]);
      }
      expect(a.commitHistory().length, anchorHorizon);
      expect(a.commitHistory().last, a.commitSeq());
      expect(a.commitRoots().length, anchorHorizon);
      expect(a.commitHistory().first, a.commitSeq() - anchorHorizon + 1);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a locator mismatch does not reopen a different plaintext identity', () {
    final original = open('identity', create: true);
    original.commit([PutOp(1, bytes('profile'), bytes('preserved'))]);
    original.close();
    final connection = ManagedSqliteConnection.openUnencrypted(
      '${temp.path}/identity',
    );
    expect(
      () => PlainSqliteKvLogStore(connection, keys: Uint8List(64)),
      throwsA(isA<ManagedSqliteFailure>()),
    );
    final reopened = open('identity');
    expect(reopened.get(1, bytes('profile')), bytes('preserved'));
  });

  test(
    'the plaintext adapter refuses an encrypted connection before initialization',
    () {
      final connection = ManagedSqliteConnection.openEncrypted(
        '${temp.path}/cipher',
        key: Uint8List.sublistView(keys, 0, 32),
        salt: salt,
        create: true,
      );
      expect(
        () => PlainSqliteKvLogStore(connection, keys: keys, initialize: true),
        throwsUnsupportedError,
      );
    },
  );
}
