part of 'managed_directory_catalog.dart';

/// Durable intent for the enumerable portion of a whole-profile wipe. This is
/// an actor-side port, NOT permission to enable the application wipe/default.
/// The enclosing wipe must also retire every OS scope, the legacy container,
/// pending enrollment and preferences before finalizing this intent. That
/// application integration remains disabled. Ordinary startup never bypasses it.
final class ManagedRootErasure {
  ManagedRootErasure._(
    this._gate,
    this._plan,
    this._directory,
    this._file,
    this.binding,
  );
  ManagedRootErasure._finishing(this._gate, _ErasureCompletion completion)
    : _completion = completion,
      _plan = null,
      _directory = null,
      _file = null,
      binding = ManagedErasureBinding._(
        completion._record['profile'] as String,
        completion._record['coordinator'] as String,
        completion._record['directory'] as String,
        completion._record['sha256'] as String,
      );
  static const pendingName = 'erasure-pending';
  static const completionName = 'erasure-complete.json';
  static const _planName = 'plan.json';
  final StorageProfileCoordinator _gate;

  /// Opaque operation binding, stable across explicit pending/terminal recovery.
  /// It grants no admission and exposes no paths, catalog or scope roster.
  final ManagedErasureBinding binding;
  final _RootErasePlan? _plan;
  final ManagedPathWitness? _directory, _file;
  _ErasureCompletion? _completion;
  bool _finished = false;
  bool _operating = false;
  late final _stamp = File(_planPath).statSync();
  String get _intentPath =>
      ManagedDirectoryCatalog._child(_gate.directory, pendingName);
  String get _planPath =>
      ManagedDirectoryCatalog._child(_intentPath, _planName);

  /// Public locators survive catalog deletion so the enclosing wipe can derive
  /// their OS-vault scopes. No credential, network ID or hidden-space pointer.
  ManagedIdentityCatalog get catalog => _removingPlan.catalog;
  StorageUnlockScopes get unlockScopes => _removingPlan.unlockScopes;
  _RootErasePlan get _removingPlan {
    _gate.requireHeld(exclusive: true);
    if (_completion != null || _finished || _plan == null) {
      throw const ManagedFsFailure(ManagedFsFailureKind.erasurePending);
    }
    return _plan;
  }

  ManagedRootErasurePhase get phase => _finished
      ? ManagedRootErasurePhase.complete
      : _completion != null
      ? ManagedRootErasurePhase.finishing
      : ManagedRootErasurePhase.removing;

  /// Immutable public progress, not an authorization to retire OS scopes.
  /// A worker client supplies a live UI-side lease for that separate boundary.
  ManagedErasureSnapshot snapshot() {
    if (!_finished) {
      _gate.requireHeld(exclusive: true);
      if (_completion == null) _validate();
    }
    return ManagedErasureSnapshot._(
      binding,
      phase,
      phase == ManagedRootErasurePhase.removing ? catalog : null,
      phase == ManagedRootErasurePhase.removing ? unlockScopes : null,
    );
  }

