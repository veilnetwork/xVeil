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

final class _CatalogEraseReq extends _Req {
  const _CatalogEraseReq(
    this.entry,
    this.password,
    this.keys,
    this.review,
    super.reply,
  );
  final ManagedIdentityEntry entry;
  final Uint8List? password, keys;
  final IdentityEraseReview? review;
}

final class _CatalogReviewEraseReq extends _Req {
  const _CatalogReviewEraseReq(this.entry, this.keys, super.reply);
  final ManagedIdentityEntry entry;
  final Uint8List keys;
}

/// Off-UI profile owner. Enumeration/selection never opens identities or
/// creates an absent catalog. Explicit erasure authenticates only its selected
/// visible identity. No operation probes hidden credentials. The storage-worker
/// close protocol retains ownership across errors/timeouts.
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
  Future<ManagedCatalogSnapshot> erase(
    ManagedIdentityEntry entry, {
    Uint8List? password,
    Uint8List? keys,
    IdentityEraseReview? review,
  }) {
    final pass = password == null ? null : Uint8List.fromList(password);
    final key = keys == null ? null : Uint8List.fromList(keys);
    return _worker
        ._call<ManagedCatalogSnapshot>(
          (reply) => _CatalogEraseReq(entry, pass, key, review, reply),
        )
        .whenComplete(() {
          pass?.fillRange(0, pass.length, 0);
          key?.fillRange(0, key.length, 0);
        });
  }

  Future<IdentityEraseReview> reviewErasure(
    ManagedIdentityEntry entry,
    Uint8List keys,
  ) {
    final copy = Uint8List.fromList(keys);
    return _worker
        ._call<IdentityEraseReview>(
          (reply) => _CatalogReviewEraseReq(entry, copy, reply),
        )
        .whenComplete(() => copy.fillRange(0, copy.length, 0));
  }

  Future<void> close() => _worker.close();
}

void _managedCatalogEntry(_OpenManagedCatalog config) {
  ManagedDirectoryCatalog? root;
  StorageProfileCoordinator? coordinator;
  void cleanup() {
    root?.close();
    coordinator?.close();
  }

  try {
    coordinator = StorageProfileCoordinator.createOrOpen(config.path);
    root = ManagedDirectoryCatalog.openExisting(config.path);
  } catch (error) {
    try {
      cleanup();
    } catch (_) {
      config.reply.send(
        _ManagedOpenFailed(
          _managedFailureKind(error),
          _serveManagedCleanup(cleanup),
        ),
      );
      return;
    }
    config.reply.send(_workerErrorReply(error, managed: true));
    return;
  }
  final rx = ReceivePort();
  var closing = false;
  // Root.close retries failed identity cleanup; the consuming catalog release
  // is separately guarded INSIDE that owner, not around the entire protocol.
  ManagedDirectoryCatalog? current() =>
      root ??= ManagedDirectoryCatalog.openExisting(config.path);
  ManagedCatalogSnapshot absent() =>
      ManagedCatalogSnapshot(ManagedIdentityCatalog([]), 0);
  late final StreamSubscription<dynamic> subscription;
  subscription = rx.listen((dynamic message) {
    if (message is! _Req) return;
    if (closing && message is! _CloseReq) {
      if (message is _CatalogEraseReq) {
        message.password?.fillRange(0, message.password!.length, 0);
        message.keys?.fillRange(0, message.keys!.length, 0);
      }
      if (message is _CatalogReviewEraseReq) {
        message.keys.fillRange(0, message.keys.length, 0);
      }
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
        case _CatalogEraseReq(
          :final entry,
          :final password,
          :final keys,
          :final review,
        ):
          subscription.pause();
          unawaited(() async {
            try {
              final owner = current();
              if (owner == null && review != null) {
                throw const ManagedWorkerFailure(
                  ManagedWorkerFailureKind.missing,
                );
              }
              if (owner != null) {
                await ManagedIdentityFiles.erase(
                  owner,
                  entry: entry,
                  password: password,
                  keys: keys,
                  review: review,
                );
              }
              message.reply.send(_Ok(owner?.snapshot() ?? absent()));
            } catch (error) {
              message.reply.send(_workerErrorReply(error, managed: true));
            } finally {
              password?.fillRange(0, password.length, 0);
              keys?.fillRange(0, keys.length, 0);
              subscription.resume();
            }
          }());
        case _CatalogReviewEraseReq(:final entry, :final keys):
          subscription.pause();
          unawaited(() async {
            try {
              final owner = current();
              if (owner == null) {
                throw const ManagedWorkerFailure(
                  ManagedWorkerFailureKind.missing,
                );
              }
              message.reply.send(
                _Ok(
                  await ManagedIdentityFiles.reviewErasure(
                    owner,
                    entry: entry,
                    keys: keys,
                  ),
                ),
              );
            } catch (error) {
              message.reply.send(_workerErrorReply(error, managed: true));
            } finally {
              keys.fillRange(0, keys.length, 0);
              subscription.resume();
            }
          }());
        case _CloseReq():
          closing = true;
          cleanup();
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
