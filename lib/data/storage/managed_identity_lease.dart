import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/posix_file_facts.dart';
import '../../domain/storage_protection.dart';
import 'managed_identity_catalog.dart';
import 'managed_fs_platform.dart';
import 'managed_sqlite_connection.dart';
import 'native_handle_close.dart';

part 'managed_profile_lease.dart';

enum ManagedLeaseFailureKind { invalid, mismatch, closed, busy }

/// No local locator, path, credentials or native error text is included.
final class ManagedLeaseFailure implements Exception {
  const ManagedLeaseFailure(this.kind);
  final ManagedLeaseFailureKind kind;
  @override
  String toString() => 'ManagedLeaseFailure(${kind.name})';
}

/// Public identity-role metadata and a lifetime identity lease. All cooperating
/// backend owners acquire it before payloads and retain it until those close.
/// POSIX additionally holds flock on an independent open-file description:
/// closing an unrelated fd must not release the identity to another writer.
/// Windows uses SQLite's handle-bound locking. The metadata SQL transaction
/// remains EXCLUSIVE on all hosts. It does not authenticate plaintext against
/// a hostile filesystem or authorize cleanup. Never unlink/recreate a lease
/// to bypass contention. Live database backup still requires quiescence.
final class ManagedIdentityLease {
  ManagedIdentityLease._(this._connection, this.entry);
  final ManagedSqliteConnection _connection;
  final ManagedIdentityEntry entry;
  bool _closing = false;
  bool _closed = false;
  bool _transactionHeld = false;
  PosixSidecarLock? _posixLock;
  late final _connectionRelease = NativeHandleClose(_connection.close);

  static const _applicationId = 0x58564c53;
  static const _schema =
      'CREATE TABLE identity_role ('
      'id INTEGER PRIMARY KEY CHECK (id = 1), '
      'identity TEXT NOT NULL, protection TEXT NOT NULL)';

  /// Consumes an admitted, freshly reserved plaintext connection. Existing
  /// schemas/metadata are never relabelled after an initialization error.
  static ManagedIdentityLease initializeOwned(
    ManagedSqliteConnection connection, {
    required ManagedIdentityEntry entry,
  }) {
    final lease = ManagedIdentityLease._(connection, entry);
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
        if (db.select('SELECT 1 FROM sqlite_master LIMIT 1').isNotEmpty ||
            _pragma(db, 'application_id') != 0 ||
            _pragma(db, 'user_version') != 0) {
          throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
        }
        db.execute('BEGIN EXCLUSIVE');
        try {
          db.execute(_schema);
          db.execute('PRAGMA application_id = $_applicationId');
          db.execute('PRAGMA user_version = 1');
          db.execute('INSERT INTO identity_role VALUES (1, ?, ?)', [
            entry.id.value,
            entry.protection.name,
          ]);
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

  /// Consumes the connection even on mismatch/contention/corruption. No open
  /// error falls back to initialization or to a different protection mode.
  static ManagedIdentityLease openOwned(
    ManagedSqliteConnection connection, {
    required ManagedIdentityEntry expected,
  }) {
    final lease = ManagedIdentityLease._(connection, expected);
    try {
      lease._posixLock = PosixSidecarLock.acquire(connection.filePath);
      lease._configure();
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
    db.execute('BEGIN EXCLUSIVE');
    _transactionHeld = true;
    final schema = db.select(
      'SELECT type, name, sql FROM sqlite_master LIMIT 2',
    );
    if (_pragma(db, 'application_id') != _applicationId ||
        _pragma(db, 'user_version') != 1 ||
        schema.length != 1 ||
        schema.single['type'] != 'table' ||
        schema.single['name'] != 'identity_role' ||
        schema.single['sql'] != _schema) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    final rows = db.select(
      'SELECT id, CASE WHEN typeof(identity) = \'text\' AND '
      'length(CAST(identity AS BLOB)) = 32 THEN identity END AS identity, '
      'CASE WHEN typeof(protection) = \'text\' AND '
      'length(CAST(protection AS BLOB)) <= 16 THEN protection END AS protection '
      'FROM identity_role LIMIT 2',
    );
    if (rows.length != 1 ||
        rows.single['id'] != 1 ||
        rows.single['identity'] is! String ||
        rows.single['protection'] is! String) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    final row = rows.single;
    // Validate syntax/mode before comparing so malformed metadata is not
    // accepted just because a caller supplied a similarly malformed locator.
    final ManagedIdentityId id;
    try {
      id = ManagedIdentityId(row['identity'] as String);
    } on FormatException {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    final protection = switch (row['protection']) {
      'encrypted' => StorageProtection.encrypted,
      'unencrypted' => StorageProtection.unencrypted,
      _ => throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid),
    };
    if (id != entry.id || protection != entry.protection) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.mismatch);
    }
  });

  void requireHeld() {
    if (_closing || _closed || !_transactionHeld) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.closed);
    }
  }

  /// A failed release blocks use and is retryable; a caller must not publish
  /// or hand off the identity until close completes successfully.
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

