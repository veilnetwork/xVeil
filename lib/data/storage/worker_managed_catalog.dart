part of 'async_kv_log_store.dart';

final class _OpenManagedCatalog extends _OpenConfig {
  const _OpenManagedCatalog({required super.path, required super.reply})
    : super(paddingPresetTag: 0);
}

final class _CatalogSnapshotReq extends _Req {
  const _CatalogSnapshotReq(super.reply);
}

final class _CatalogSelectReq extends _Req {
  const _CatalogSelectReq(this.entry, super.reply);
  final ManagedIdentityEntry? entry;
}

/// Off-UI profile metadata owner. Enumeration/selection never opens identities,
/// probes hidden credentials or creates an absent managed catalog. The existing
/// storage-worker close protocol retains ownership across errors/timeouts.
final class ManagedCatalogWorker {
  ManagedCatalogWorker._(this._worker);
  final WorkerKvLogStore _worker;

  static Future<ManagedCatalogWorker> open(String profileDirectory) async {
    final profile = ManagedWorkerIdentity._profileKey(profileDirectory);
    final worker = await ManagedWorkerIdentity._spawnOwned(
      profile,
      null,
      () => WorkerKvLogStore._spawn(
        (reply) => _OpenManagedCatalog(path: profile, reply: reply),
      ),
    );
    if (worker == null) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
    }
    return ManagedCatalogWorker._(worker);
  }

  Future<({bool exists, ManagedCatalogSnapshot snapshot})> snapshot() =>
      _worker._call((reply) => _CatalogSnapshotReq(reply));
  Future<ManagedCatalogSnapshot> select(ManagedIdentityEntry? entry) =>
      _worker._call((reply) => _CatalogSelectReq(entry, reply));
  Future<void> close() => _worker.close();
}

void _managedCatalogEntry(_OpenManagedCatalog config) {
  ManagedDirectoryCatalog? root;
  try {
    root = ManagedDirectoryCatalog.openExisting(config.path);
  } catch (error) {
    config.reply.send(_workerErrorReply(error, managed: true));
    return;
  }
  final rx = ReceivePort();
  var closing = false;
  // This read/selection-only owner has no identity sessions. Its only native
  // release is the consuming SQLite/catalog close; preserve an uncertain error.
  final release = NativeHandleClose(() => root?.close());
  ManagedDirectoryCatalog? current() =>
      root ??= ManagedDirectoryCatalog.openExisting(config.path);
  ManagedCatalogSnapshot absent() =>
      ManagedCatalogSnapshot(ManagedIdentityCatalog([]), 0);
  rx.listen((dynamic message) {
    if (message is! _Req) return;
    if (closing && message is! _CloseReq) {
      message.reply.send(
        const _ManagedWorkerErr(ManagedWorkerFailureKind.closed),
      );
      return;
    }
    try {
      switch (message) {
        case _CatalogSnapshotReq():
          final owner = current();
          message.reply.send(
            _Ok((
              exists: owner != null,
              snapshot: owner?.snapshot() ?? absent(),
            )),
          );
        case _CatalogSelectReq(:final entry):
          final owner = current();
          if (owner == null && entry != null) {
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
          }
          message.reply.send(_Ok(owner?.select(entry) ?? absent()));
        case _CloseReq():
          closing = true;
          release.close();
          message.reply.send(const _Ok(null));
          rx.close();
          Isolate.current.kill(priority: Isolate.immediate);
        default:
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
      }
    } catch (error) {
      message.reply.send(_workerErrorReply(error, managed: true));
    }
  });
  config.reply.send(_Ok(rx.sendPort));
}
