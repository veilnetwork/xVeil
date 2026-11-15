part of 'managed_directory_catalog.dart';

enum ManagedIdentityFailureKind {
  busy,
  exists,
  missing,
  mode,
  authentication,
  backend,
  closed,
  ambiguous,
}

/// Opening/creation errors contain no password, keys, local ID or path.
final class ManagedIdentityFailure implements Exception {
  const ManagedIdentityFailure(this.kind);
  final ManagedIdentityFailureKind kind;
  @override
  String toString() => 'ManagedIdentityFailure(${kind.name})';
}

/// File factory for the two ENUMERABLE modes. No hidden-container opener or
/// automatic migration/fallback lives here. Run on a storage worker.
abstract final class ManagedIdentityFiles {
  /// Explicit whole-identity deletion. Every cooperating data owner must be
  /// closed first; a live lease refuses deletion. Does not scan hidden stores.
  /// Repeating the same immutable ID/mode finishes interrupted deletion.
  static Future<void> erase(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityEntry entry,
    Uint8List? password,
    Uint8List? keys,
    IdentityEraseReview? review,
    Future<void> Function()? beforeErase,
  }) => _ManagedIdentityEraser.run(
    owner,
    entry,
    password: password,
    keys: keys,
    review: review,
    beforeErase: beforeErase,
  );

  /// Read-only review of safe unrecognized entries. Authenticates the same
  /// role/keybox as erasure; releases the lease before returning to the UI.
  static Future<IdentityEraseReview> reviewErasure(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityEntry entry,
    required Uint8List keys,
  }) async {
    IdentityEraseReview? result;
    await _ManagedIdentityEraser.run(
      owner,
      entry,
      keys: keys,
      collectReview: (value) => result = value,
    );
    if (result == null) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.missing);
    }
    return result!;
  }

  @visibleForTesting
  static Future<void> debugErase(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityEntry entry,
    Uint8List? password,
    Uint8List? keys,
    required ManagedEraseObserver observer,
  }) => _ManagedIdentityEraser.run(
    owner,
    entry,
    password: password,
    keys: keys,
    observer: observer,
  );

  static ManagedIdentityId newId() {
    final random = Random.secure();
    return ManagedIdentityId(
      List.generate(
        16,
        (_) => random.nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  static ManagedIdentityStore createEncrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
    required Uint8List password,
    List<KvLogOp> initial = const [],
  }) => _create(
    owner,
    ManagedIdentityEntry(id: id, protection: StorageProtection.encrypted),
    password: password,
    initial: initial,
  );

  static ManagedIdentityStore createUnencrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
    List<KvLogOp> initial = const [],
  }) => _create(
    owner,
    ManagedIdentityEntry(id: id, protection: StorageProtection.unencrypted),
    initial: initial,
  );

  static ManagedIdentityStore openWithPassword(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
    required Uint8List password,
  }) => _openListed(owner, id, password: password);

  static ManagedIdentityStore openWithKeys(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
    required Uint8List keys,
  }) => _openListed(owner, id, keys: keys);

  static ManagedIdentityStore openUnencrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
  }) => _openListed(owner, id, plain: true);

  /// Explicitly finish an interrupted, unlisted creation after authenticating
  /// its role/payload. Entry/mode are explicit; a failed password never tries
  /// a plaintext backend. Both final+staging directories are ambiguous.
  static ManagedIdentityStore resumeEncrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
    required Uint8List password,
  }) => _resume(
    owner,
    ManagedIdentityEntry(id: id, protection: StorageProtection.encrypted),
    password: password,
  );

  static ManagedIdentityStore resumeUnencrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
  }) => _resume(
    owner,
    ManagedIdentityEntry(id: id, protection: StorageProtection.unencrypted),
  );

  /// Only for an authenticated parent's durable planned slot. Enumerate the
  /// admitted parent to prove absence; never reinterpret an open/authentication
  /// failure as permission to create. Publication remains strictly no-replace.
  static ManagedIdentityStore openPlannedEncrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
    required Uint8List password,
  }) => _planned(
    owner,
    ManagedIdentityEntry(id: id, protection: StorageProtection.encrypted),
    password: password,
  );

  static ManagedIdentityStore openPlannedUnencrypted(
    ManagedDirectoryCatalog owner, {
    required ManagedIdentityId id,
  }) => _planned(
    owner,
    ManagedIdentityEntry(id: id, protection: StorageProtection.unencrypted),
  );

  static ManagedIdentityStore _planned(
    ManagedDirectoryCatalog owner,
    ManagedIdentityEntry entry, {
    Uint8List? password,
  }) => _safe(() {
    owner._validate();
    final target = owner.layout.directory(entry.id);
    final staged = _staging(owner, entry.id);
    // listSync throws on inaccessible enumeration. typeSync(notFound) alone
    // would not distinguish a missing entry from an unsuccessful path lookup.
    final paths = Directory(
      owner.directory,
    ).listSync(followLinks: false).map((entity) => entity.path).toSet();
    owner._validate();
    if (_listed(owner, entry.id) != null ||
        paths.contains(target) ||
        paths.contains(staged)) {
      return _resume(owner, entry, password: password);
    }
    return _create(owner, entry, password: password, initial: const []);
  });

  static String _staging(ManagedDirectoryCatalog owner, ManagedIdentityId id) =>
      ManagedDirectoryCatalog._child(
        owner.directory,
        '.identity-${id.value}.pending',
      );

  static bool _exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  static ManagedIdentityEntry? _listed(
    ManagedDirectoryCatalog owner,
    ManagedIdentityId id,
  ) {
    for (final entry in owner.snapshot().catalog.identities) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  static void _sameMode(
    ManagedIdentityEntry actual,
    ManagedIdentityEntry expected,
  ) {
    if (actual.protection != expected.protection) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.mode);
    }
  }

  static ManagedIdentityStore _create(
    ManagedDirectoryCatalog owner,
    ManagedIdentityEntry entry, {
    Uint8List? password,
    required List<KvLogOp> initial,
  }) => _safe(() {
    final existing = owner.snapshot().catalog.identities;
    if (existing.length >= ManagedIdentityCatalog.maxIdentities) {
      throw const ManagedCatalogFailure(ManagedCatalogFailureKind.full);
    }
    if (entry.protection == StorageProtection.encrypted &&
        (password == null || password.isEmpty)) {
      throw const ManagedIdentityFailure(
        ManagedIdentityFailureKind.authentication,
      );
    }
    if (_listed(owner, entry.id) != null ||
        _exists(owner.layout.directory(entry.id))) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.exists);
    }
    final resources = _ManagedIdentityResources(owner, entry);
    owner._reserveIdentity(resources);
    final copied = password == null ? null : Uint8List.fromList(password);
    Uint8List? keys;
    try {
      final staged = _staging(owner, entry.id);
      if (!owner._fs.createPrivateDirectory(staged)) {
        throw const ManagedIdentityFailure(ManagedIdentityFailureKind.exists);
      }
      resources.admit(staged);
      resources.create(copied);
      if (initial.isNotEmpty) resources.backend!.commit(initial);
      keys = resources.backend!.exportKeys();
      resources.closePayloads();
      _publish(resources, staged);
      resources.open(keys: keys);
      return _register(resources);
    } catch (_) {
      resources.close();
      rethrow;
    } finally {
      copied?.fillRange(0, copied.length, 0);
      keys?.fillRange(0, keys.length, 0);
    }
  });

  static ManagedIdentityStore _openListed(
    ManagedDirectoryCatalog owner,
    ManagedIdentityId id, {
    Uint8List? password,
    Uint8List? keys,
    bool plain = false,
  }) => _safe(() {
    final entry = _listed(owner, id);
    if (entry == null) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.missing);
    }
    if ((plain || password != null) &&
        entry.protection !=
            (plain
                ? StorageProtection.unencrypted
                : StorageProtection.encrypted)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.mode);
    }
    final resources = _ManagedIdentityResources(owner, entry);
    owner._reserveIdentity(resources);
    final credential = keys ?? password;
    final copied = credential == null ? null : Uint8List.fromList(credential);
    try {
      resources.admit(owner.layout.directory(id));
      resources.open(
        password: password == null ? null : copied,
        keys: keys == null ? null : copied,
        requireListed: true,
      );
      return resources.handOff();
    } catch (_) {
      resources.close();
      rethrow;
    } finally {
      copied?.fillRange(0, copied.length, 0);
    }
  });

  static ManagedIdentityStore _resume(
    ManagedDirectoryCatalog owner,
    ManagedIdentityEntry entry, {
    Uint8List? password,
  }) => _safe(() {
    final listed = _listed(owner, entry.id);
    if (listed != null) _sameMode(listed, entry);
    final staged = _staging(owner, entry.id);
    final target = owner.layout.directory(entry.id);
    if (_exists(staged) && _exists(target)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.ambiguous);
    }
    final resources = _ManagedIdentityResources(owner, entry);
    owner._reserveIdentity(resources);
    final copied = password == null ? null : Uint8List.fromList(password);
    Uint8List? keys;
    try {
      final fromStage = !_exists(target);
      resources.admit(fromStage ? staged : target);
      resources.open(password: copied);
      if (fromStage) {
        keys = resources.backend!.exportKeys();
        resources.closePayloads();
        _publish(resources, staged);
        resources.open(keys: keys);
      }
      return _register(resources);
    } catch (_) {
      resources.close();
      rethrow;
    } finally {
      copied?.fillRange(0, copied.length, 0);
      keys?.fillRange(0, keys.length, 0);
    }
  });

  static void _publish(_ManagedIdentityResources resources, String staged) {
    final owner = resources.owner;
    owner._validate();
    resources.validatePaths();
    owner._fs.syncDirectory(staged);
    final destination = owner.layout.directory(resources.entry.id);
    if (!owner._fs.publishDirectoryNoReplace(staged, destination)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.exists);
    }
    owner._fs.syncDirectory(owner.directory);
    resources.path = destination;
    resources.validatePaths();
  }

  static ManagedIdentityStore _register(_ManagedIdentityResources resources) {
    resources.validatePaths();
    resources.owner._catalog.register(resources.entry);
    resources.owner._validate();
    return resources.handOff();
  }

  static T _safe<T>(T Function() action) {
    try {
      return action();
    } on ManagedIdentityFailure {
      rethrow;
    } on ManagedSqliteFailure catch (error, trace) {
      Error.throwWithStackTrace(
        ManagedIdentityFailure(
          error.sqliteCode == 5
              ? ManagedIdentityFailureKind.busy
              : ManagedIdentityFailureKind.backend,
        ),
        trace,
      );
    } on hv.HvException catch (error, trace) {
      Error.throwWithStackTrace(
        ManagedIdentityFailure(
          error.kind == 'AuthFailed'
              ? ManagedIdentityFailureKind.authentication
              : error.kind == 'Busy'
              ? ManagedIdentityFailureKind.busy
              : ManagedIdentityFailureKind.backend,
        ),
        trace,
      );
    } on ManagedFsFailure {
      rethrow;
    } on ManagedLeaseFailure catch (error, trace) {
      if (error.kind == ManagedLeaseFailureKind.busy) {
        Error.throwWithStackTrace(
          const ManagedIdentityFailure(ManagedIdentityFailureKind.busy),
          trace,
        );
      }
      rethrow;
    } on ManagedCatalogFailure {
      rethrow;
    } catch (_, trace) {
      Error.throwWithStackTrace(
        const ManagedIdentityFailure(ManagedIdentityFailureKind.backend),
        trace,
      );
    }
  }

  static Future<T> _safeAsync<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error, trace) {
      return _safe(() => Error.throwWithStackTrace(error, trace));
    }
  }
}