/// Independent permanent sidecar: flock and fcntl can conflict on the SAME
/// inode on BSD hosts. FILE* supplies a native finalizer with the correct
/// pointer argument. GC finalization is a fallback, not a prompt worker-close
/// barrier: worker teardown must explicitly close all native owners.
final class PosixSidecarLock implements Finalizable {
  PosixSidecarLock._(this._fd, this._stream, this._flock, this._fclose) {
    _finalizer.attach(this, _stream, detach: this);
  }
  int _fd;
  Pointer<Void> _stream;
  final int Function(int, int) _flock;
  final int Function(Pointer<Void>) _fclose;
  // As in sqlite3's close/finalize callbacks, the native int return is ignored
  // by NativeFinalizer; its opaque pointer argument matches FILE* exactly.
  static final _finalizer = NativeFinalizer(
    DynamicLibrary.process()
        .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>('fclose')
        .cast(),
  );

  /// Publish a new empty sidecar with private permissions at creation. A
  /// concurrent publisher can open it as soon as its name becomes visible.
  static void reservePrivate(String path) {
    final apple = Platform.isMacOS || Platform.isIOS;
    final lib = DynamicLibrary.process();
    final open = lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
          int Function(Pointer<Utf8>, int, int)
        >('open');
    final close = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    final name = path.toNativeUtf8();
    try {
      // O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC. O_EXCL refuses an existing
      // name, including a symbolic link. The caller checks the winning leaf.
      final flags = 1 | (apple ? 0x1000a00 : 0x800c0);
      final fd = open(name, flags, 0x180);
      if (fd >= 0) {
        if (close(fd) != 0) {
          throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
        }
      } else if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
      }
    } finally {
      calloc.free(name);
    }
  }

  static PosixSidecarLock? acquire(
    String file, {
    bool create = false,
    bool shared = false,
  }) {
    final path = '$file.lock';
    if (create) {
      const ManagedFsPlatform().reserveNewFile(path);
      if (!Platform.isWindows && posixChmod(path, 0x180) != 0) {
        throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
      }
      final created = File(path).openSync(mode: FileMode.append);
      try {
        created.flushSync();
      } finally {
        created.closeSync();
      }
    }
    // Keep the empty marker on Windows too so closed profiles remain portable.
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file ||
        File(path).lengthSync() != 0) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    if (Platform.isWindows) return null;
    final facts = posixLstat(path);
    if (facts == null ||
        !facts.isRegularFile ||
        facts.uid != posixEuid() ||
        facts.permissions & 0x3f != 0) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    final name = path.toNativeUtf8();
    final mode = 'r+'.toNativeUtf8();
    var fd = -1;
    int Function(int)? close;
    try {
      final lib = DynamicLibrary.process();
      final open = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('open');
      close = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
      );
      final flock = lib
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'flock',
          );
      final fdopen = lib
          .lookupFunction<
            Pointer<Void> Function(Int32, Pointer<Utf8>),
            Pointer<Void> Function(int, Pointer<Utf8>)
          >('fdopen');
      final fclose = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('fclose');
      Pointer<Int32> Function()? errno;
      for (final symbol in ['__error', '__errno_location', '__errno']) {
        try {
          errno = lib
              .lookupFunction<
                Pointer<Int32> Function(),
                Pointer<Int32> Function()
              >(symbol);
          break;
        } on ArgumentError {
          continue;
        }
      }
      final apple = Platform.isMacOS || Platform.isIOS;
      // O_RDWR | O_NOFOLLOW | O_CLOEXEC; the sidecar is never recreated on open.
      fd = open(name, 2 | (apple ? 0x100 | 0x1000000 : 0x20000 | 0x80000));
      if (fd < 0) {
        throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
      }
      if (flock(fd, (shared ? 1 : 2) | 4) != 0) {
        final error = errno?.call().value;
        throw ManagedLeaseFailure(
          error == 11 || error == 35
              ? ManagedLeaseFailureKind.busy
              : ManagedLeaseFailureKind.invalid,
        );
      }
      final stream = fdopen(fd, mode);
      if (stream == nullptr) {
        throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
      }
      final PosixSidecarLock result;
      try {
        result = PosixSidecarLock._(fd, stream, flock, fclose);
      } catch (_) {
        fd = -1;
        fclose(stream);
        rethrow;
      }
      fd = -1; // FILE* owns it from here, including native finalization.
      return result;
    } on ManagedLeaseFailure {
      rethrow;
    } catch (_) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    } finally {
      if (fd >= 0) close?.call(fd);
      calloc.free(name);
      calloc.free(mode);
    }
  }

  void close() {
    if (_stream == nullptr) return;
    if (_flock(_fd, 8) != 0) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
    final stream = _stream;
    _stream = nullptr;
    _fd = -1;
    _finalizer.detach(this);
    // The lock was released before fclose. A consumed FILE* must never be
    // retried (even after EINTR), because its address/fd can now be reused.
    if (_fclose(stream) != 0) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.invalid);
    }
  }
}
