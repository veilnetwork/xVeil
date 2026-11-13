import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';
import 'package:xveil/data/storage/plain_sqlite_kv_log_store.dart';

// Negative control: SQLCipher page authentication is NOT replay protection.
void main() {
  test(
    'native page replay remains possible; encrypted identity use is refused',
    () {
      final dir = Directory.systemTemp.createTempSync('managed-replay-probe-');
      final path = '${dir.path}/identity';
      final keys = Uint8List.fromList(List.generate(64, (i) => i + 1));
      final salt = Uint8List.fromList(List.generate(16, (i) => i + 97));
      ManagedSqliteConnection open({bool create = false}) =>
          ManagedSqliteConnection.openEncrypted(
            path,
            key: Uint8List.sublistView(keys, 0, 32),
            salt: salt,
            create: create,
          );
      ManagedSqliteConnection? connection;
      try {
        connection = open(create: true);
        final layout = connection.use((db) {
          db.execute('CREATE TABLE probe_meta (seq INTEGER, root TEXT)');
          db.execute('CREATE TABLE probe_data (reserved INTEGER)');
          db.execute("INSERT INTO probe_meta VALUES (1, 'old')");
          db.execute('INSERT INTO probe_data VALUES (1)');
          return (
            page:
                db
                        .select(
                          "SELECT rootpage FROM sqlite_master WHERE name = 'probe_data'",
                        )
                        .single['rootpage']
                    as int,
            size: int.parse(
              db.select('PRAGMA page_size').single.values.single.toString(),
            ),
          );
        });
        connection.close();
        final previous = File(path).readAsBytesSync();
        connection = open();
        connection.use((db) {
          db.execute('BEGIN IMMEDIATE');
          db.execute('UPDATE probe_data SET reserved = 2');
          db.execute("UPDATE probe_meta SET seq = 2, root = 'fresh'");
          db.execute('COMMIT');
        });
        connection.close();
        final current = File(path).readAsBytesSync();
        final start = (layout.page - 1) * layout.size;
        current.setRange(start, start + layout.size, previous, start);
        File(path).writeAsBytesSync(current, flush: true);
        connection = open();
        connection.use((db) {
          expect(db.select('SELECT seq FROM probe_meta').single['seq'], 2);
          expect(
            db.select('SELECT root FROM probe_meta').single['root'],
            'fresh',
          );
          expect(
            db.select('SELECT reserved FROM probe_data').single['reserved'],
            1,
          );
        });
        final beforeRejection = File(path).readAsBytesSync();
        final owned = connection;
        expect(
          () => PlainSqliteKvLogStore(owned, keys: keys),
          throwsUnsupportedError,
        );
        expect(File(path).readAsBytesSync(), beforeRejection);
      } finally {
        connection?.close();
        dir.deleteSync(recursive: true);
      }
    },
  );
}
