part of 'async_kv_log_store.dart';

enum ManagedWorkerFailureKind {
  authentication,
  busy,
  exists,
  missing,
  mode,
  closed,
  ambiguous,
  invalid,
  backend,
}

/// Bounded transport error: never contains native messages, paths, IDs or keys.
final class ManagedWorkerFailure implements Exception {
  const ManagedWorkerFailure(this.kind);
  final ManagedWorkerFailureKind kind;
  @override
  String toString() => 'ManagedWorkerFailure(${kind.name})';
}

enum _ManagedWorkerAction { create, password, keys, plain, resume }

final class _OpenManagedIdentity extends _OpenConfig {
  const _OpenManagedIdentity({
    required super.path,
    required super.reply,
    required this.entry,
    required this.action,
    required this.credential,
    required this.initial,
  }) : super(paddingPresetTag: 0);
  final ManagedIdentityEntry entry;
  final _ManagedWorkerAction action;
  final Uint8List? credential;
  final List<KvLogOp> initial;
}

final class _ManagedWorkerErr extends _Reply {
  const _ManagedWorkerErr(this.kind);
  final ManagedWorkerFailureKind kind;
}

final class _ManagedReclaimReq extends _Req {
  const _ManagedReclaimReq(this.force, super.reply);
  final bool force;
}

final class _ManagedOpenFailed extends _Reply {
  const _ManagedOpenFailed(this.kind, this.cleanup);
  final ManagedWorkerFailureKind kind;
  final SendPort cleanup;
}

final class _ManagedBootstrapCleanup implements Exception {
  const _ManagedBootstrapCleanup(this.kind, this.owner);
  final ManagedWorkerFailureKind kind;
  final WorkerKvLogStore owner;
}

/// Visible-only worker bootstrap. No inline fallback, hidden-container probe or
/// automatic conversion exists here. Create/open/KDF and all store I/O run in
/// the worker, with its admitted root retained until confirmed close.
abstract final class ManagedWorkerIdentity {
  /// Queue owned maintenance. Legacy/hidden workers reject this request.
  static Future<ManagedReclaimReport> reclaim(
    WorkerKvLogStore worker, {
    bool force = false,
  }) => worker._call((reply) => _ManagedReclaimReq(force, reply));
  // Lexical only: actual path/ancestor admission remains in the worker.
  static String _profileKey(String profile) =>
      Directory(profile).absolute.uri.normalizePath().toFilePath();
  // Failed-open owners remain reachable until their actual native release.
  // A later request for this local ID must drain them before another spawn.
  static final _retiring =
      <(String, ManagedIdentityId?), Set<WorkerKvLogStore>>{};

  @visibleForTesting
  static int get debugRetiringOwnerCount =>
      _retiring.values.fold(0, (count, owners) => count + owners.length);

  /// Exercises failed-bootstrap retirement with a disposable test worker.
  @visibleForTesting
  static Future<WorkerKvLogStore?> debugFailedBootstrap({
    required String profileDirectory,
    required ManagedIdentityId id,
    required WorkerKvLogStore owner,
  }) => _spawnOwned(
    _profileKey(profileDirectory),
    id,
    () => Future.error(
      _ManagedBootstrapCleanup(ManagedWorkerFailureKind.invalid, owner),
    ),
  );

  static Future<void> _drainRetired(
    String profile,
    ManagedIdentityId? id,
  ) async {
    final key = (profile, id);
    final owners = _retiring[key];
    if (owners == null) return;
    for (final owner in owners.toList()) {
      try {
        await owner.close();
      } catch (error) {
        throw ManagedWorkerFailure(_managedFailureKind(error));
      }
      owners.remove(owner);
    }
    if (owners.isEmpty && identical(_retiring[key], owners)) {
      _retiring.remove(key);
    }
  }

  static Future<WorkerKvLogStore> createEncrypted({
    required String profileDirectory,
    required ManagedIdentityId id,
    required Uint8List password,
    List<KvLogOp> initial = const [],
  }) => _start(
    profileDirectory,
    id,
    StorageProtection.encrypted,
    _ManagedWorkerAction.create,
    credential: password,
    initial: initial,
  );

  static Future<WorkerKvLogStore> createUnencrypted({
    required String profileDirectory,
    required ManagedIdentityId id,
    List<KvLogOp> initial = const [],
  }) => _start(
    profileDirectory,
    id,
    StorageProtection.unencrypted,
    _ManagedWorkerAction.create,
    initial: initial,
  );