  /// A worker closing after an error may retry ONLY this already-authorized
  /// final sync before releasing its native role. No external cleanup is run.
  bool get finalSyncPending => _completion?.unlinked == true && !_finished;

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
    _publishPlan(owner._coordinator, plan, owner.requireExclusiveMaintenance);
  }

  /// Explicit full-profile wipe without inventing a managed catalog. The
  /// caller owns the permanent EXCLUSIVE role, including for hidden-only
  /// profiles. The plan records root absence and the known OS scope names;
  /// it never scans hidden storage. Caller retains/actually closes this role
  /// after publication, then the explicit recovery actor owns continuation.
  static Future<void> prepareAbsent(
    StorageProfileCoordinator owner, {
    required StorageUnlockScopes unlockScopes,
  }) async {
    try {
      void requireHeld() => owner.requireHeld(exclusive: true);
      requireHeld();
      _ErasureCompletion.requireRootAbsent(owner);
      final plan = _RootErasePlan(
        owner._profileWitness.identity,
        owner._directoryWitness.identity,
        ManagedIdentityCatalog([]),
        {},
        unlockScopes,
      );
      _publishPlan(owner, plan, requireHeld);
    } on FileSystemException catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedFsFailure(ManagedFsFailureKind.io),
        trace,
      );
    }
  }

  static void _publishPlan(
    StorageProfileCoordinator gate,
    _RootErasePlan plan,
    void Function() requirePreparationHeld,
  ) {
    requirePreparationHeld();
    plan.validateTree(gate);
    final bytes = plan.encode();
    final fs = gate._fs;
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
      requirePreparationHeld();
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
      final terminal = _ErasureCompletion.openIfPresent(gate);
      if (terminal != null) {
        terminal.validate(gate);
        return ManagedRootErasure._finishing(gate, terminal);
      }
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
      final result = ManagedRootErasure._(
        gate,
        plan,
        directory,
        witness,
        ManagedErasureBinding._(
          gate._profileWitness.identity,
          gate._directoryWitness.identity,
          directory.identity,
          sha256.convert(bytes).toString(),
        ),
      );
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
    ManagedDirectoryCatalog._assertSame(_intentPath, _directory!, _gate._fs);
    _gate._fs.requirePrivateFile(_planPath);
    ManagedDirectoryCatalog._assertSame(_planPath, _file!, _gate._fs);
    final stamp = File(_planPath).statSync();
    if (stamp.size != _stamp.size ||
        stamp.modified != _stamp.modified ||
        Directory(
          _intentPath,
        ).listSync(followLinks: false).any((e) => e.path != _planPath)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    _removingPlan.validateBinding(_gate);
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
      final plan = _removingPlan;
      _validate();
      plan.validateTree(_gate);
      await retireScopes(catalog);
      _validate();
      plan.validateTree(_gate);
      final entries = plan.entries.values.toList()
        ..sort((a, b) {
          final depth = b.parts.length.compareTo(a.parts.length);
          return depth != 0 ? depth : a.path.compareTo(b.path);
        });
      for (final entry in entries) {
        _validate();
        if (!plan.validateEntry(_gate, entry)) continue;
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
      plan.validateTree(_gate);
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

  /// Called only by the enclosing whole-profile wipe after it has joined all
  /// accepted work and verified legacy files, preferences and EVERY OS scope
  /// absent. A durable terminal witness survives the removal of plan.json.
  /// Recovered terminal owners do not need (or reconstruct) the old scope list.
  Future<void> finish({
    required Future<void> Function() verifyOtherDataAbsent,
    Future<void> Function(ManagedErasureFinishStage stage)? afterStage,
  }) async {
    if (_operating) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _operating = true;
    try {
      _gate.requireHeld(exclusive: true);
      _ErasureCompletion.requireRootAbsent(_gate);
      if (_finished) return; // Lost reply, same still-held lifetime only.
      _completion ??= _ErasureCompletion.openIfPresent(_gate);
      if (_completion == null) {
        _validate();
        await verifyOtherDataAbsent();
        _validate();
        _ErasureCompletion.requireRootAbsent(_gate);
        await afterStage?.call(ManagedErasureFinishStage.beforeCompletion);
        _validate();
        _ErasureCompletion.requireRootAbsent(_gate);
        _completion = _ErasureCompletion.publish(
          _gate,
          _directory!,
          _file!,
          _stamp,
        );
      }
      // Record ownership before this sync: a failed sync must never delete the
      // published witness or permit ordinary admission on this live owner.
      final completion = _completion!;
      if (!completion.unlinked) {
        completion.validate(_gate);
        _gate._fs.syncDirectory(_gate.directory);
        await afterStage?.call(ManagedErasureFinishStage.completionPublished);
        completion.removePlan(_gate);
        await afterStage?.call(ManagedErasureFinishStage.planRemoved);
        completion.removePending(_gate);
        await afterStage?.call(ManagedErasureFinishStage.pendingRemoved);
        completion.unlink(_gate);
      }
      // If the last unlink succeeded but sync failed, retain this exclusive
      // owner. Retrying only confirms the absent terminal and syncs its parent.
      completion.confirmUnlinked(_gate);
      _finished = true;
      await afterStage?.call(ManagedErasureFinishStage.completionRemoved);
    } on FileSystemException catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedFsFailure(ManagedFsFailureKind.io),
        trace,
      );
    } finally {
      _operating = false;
    }
  }

  /// Proof is issued only after durable terminal finalization AND successful
  /// native role/lock close. A failed close issues no permission for new OS
  /// scope owners; retry uses the same consuming-close owner.
  ManagedErasureRelease releaseCompleted() {
    if (_operating || !_finished) {
      throw const ManagedFsFailure(ManagedFsFailureKind.erasurePending);
    }
    close();
    return ManagedErasureRelease._(binding);
  }

  void close() {
    if (_operating || (_completion?.unlinked == true && !_finished)) {
      throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
    }
    _gate.close();
  }
}

