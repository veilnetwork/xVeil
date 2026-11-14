part of 'managed_directory_catalog.dart';

/// Permanent, constant metadata for storage lifetime admission. It contains no
/// identities/keys and survives removal of the enumerable root. Creators must
/// hold a shared grant BEFORE creating/staging that root. Exclusive admission
/// blocks new readers and creators even when no root exists.
final class StorageProfileCoordinator {
  StorageProfileCoordinator._(
    this.profileDirectory,
    this._profileWitness,
    this._directoryWitness,
    this._files,
    this._lease,
    this._fs,
  );
  static const directoryName = 'storage-lifetime';
  final String profileDirectory;
  final ManagedPathWitness _profileWitness, _directoryWitness;
  final Map<String, ManagedPathWitness> _files;
  final ManagedProfileLease _lease;
  final ManagedFsPlatform _fs;
  bool _closed = false;
  bool get exclusive => _lease.exclusive;
  String get directory =>
      ManagedDirectoryCatalog._child(profileDirectory, directoryName);

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

  static StorageProfileCoordinator _open(
    String profile,
    ManagedPathWitness witness,
    ManagedFsPlatform fs,
    bool exclusive,
  ) {
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
