import 'package:sqlite3/sqlite3.dart';

import 'managed_identity_catalog.dart';
import 'managed_sqlite_connection.dart';

/// No locator, path, payload or native error text is included in failures.
enum ManagedCatalogFailureKind { invalid, conflict, full, exhausted, closed }

final class ManagedCatalogFailure implements Exception {
  const ManagedCatalogFailure(this.kind);
  final ManagedCatalogFailureKind kind;

  @override
  String toString() => 'ManagedCatalogFailure(${kind.name})';
}

final class ManagedCatalogSnapshot {
  const ManagedCatalogSnapshot(this.catalog, this.revision);
  final ManagedIdentityCatalog catalog;

  /// Local change counter, not an authentication or rollback-protection claim.
  final int revision;
}

/// Durable PUBLIC metadata for visible identities only. The connection is
/// consumed on entry, including failed initialization/open. Call on a worker
/// after filesystem admission; this class never creates directories, discovers
/// hidden spaces, opens identities or deletes their files.
///
/// Mutations reload the current catalog under SQLite's write transaction,
/// rather than overwriting a snapshot read before another owner registered an
/// identity. Contention fails explicitly; callers may retry the whole method.
final class ManagedCatalogStore {
  ManagedCatalogStore.initializeOwned(ManagedSqliteConnection connection)
    : this._(connection, initialize: true);

  ManagedCatalogStore.openOwned(ManagedSqliteConnection connection)
    : this._(connection, initialize: false);

  ManagedCatalogStore._(this._connection, {required bool initialize}) {
    try {
      _connection.use((db) {
        db.execute('PRAGMA trusted_schema = OFF');
        db.execute('PRAGMA temp_store = MEMORY');
        db.execute('PRAGMA busy_timeout = 0');
        db.execute('PRAGMA synchronous = EXTRA');
        db.execute('PRAGMA secure_delete = ON');
        // Do not convert a foreign/WAL database as an unlock side effect.
        if (db.select('PRAGMA journal_mode').single.values.single != 'delete') {
          throw const ManagedCatalogFailure(ManagedCatalogFailureKind.invalid);
        }
        _transaction(db, write: initialize, () {
          if (initialize) {
            if (db.select('SELECT 1 FROM sqlite_master LIMIT 1').isNotEmpty ||
                _pragma(db, 'application_id') != 0 ||
                _pragma(db, 'user_version') != 0) {
              throw const ManagedCatalogFailure(
                ManagedCatalogFailureKind.invalid,
              );
            }
            db.execute(_schema);
            db.execute('PRAGMA application_id = $_applicationId');
            db.execute('PRAGMA user_version = 1');
            db.execute('INSERT INTO managed_catalog VALUES (1, 0, ?)', [
              ManagedIdentityCatalog([]).encode(),
            ]);
          }
          _validateSchema(db);
          _read(db);
        });
      });
    } catch (_) {
      close();
      rethrow;
    }
  }

  static const _applicationId = 0x58564d43;
  static const _maxRevision = 0x7fffffffffffffff;
  static const _schema =
      'CREATE TABLE managed_catalog ('
      'id INTEGER PRIMARY KEY CHECK (id = 1), '
      'revision INTEGER NOT NULL CHECK (revision >= 0), '
      'payload TEXT NOT NULL)';
  final ManagedSqliteConnection _connection;
  bool _closed = false;

  ManagedCatalogSnapshot snapshot() =>
      _use((db) => _transaction(db, write: false, () => _read(db)));

  /// Idempotent after a lost response: the same ID/mode is already registered.
  /// A different mode is refused, never used as a plaintext downgrade request.
  ManagedCatalogSnapshot register(ManagedIdentityEntry entry) => _use(
    (db) => _transaction(db, write: true, () {
      final current = _read(db);
      for (final previous in current.catalog.identities) {
        if (previous.id != entry.id) continue;
        if (previous.protection != entry.protection) {
          throw const ManagedCatalogFailure(ManagedCatalogFailureKind.conflict);
        }
        return current;
      }
      if (current.catalog.identities.length >=
          ManagedIdentityCatalog.maxIdentities) {
        throw const ManagedCatalogFailure(ManagedCatalogFailureKind.full);
      }
      if (current.revision == _maxRevision) {
        throw const ManagedCatalogFailure(ManagedCatalogFailureKind.exhausted);
      }
      final next = ManagedIdentityCatalog([
        ...current.catalog.identities,
        entry,
      ]);
      final revision = current.revision + 1;
      db.execute(
        'UPDATE managed_catalog SET revision = ?, payload = ? WHERE id = 1',
        [revision, next.encode()],
      );
      return ManagedCatalogSnapshot(next, revision);
    }),
  );

  static int _pragma(Database db, String name) =>
      db.select('PRAGMA $name').single.values.single as int;

  static void _validateSchema(Database db) {
    final schema = db.select(
      'SELECT type, name, sql FROM sqlite_master LIMIT 2',
    );
    if (_pragma(db, 'application_id') != _applicationId ||
        _pragma(db, 'user_version') != 1 ||
        schema.length != 1 ||
        schema.single['type'] != 'table' ||
        schema.single['name'] != 'managed_catalog' ||
        schema.single['sql'] != _schema) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.invalid);
    }
  }

  static ManagedCatalogSnapshot _read(Database db) {
    // Apply the byte limit in SQLite, before a potentially corrupt TEXT value
    // crosses into Dart. Read the entire bounded catalog, not a filtered subset
    // that would silently hide malformed rows.
    final rows = db.select(
      'SELECT id, revision, CASE WHEN typeof(payload) = \'text\' AND '
      'length(CAST(payload AS BLOB)) <= ? THEN payload END AS payload '
      'FROM managed_catalog LIMIT 2',
      [ManagedIdentityCatalog.maxEncodedBytes],
    );
    if (rows.length != 1) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.invalid);
    }
    final row = rows.single;
    final revision = row['revision'];
    final payload = row['payload'];
    if (row['id'] != 1 ||
        revision is! int ||
        revision < 0 ||
        payload is! String) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.invalid);
    }
    try {
      return ManagedCatalogSnapshot(
        ManagedIdentityCatalog.decode(payload),
        revision,
      );
    } on FormatException {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.invalid);
    }
  }

  T _use<T>(T Function(Database) action) {
    if (_closed) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.closed);
    }
    return _connection.use(action);
  }

  T _transaction<T>(Database db, T Function() action, {required bool write}) {
    if (!db.autocommit) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.invalid);
    }
    db.execute(write ? 'BEGIN IMMEDIATE' : 'BEGIN');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      if (!db.autocommit) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {
          // An uncertain transaction must never be reused by another caller.
          close();
        }
      }
      rethrow;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _connection.close();
  }
}
