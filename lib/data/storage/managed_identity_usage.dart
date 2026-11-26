part of 'managed_directory_catalog.dart';

extension on _ManagedIdentityResources {
  Future<StorageUsage> measureUsage() async {
    requireOwned();
    inspecting = true;
    try {
      validatePaths();
      final result = await _ManagedUsageInventory(this).measure();
      validatePaths();
      lease!.requireHeld();
      return result;
    } on ManagedFsFailure {
      rethrow;
    } on ManagedIdentityFailure {
      rethrow;
    } catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedFsFailure(ManagedFsFailureKind.io),
        trace,
      );
    } finally {
      inspecting = false;
    }
  }
}

/// Stream directory entries instead of materializing a list of every piece.
/// No symlink traversal, payload read, native open, KDF or sibling scan. A
/// replaced/unsafe path fails rather than returning a partial sum. Sizes are
/// measured per file; this is not a filesystem-wide atomic snapshot.
final class _ManagedUsageInventory {
  _ManagedUsageInventory(this.resources, {this.unknownEntry});
  final void Function(_ManagedUnknownEntry)? unknownEntry;
  final _ManagedIdentityResources resources;
  int data = 0, blobs = 0, metadata = 0, other = 0, files = 0, unknown = 0;
  int total = 0;
  int dataFiles = 0, blobFiles = 0;
  final seen = <String>{};
  static final _blobName = RegExp(r'^[A-Za-z0-9_-]{16}$');
  static final _pieceName = RegExp(r'^p(0|[1-9][0-9]*)(\.tmp)?$');
  static const _metadata = {'identity.meta', 'identity.meta.lock'};

  Set<String> get _data =>
      resources.entry.protection == StorageProtection.encrypted
      ? const {'keybox.hv', 'content.hv', 'maintenance.hv'}
      : const {'data.store'};

  bool _sqliteSidecar(String name, String base) =>
      name == '$base-journal' || name == '$base-wal' || name == '$base-shm';

  Future<StorageUsage> measure({bool requireComplete = true}) async {
    await _directory(resources.path!, const [], 0, const []);
    if (requireComplete &&
        !seen.containsAll({..._metadata, ..._data, 'blobs'})) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    return StorageUsage(
      dataBytes: data,
      blobBytes: blobs,
      metadataBytes: metadata,
      otherBytes: other,
      files: files,
      unrecognizedEntries: unknown,
    );
  }

  ManagedPathWitness _inspect(String path, {bool requirePrivate = false}) {
    final fs = resources.owner._fs;
    final witness = fs.inspectAcl(path);
    if (requirePrivate || witness.aclWarning?.extendedAcl != null) {
      return witness.directory
          ? ManagedDirectoryCatalog._privateDirectory(
              path,
              fs,
              allowReadOnlyAclApproval: true,
            )
          : fs.requirePrivateFile(path, allowReadOnlyAclApproval: true);
    }
    if (!witness.ownedByCurrentUser || !witness.safeAncestor) {
      throw ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        path: path,
        aclWarnings: [
          if (witness.aclWarning case final warning?)
            warning.withPolicy(canContinue: false),
        ],
      );
    }
    return witness;
  }

  void _verify(
    String path,
    ManagedPathWitness expected, {
    bool requirePrivate = false,
  }) {
    final current = _inspect(path, requirePrivate: requirePrivate);
    if (!expected.sameObject(current) ||
        expected.aclWarning?.fingerprint != current.aclWarning?.fingerprint) {
      throw ManagedFsFailure(ManagedFsFailureKind.changed, path: path);
    }
  }

  Future<void> _directory(
    String path,
    List<String> parts,
    int depth,
    List<({String path, ManagedPathWitness witness})> parents,
  ) async {
    // Bound stack use for unexpected content. Refuse, never truncate a size.
    if (depth > 16) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    resources.validatePaths();
    final privateDirectory =
        parts.isEmpty || parts.length == 1 && parts.single == 'blobs';
    final before = _inspect(path, requirePrivate: privateDirectory);
    if (!before.directory) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    await for (final entity in Directory(path).list(followLinks: false)) {
      resources.validatePaths();
      _verify(path, before, requirePrivate: privateDirectory);
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final child = [...parts, name];
      final metadataFile =
          parts.isEmpty &&
          (_metadata.contains(name) || _sqliteSidecar(name, 'identity.meta'));
      final dataFile =
          parts.isEmpty &&
          (_data.contains(name) ||
              (_data.contains('data.store') &&
                  _sqliteSidecar(name, 'data.store')));
      final privateEntry =
          metadataFile || dataFile || parts.isEmpty && name == 'blobs';
      final witness = _inspect(entity.path, requirePrivate: privateEntry);
      if (parts.isEmpty && {..._metadata, ..._data, 'blobs'}.contains(name)) {
        if (witness.directory != (name == 'blobs')) {
          throw ManagedFsFailure(
            ManagedFsFailureKind.unsafe,
            path: entity.path,
          );
        }
        seen.add(name);
      }
      final blobDirectory =
          child.length == 1 && name == 'blobs' ||
          child.length == 2 && child[0] == 'blobs' && _blobName.hasMatch(name);
      final blobFile =
          child.length == 3 &&
          child[0] == 'blobs' &&
          _blobName.hasMatch(child[1]) &&
          _pieceName.hasMatch(name);
      final recognized = witness.directory
          ? blobDirectory
          : metadataFile || dataFile || blobFile;
      if (!recognized) unknown++;
      if (witness.directory) {
        if (!recognized) {
          unknownEntry?.call(
            _ManagedUnknownEntry(
              child,
              witness,
              [...parents, (path: path, witness: before)],
              0,
              0,
            ),
          );
        }
        await _directory(
          entity.path,
          child,
          depth + 1,
          unknownEntry == null
              ? const []
              : [...parents, (path: path, witness: before)],
        );
      } else {
        final length = await File(entity.path).length();
        // length() follows links; sandwich it between no-follow object checks.
        _verify(entity.path, witness, requirePrivate: privateEntry);
        if (length < 0 || length > 0x7fffffffffffffff - total) {
          throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
        }
        if (!recognized && unknownEntry != null) {
          final stat = await File(entity.path).stat();
          _verify(entity.path, witness, requirePrivate: privateEntry);
          if (stat.type != FileSystemEntityType.file || stat.size != length) {
            throw const ManagedFsFailure(ManagedFsFailureKind.changed);
          }
          unknownEntry!(
            _ManagedUnknownEntry(
              child,
              witness,
              [...parents, (path: path, witness: before)],
              length,
              stat.modified.microsecondsSinceEpoch,
            ),
          );
        }
        total += length;
        files++;
        if (metadataFile) {
          metadata += length;
        } else if (dataFile) {
          data += length;
          dataFiles++;
        } else if (blobFile) {
          blobs += length;
          blobFiles++;
        } else {
          other += length;
        }
      }
    }
    _verify(path, before, requirePrivate: privateDirectory);
  }
}
