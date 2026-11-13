import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../domain/storage_protection.dart';

@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Int)>(
  symbol: 'sqlite3_key',
  assetId: 'package:sqlite3/src/ffi/libsqlite3.g.dart',
)
external int _setCipherKey(
  Pointer<Void> database,
  Pointer<Uint8> key,
  int length,
);

enum ManagedSqliteFailureKind { unavailableCipher, open, operation, closed }

/// Deliberately excludes SQL text, parameters, paths and native error messages.
final class ManagedSqliteFailure implements Exception {
  const ManagedSqliteFailure(this.kind, {this.sqliteCode});
  final ManagedSqliteFailureKind kind;
  final int? sqliteCode;

  @override
  String toString() => 'ManagedSqliteFailure(${kind.name}, $sqliteCode)';
}

/// Low-level experimental connection, not yet wired into application storage.
/// Call on a storage worker. Parent-directory ownership, persistence schema,
/// durable commits and the password KDF belong to the managed-store adapter.
final class ManagedSqliteConnection {
  ManagedSqliteConnection._(this._database, this.protection, this._keyDigest);
  Database? _database;
  final StorageProtection protection;
  final Uint8List? _keyDigest;

  /// Bind exported credentials to the key actually used by this connection,
  /// without retaining another plaintext encryption key buffer.
  bool keyedBy(Uint8List key) {
    final expected = _keyDigest;
    if (expected == null || _database == null || key.length != 32) return false;
    final actual = sha256.convert(key).bytes;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ actual[i];
    }
    return difference == 0;
  }

  static ManagedSqliteConnection openEncrypted(
    String path, {
    required Uint8List key,
    required Uint8List salt,
    bool create = false,
  }) {
    if (key.length != 32 || salt.length != 16) {
      throw ArgumentError('Expected a 32-byte key and 16-byte salt');
    }
    // Check an in-memory connection first. No on-disk file may be created if
    // the packaged provider lacks encryption; never fall back to plain SQLite.
    Database? probe;
    try {
      probe = sqlite3.openInMemory();
      final version = probe.select('PRAGMA cipher_version');
      if (version.isEmpty ||
          version.first.values.first is! String ||
          (version.first.values.first as String).isEmpty) {
        throw const ManagedSqliteFailure(
          ManagedSqliteFailureKind.unavailableCipher,
        );
      }
    } catch (_) {
      throw const ManagedSqliteFailure(
        ManagedSqliteFailureKind.unavailableCipher,
      );
    } finally {
      probe?.close();
    }
    return _open(path, create: create, key: key, salt: salt);
  }

  /// Actual plaintext storage, explicitly selected; never an unlock fallback.
  static ManagedSqliteConnection openUnencrypted(
    String path, {
    bool create = false,
  }) => _open(path, create: create);

  static ManagedSqliteConnection _open(
    String path, {
    required bool create,
    Uint8List? key,
    Uint8List? salt,
  }) {
    Database? database;
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if ((create && type != FileSystemEntityType.notFound) ||
          (!create && type != FileSystemEntityType.file)) {
        throw const ManagedSqliteFailure(ManagedSqliteFailureKind.open);
      }
      database = sqlite3.open(
        path,
        mode: create ? OpenMode.readWriteCreate : OpenMode.readWrite,
      );
      if (key != null) {
        // Use the C API, not a SQL statement containing the raw key. Native
        // SQLite errors and query traces must never receive a key-bearing SQL
        // string. SQLCipher's documented x'<key><salt>' form is 99 bytes.
        final buffer = calloc<Uint8>(100);
        try {
          final bytes = buffer.asTypedList(100);
          bytes[0] = 0x78;
          bytes[1] = 0x27;
          var offset = 2;
          for (final source in [key, salt!]) {
            for (final value in source) {
              final hi = value >> 4;
              final lo = value & 15;
              bytes[offset++] = hi < 10 ? 48 + hi : 87 + hi;
              bytes[offset++] = lo < 10 ? 48 + lo : 87 + lo;
            }
          }
          bytes[98] = 0x27;
          if (_setCipherKey(database.handle.cast<Void>(), buffer, 99) != 0) {
            throw const ManagedSqliteFailure(ManagedSqliteFailureKind.open);
          }
        } finally {
          buffer.asTypedList(100).fillRange(0, 100, 0);
          calloc.free(buffer);
        }
        database.execute('PRAGMA cipher_memory_security = ON');
      }
      // Keying is lazy: only an actual schema read authenticates an existing
      // encrypted database. A successful sqlite3_key alone proves nothing.
      database.select('SELECT count(*) FROM sqlite_master');
      return ManagedSqliteConnection._(
        database,
        key == null
            ? StorageProtection.unencrypted
            : StorageProtection.encrypted,
        key == null ? null : Uint8List.fromList(sha256.convert(key).bytes),
      );
    } catch (error) {
      database?.close();
      if (error is ManagedSqliteFailure) rethrow;
      if (error is SqliteException) {
        throw ManagedSqliteFailure(
          ManagedSqliteFailureKind.open,
          sqliteCode: error.resultCode,
        );
      }
      // In particular, a missing native cipher symbol must not expose loader
      // paths or cause an attempt to reopen this file without encryption.
      throw const ManagedSqliteFailure(ManagedSqliteFailureKind.open);
    }
  }

  T use<T>(T Function(Database database) action) {
    final database = _database;
    if (database == null) {
      throw const ManagedSqliteFailure(ManagedSqliteFailureKind.closed);
    }
    try {
      return action(database);
    } on SqliteException catch (error) {
      throw ManagedSqliteFailure(
        ManagedSqliteFailureKind.operation,
        sqliteCode: error.resultCode,
      );
    }
  }

  void close() {
    final database = _database;
    if (database == null) return;
    _database = null;
    try {
      database.close();
    } finally {
      _keyDigest?.fillRange(0, _keyDigest.length, 0);
    }
  }
}
