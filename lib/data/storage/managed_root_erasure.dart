part of 'managed_directory_catalog.dart';

/// Durable intent for the enumerable portion of a whole-profile wipe. This is
/// an actor-side port, NOT permission to enable the application wipe/default.
/// The enclosing wipe must also retire every OS scope, the legacy container,
/// pending enrollment and preferences before retiring this intent (not yet
/// implemented). No payload authentication is weakened by ordinary startup.
final class ManagedRootErasure {
  ManagedRootErasure._(this._gate, this._plan, this._directory, this._file);
  static const pendingName = 'erasure-pending';
  static const _planName = 'plan.json';
  final StorageProfileCoordinator _gate;
  final _RootErasePlan _plan;
  final ManagedPathWitness _directory, _file;
  bool _operating = false;
  late final _stamp = File(_planPath).statSync();
  String get _intentPath =>
      ManagedDirectoryCatalog._child(_gate.directory, pendingName);
  String get _planPath =>
      ManagedDirectoryCatalog._child(_intentPath, _planName);

  /// Public locators survive catalog deletion so the enclosing wipe can derive
  /// their OS-vault scopes. No credential, network ID or hidden-space pointer.
  ManagedIdentityCatalog get catalog => _plan.catalog;
  StorageUnlockScopes get unlockScopes => _plan.unlockScopes;