/// Resources remain attached to their root even if an open's cleanup fails.
/// Root.close retries failed opens, and refuses to forget any active session.
final class _ManagedIdentityResources {
  _ManagedIdentityResources(this.owner, this.entry);
  final ManagedDirectoryCatalog owner;
  final ManagedIdentityEntry entry;
  String? path;
  ManagedPathWitness? witness;
  ManagedIdentityLease? lease;
  HvKvLogStore? rawKeybox;
  ManagedKeybox? keybox;
  HvKvLogStore? content;
  HvKvLogStore? maintenance;
  KvLogStore? backend;
  bool handedOff = false;
  bool closing = false;
  bool closed = false;
  bool reclaiming = false;
  bool inspecting = false;
  bool erasing = false;
  HvKvLogStore? reclaimStaged;

  String file(String name) => ManagedDirectoryCatalog._child(path!, name);

  void admit(String directory) {
    owner._validate();
    witness = ManagedDirectoryCatalog._privateDirectory(directory, owner._fs);
    path = directory;
  }

  void validatePaths() {
    owner._validate();
    if (path == null || witness == null) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.missing);
    }
    ManagedDirectoryCatalog._privateDirectory(path!, owner._fs);
    ManagedDirectoryCatalog._assertSame(path!, witness!, owner._fs);
  }

  ManagedSqliteConnection _sql(String name, {bool create = false}) {
    validatePaths();
    final target = file(name);
    if (create) {
      File(target).createSync(exclusive: true);
      owner._fs.restrictNewFile(target);
    }
    final before = owner._fs.requirePrivateFile(target);
    ManagedDirectoryCatalog._checkSqliteSidecars(target, owner._fs);
    final connection = ManagedSqliteConnection.openUnencrypted(target);
    try {
      validatePaths();
      ManagedDirectoryCatalog._assertSame(target, before, owner._fs);
      return connection;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  HvKvLogStore _native(
    String name, {
    required Uint8List password,
    Uint8List? keys,
    bool create = false,
    bool outer = false,
  }) {
    if (!ensureHiddenVolumeLoaded()) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.backend);
    }
    validatePaths();
    final target = file(name);
    ManagedPathWitness? before;
    if (!create) {
      before = owner._fs.requirePrivateFile(target);
    } else if (ManagedIdentityFiles._exists(target)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.exists);
    }
    final hv.HvSpace space;
    if (create) {
      space = hv.HvSpace.create(
        path: target,
        password: password,
        argon: outer ? hv.ArgonPreset.heavy : hv.ArgonPreset.defaults,
        // Persist this enumerable store's posture: a session-only override
        // would let native repacking restore the header's hidden padding.
        padding: hv.PaddingPreset.none,
      );
    } else {
      space = keys == null
          ? hv.HvSpace.open(path: target, password: password)
          : hv.HvSpace.openWithKeys(path: target, keys: keys);
      space.cancelDeferredVacuum();
    }
    try {
      space.setPaddingPolicy(hv.PaddingPreset.none);
      validatePaths();
      owner._fs.requirePrivateFile(target);
      if (before != null) {
        ManagedDirectoryCatalog._assertSame(target, before, owner._fs);
      }
      return HvKvLogStore(space);
    } catch (_) {
      space.close();
      rethrow;
    }
  }

  Uint8List _plainKeys() => Uint8List.fromList(
    sha512
        .convert(
          'xveil-unencrypted-local-locator-v1:${entry.id.value}'.codeUnits,
        )
        .bytes,
  );

  void create(Uint8List? password) {
    lease = ManagedIdentityLease.initializeOwned(
      _sql('identity.meta', create: true),
      entry: entry,
    );
    if (!owner._fs.createPrivateDirectory(file('blobs'))) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.exists);
    }
    owner._fs.syncDirectory(file('blobs'));
    if (entry.protection == StorageProtection.unencrypted) {
      final keys = _plainKeys();
      try {
        backend = PlainSqliteKvLogStore(
          _sql('data.store', create: true),
          keys: keys,
          initialize: true,
        );
      } finally {
        keys.fillRange(0, keys.length, 0);
      }
    } else {
      if (password == null) {
        throw const ManagedIdentityFailure(ManagedIdentityFailureKind.mode);
      }
      rawKeybox = _native(
        'keybox.hv',
        password: password,
        create: true,
        outer: true,
      );
      keybox = ManagedKeybox.initializeNew(rawKeybox!, identity: entry.id);
      _openInner(create: true);
    }
  }

  void acquireLease() {
    owner._fs.requirePrivateFile(file('identity.meta.lock'));
    lease = ManagedIdentityLease.openOwned(
      _sql('identity.meta'),
      expected: entry,
    );
  }

  void open({
    Uint8List? password,
    Uint8List? keys,
    bool requireListed = false,
  }) {
    acquireLease();
    // A delete may have finished while this opener held an old catalog view.
    // Do not open payloads or recreate any files after winning that stale race.
    if (requireListed) {
      final current = ManagedIdentityFiles._listed(owner, entry.id);
      if (current == null) {
        throw const ManagedIdentityFailure(ManagedIdentityFailureKind.missing);
      }
      ManagedIdentityFiles._sameMode(current, entry);
    }
    ManagedDirectoryCatalog._privateDirectory(file('blobs'), owner._fs);
    if (entry.protection == StorageProtection.unencrypted) {
      final expected = _plainKeys();
      try {
        if (password != null || (keys != null && !_equal(expected, keys))) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.authentication,
          );
        }
        backend = PlainSqliteKvLogStore(_sql('data.store'), keys: expected);
      } finally {
        expected.fillRange(0, expected.length, 0);
      }
    } else {
      if (keys != null && keys.length != 64) {
        throw const ManagedIdentityFailure(
          ManagedIdentityFailureKind.authentication,
        );
      }
      if (password == null && keys == null) {
        throw const ManagedIdentityFailure(ManagedIdentityFailureKind.mode);
      }
      rawKeybox = _native(
        'keybox.hv',
        password: password ?? Uint8List(0),
        keys: keys,
        outer: true,
      );
      keybox = ManagedKeybox.openOwned(rawKeybox!, identity: entry.id);
      _openInner();
    }
  }

  void _openInner({bool create = false}) {
    final contentPassword = keybox!.copyContentPassword();
    final maintenancePassword = keybox!.copyMaintenancePassword();
    try {
      content = _native(
        'content.hv',
        password: contentPassword,
        create: create,
      );
      maintenance = _native(
        'maintenance.hv',
        password: maintenancePassword,
        create: create,
      );
      backend = create
          ? ManagedEncryptedKvLogStore.initializeOwned(
              keybox: keybox!,
              content: content!,
              maintenance: maintenance!,
            )
          : ManagedEncryptedKvLogStore.openOwned(
              keybox: keybox!,
              content: content!,
              maintenance: maintenance!,
            );
    } finally {
      contentPassword.fillRange(0, contentPassword.length, 0);
      maintenancePassword.fillRange(0, maintenancePassword.length, 0);
    }
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  void closePayloads() {
    // Never release the identity lease before every payload close succeeds.
    closeDataHandles();
    lease?.close();
    lease = null;
  }

  void closeDataHandles() {
    reclaimStaged?.close();
    reclaimStaged = null;
    backend?.close();
    backend = null;
    content?.close();
    content = null;
    maintenance?.close();
    maintenance = null;
    keybox?.close();
    keybox = null;
    rawKeybox?.close();
    rawKeybox = null;
  }

  ManagedIdentityStore handOff() {
    requireOwned();
    handedOff = true;
    return entry.protection == StorageProtection.encrypted
        ? _EncryptedIdentityStore(this)
        : _PlainIdentityStore(this);
  }

  void requireOwned() {
    if (reclaiming || inspecting || erasing) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.busy);
    }
    if (closing ||
        closed ||
        backend == null ||
        !identical(owner._identityOwners[entry.id], this)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.closed);
    }
    lease!.requireHeld();
  }

  void close() {
    if (closed) return;
    if (reclaiming || inspecting || erasing) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.busy);
    }
    closing = true;
    closePayloads();
    closed = true;
    owner._releaseIdentity(this);
  }
}

