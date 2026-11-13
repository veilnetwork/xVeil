import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:meta/meta.dart' show visibleForTesting;

import '../../domain/identity_erase_review.dart';
import '../../domain/storage_protection.dart';
import '../../domain/storage_usage.dart';
import '../native_libs.dart' show envLibPath;
import 'hv_kv_log_store.dart';
import 'hv_native.dart';
import 'kv_log_store.dart';
import 'managed_encrypted_kv_log_store.dart';
import 'managed_anchor_state.dart';
import 'managed_catalog_store.dart';
import 'managed_fs_platform.dart';
import 'managed_identity_catalog.dart';
import 'managed_identity_lease.dart';
import 'managed_keybox.dart';
import 'managed_metadata_blob.dart';
import 'managed_reclaim_budget.dart';
import 'managed_sqlite_connection.dart';
import 'managed_store_tag.dart';
import 'native_handle_close.dart';
import 'plain_sqlite_kv_log_store.dart';
import 'rollback_anchor.dart';

part 'managed_identity_files.dart';
part 'managed_identity_reclaim.dart';
part 'managed_identity_usage.dart';
part 'managed_identity_erase.dart';
part 'managed_identity_erase_review.dart';

/// Admits the filesystem root and owns its catalog connection. The companion
/// managed file factory owns identity sessions. No migration, hidden-space
/// discovery or recursive cleanup occurs here.
/// Must run on a storage worker. Existing legacy containers are never touched.
final class ManagedDirectoryCatalog {
  ManagedDirectoryCatalog._(
    this.profileDirectory,
    this.directory,
    this._profileWitness,
    this._rootWitness,
    this._catalogWitness,
    this._catalog,
    this._fs,
  );

  final String profileDirectory;
  final String directory;
  final ManagedPathWitness _profileWitness;
  final ManagedPathWitness _rootWitness;
  final ManagedPathWitness _catalogWitness;
  final ManagedCatalogStore _catalog;
  final ManagedFsPlatform _fs;
  bool _closed = false;
  late final _catalogRelease = NativeHandleClose(_catalog.close);
  final _identityOwners = <ManagedIdentityId, _ManagedIdentityResources>{};
  final _eraseReviews = <String, _ManagedEraseConsent>{};