  static Future<WorkerKvLogStore> openEncrypted({
    required String profileDirectory,
    required ManagedIdentityId id,
    required Uint8List password,
  }) => _start(
    profileDirectory,
    id,
    StorageProtection.encrypted,
    _ManagedWorkerAction.password,
    credential: password,
  );

  static Future<WorkerKvLogStore> openWithKeys({
    required String profileDirectory,
    required ManagedIdentityId id,
    required StorageProtection protection,
    required Uint8List keys,
  }) => _start(
    profileDirectory,
    id,
    protection,
    _ManagedWorkerAction.keys,
    credential: keys,
  );

  static Future<WorkerKvLogStore> openUnencrypted({
    required String profileDirectory,
    required ManagedIdentityId id,
  }) => _start(
    profileDirectory,
    id,
    StorageProtection.unencrypted,
    _ManagedWorkerAction.plain,
  );

  static Future<WorkerKvLogStore> resumeEncrypted({
    required String profileDirectory,
    required ManagedIdentityId id,
    required Uint8List password,
  }) => _start(
    profileDirectory,
    id,
    StorageProtection.encrypted,
    _ManagedWorkerAction.resume,
    credential: password,
  );

  static Future<WorkerKvLogStore> resumeUnencrypted({
    required String profileDirectory,
    required ManagedIdentityId id,
  }) => _start(
    profileDirectory,
    id,
    StorageProtection.unencrypted,
    _ManagedWorkerAction.resume,
  );

  static Future<WorkerKvLogStore> _start(
    String profile,
    ManagedIdentityId id,
    StorageProtection protection,
    _ManagedWorkerAction action, {
    Uint8List? credential,
    List<KvLogOp> initial = const [],
  }) {
    // Snapshot before spawning/awaiting so caller mutation cannot change the
    // credential or initial durable payload selected by this request.
    final entry = ManagedIdentityEntry(id: id, protection: protection);
    final owned = credential == null ? null : Uint8List.fromList(credential);
    final records = [
      for (final op in initial)
        switch (op) {
          PutOp() => PutOp(
            op.namespace,
            Uint8List.fromList(op.key),
            Uint8List.fromList(op.value),
          ),
          DeleteOp() => DeleteOp(op.namespace, Uint8List.fromList(op.key)),
          AppendLogOp() => AppendLogOp(
            op.namespace,
            op.logId,
            Uint8List.fromList(op.payload),
          ),
          DeleteLogOp() => DeleteLogOp(op.namespace, op.logId),
        },
    ];
    return _spawnOwned(
          _profileKey(profile),
          id,
          () => WorkerKvLogStore._spawn(
            (reply) => _OpenManagedIdentity(
              path: profile,
              reply: reply,
              entry: entry,
              action: action,
              credential: owned,
              initial: records,
            ),
          ),
        )
        .then((store) {
          if (store == null) {
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
          }
          return store;
        })
        .whenComplete(() {
          owned?.fillRange(0, owned.length, 0);
          _wipeManagedInitial(records);
        });
  }

  static Future<WorkerKvLogStore?> _spawnOwned(
    String profile,
    ManagedIdentityId? id,
    Future<WorkerKvLogStore?> Function() spawn,
  ) async {
    await _drainRetired(profile, id);
    try {
      return await spawn();
    } on _ManagedBootstrapCleanup catch (failure) {
      (_retiring[(profile, id)] ??= {}).add(failure.owner);
      try {
        await _drainRetired(profile, id);
      } on ManagedWorkerFailure {
        // Ownership is retained in the registry, not declared released. A
        // later create/open retries it, with no new filesystem access first.
      }
      throw ManagedWorkerFailure(failure.kind);
    }
  }
}

void _wipeManagedInitial(List<KvLogOp> records) {
  for (final op in records) {
    switch (op) {
      case PutOp():
        op.key.fillRange(0, op.key.length, 0);
        op.value.fillRange(0, op.value.length, 0);
      case DeleteOp():
        op.key.fillRange(0, op.key.length, 0);
      case AppendLogOp():
        op.payload.fillRange(0, op.payload.length, 0);
      case DeleteLogOp():
        break;
    }
  }
}

final class _ManagedWorkerOwner {
  _ManagedWorkerOwner(this.root, this.store) : failure = null;
  _ManagedWorkerOwner.retiring(this.root, this.failure) : store = null;
  final ManagedDirectoryCatalog root;
  final ManagedIdentityStore? store;
  final ManagedWorkerFailureKind? failure;
  void close() {
    store?.close();
    root.close();
  }
}