  /// Caller owns an explicitly confirmed wipe and an exclusive complete root.
  /// Capture no-follow owned entries before publication. All identity roles
  /// must close successfully; unknown content is preserved and refuses a plan.
  static Future<void> prepare(
    ManagedDirectoryCatalog owner, {
    required StorageUnlockScopes unlockScopes,
  }) async {
    try {
      await _prepare(owner, unlockScopes);
    } on FileSystemException catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedFsFailure(ManagedFsFailureKind.io),
        trace,
      );
    }
  }

  static Future<void> _prepare(
    ManagedDirectoryCatalog owner,
    StorageUnlockScopes unlockScopes,
  ) async {
    owner.requireExclusiveMaintenance();
    final catalog = owner.snapshot().catalog;
    for (final entry in catalog.identities) {
      final resources = _ManagedIdentityResources(owner, entry);
      owner._reserveIdentity(resources);
      try {
        resources.erasing = true;
        resources.admit(owner.layout.directory(entry.id));
        resources.acquireLease();
        final usage = await _ManagedUsageInventory(resources).measure();
        if (usage.unrecognizedEntries != 0) {
          throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
        }
      } finally {
        resources.erasing = false;
        resources.close();
      }
    }
    owner.requireExclusiveMaintenance();
    final plan = await _RootErasePlan.capture(owner, catalog, unlockScopes);
    plan.validateTree(owner._coordinator);
    final bytes = plan.encode();
    final gate = owner._coordinator;
    final fs = owner._fs;
    final destination = ManagedDirectoryCatalog._child(
      gate.directory,
      pendingName,
    );
    final suffix = List.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final stage = ManagedDirectoryCatalog._child(
      gate.directory,
      '.erasure-$suffix.pending',
    );
    if (!fs.createPrivateDirectory(stage)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    final staged = ManagedDirectoryCatalog._privateDirectory(stage, fs);
    final files = <String, ManagedPathWitness>{};
    var published = false;
    try {
      final file = File(ManagedDirectoryCatalog._child(stage, _planName));
      file.createSync(exclusive: true);
      files[_planName] = fs.inspect(file.path);
      fs.restrictNewFile(file.path);
      ManagedDirectoryCatalog._assertSame(file.path, files[_planName]!, fs);
      file.writeAsBytesSync(bytes, flush: true);
      ManagedDirectoryCatalog._assertSame(file.path, files[_planName]!, fs);
      fs.syncDirectory(stage);
      owner.requireExclusiveMaintenance();
      plan.validateTree(gate);
      ManagedDirectoryCatalog._assertSame(stage, staged, fs);
      published = fs.publishDirectoryNoReplace(stage, destination);
      if (!published) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      // No deletion before this parent sync succeeds. Once published even a
      // sync error leaves normal admission blocked, and retry uses recovery.
      fs.syncDirectory(gate.directory);
    } finally {
      if (!published) {
        ManagedDirectoryCatalog._discardOwnedEmptyBootstrap(
          stage,
          staged,
          files,
          fs,
        );
      }
    }
  }

  /// Does not need the catalog, inner root role, payload keys or their handles.
  /// Owns the permanent exclusive coordinator through all cleanup and errors.
  static ManagedRootErasure openPending(
    String profileDirectory, {
    ManagedFsPlatform fs = const ManagedFsPlatform(),
  }) => ManagedDirectoryCatalog._safe(() {
    final gate = StorageProfileCoordinator._openErasureRecovery(
      profileDirectory,
      fs,
    );
    try {
      final path = ManagedDirectoryCatalog._child(gate.directory, pendingName);
      final directory = ManagedDirectoryCatalog._privateDirectory(path, fs);
      final file = ManagedDirectoryCatalog._child(path, _planName);
      final witness = fs.requirePrivateFile(file);
      if (File(file).lengthSync() > _RootErasePlan.maxBytes) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      final handle = File(file).openSync();
      final List<int> bytes;
      try {
        bytes = handle.readSync(_RootErasePlan.maxBytes + 1);
      } finally {
        handle.closeSync();
      }
      if (bytes.length > _RootErasePlan.maxBytes) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      ManagedDirectoryCatalog._assertSame(file, witness, fs);
      final plan = _RootErasePlan.decode(bytes);
      final result = ManagedRootErasure._(gate, plan, directory, witness);
      result._validate();
      plan.validateTree(gate);
      return result;
    } catch (_) {
      gate.close();
      rethrow;
    }
  });

  void _validate() {
    _gate.requireHeld(exclusive: true);
    ManagedDirectoryCatalog._privateDirectory(_intentPath, _gate._fs);
    ManagedDirectoryCatalog._assertSame(_intentPath, _directory, _gate._fs);
    _gate._fs.requirePrivateFile(_planPath);
    ManagedDirectoryCatalog._assertSame(_planPath, _file, _gate._fs);
    final stamp = File(_planPath).statSync();
    if (stamp.size != _stamp.size ||
        stamp.modified != _stamp.modified ||
        Directory(
          _intentPath,
        ).listSync(followLinks: false).any((e) => e.path != _planPath)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    _plan.validateBinding(_gate);
  }

  /// The enclosing wipe must VERIFY OS absence, including pending enrollment,
  /// before returning from this callback. It is deliberately required and
  /// repeated after each restart; a UI opt-in preference is not such a witness.
  /// This port leaves the durable intent standing even when managed files are
  /// absent, until the full-profile protocol can finish its other obligations.
  Future<void> removeManagedFiles({
    required Future<void> Function(ManagedIdentityCatalog catalog) retireScopes,
    Future<void> Function(String localRelativePath)? afterUnlink,
  }) async {
    if (_operating) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _operating = true;
    try {
      _validate();
      _plan.validateTree(_gate);
      await retireScopes(catalog);
      _validate();
      _plan.validateTree(_gate);
      final entries = _plan.entries.values.toList()
        ..sort((a, b) {
          final depth = b.parts.length.compareTo(a.parts.length);
          return depth != 0 ? depth : a.path.compareTo(b.path);
        });
      for (final entry in entries) {
        _validate();
        if (!_plan.validateEntry(_gate, entry)) continue;
        final path = entry.absolute(_gate);
        if (entry.directory) {
          Directory(path).deleteSync(); // Never recursive; a new entry refuses.
        } else {
          File(path).deleteSync();
        }
        _gate._fs.syncDirectory(File(path).parent.path);
        await afterUnlink?.call(entry.path);
      }
      _validate();
      _plan.validateTree(_gate);
      if (FileSystemEntity.typeSync(
            ManagedDirectoryCatalog._child(
              _gate.profileDirectory,
              'identities',
            ),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
    } on FileSystemException catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedFsFailure(ManagedFsFailureKind.io),
        trace,
      );
    } finally {
      _operating = false;
    }
  }

  void close() {
    if (_operating) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _gate.close();
  }
}

final class _RootEraseEntry {
  _RootEraseEntry(
    this.parts,
    this.identity,
    this.directory,
    this.bytes,
    this.modified,
  );
  final List<String> parts;
  final String identity;
  final bool directory;
  final int bytes, modified;
  String get path => parts.join('/');
  String absolute(StorageProfileCoordinator gate) => File.fromUri(
    Directory(gate.profileDirectory).uri.resolveUri(Uri(pathSegments: parts)),
  ).path;
  List<Object> encode() => [path, identity, directory, bytes, modified];
}

final class _RootErasePlan {
  _RootErasePlan(
    this.profile,
    this.coordinator,
    this.catalog,
    this.entries,
    this.unlockScopes,
  );
  static const maxBytes = 8 * 1024 * 1024, maxEntries = 32768;
  final String profile, coordinator;
  final ManagedIdentityCatalog catalog;
  final StorageUnlockScopes unlockScopes;
  final Map<String, _RootEraseEntry> entries;
  late final Map<String, Set<String>> _children = () {
    final result = <String, Set<String>>{};
    for (final entry in entries.values) {
      if (entry.parts.length > 1) {
        (result[entry.parts.take(entry.parts.length - 1).join('/')] ??=
                <String>{})
            .add(entry.parts.last);
      }
    }
    return result;
  }();
  static final _id = RegExp(r'^[0-9a-f]{32}$');
  static final _blob = RegExp(r'^[A-Za-z0-9_-]{16}$');
  static final _piece = RegExp(r'^p(0|[1-9][0-9]*)(\.tmp)?$');

  static bool _allowed(
    List<String> p,
    bool directory,
    ManagedIdentityCatalog catalog,
  ) {
    if (p.isEmpty || p.first != 'identities') return false;
    if (p.length == 1) return directory;
    if (p.length == 2 && !directory) {
      return const {
        'catalog.sqlite3',
        'catalog.sqlite3-journal',
        'catalog.sqlite3-wal',
        'catalog.sqlite3-shm',
        'profile.meta',
        'profile.meta.lock',
        'profile.meta-journal',
        'profile.meta-wal',
        'profile.meta-shm',
      }.contains(p[1]);
    }
    if (!_id.hasMatch(p[1])) return false;
    ManagedIdentityEntry? identity;
    for (final entry in catalog.identities) {
      if (entry.id.value == p[1]) identity = entry;
    }
    if (identity == null) return false;
    if (p.length == 2) return directory;
    if (p.length == 3) {
      if (p[2] == 'blobs') return directory;
      if (directory) return false;
      return {
        'identity.meta',
        'identity.meta.lock',
        'identity.meta-journal',
        'identity.meta-wal',
        'identity.meta-shm',
        if (identity.protection == StorageProtection.encrypted) ...[
          'keybox.hv',
          'content.hv',
          'maintenance.hv',
        ] else ...[
          'data.store',
          'data.store-journal',
          'data.store-wal',
          'data.store-shm',
        ],
      }.contains(p[2]);
    }
    return p[2] == 'blobs' &&
        _blob.hasMatch(p[3]) &&
        (p.length == 4 && directory ||
            p.length == 5 && !directory && _piece.hasMatch(p[4]));
  }

  static Future<_RootErasePlan> capture(
    ManagedDirectoryCatalog owner,
    ManagedIdentityCatalog catalog,
    StorageUnlockScopes unlockScopes,
  ) async {
    final entries = <String, _RootEraseEntry>{};
    Future<void> visit(String path, List<String> parts) async {
      owner.requireExclusiveMaintenance();
      final witness = owner._fs.inspect(path);
      if (!_allowed(parts, witness.directory, catalog) ||
          !witness.ownedByCurrentUser ||
          !witness.safeAncestor ||
          parts.length <= 3 && !witness.ownerOnly) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      final stat = File(path).statSync();
      final entry = _RootEraseEntry(
        parts,
        witness.identity,
        witness.directory,
        witness.directory ? 0 : stat.size,
        witness.directory ? 0 : stat.modified.microsecondsSinceEpoch,
      );
      entries[entry.path] = entry;
      if (entries.length > maxEntries) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      if (witness.directory) {
        await for (final child in Directory(path).list(followLinks: false)) {
          final name = child.uri.pathSegments.where((p) => p.isNotEmpty).last;
          await visit(child.path, [...parts, name]);
        }
      }
    }

    await visit(owner.directory, ['identities']);
    return _RootErasePlan(
      owner._profileWitness.identity,
      owner._coordinator._directoryWitness.identity,
      catalog,
      entries,
      unlockScopes,
    );
  }

  Uint8List encode() {
    final result = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 2,
          'profile': profile,
          'coordinator': coordinator,
          'catalog': catalog.encode(),
          'unlockScopes': unlockScopes.ids,
          'entries': [for (final e in entries.values) e.encode()],
        }),
      ),
    );
    if (result.length > maxBytes) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    return result;
  }

  static _RootErasePlan decode(List<int> bytes) {
    try {
      if (bytes.length > maxBytes) throw const FormatException();
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic> ||
          raw.length != 6 ||
          raw['v'] is! int ||
          raw['v'] != 2 ||
          raw['profile'] is! String ||
          raw['coordinator'] is! String ||
          raw['catalog'] is! String ||
          raw['entries'] is! List ||
          raw['unlockScopes'] is! List) {
        throw const FormatException();
      }
      bool identity(Object? v) =>
          v is String && v.isNotEmpty && v.length <= 256 && !v.contains('\x00');
      if (!identity(raw['profile']) || !identity(raw['coordinator'])) {
        throw const FormatException();
      }
      final catalog = ManagedIdentityCatalog.decode(raw['catalog'] as String);
      final scopes = StorageUnlockScopes(
        (raw['unlockScopes'] as List).cast<String>(),
      );
      final list = raw['entries'] as List;
      if (list.isEmpty || list.length > maxEntries) {
        throw const FormatException();
      }
      final entries = <String, _RootEraseEntry>{};
      for (final row in list) {
        if (row is! List ||
            row.length != 5 ||
            row[0] is! String ||
            !identity(row[1]) ||
            row[2] is! bool ||
            row[3] is! int ||
            row[4] is! int ||
            row[3] < 0 ||
            row[4] < 0 ||
            row[3] > 0x7fffffffffffffff ||
            row[4] > 0x7fffffffffffffff) {
          throw const FormatException();
        }
        final path = row[0] as String;
        if (path.length > 256 || path.contains('\\') || path.contains('%')) {
          throw const FormatException();
        }
        final parts = path.split('/');
        if (!_allowed(parts, row[2] as bool, catalog) ||
            entries.containsKey(path) ||
            row[2] == true && (row[3] != 0 || row[4] != 0)) {
          throw const FormatException();
        }
        entries[path] = _RootEraseEntry(
          parts,
          row[1] as String,
          row[2] as bool,
          row[3] as int,
          row[4] as int,
        );
      }
      for (final e in entries.values) {
        for (var i = 1; i < e.parts.length; i++) {
          if (entries[e.parts.take(i).join('/')]?.directory != true) {
            throw const FormatException();
          }
        }
      }
      if (entries['identities']?.directory != true) {
        throw const FormatException();
      }
      return _RootErasePlan(
        raw['profile'] as String,
        raw['coordinator'] as String,
        catalog,
        entries,
        scopes,
      );
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
  }

  void validateBinding(StorageProfileCoordinator gate) {
    if (profile != gate._profileWitness.identity ||
        coordinator != gate._directoryWitness.identity) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  bool validateEntry(StorageProfileCoordinator gate, _RootEraseEntry entry) {
    gate.requireHeld(exclusive: true);
    validateBinding(gate);
    for (var i = 1; i <= entry.parts.length; i++) {
      final expected = entries[entry.parts.take(i).join('/')]!;
      final path = expected.absolute(gate);
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return false;
      }
      final actual = gate._fs.inspect(path);
      if (actual.identity != expected.identity ||
          actual.directory != expected.directory ||
          !actual.ownedByCurrentUser ||
          !actual.safeAncestor ||
          i <= 3 && !actual.ownerOnly) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      if (!actual.directory) {
        final stat = File(path).statSync();
        if (stat.size != expected.bytes ||
            stat.modified.microsecondsSinceEpoch != expected.modified) {
          throw const ManagedFsFailure(ManagedFsFailureKind.changed);
        }
        ManagedDirectoryCatalog._assertSame(path, actual, gate._fs);
      }
    }
    return true;
  }

  void validateTree(StorageProfileCoordinator gate) {
    validateBinding(gate);
    for (final e in entries.values) {
      if (!validateEntry(gate, e) || !e.directory) continue;
      final expected = _children[e.path] ?? const <String>{};
      for (final child in Directory(
        e.absolute(gate),
      ).listSync(followLinks: false).take(expected.length + 1)) {
        if (!expected.contains(
          child.uri.pathSegments.where((p) => p.isNotEmpty).last,
        )) {
          throw const ManagedFsFailure(ManagedFsFailureKind.changed);
        }
      }
    }
  }
}
