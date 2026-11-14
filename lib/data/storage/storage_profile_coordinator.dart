part of 'managed_directory_catalog.dart';

/// Permanent lifetime role: only a constant tag and empty lock, no identity
/// locators or keys. A separate pending erasure intent may retain the public
/// enumerable catalog. The role survives root removal. Creators hold a shared
/// grant BEFORE staging a root; exclusive admission also works without a root.
final class StorageProfileCoordinator {
  StorageProfileCoordinator._(
    this.profileDirectory,
    this._profileWitness,
    this._directoryWitness,
    this._files,
    this._lease,
    this._fs, {
    this._erasureRecovery = false,
  });
  static const directoryName = 'storage-lifetime';
  final String profileDirectory;
  final ManagedPathWitness _profileWitness, _directoryWitness;
  final Map<String, ManagedPathWitness> _files;
  final ManagedProfileLease _lease;
  final ManagedFsPlatform _fs;
  final bool _erasureRecovery;
  bool _closed = false;
  bool get exclusive => _lease.exclusive;
  String get directory =>
      ManagedDirectoryCatalog._child(profileDirectory, directoryName);

  /// Admit the actual application profile before opening its preferences.
  /// This initializes only the fixed lifetime role, never an identity catalog.
  static StorageProfileCoordinator forPreferences(
    String suppliedBase, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final base = ManagedDirectoryCatalog._admitProfile(suppliedBase, fs);
    final profile = ManagedDirectoryCatalog._child(
      base.path,
      'visible-storage',
    );
    if (FileSystemEntity.typeSync(profile, followLinks: false) ==
            FileSystemEntityType.notFound &&
        !fs.createPrivateDirectory(profile)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    ManagedDirectoryCatalog._assertProfile(base.path, base.witness, fs);
    return createOrOpen(profile, fs: fs);
  });