/// Pure cross-isolate progress. No native handle, password or hidden roster.
/// An old snapshot alone is intentionally NOT a fresh OS-retirement grant.
final class ManagedErasureSnapshot {
  ManagedErasureSnapshot._(
    this.binding,
    this.phase,
    this._catalog,
    this._scopes,
  );
  final ManagedErasureBinding binding;
  final ManagedRootErasurePhase phase;
  final ManagedIdentityCatalog? _catalog;
  final StorageUnlockScopes? _scopes;
  ManagedIdentityCatalog get catalog =>
      _catalog ??
      (throw const ManagedFsFailure(ManagedFsFailureKind.erasurePending));
  StorageUnlockScopes get unlockScopes =>
      _scopes ??
      (throw const ManagedFsFailure(ManagedFsFailureKind.erasurePending));
}

/// Opaque binding of the exact immutable intent and its original local role
/// objects. Public mutable metadata is not an authorization against its owner.
final class ManagedErasureBinding {
  const ManagedErasureBinding._(
    this._profile,
    this._coordinator,
    this._pending,
    this._digest,
  );
  final String _profile, _coordinator, _pending, _digest;
}

/// Cannot be constructed by UI callers or obtained from a merely deleted root.
/// Its issuer has completed the terminal protocol and actually released locks.
final class ManagedErasureRelease {
  const ManagedErasureRelease._(this._binding);
  final ManagedErasureBinding _binding;
  bool authorizes(ManagedErasureBinding binding) =>
      _binding._profile == binding._profile &&
      _binding._coordinator == binding._coordinator &&
      _binding._pending == binding._pending &&
      _binding._digest == binding._digest;
}

enum ManagedRootErasurePhase { removing, finishing, complete }

/// No local paths or identity/OS-scope names in phase observations.
enum ManagedErasureFinishStage {
  beforeCompletion,
  completionPublished,
  planRemoved,
  pendingRemoved,
  completionRemoved,
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
    this.unlockScopes, {
    String? operation,
  }) : operation = operation ?? _newOperation();
  static String _newOperation() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Distinguish successive empty-root intents even if filesystem object IDs
  /// are reused. The plan digest carries this public nonce into release proofs.
  final String operation;
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
          'v': 3,
          'operation': operation,
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
          raw.length != 7 ||
          raw['v'] is! int ||
          raw['v'] != 3 ||
          raw['operation'] is! String ||
          !_id.hasMatch(raw['operation'] as String) ||
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
      if (list.length > maxEntries ||
          list.isEmpty && catalog.identities.isNotEmpty) {
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
      if (entries.isNotEmpty && entries['identities']?.directory != true) {
        throw const FormatException();
      }
      return _RootErasePlan(
        raw['profile'] as String,
        raw['coordinator'] as String,
        catalog,
        entries,
        scopes,
        operation: raw['operation'] as String,
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
    gate.requireHeld(exclusive: true);
    validateBinding(gate);
    if (entries.isEmpty) {
      // An absent-root intent can never become authority to remove a later
      // directory, file or link. This check also runs after enclosing awaits.
      _ErasureCompletion.requireRootAbsent(gate);
      return;
    }
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