SendPort _serveManagedCleanup(void Function() close) {
  final requests = ReceivePort();
  requests.listen((dynamic message) {
    if (message is! _CloseReq) return;
    try {
      close();
      message.reply.send(const _Ok(null));
      requests.close();
      Isolate.current.kill(priority: Isolate.immediate);
    } catch (error) {
      message.reply.send(_workerErrorReply(error, managed: true));
    }
  });
  return requests.sendPort;
}

_ManagedWorkerOwner _openManagedWorker(_OpenManagedIdentity config) {
  ManagedDirectoryCatalog? root;
  try {
    root = config.action == _ManagedWorkerAction.create
        ? ManagedDirectoryCatalog.createOrOpen(config.path)
        : ManagedDirectoryCatalog.openExisting(config.path);
    if (root == null) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.missing);
    }
    final id = config.entry.id;
    final encrypted = config.entry.protection == StorageProtection.encrypted;
    if (config.action != _ManagedWorkerAction.create) {
      for (final entry in root.snapshot().catalog.identities) {
        if (entry.id == id && entry.protection != config.entry.protection) {
          throw const ManagedIdentityFailure(ManagedIdentityFailureKind.mode);
        }
      }
    }
    final credential = config.credential;
    final store = switch (config.action) {
      _ManagedWorkerAction.create =>
        encrypted
            ? ManagedIdentityFiles.createEncrypted(
                root,
                id: id,
                password: credential!,
                initial: config.initial,
              )
            : ManagedIdentityFiles.createUnencrypted(
                root,
                id: id,
                initial: config.initial,
              ),
      _ManagedWorkerAction.password => ManagedIdentityFiles.openWithPassword(
        root,
        id: id,
        password: credential!,
      ),
      _ManagedWorkerAction.keys => ManagedIdentityFiles.openWithKeys(
        root,
        id: id,
        keys: credential!,
      ),
      _ManagedWorkerAction.plain => ManagedIdentityFiles.openUnencrypted(
        root,
        id: id,
      ),
      _ManagedWorkerAction.resume =>
        encrypted
            ? ManagedIdentityFiles.resumeEncrypted(
                root,
                id: id,
                password: credential!,
              )
            : ManagedIdentityFiles.resumeUnencrypted(root, id: id),
    };
    return _ManagedWorkerOwner(root, store);
  } catch (error) {
    try {
      root?.close();
    } catch (_) {
      // Root still owns the partial open. Keep a cleanup-only worker alive and
      // hand its close capability to the caller's retirement registry.
      return _ManagedWorkerOwner.retiring(root!, _managedFailureKind(error));
    }
    rethrow;
  } finally {
    config.credential?.fillRange(0, config.credential!.length, 0);
    _wipeManagedInitial(config.initial);
  }
}

_Reply _workerErrorReply(Object error, {required bool managed}) {
  if (!managed) {
    return error is hv.HvException
        ? _Err(error.kind, error.message)
        : _Err('Internal', error.toString());
  }
  return _ManagedWorkerErr(_managedFailureKind(error));
}

ManagedWorkerFailureKind _managedFailureKind(Object error) => switch (error) {
  ManagedWorkerFailure(:final kind) => kind,
  ManagedIdentityFailure(:final kind) => switch (kind) {
    ManagedIdentityFailureKind.authentication =>
      ManagedWorkerFailureKind.authentication,
    ManagedIdentityFailureKind.busy => ManagedWorkerFailureKind.busy,
    ManagedIdentityFailureKind.exists => ManagedWorkerFailureKind.exists,
    ManagedIdentityFailureKind.missing => ManagedWorkerFailureKind.missing,
    ManagedIdentityFailureKind.mode => ManagedWorkerFailureKind.mode,
    ManagedIdentityFailureKind.closed => ManagedWorkerFailureKind.closed,
    ManagedIdentityFailureKind.ambiguous => ManagedWorkerFailureKind.ambiguous,
    ManagedIdentityFailureKind.backend => ManagedWorkerFailureKind.backend,
  },
  ManagedLeaseFailure(kind: ManagedLeaseFailureKind.busy) =>
    ManagedWorkerFailureKind.busy,
  ManagedSqliteFailure(sqliteCode: 5) => ManagedWorkerFailureKind.busy,
  hv.HvException(kind: 'Busy') => ManagedWorkerFailureKind.busy,
  hv.HvException(kind: 'AuthFailed') => ManagedWorkerFailureKind.authentication,
  ManagedCatalogFailure() ||
  ManagedLeaseFailure() ||
  ManagedFsFailure() => ManagedWorkerFailureKind.invalid,
  _ => ManagedWorkerFailureKind.backend,
};
