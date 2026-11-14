part of 'managed_directory_catalog.dart';

/// A terminal witness, not an authorization token. The exclusively held
/// permanent role and trusted enclosing verifier authorize this transition.
/// Contains only local object witnesses and a digest of the immutable plan;
/// no catalog, scope names, credentials or hidden-space information survives.
final class _ErasureCompletion {
  _ErasureCompletion(this._record, this._witness, this._digest);
  static const _maxBytes = 4096;
  final Map<String, Object> _record;
  final ManagedPathWitness _witness;
  final String _digest;
  bool unlinked = false;

  static String _path(StorageProfileCoordinator gate) =>
      ManagedDirectoryCatalog._child(
        gate.directory,
        ManagedRootErasure.completionName,
      );
  static String _pending(StorageProfileCoordinator gate) =>
      ManagedDirectoryCatalog._child(
        gate.directory,
        ManagedRootErasure.pendingName,
      );
  static String _plan(StorageProfileCoordinator gate) =>
      ManagedDirectoryCatalog._child(
        _pending(gate),
        ManagedRootErasure._planName,
      );

  static void requireRootAbsent(StorageProfileCoordinator gate) {
    gate.requireHeld(exclusive: true);
    if (FileSystemEntity.typeSync(
          ManagedDirectoryCatalog._child(gate.profileDirectory, 'identities'),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  static List<int> _read(
    String path,
    ManagedPathWitness witness,
    int limit,
    ManagedFsPlatform fs,
  ) {
    fs.requirePrivateFile(path);
    ManagedDirectoryCatalog._assertSame(path, witness, fs);
    if (File(path).lengthSync() > limit) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final handle = File(path).openSync();
    final List<int> bytes;
    try {
      bytes = handle.readSync(limit + 1);
    } finally {
      handle.closeSync();
    }
    ManagedDirectoryCatalog._assertSame(path, witness, fs);
    if (bytes.length > limit) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    return bytes;
  }

  static _ErasureCompletion? openIfPresent(StorageProfileCoordinator gate) {
    gate.requireHeld(exclusive: true);
    final path = _path(gate);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    final witness = gate._fs.requirePrivateFile(path);
    final bytes = _read(path, witness, _maxBytes, gate._fs);
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      bool objectId(Object? v) =>
          v is String && v.isNotEmpty && v.length <= 256 && !v.contains('\x00');
      if (raw is! Map<String, dynamic> ||
          raw.length != 8 ||
          raw['v'] is! int ||
          raw['v'] != 1 ||
          !objectId(raw['profile']) ||
          !objectId(raw['coordinator']) ||
          !objectId(raw['directory']) ||
          !objectId(raw['plan']) ||
          raw['size'] is! int ||
          (raw['size'] as int) <= 0 ||
          (raw['size'] as int) > _RootErasePlan.maxBytes ||
          raw['modified'] is! int ||
          raw['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['sha256'] as String)) {
        throw const FormatException();
      }
      return _ErasureCompletion(
        Map<String, Object>.unmodifiable(raw),
        witness,
        sha256.convert(bytes).toString(),
      );
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
  }

  static _ErasureCompletion publish(
    StorageProfileCoordinator gate,
    ManagedPathWitness directory,
    ManagedPathWitness plan,
    FileStat stamp,
  ) {
    requireRootAbsent(gate);
    final bytes = _read(_plan(gate), plan, _RootErasePlan.maxBytes, gate._fs);
    final record = <String, Object>{
      'v': 1,
      'profile': gate._profileWitness.identity,
      'coordinator': gate._directoryWitness.identity,
      'directory': directory.identity,
      'plan': plan.identity,
      'size': stamp.size,
      'modified': stamp.modified.microsecondsSinceEpoch,
      'sha256': sha256.convert(bytes).toString(),
    };
    final encoded = utf8.encode(jsonEncode(record));
    if (encoded.length > _maxBytes) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final suffix = List.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final stage = File(
      ManagedDirectoryCatalog._child(
        gate.directory,
        '.completion-$suffix.pending',
      ),
    );
    stage.createSync(exclusive: true);
    final witness = gate._fs.inspect(stage.path);
    var published = false;
    try {
      gate._fs.restrictNewFile(stage.path);
      ManagedDirectoryCatalog._assertSame(stage.path, witness, gate._fs);
      stage.writeAsBytesSync(encoded, flush: true);
      ManagedDirectoryCatalog._assertSame(stage.path, witness, gate._fs);
      requireRootAbsent(gate);
      published = gate._fs.publishFileNoReplace(stage.path, _path(gate));
      if (!published) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      // Caller retains this witness BEFORE syncing the parent or deleting any
      // part of the plan. A failed sync therefore leaves a recoverable marker.
      return _ErasureCompletion(
        Map.unmodifiable(record),
        witness,
        sha256.convert(encoded).toString(),
      );
    } finally {
      if (!published &&
          FileSystemEntity.typeSync(stage.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        // No recursive cleanup and never remove a replaced stage.
        ManagedDirectoryCatalog._assertSame(stage.path, witness, gate._fs);
        gate._fs.requirePrivateFile(stage.path);
        stage.deleteSync();
        gate._fs.syncDirectory(gate.directory);
      }
    }
  }

  void validate(StorageProfileCoordinator gate) {
    requireRootAbsent(gate);
    if (unlinked ||
        _record['profile'] != gate._profileWitness.identity ||
        _record['coordinator'] != gate._directoryWitness.identity ||
        sha256
                .convert(_read(_path(gate), _witness, _maxBytes, gate._fs))
                .toString() !=
            _digest) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    _validateTail(gate);
  }

  /// The terminal may outlive plan.json, the empty pending directory, or both.
  /// Only those exact original objects may be removed. Foreign entries refuse.
  void _validateTail(StorageProfileCoordinator gate) {
    final path = _pending(gate);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final directory = ManagedDirectoryCatalog._privateDirectory(path, gate._fs);
    if (directory.identity != _record['directory'] ||
        Directory(
          path,
        ).listSync(followLinks: false).any((f) => f.path != _plan(gate))) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    final planPath = _plan(gate);
    if (FileSystemEntity.typeSync(planPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final file = gate._fs.requirePrivateFile(planPath);
    final stamp = File(planPath).statSync();
    if (file.identity != _record['plan'] ||
        stamp.size != _record['size'] ||
        stamp.modified.microsecondsSinceEpoch != _record['modified'] ||
        sha256
                .convert(
                  _read(planPath, file, _RootErasePlan.maxBytes, gate._fs),
                )
                .toString() !=
            _record['sha256']) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  void removePlan(StorageProfileCoordinator gate) {
    validate(gate);
    if (FileSystemEntity.typeSync(_plan(gate), followLinks: false) !=
        FileSystemEntityType.notFound) {
      File(_plan(gate)).deleteSync();
    }
    // Also retry a failed previous sync after the file has already disappeared.
    if (FileSystemEntity.typeSync(_pending(gate), followLinks: false) !=
        FileSystemEntityType.notFound) {
      gate._fs.syncDirectory(_pending(gate));
    }
  }

  void removePending(StorageProfileCoordinator gate) {
    validate(gate);
    if (FileSystemEntity.typeSync(_pending(gate), followLinks: false) !=
        FileSystemEntityType.notFound) {
      Directory(_pending(gate)).deleteSync(); // Never recursive.
    }
    gate._fs.syncDirectory(gate.directory);
  }

  void unlink(StorageProfileCoordinator gate) {
    validate(gate);
    // Never retire the terminal while its old plan/directory is still present.
    if (FileSystemEntity.typeSync(_pending(gate), followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    File(_path(gate)).deleteSync();
    unlinked = true;
  }

  void confirmUnlinked(StorageProfileCoordinator gate) {
    requireRootAbsent(gate);
    if (!unlinked ||
        FileSystemEntity.typeSync(_path(gate), followLinks: false) !=
            FileSystemEntityType.notFound ||
        FileSystemEntity.typeSync(_pending(gate), followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    gate._fs.syncDirectory(gate.directory);
  }
}
