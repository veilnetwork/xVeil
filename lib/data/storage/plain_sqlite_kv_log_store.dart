import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../domain/storage_protection.dart';
import 'kv_log_store.dart';
import 'managed_sqlite_connection.dart';
import 'rollback_anchor.dart';

/// Experimental managed-identity adapter. The application does not select it
/// yet: admission/worker ownership and password derivation must be qualified
/// before enabling it. The connection belongs to this adapter after entry.
final class PlainSqliteKvLogStore
    implements KvLogStore, SyncCommitAnchorSource {
  PlainSqliteKvLogStore(
    this._connection, {
    required Uint8List keys,
    bool initialize = false,
  }) : _keys = Uint8List.fromList(keys) {
    try {
      // SQLCipher page authentication does not prevent replay of an older
      // valid data page while metadata/commit roots remain new. A native
      // qualification probe reproduced exactly that rollback. Ratchet state
      // therefore MUST NOT use this adapter in an encrypted identity.
      if (_connection.protection != StorageProtection.unencrypted) {
        throw UnsupportedError(
          'Encrypted identities require authenticated storage state',
        );
      }
      if (keys.length != 64) {
        throw ArgumentError('Invalid managed identity storage credentials');
      }
      _connection.use((db) {
        if (initialize) db.execute('PRAGMA auto_vacuum = FULL');
        db.execute('PRAGMA journal_mode = DELETE');
        db.execute('PRAGMA synchronous = EXTRA');
        db.execute('PRAGMA secure_delete = ON');
        db.execute('PRAGMA temp_store = MEMORY');
        db.execute('PRAGMA cache_size = -4096');
        db.execute('PRAGMA busy_timeout = 0');
        if (initialize) _initialize(db, StorageProtection.unencrypted);
        final row = db.select('SELECT * FROM store_meta WHERE id = 1').single;
        if (row['version'] != 1 ||
            row['protection'] != StorageProtection.unencrypted.name ||
            !_same(row['witness'] as Uint8List, _witness())) {
          throw const ManagedSqliteFailure(ManagedSqliteFailureKind.open);
        }
        if (db.select('PRAGMA auto_vacuum').single.values.single != 1 ||
            db.select('PRAGMA synchronous').single.values.single != 3) {
          throw const ManagedSqliteFailure(ManagedSqliteFailureKind.open);
        }
      });
    } catch (_) {
      _keys.fillRange(0, _keys.length, 0);
      _connection.close();
      rethrow;
    }
  }

  final ManagedSqliteConnection _connection;
  final Uint8List _keys;
  bool _closed = false;

  Uint8List _witness() => Uint8List.fromList(
    Hmac(sha256, _keys).convert(utf8.encode('xveil-managed-store-v1')).bytes,
  );

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  void _initialize(Database db, StorageProtection protection) {
    final random = Random.secure();
    final root = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('''CREATE TABLE store_meta (
        id INTEGER PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL,
        protection TEXT NOT NULL, seq INTEGER NOT NULL,
        root BLOB NOT NULL, witness BLOB NOT NULL)''');
      db.execute('''CREATE TABLE store_kv (
        ns INTEGER NOT NULL, key BLOB NOT NULL, value BLOB NOT NULL,
        PRIMARY KEY(ns, key)) WITHOUT ROWID''');
      db.execute('''CREATE TABLE store_log (
        ns INTEGER NOT NULL, id INTEGER NOT NULL, value BLOB NOT NULL,
        PRIMARY KEY(ns, id)) WITHOUT ROWID''');
      db.execute('''CREATE TABLE store_epochs (
        seq INTEGER PRIMARY KEY, root BLOB NOT NULL)''');
      db.execute('INSERT INTO store_meta VALUES (1, 1, ?, 0, ?, ?)', [
        protection.name,
        root,
        _witness(),
      ]);
      db.execute('INSERT INTO store_epochs VALUES (0, ?)', [root]);
      db.execute('COMMIT');
    } catch (_) {
      _rollback(db);
      rethrow;
    }
  }

  static void _rollback(Database db) {
    try {
      db.execute('ROLLBACK');
    } catch (_) {
      // Preserve the original failure; no successful commit is reported.
    }
  }

  static void _namespace(int ns) {
    if (ns <= 0 || ns > 255) throw ArgumentError('Invalid storage namespace');
  }

  static void _logId(int id) {
    if (id <= 0) throw ArgumentError('Invalid storage log ID');
  }

  static Uint8List _u64(int value) =>
      (ByteData(8)..setUint64(0, value, Endian.big)).buffer.asUint8List();

  static void _field(BytesBuilder out, Uint8List bytes) {
    out.add(_u64(bytes.length));
    out.add(bytes);
  }

  /// Atomic commit: payloads, commit number and fork-detection root become
  /// durable in the SAME SQLite transaction. No successful return precedes
  /// COMMIT with synchronous=EXTRA. Reclamation retains these logical anchors.
  @override
  int commit(List<KvLogOp> ops) {
    for (final op in ops) {
      switch (op) {
        case PutOp(:final namespace, :final key, :final value):
          _namespace(namespace);
          if (key.isEmpty || value.length > 2048) {
            throw ArgumentError('Invalid managed KV write');
          }
        case DeleteOp(:final namespace, :final key):
          _namespace(namespace);
          if (key.isEmpty) throw ArgumentError('Invalid managed KV key');
        case AppendLogOp(:final namespace, :final logId):
          _namespace(namespace);
          _logId(logId);
        case DeleteLogOp(:final namespace, :final logId):
          _namespace(namespace);
          _logId(logId);
      }
    }
    return _connection.use((db) {
      if (ops.isEmpty) return _seq(db);
      db.execute('BEGIN IMMEDIATE');
      try {
        final previous = db.select('SELECT seq, root FROM store_meta').single;
        final seq = (previous['seq'] as int) + 1;
        if (seq <= 0) throw StateError('Managed commit sequence exhausted');
        final digest = BytesBuilder(copy: false)
          ..add(utf8.encode('xveil-managed-commit-v1'))
          ..add(previous['root'] as Uint8List)
          ..add(_u64(seq))
          ..add(_u64(ops.length));
        for (final op in ops) {
          switch (op) {
            case PutOp(:final namespace, :final key, :final value):
              digest.add([1, namespace]);
              _field(digest, key);
              _field(digest, value);
              db.execute('INSERT OR REPLACE INTO store_kv VALUES (?, ?, ?)', [
                namespace,
                key,
                value,
              ]);
            case DeleteOp(:final namespace, :final key):
              digest.add([2, namespace]);
              _field(digest, key);
              db.execute('DELETE FROM store_kv WHERE ns = ? AND key = ?', [
                namespace,
                key,
              ]);
            case AppendLogOp(:final namespace, :final logId, :final payload):
              digest.add([3, namespace]);
              digest.add(_u64(logId));
              _field(digest, payload);
              db.execute('INSERT OR REPLACE INTO store_log VALUES (?, ?, ?)', [
                namespace,
                logId,
                payload,
              ]);
            case DeleteLogOp(:final namespace, :final logId):
              digest.add([4, namespace]);
              digest.add(_u64(logId));
              db.execute('DELETE FROM store_log WHERE ns = ? AND id = ?', [
                namespace,
                logId,
              ]);
          }
        }
        final root = Uint8List.fromList(
          sha256.convert(digest.takeBytes()).bytes,
        );
        db.execute('UPDATE store_meta SET seq = ?, root = ? WHERE id = 1', [
          seq,
          root,
        ]);
        db.execute('INSERT INTO store_epochs VALUES (?, ?)', [seq, root]);
        db.execute('DELETE FROM store_epochs WHERE seq <= ?', [
          seq - anchorHorizon,
        ]);
        db.execute('COMMIT');
        return seq;
      } catch (_) {
        _rollback(db);
        rethrow;
      }
    });
  }

  static int _seq(Database db) =>
      db.select('SELECT seq FROM store_meta WHERE id = 1').single['seq'] as int;

  @override
  int commitSeq() => _connection.use(_seq);

  @override
  List<int> commitHistory() => _connection.use(
    (db) => [
      for (final row in db.select('SELECT seq FROM store_epochs ORDER BY seq'))
        row['seq'] as int,
    ],
  );

  @override
  Map<int, String> commitRoots() => _connection.use(
    (db) => {
      for (final row in db.select(
        'SELECT seq, root FROM store_epochs ORDER BY seq',
      ))
        row['seq'] as int: (row['root'] as Uint8List)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
    },
  );

  static Uint8List? _value(ResultSet result) => result.isEmpty
      ? null
      : Uint8List.fromList(result.single['value'] as Uint8List);

  @override
  Uint8List? get(int namespace, Uint8List key) {
    _namespace(namespace);
    return _connection.use(
      (db) => _value(
        db.select('SELECT value FROM store_kv WHERE ns = ? AND key = ?', [
          namespace,
          key,
        ]),
      ),
    );
  }

  @override
  Uint8List? readLog(int namespace, int logId) {
    _namespace(namespace);
    _logId(logId);
    return _connection.use(
      (db) => _value(
        db.select('SELECT value FROM store_log WHERE ns = ? AND id = ?', [
          namespace,
          logId,
        ]),
      ),
    );
  }

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    _namespace(namespace);
    if (limit < 0) throw ArgumentError('Invalid storage read limit');
    return _connection.use(
      (db) => [
        for (final row in db.select(
          '''SELECT id, value FROM store_log
        WHERE ns = ? AND (? IS NULL OR id >= ?) AND (? IS NULL OR id < ?)
        ORDER BY id LIMIT ?''',
          [namespace, start, start, end, end, limit],
        ))
          KvLogEntry(
            row['id'] as int,
            Uint8List.fromList(row['value'] as Uint8List),
          ),
      ],
    );
  }

  @override
  int count(int namespace) {
    _namespace(namespace);
    return _connection.use(
      (db) =>
          db
                  .select(
                    '''SELECT
      (SELECT count(*) FROM store_kv WHERE ns = ?) +
      (SELECT count(*) FROM store_log WHERE ns = ?) AS n''',
                    [namespace, namespace],
                  )
                  .single['n']
              as int,
    );
  }

  @override
  List<Uint8List> kvKeys(int namespace) {
    _namespace(namespace);
    return _connection.use(
      (db) => [
        for (final row in db.select(
          'SELECT key FROM store_kv WHERE ns = ? ORDER BY key',
          [namespace],
        ))
          Uint8List.fromList(row['key'] as Uint8List),
      ],
    );
  }

  @override
  int eraseNamespace(int namespace) {
    _namespace(namespace);
    return _connection.use((db) {
      db.execute('BEGIN IMMEDIATE');
      try {
        final count =
            db
                    .select(
                      '''SELECT
          (SELECT count(*) FROM store_kv WHERE ns = ?) +
          (SELECT count(*) FROM store_log WHERE ns = ?) AS n''',
                      [namespace, namespace],
                    )
                    .single['n']
                as int;
        if (count == 0) {
          db.execute('COMMIT');
          return 0;
        }
        final previous = db.select('SELECT seq, root FROM store_meta').single;
        final seq = (previous['seq'] as int) + 1;
        if (seq <= 0) throw StateError('Managed commit sequence exhausted');
        final digest = BytesBuilder(copy: false)
          ..add(utf8.encode('xveil-managed-commit-v1'))
          ..add(previous['root'] as Uint8List)
          ..add(_u64(seq))
          ..add(_u64(1))
          ..add([5, namespace]);
        final root = Uint8List.fromList(
          sha256.convert(digest.takeBytes()).bytes,
        );
        db.execute('DELETE FROM store_kv WHERE ns = ?', [namespace]);
        db.execute('DELETE FROM store_log WHERE ns = ?', [namespace]);
        db.execute('UPDATE store_meta SET seq = ?, root = ? WHERE id = 1', [
          seq,
          root,
        ]);
        db.execute('INSERT INTO store_epochs VALUES (?, ?)', [seq, root]);
        db.execute('DELETE FROM store_epochs WHERE seq <= ?', [
          seq - anchorHorizon,
        ]);
        db.execute('COMMIT');
        return count;
      } catch (_) {
        _rollback(db);
        rethrow;
      }
    });
  }

  @override
  void scrub() => _connection.use((db) => db.execute('VACUUM'));

  @override
  Uint8List exportKeys() {
    if (_closed) {
      throw const ManagedSqliteFailure(ManagedSqliteFailureKind.closed);
    }
    return Uint8List.fromList(_keys);
  }

  @override
  SlotUtilization? slotUtilization() => null; // SQL pages are not HV slots.
  @override
  String? hardeningWarning() => null;
  @override
  void acknowledgeHardeningWarning() {}

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _keys.fillRange(0, _keys.length, 0);
    _connection.close();
  }
}