/// Application port owns both the data backend and its identity lease. Ordinary
/// reads/writes stay on pinned native handles, with no path/KDF work per key.
/// Path admission is repeated for pathname-based lifecycle operations instead.
sealed class ManagedIdentityStore
    implements
        KvLogStore,
        SyncCommitAnchorSource,
        StorageUsageSource,
        SyncInitializationNamespaceSource {
  ManagedIdentityStore._(this._resources);
  final _ManagedIdentityResources _resources;
  ManagedIdentityEntry get entry => _resources.entry;
  @override
  Future<StorageUsage> storageUsage() => _resources.measureUsage();
  Future<ManagedReclaimReport> reclaim({bool force = false}) =>
      _resources.reclaim(force: force);

  @visibleForTesting
  Future<ManagedReclaimReport> debugReclaim(
    ManagedReclaimObserver observer, {
    bool force = true,
  }) => _resources.reclaim(force: force, observer: observer);
  T _use<T>(T Function(KvLogStore) work) {
    _resources.requireOwned();
    return work(_resources.backend!);
  }

  @override
  int commit(List<KvLogOp> ops) => _use((s) => s.commit(ops));
  @override
  Uint8List? get(int namespace, Uint8List key) =>
      _use((s) => s.get(namespace, key));
  @override
  Uint8List? readLog(int namespace, int logId) =>
      _use((s) => s.readLog(namespace, logId));
  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) => _use(
    (s) => s.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    ),
  );
  @override
  int count(int namespace) => _use((s) => s.count(namespace));
  @override
  List<Uint8List> kvKeys(int namespace) => _use((s) => s.kvKeys(namespace));
  @override
  int eraseNamespace(int namespace) => _use((s) => s.eraseNamespace(namespace));
  @override
  void scrub() => _use((s) => s.scrub());
  @override
  Uint8List exportKeys() => _use((s) => s.exportKeys());
  @override
  SlotUtilization? slotUtilization() => _use((s) => s.slotUtilization());
  @override
  String? hardeningWarning() => _use((s) => s.hardeningWarning());
  @override
  void acknowledgeHardeningWarning() =>
      _use((s) => s.acknowledgeHardeningWarning());
  @override
  int initializationNamespaceLimit() => _use(
    (s) => s is SyncInitializationNamespaceSource
        ? (s as SyncInitializationNamespaceSource)
              .initializationNamespaceLimit()
        : 256,
  );
  @override
  int commitSeq() => _use((s) => (s as SyncCommitAnchorSource).commitSeq());
  @override
  List<int> commitHistory() =>
      _use((s) => (s as SyncCommitAnchorSource).commitHistory());
  @override
  Map<int, String> commitRoots() =>
      _use((s) => (s as SyncCommitAnchorSource).commitRoots());
  @override
  void close() => _resources.close();
}

final class _PlainIdentityStore extends ManagedIdentityStore {
  _PlainIdentityStore(super.resources) : super._();
}

final class _EncryptedIdentityStore extends ManagedIdentityStore
    implements SyncLogGroupReader {
  _EncryptedIdentityStore(super.resources) : super._();
  @override
  List<Uint8List>? readLogGroups(int namespace, List<LogReadGroup> groups) =>
      _use((s) => (s as SyncLogGroupReader).readLogGroups(namespace, groups));
}
