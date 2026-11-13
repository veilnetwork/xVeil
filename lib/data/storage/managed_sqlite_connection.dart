import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../domain/storage_protection.dart';

enum ManagedSqliteFailureKind { unsupportedProtection, open, operation, closed }

/// Deliberately excludes SQL text, parameters, paths and native error messages.
final class ManagedSqliteFailure implements Exception {
  const ManagedSqliteFailure(this.kind, {this.sqliteCode});
  final ManagedSqliteFailureKind kind;
  final int? sqliteCode;

  @override
  String toString() => 'ManagedSqliteFailure(${kind.name}, $sqliteCode)';
}

/// Plaintext-only connection for explicitly enumerable, unencrypted stores.
/// Call on a storage worker. The caller must admit and exclusively own the
/// containing directory; leaf checks below do not prevent ancestor/rename races.
final class ManagedSqliteConnection {
  ManagedSqliteConnection._(this._database, this.filePath);
  Database? _database;

  /// Admitted local name for resource owners, not a cleanup capability.
  /// Never include this path in diagnostics or public metadata.
  final String filePath;
  StorageProtection get protection => StorageProtection.unencrypted;

  /// Deliberate architectural rejection, independent of the native provider.
  /// Authenticated pages alone did not protect encrypted ratchet state from
  /// page replay. Never create a file or try plaintext as an unlock fallback.
  static Never openEncrypted(
    String path, {
    required Uint8List key,
    required Uint8List salt,
    bool create = false,
  }) => throw const ManagedSqliteFailure(
    ManagedSqliteFailureKind.unsupportedProtection,
  );

  /// Actual plaintext storage, explicitly selected; never an unlock fallback.
  static ManagedSqliteConnection openUnencrypted(
    String path, {
    bool create = false,
  }) => _open(path, create: create);

  static ManagedSqliteConnection _open(String path, {required bool create}) {
    Database? database;
    try {
      path = File(path).absolute.path;
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if ((create && type != FileSystemEntityType.notFound) ||
          (!create && type != FileSystemEntityType.file)) {
        throw const ManagedSqliteFailure(ManagedSqliteFailureKind.open);
      }
      // Reserve the leaf with O_EXCL (or its platform equivalent). SQLite's
      // CREATE flag would otherwise adopt a file created after the check above.
      // No cleanup on failure: a separate path owner must decide whether this
      // still names its own stub before deleting it.
      if (create) File(path).createSync(exclusive: true);
      database = sqlite3.open(path, mode: OpenMode.readWrite);
      database.select('SELECT count(*) FROM sqlite_master');
      return ManagedSqliteConnection._(database, path);
    } catch (error) {
      database?.close();
      if (error is ManagedSqliteFailure) rethrow;
      if (error is SqliteException) {
        throw ManagedSqliteFailure(
          ManagedSqliteFailureKind.open,
          sqliteCode: error.resultCode,
        );
      }
      // Do not expose filesystem, native loader or database error text.
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
    database.close();
  }
}
