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
part 'storage_profile_coordinator.dart';
part 'managed_root_erasure.dart';

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
    this._profileLease,
    this._coordinator,
    this._leaseWitnesses,
    this._fs,
  );

  final String profileDirectory;
  final String directory;
  final ManagedPathWitness _profileWitness;
  final ManagedPathWitness _rootWitness;
  final ManagedPathWitness _catalogWitness;
  final ManagedCatalogStore _catalog;
  final ManagedProfileLease _profileLease;
  final StorageProfileCoordinator _coordinator;
  final Map<String, ManagedPathWitness> _leaseWitnesses;
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
  }) => _openExisting(profileDirectory, fs, exclusive: false);

  /// Exclusive coordination only; does not delete data or authorize erasure.
  static ManagedDirectoryCatalog? openExclusiveMaintenance(
    String profileDirectory, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => _openExisting(profileDirectory, fs, exclusive: true);

  static ManagedDirectoryCatalog? _openExisting(
    String supplied,
    ManagedFsPlatform fs, {
    required bool exclusive,
  }) => _safe(() {
    final profile = _admitProfile(supplied, fs);
    final path = _child(profile.path, 'identities');
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      StorageProfileCoordinator.openExisting(profile.path, fs: fs)?.close();
      return null;
    }
    final coordinator = StorageProfileCoordinator.openExisting(
      profile.path,
      fs: fs,
      exclusive: exclusive,
    );
    if (coordinator == null) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    var adopted = false;
    try {
      final result = _open(
        profile.path,
        profile.witness,
        path,
        fs,
        exclusive: exclusive,
        coordinator: coordinator,
      );
      adopted = true;
      return result;
    } finally {
      if (!adopted) coordinator.close();
    }
  });

  void requireExclusiveMaintenance() {
    _validate();
    _profileLease.requireHeld(exclusive: true);
    _coordinator.requireHeld(exclusive: true);
    if (_identityOwners.isNotEmpty) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.busy);
    }
  }

  /// Explicit new-mode initialization. Publishes a complete PRIVATE directory
  /// with its initialized catalog in a single no-replace rename. Competing
  /// creators open the winner, never overwrite it. Interrupted unpublished
  /// sibling directories are retained, not adopted or recursively swept.
  static ManagedDirectoryCatalog createOrOpen(
    String profileDirectory, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => _safe(() {
    final coordinator = StorageProfileCoordinator.createOrOpen(
      profileDirectory,
      fs: fs,
    );
    var adopted = false;
    try {
      final result = _createOrOpen(coordinator, fs);
      adopted = true;
      return result;
    } finally {
      if (!adopted) coordinator.close();
    }
  });

  static ManagedDirectoryCatalog _createOrOpen(
    StorageProfileCoordinator coordinator,
    ManagedFsPlatform fs,
  ) {
    coordinator.requireHeld();
    final profile = (
      path: coordinator.profileDirectory,
      witness: coordinator._profileWitness,
    );
    final path = _child(profile.path, 'identities');
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return _open(
        profile.path,
        profile.witness,
        path,
        fs,
        coordinator: coordinator,
      );
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
      final ownedFiles = <String, ManagedPathWitness>{};
      ManagedSqliteConnection? connection;
      ManagedCatalogStore? catalog;
      ManagedProfileLease? profileLease;
      var published = false;
      try {
        final file = File(_child(staged, _catalogName));
        file.createSync(exclusive: true);
        final fileWitness = fs.inspect(file.path);
        ownedFiles[_catalogName] = fileWitness;
        fs.restrictNewFile(file.path);
        _assertSame(file.path, fileWitness, fs);
        connection = ManagedSqliteConnection.openUnencrypted(file.path);
        // Constructor consumes the connection even if initialization fails.
        final owned = connection;
        connection = null;
        catalog = ManagedCatalogStore.initializeOwned(owned);
        catalog.close();
        catalog = null;
        final role = File(_child(staged, ManagedProfileLease.fileName));
        role.createSync(exclusive: true);
        final roleWitness = fs.inspect(role.path);
        ownedFiles[ManagedProfileLease.fileName] = roleWitness;
        fs.restrictNewFile(role.path);
        _assertSame(role.path, roleWitness, fs);
        profileLease = ManagedProfileLease.initializeOwned(
          ManagedSqliteConnection.openUnencrypted(role.path),
        );
        profileLease.close();
        profileLease = null;
        ownedFiles['${ManagedProfileLease.fileName}.lock'] = fs
            .requirePrivateFile('${role.path}.lock');
        fs.syncDirectory(staged);
        _assertProfile(profile.path, profile.witness, fs);
        _assertSame(staged, stagedWitness, fs);
        for (final entry in ownedFiles.entries) {
          _assertSame(_child(staged, entry.key), entry.value, fs);
        }
        published = fs.publishDirectoryNoReplace(staged, path);
        if (published) {
          fs.syncDirectory(profile.path);
          _assertSame(path, stagedWitness, fs);
        }
      } finally {
        catalog?.close();
        connection?.close();
        profileLease?.close();
        if (!published) {
          // Only these exact, freshly created files. Unexpected content or
          // replacement leaves the complete bootstrap intact for review.
          _discardOwnedEmptyBootstrap(staged, stagedWitness, ownedFiles, fs);
        }
      }
      return _open(
        profile.path,
        profile.witness,
        path,
        fs,
        coordinator: coordinator,
      );
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.io);
  }

  static ManagedDirectoryCatalog _open(
    String profile,
    ManagedPathWitness profileWitness,
    String root,
    ManagedFsPlatform fs, {
    bool exclusive = false,
    required StorageProfileCoordinator coordinator,
  }) {
    coordinator.requireHeld(exclusive: exclusive);
    _assertProfile(profile, profileWitness, fs);
    final rootWitness = _privateDirectory(root, fs);
    final catalogPath = _child(root, _catalogName);
    if (FileSystemEntity.typeSync(catalogPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.missingCatalog);
    }
    final catalogWitness = fs.requirePrivateFile(catalogPath);
    _checkSqliteSidecars(catalogPath, fs);
    final rolePath = _child(root, ManagedProfileLease.fileName);
    final leaseWitnesses = <String, ManagedPathWitness>{
      ManagedProfileLease.fileName: fs.requirePrivateFile(rolePath),
      '${ManagedProfileLease.fileName}.lock': fs.requirePrivateFile(
        '$rolePath.lock',
      ),
    };
    _checkSqliteSidecars(rolePath, fs);
    if (File('$rolePath.lock').lengthSync() != 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final profileLease = ManagedProfileLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(rolePath),
      exclusive: exclusive,
    );
    ManagedSqliteConnection? connection;
    ManagedCatalogStore? catalog;
    try {
      connection = ManagedSqliteConnection.openUnencrypted(catalogPath);
      catalog = ManagedCatalogStore.openOwned(connection);
      _assertProfile(profile, profileWitness, fs);
      _assertSame(root, rootWitness, fs);
      _assertSame(catalogPath, catalogWitness, fs);
      for (final entry in leaseWitnesses.entries) {
        _assertSame(_child(root, entry.key), entry.value, fs);
      }
      return ManagedDirectoryCatalog._(
        profile,
        root,
        profileWitness,
        rootWitness,
        catalogWitness,
        catalog,
        profileLease,
        coordinator,
        Map.unmodifiable(leaseWitnesses),
        fs,
      );
    } catch (_) {
      catalog?.close();
      // openOwned consumes it on failure; close is idempotent.
      connection?.close();
      profileLease.close();
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
    _coordinator.requireHeld();
    _profileLease.requireHeld();
    _assertProfile(profileDirectory, _profileWitness, _fs);
    _privateDirectory(directory, _fs);
    _assertSame(directory, _rootWitness, _fs);
    for (final entry in _leaseWitnesses.entries) {
      _fs.requirePrivateFile(_child(directory, entry.key));
      _assertSame(_child(directory, entry.key), entry.value, _fs);
    }
    if (File(
          _child(directory, '${ManagedProfileLease.fileName}.lock'),
        ).lengthSync() !=
        0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
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
    _profileLease.close();
    _coordinator.close();
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
    Map<String, ManagedPathWitness> files,
    ManagedFsPlatform fs,
  ) {
    try {
      _assertSame(path, expected, fs);
      final children = Directory(
        path,
      ).listSync(followLinks: false).take(files.length + 1).toList();
      if (children.length != files.length) return;
      // Validate the WHOLE exact manifest before the first unlink.
      for (final child in children) {
        final name = File(child.path).uri.pathSegments.last;
        final witness = files[name];
        if (witness == null || child.path != _child(path, name)) return;
        _assertSame(child.path, witness, fs);
      }
      for (final entry in files.entries) {
        _assertSame(path, expected, fs);
        _assertSame(_child(path, entry.key), entry.value, fs);
        File(_child(path, entry.key)).deleteSync();
      }
      Directory(
        path,
      ).deleteSync(); // New content refuses non-recursive removal.
      fs.syncDirectory(Directory(path).parent.path);
    } catch (_) {
      // Cleanup cannot authorize deleting an unproved object or hide failure.
    }
  }

  static T _safe<T>(T Function() action) {
    try {
      return action();
    } on ManagedFsFailure {
      rethrow;
    } on ManagedCatalogFailure {
      rethrow;
    } on ManagedLeaseFailure {
      rethrow;
    } on ManagedSqliteFailure {
      rethrow;
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
  }
}
