import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/managed_sqlite_connection.dart';

// Boundary of explicit plaintext storage: hostile filesystem page edits are
// not authenticated. Historical SQLCipher replay evidence is documented in
// STORAGE-MODES.md; this ordinary SQLite case does not requalify that engine.
void main() {
  test(
    'plaintext storage does not claim authenticated protection from page replay',
    () {
      final dir = Directory.systemTemp.createTempSync('managed-replay-probe-');
      final path = '${dir.path}/identity';
      ManagedSqliteConnection open({bool create = false}) =>
          ManagedSqliteConnection.openUnencrypted(path, create: create);
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
      } finally {
        connection?.close();
        dir.deleteSync(recursive: true);
      }
    },
  );
}