  void _reserveIdentity(_ManagedIdentityResources owner) {
    _validate();
    if (_identityOwners.containsKey(owner.entry.id)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.busy);
    }
    _identityOwners[owner.entry.id] = owner;
  }

  void _releaseIdentity(_ManagedIdentityResources owner) {
    if (identical(_identityOwners[owner.entry.id], owner)) {
      _identityOwners.remove(owner.entry.id);
    }
  }

  static const _catalogName = 'catalog.sqlite3';
  String get _catalogPath => _child(directory, _catalogName);

  static String _child(String parent, String name) =>
      File.fromUri(Directory(parent).uri.resolve(name)).path;

  /// Null means ONLY an absent managed root, not an absent/corrupt catalog
  /// inside an existing root. The latter always fails closed.
  static ManagedDirectoryCatalog? openExisting(
    String profileDirectory, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) {
    return _safe(() {
      final profile = _admitProfile(profileDirectory, fs);
      final path = _child(profile.path, 'identities');
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return null;
      }
      return _open(profile.path, profile.witness, path, fs);
    });
  }

  /// Explicit new-mode initialization. Publishes a complete PRIVATE directory
  /// with its initialized catalog in a single no-replace rename. Competing
  /// creators open the winner, never overwrite it. Interrupted unpublished
  /// sibling directories are retained, not adopted or recursively swept.
  static ManagedDirectoryCatalog createOrOpen(
    String profileDirectory, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => _safe(() {
    final profile = _admitProfile(profileDirectory, fs);
    final path = _child(profile.path, 'identities');
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return _open(profile.path, profile.witness, path, fs);
    }
    final random = Random.secure();
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix = List.generate(
        16,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final staged = _child(profile.path, '.identities-$suffix.pending');
      _assertProfile(profile.path, profile.witness, fs);
      if (!fs.createPrivateDirectory(staged)) continue;
      final stagedWitness = _privateDirectory(staged, fs);
      ManagedPathWitness? fileWitness;
      ManagedSqliteConnection? connection;
      ManagedCatalogStore? catalog;
      var published = false;
      try {
        final file = File(_child(staged, _catalogName));
        file.createSync(exclusive: true);
        fileWitness = fs.inspect(file.path);
        fs.restrictNewFile(file.path);
        _assertSame(file.path, fileWitness, fs);
        connection = ManagedSqliteConnection.openUnencrypted(file.path);
        // Constructor consumes the connection even if initialization fails.
        final owned = connection;
        connection = null;
        catalog = ManagedCatalogStore.initializeOwned(owned);
        catalog.close();
        catalog = null;
        fs.syncDirectory(staged);
        _assertProfile(profile.path, profile.witness, fs);
        _assertSame(staged, stagedWitness, fs);
        _assertSame(file.path, fileWitness, fs);
        published = fs.publishDirectoryNoReplace(staged, path);
        if (published) {
          fs.syncDirectory(profile.path);
          _assertSame(path, stagedWitness, fs);
        }
      } finally {
        catalog?.close();
        connection?.close();
        if (!published) {
          // Only this exact, freshly created directory and its exact one file.
          // Unexpected content/replacement leaves everything intact for review.
          _discardOwnedEmptyBootstrap(staged, stagedWitness, fileWitness, fs);
        }
      }
      return _open(profile.path, profile.witness, path, fs);
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.io);
  });

  static ManagedDirectoryCatalog _open(
    String profile,
    ManagedPathWitness profileWitness,
    String root,
    ManagedFsPlatform fs,
  ) {
    _assertProfile(profile, profileWitness, fs);
    final rootWitness = _privateDirectory(root, fs);
    final catalogPath = _child(root, _catalogName);
    if (FileSystemEntity.typeSync(catalogPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.missingCatalog);
    }
    final catalogWitness = fs.requirePrivateFile(catalogPath);
    _checkSqliteSidecars(catalogPath, fs);
    final connection = ManagedSqliteConnection.openUnencrypted(catalogPath);
    ManagedCatalogStore? catalog;
    try {
      catalog = ManagedCatalogStore.openOwned(connection);
      _assertProfile(profile, profileWitness, fs);
      _assertSame(root, rootWitness, fs);
      _assertSame(catalogPath, catalogWitness, fs);
      return ManagedDirectoryCatalog._(
        profile,
        root,
        profileWitness,
        rootWitness,
        catalogWitness,
        catalog,
        fs,
      );
    } catch (_) {
      catalog?.close();
      // openOwned consumes it on failure; close is idempotent.
      connection.close();
      rethrow;
    }
  }

  ManagedCatalogSnapshot snapshot() => _safe(() {
    _validate();
    final result = _catalog.snapshot();
    _validate();
    return result;
  });

  ManagedCatalogSnapshot select(ManagedIdentityEntry? entry) => _safe(() {
    _validate();
    final result = _catalog.select(entry);
    _validate();
    return result;
  });

  /// Pure names, not an opening/deletion capability. Catalog membership alone
  /// cannot authorize cleanup. A backend factory still has to validate its
  /// mode, role and authenticated identity before using its data.
  ManagedIdentityLayout get layout => ManagedIdentityLayout(profileDirectory);

  void _validate() {
    if (_closed) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.closed);
    }
    _assertProfile(profileDirectory, _profileWitness, _fs);
    _privateDirectory(directory, _fs);
    _assertSame(directory, _rootWitness, _fs);
    _checkSqliteSidecars(_catalogPath, _fs);
    _fs.requirePrivateFile(_catalogPath);
    _assertSame(_catalogPath, _catalogWitness, _fs);
  }

  void close() {
    if (_closed) return;
    // Failed opens/closes remain owned until cleanup succeeds. An ordinary
    // active session must be drained before the catalog itself can close.
    for (final resource in _identityOwners.values.toList()) {
      if (!resource.handedOff || resource.closing) resource.close();
    }
    if (_identityOwners.isNotEmpty) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.busy);
    }
    _catalogRelease.close();
    _eraseReviews.clear();
    _closed = true;
  }

  static ({String path, ManagedPathWitness witness}) _admitProfile(
    String supplied,
    ManagedFsPlatform fs,
  ) {
    if (supplied.isEmpty ||
        supplied.contains('\x00') ||
        !Directory(supplied).isAbsolute) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    if (Platform.isWindows && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(supplied)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    // The profile is the caller's grant. Resolve once, then use only the actual
    // canonical path; subsequent aliases in the original spelling cannot move it.
    final path = Directory(supplied).resolveSymbolicLinksSync();
    final witness = fs.inspect(path);
    if (!witness.directory || !witness.ownedByCurrentUser) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    _assertProfile(path, witness, fs);
    return (path: path, witness: witness);
  }

  static void _assertProfile(
    String path,
    ManagedPathWitness expected,
    ManagedFsPlatform fs,
  ) {
    _assertSame(path, expected, fs);
    var current = Directory(path);
    for (var depth = 0; depth < 256; depth++) {
      final facts = fs.inspect(current.path);
      if (!facts.directory || !facts.safeAncestor) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      final parent = current.parent;
      if (parent.path == current.path) return;
      current = parent;
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
  }

  static ManagedPathWitness _privateDirectory(
    String path,
    ManagedFsPlatform fs,
  ) {
    final witness = fs.inspect(path);
    if (!witness.directory ||
        !witness.ownerOnly ||
        !witness.ownedByCurrentUser) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    return witness;
  }

  static void _assertSame(
    String path,
    ManagedPathWitness expected,
    ManagedFsPlatform fs,
  ) {
    if (!expected.sameObject(fs.inspect(path))) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  static void _checkSqliteSidecars(String database, ManagedFsPlatform fs) {
    // SQLite opens these itself during recovery. Checking only the database
    // leaf would still allow a planted journal/WAL link to escape the root.
    for (final suffix in ['-journal', '-wal', '-shm']) {
      final path = '$database$suffix';
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        fs.requirePrivateFile(path);
      }
    }
  }

  static void _discardOwnedEmptyBootstrap(
    String path,
    ManagedPathWitness expected,
    ManagedPathWitness? file,
    ManagedFsPlatform fs,
  ) {
    try {
      _assertSame(path, expected, fs);
      final children = Directory(
        path,
      ).listSync(followLinks: false).take(2).toList();
      if (children.isNotEmpty) {
        if (children.length != 1 ||
            file == null ||
            children.single.path != _child(path, _catalogName)) {
          return;
        }
        _assertSame(children.single.path, file, fs);
        File(children.single.path).deleteSync();
      }
      Directory(
        path,
      ).deleteSync(); // non-recursive: new content refuses removal
      fs.syncDirectory(Directory(path).parent.path);
    } catch (_) {
      // Cleanup cannot justify deleting an unproved object or hide the primary
      // operation's result. A later launch never automatically sweeps this path.
    }
  }

  static T _safe<T>(T Function() action) {
    try {
      return action();
    } on ManagedFsFailure {
      rethrow;
    } on ManagedCatalogFailure {
      rethrow;
    } on ManagedSqliteFailure {
      rethrow;
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
  }
}
