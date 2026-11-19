part of 'managed_identity_lease.dart';

enum ManagedProfileLeaseRole { publishedRoot, storageProfile }

/// A lifetime reader/writer lease for the whole enumerable root. Catalog and
/// identity owners retain SHARED leases; destructive profile maintenance needs
/// EXCLUSIVE admission after all such owners have actually closed. This public
/// role contains no identity locators, credentials or hidden-space information.
/// It coordinates cooperating processes, not hostile same-user filesystem edits.
final class ManagedProfileLease {
  ManagedProfileLease._(
    this._connection, {
    required this.exclusive,
    required this.role,
  });
  final ManagedSqliteConnection _connection;
  final bool exclusive;
  final ManagedProfileLeaseRole role;
  bool _closed = false, _closing = false, _transactionHeld = false;
  PosixSidecarLock? _posixLock;
  late final _connectionRelease = NativeHandleClose(_connection.close);

  static const fileName = 'profile.meta';
  static const _applicationId = 0x5856504c;
  String get _role => switch (role) {
    ManagedProfileLeaseRole.publishedRoot => 'xveil-managed-profile-v1',
    ManagedProfileLeaseRole.storageProfile => 'xveil-storage-lifetime-v1',
  };
  static const _schema =
      'CREATE TABLE profile_role ('
      'id INTEGER PRIMARY KEY CHECK (id = 1), role TEXT NOT NULL)';

  /// Only for the unpublished, freshly reserved managed-root bootstrap.
  /// Consumes the supplied connection on every outcome, like identity leases.
  static ManagedProfileLease initializeOwned(
    ManagedSqliteConnection connection, {
    ManagedProfileLeaseRole role = ManagedProfileLeaseRole.publishedRoot,
  }) {
    final lease = ManagedProfileLease._(
      connection,
      exclusive: true,
      role: role,
    );
    try {
      lease._configure();
      connection.use((db) {
        if (db.select('SELECT 1 FROM sqlite_master LIMIT 1').isNotEmpty ||
            _pragma(db, 'application_id') != 0 ||
            _pragma(db, 'user_version') != 0) {
          throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
        }
      });
      lease._posixLock = PosixSidecarLock.acquire(
        connection.filePath,
        create: true,
      );
      connection.use((db) {
        db.execute('BEGIN EXCLUSIVE');
        try {
          if (db.select('SELECT 1 FROM sqlite_master LIMIT 1').isNotEmpty ||
              _pragma(db, 'application_id') != 0 ||
              _pragma(db, 'user_version') != 0) {
            throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
          }
          db.execute(_schema);
          db.execute('PRAGMA application_id = $_applicationId');
          db.execute('PRAGMA user_version = 1');
          db.execute('INSERT INTO profile_role VALUES (1, ?)', [lease._role]);
          db.execute('COMMIT');
        } catch (_) {
          if (!db.autocommit) db.execute('ROLLBACK');
          rethrow;
        }
      });
      lease._acquire();
      return lease;
    } catch (_) {
      lease.close();
      rethrow;
    }
  }

  /// Never initializes a missing, corrupt or foreign role. Native lifetime
  /// locks are nonblocking: a conflict is a refusal, not a hidden retry queue
  /// that could create data after a completed wipe.
  static ManagedProfileLease openOwned(
    ManagedSqliteConnection connection, {
    bool exclusive = false,
    ManagedProfileLeaseRole role = ManagedProfileLeaseRole.publishedRoot,
  }) {
    final lease = ManagedProfileLease._(
      connection,
      exclusive: exclusive,
      role: role,
    );
    try {
      lease._configure();
      lease._posixLock = PosixSidecarLock.acquire(
        connection.filePath,
        shared: !exclusive,
      );
      lease._acquire();
      return lease;
    } catch (_) {
      lease.close();
      rethrow;
    }
  }

  void _configure() => _connection.use((db) {
    db.execute('PRAGMA trusted_schema = OFF');
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA busy_timeout = 0');
    db.execute('PRAGMA synchronous = EXTRA');
    if (db.select('PRAGMA journal_mode').single.values.single != 'delete') {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
  });
  static int _pragma(Database db, String name) =>
      db.select('PRAGMA $name').single.values.single as int;

  void _acquire() => _connection.use((db) {
    db.execute(exclusive ? 'BEGIN EXCLUSIVE' : 'BEGIN DEFERRED');
    _transactionHeld = true;
    // A deferred transaction holds no SHARED lock until it actually reads.
    final schema = db.select(
      'SELECT type, name, sql FROM sqlite_master LIMIT 2',
    );
    if (_pragma(db, 'application_id') != _applicationId ||
        _pragma(db, 'user_version') != 1 ||
        schema.length != 1 ||
        schema.single['type'] != 'table' ||
        schema.single['name'] != 'profile_role' ||
        schema.single['sql'] != _schema) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    final rows = db.select(
      "SELECT id, CASE WHEN typeof(role) = 'text' AND "
      'length(CAST(role AS BLOB)) = ${_role.length} THEN role END AS role '
      'FROM profile_role LIMIT 2',
    );
    if (rows.length != 1 ||
        rows.single['id'] != 1 ||
        rows.single['role'] != _role) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
  });

  void requireHeld({bool exclusive = false}) {
    if (_closing || _closed || !_transactionHeld) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.closed);
    }
    if (exclusive && !this.exclusive) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.mismatch);
    }
  }

  void close() {
    if (_closed) return;
    _closing = true;
    if (_transactionHeld) {
      _connection.use((db) {
        if (!db.autocommit) db.execute('ROLLBACK');
      });
      _transactionHeld = false;
    }
    _connectionRelease.close();
    _posixLock?.close();
    _posixLock = null;
    _closed = true;
  }
}