  /// Read-only startup hint, never an ownership grant. Even a malformed file,
  /// directory or dangling link at either intent name blocks ordinary startup.
  /// The native opener repeats this check under its actual role grant.
  static bool hasErasureIntent(
    String supplied, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final profile = ManagedDirectoryCatalog._admitProfile(supplied, fs);
    final path = ManagedDirectoryCatalog._child(profile.path, directoryName);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return false;
    }
    final directory = ManagedDirectoryCatalog._privateDirectory(path, fs);
    final pending =
        [ManagedRootErasure.pendingName, ManagedRootErasure.completionName].any(
          (name) =>
              FileSystemEntity.typeSync(
                ManagedDirectoryCatalog._child(path, name),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound,
        );
    ManagedDirectoryCatalog._assertProfile(profile.path, profile.witness, fs);
    ManagedDirectoryCatalog._assertSame(path, directory, fs);
    return pending;
  });

  /// Read-only: no absent coordination directory is initialized implicitly.
  static StorageProfileCoordinator? openExisting(
    String supplied, {
    bool exclusive = false,
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final profile = ManagedDirectoryCatalog._admitProfile(supplied, fs);
    final path = ManagedDirectoryCatalog._child(profile.path, directoryName);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    return _open(profile.path, profile.witness, fs, exclusive);
  });

  /// Explicit storage-profile initialization, including profiles with only
  /// hidden storage. The fixed public role reveals no hidden-space fact/count.
  static StorageProfileCoordinator createOrOpen(
    String supplied, {
    bool exclusive = false,
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final profile = ManagedDirectoryCatalog._admitProfile(supplied, fs);
    final path = ManagedDirectoryCatalog._child(profile.path, directoryName);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return _open(profile.path, profile.witness, fs, exclusive);
    }
    final random = Random.secure();
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix = List.generate(
        16,
        (_) => random.nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final stage = ManagedDirectoryCatalog._child(
        profile.path,
        '.$directoryName-$suffix.pending',
      );
      ManagedDirectoryCatalog._assertProfile(profile.path, profile.witness, fs);
      if (!fs.createPrivateDirectory(stage)) continue;
      final staged = ManagedDirectoryCatalog._privateDirectory(stage, fs);
      final files = <String, ManagedPathWitness>{};
      ManagedProfileLease? lease;
      var published = false;
      try {
        final role = File(
          ManagedDirectoryCatalog._child(stage, ManagedProfileLease.fileName),
        );
        role.createSync(exclusive: true);
        final before = fs.inspect(role.path);
        files[ManagedProfileLease.fileName] = before;
        fs.restrictNewFile(role.path);
        ManagedDirectoryCatalog._assertSame(role.path, before, fs);
        lease = ManagedProfileLease.initializeOwned(
          ManagedSqliteConnection.openUnencrypted(role.path),
          role: ManagedProfileLeaseRole.storageProfile,
        );
        lease.close();
        lease = null;
        files['${ManagedProfileLease.fileName}.lock'] = fs.requirePrivateFile(
          '${role.path}.lock',
        );
        fs.syncDirectory(stage);
        ManagedDirectoryCatalog._assertProfile(
          profile.path,
          profile.witness,
          fs,
        );
        ManagedDirectoryCatalog._assertSame(stage, staged, fs);
        for (final entry in files.entries) {
          ManagedDirectoryCatalog._assertSame(
            ManagedDirectoryCatalog._child(stage, entry.key),
            entry.value,
            fs,
          );
        }
        published = fs.publishDirectoryNoReplace(stage, path);
        if (!published) {
          // A bootstrap started before another actor's wipe must not turn into
          // fresh post-wipe admission by adopting the winner and continuing.
          throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
        }
        fs.syncDirectory(profile.path);
        ManagedDirectoryCatalog._assertSame(path, staged, fs);
      } finally {
        lease?.close();
        if (!published) {
          ManagedDirectoryCatalog._discardOwnedEmptyBootstrap(
            stage,
            staged,
            files,
            fs,
          );
        }
      }
      return _open(profile.path, profile.witness, fs, exclusive);
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.io);
  });

  /// Recovery is a distinct exclusive owner. It cannot open catalogs or create
  /// roots through their ordinary factories while an erasure is pending.
  static StorageProfileCoordinator _openErasureRecovery(
    String supplied,
    ManagedFsPlatform fs,
  ) => ManagedDirectoryCatalog._safe(() {
    final profile = ManagedDirectoryCatalog._admitProfile(supplied, fs);
    return _open(
      profile.path,
      profile.witness,
      fs,
      true,
      erasureRecovery: true,
    );
  });

  static StorageProfileCoordinator _open(
    String profile,
    ManagedPathWitness witness,
    ManagedFsPlatform fs,
    bool exclusive, {
    bool erasureRecovery = false,
  }) {
    ManagedDirectoryCatalog._assertProfile(profile, witness, fs);
    final path = ManagedDirectoryCatalog._child(profile, directoryName);
    final directory = ManagedDirectoryCatalog._privateDirectory(path, fs);
    final role = ManagedDirectoryCatalog._child(
      path,
      ManagedProfileLease.fileName,
    );
    final files = <String, ManagedPathWitness>{
      ManagedProfileLease.fileName: fs.requirePrivateFile(role),
      '${ManagedProfileLease.fileName}.lock': fs.requirePrivateFile(
        '$role.lock',
      ),
    };
    ManagedDirectoryCatalog._checkSqliteSidecars(role, fs);
    if (File('$role.lock').lengthSync() != 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final lease = ManagedProfileLease.openOwned(
      ManagedSqliteConnection.openUnencrypted(role),
      exclusive: exclusive,
      role: ManagedProfileLeaseRole.storageProfile,
    );
    try {
      final result = StorageProfileCoordinator._(
        profile,
        witness,
        directory,
        Map.unmodifiable(files),
        lease,
        fs,
        erasureRecovery: erasureRecovery,
      );
      result.requireHeld();
      return result;
    } catch (_) {
      lease.close();
      rethrow;
    }
  }

  void requireHeld({bool exclusive = false}) {
    if (_closed) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.closed);
    }
    _lease.requireHeld(exclusive: exclusive);
    if (!_erasureRecovery &&
        [ManagedRootErasure.pendingName, ManagedRootErasure.completionName].any(
          (name) =>
              FileSystemEntity.typeSync(
                ManagedDirectoryCatalog._child(directory, name),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound,
        )) {
      throw const ManagedFsFailure(ManagedFsFailureKind.erasurePending);
    }
    ManagedDirectoryCatalog._assertProfile(
      profileDirectory,
      _profileWitness,
      _fs,
    );
    ManagedDirectoryCatalog._privateDirectory(directory, _fs);
    ManagedDirectoryCatalog._assertSame(directory, _directoryWitness, _fs);
    for (final entry in _files.entries) {
      final path = ManagedDirectoryCatalog._child(directory, entry.key);
      _fs.requirePrivateFile(path);
      ManagedDirectoryCatalog._assertSame(path, entry.value, _fs);
    }
    if (File(
          ManagedDirectoryCatalog._child(
            directory,
            '${ManagedProfileLease.fileName}.lock',
          ),
        ).lengthSync() !=
        0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
  }

  void close() {
    if (_closed) return;
    _lease.close();
    _closed = true;
  }
}
