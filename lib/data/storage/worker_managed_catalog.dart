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

final class _CatalogRecoverReferencesReq extends _Req {
  const _CatalogRecoverReferencesReq(
    this.entry,
    this.password,
    this.keys,
    this.sourceName,
    super.reply,
  );
  final ManagedIdentityEntry entry;
  final Uint8List? password, keys;
  final String sourceName;
}

final class _CatalogEraseReq extends _Req {
  const _CatalogEraseReq(
    this.entry,
    this.password,
    this.keys,
    this.review,
    this.beforeErase,
    super.reply,
  );
  final ManagedIdentityEntry entry;
  final Uint8List? password, keys;
  final IdentityEraseReview? review;
  final SendPort? beforeErase;
}

final class _CatalogReviewEraseReq extends _Req {
  const _CatalogReviewEraseReq(this.entry, this.keys, super.reply);
  final ManagedIdentityEntry entry;
  final Uint8List keys;
}

/// Keep accepted UI work owned even if the worker dies before replying. This
/// port is not a second erasure authorization: the worker asks only after its
/// existing role/authentication/consent gates have passed.
final class _ManagedEraseAdmission {
  _ManagedEraseAdmission(this._action) {
    _subscription = _requests.listen((dynamic message) {
      if (message is! SendPort) return;
      if (_closing || _accepted != null) {
        message.send(false);
        return;
      }
      _accepted = () async {
        try {
          await _action();
          message.send(true);
        } catch (_) {
          message.send(false);
        }
      }();
    });
  }
  final Future<void> Function() _action;
  final ReceivePort _requests = ReceivePort();
  late final StreamSubscription<dynamic> _subscription;
  Future<void>? _accepted;
  bool _closing = false;
  SendPort get port => _requests.sendPort;
  Future<void> settleAndClose() async {
    _closing = true;
    try {
      await _accepted;
    } finally {
      await _subscription.cancel();
      _requests.close();
    }
  }
}

Future<void> _awaitManagedEraseAdmission(
  StorageWorkerInbox inbox,
  SendPort? port,
) async {
  if (port != null && !await inbox.requestAdmission(port)) {
    throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
  }
}

/// Off-UI profile owner. Enumeration/selection never opens identities or
/// creates an absent catalog. Explicit erasure authenticates only its selected
/// visible identity. No operation probes hidden credentials. The storage-worker
/// close protocol retains ownership across errors/timeouts.
final class ManagedCatalogWorker {
  ManagedCatalogWorker._(this._worker);
  final WorkerKvLogStore _worker;

  /// Reuse the production RPC/lifetime path with a disposable supervised
  /// worker. Native handles never cross this test-only constructor.
  @visibleForTesting
  static ManagedCatalogWorker overWorkerForTesting(WorkerKvLogStore worker) =>
      ManagedCatalogWorker._(worker);

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

  /// Only a selected, authenticated root is recovered. Other private journals
  /// and credentials remain untouched; no hidden-space inventory is returned.
  Future<LegacyReferenceRepairOutcome> recoverLegacyReferences(
    ManagedIdentityEntry entry, {
    Uint8List? password,
    Uint8List? keys,
    String sourceName = LegacyCompactionSource.defaultName,
  }) {
    LegacyCompactionSource.validateName(sourceName);
    final pass = password == null ? null : Uint8List.fromList(password);
    final key = keys == null ? null : Uint8List.fromList(keys);
    return _worker
        ._call<LegacyReferenceRepairOutcome>(
          (reply) =>
              _CatalogRecoverReferencesReq(entry, pass, key, sourceName, reply),
        )
        .whenComplete(() {
          pass?.fillRange(0, pass.length, 0);
          key?.fillRange(0, key.length, 0);
        });
  }

  Future<ManagedCatalogSnapshot> erase(
    ManagedIdentityEntry entry, {
    Uint8List? password,
    Uint8List? keys,
    IdentityEraseReview? review,
    Future<void> Function()? beforeErase,
  }) {
    final admission = beforeErase == null
        ? null
        : _ManagedEraseAdmission(beforeErase);
    final pass = password == null ? null : Uint8List.fromList(password);
    final key = keys == null ? null : Uint8List.fromList(keys);
    return _worker
        ._call<ManagedCatalogSnapshot>(
          (reply) => _CatalogEraseReq(
            entry,
            pass,
            key,
            review,
            admission?.port,
            reply,
          ),
        )
        .whenComplete(() async {
          try {
            await admission?.settleAndClose();
          } finally {
            pass?.fillRange(0, pass.length, 0);
            key?.fillRange(0, key.length, 0);
          }
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

void _managedCatalogEntry(
  _OpenManagedCatalog config,
  StorageWorkerInbox inbox,
) {
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
          _serveManagedCleanup(config, inbox, cleanup),
        ),
      );
      return;
    }
    config.reply.send(_workerErrorReply(error, managed: true));
    return;
  }
  var closing = false;
  // Root.close retries failed identity cleanup; the consuming catalog release
  // is separately guarded INSIDE that owner, not around the entire protocol.
  ManagedDirectoryCatalog? current() =>
      root ??= ManagedDirectoryCatalog.openExisting(config.path);
  ManagedCatalogSnapshot absent() =>
      ManagedCatalogSnapshot(ManagedIdentityCatalog([]), 0);
  Future<LegacyReferenceRepairOutcome> recoverReferences(
    _CatalogRecoverReferencesReq request,
  ) async {
    ManagedIdentityStore? store;
    Uint8List? keys;
    var released = false;
    try {
      LegacyCompactionSource.validateName(request.sourceName);
      final owner = current();
      if (owner == null) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
      }
      final entry = request.entry;
      if (!owner.snapshot().catalog.identities.any(
            (value) =>
                value.id == entry.id && value.protection == entry.protection,
          ) ||
          (request.password != null && request.keys != null)) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
      }
      store = request.keys != null
          ? ManagedIdentityFiles.openWithKeys(
              owner,
              id: entry.id,
              keys: request.keys!,
            )
          : entry.protection == StorageProtection.encrypted
          ? ManagedIdentityFiles.openWithPassword(
              owner,
              id: entry.id,
              password:
                  request.password ??
                  (throw const ManagedWorkerFailure(
                    ManagedWorkerFailureKind.authentication,
                  )),
            )
          : ManagedIdentityFiles.openUnencrypted(owner, id: entry.id);
      if (!ManagedLegacyReferenceRepair.hasPendingJournal(store)) {
        return LegacyReferenceRepairOutcome.none;
      }
      keys = store.exportKeys();
      store.close();
      store = null;
      owner.close();
      root = null;
      coordinator?.close();
      coordinator = null;
      released = true;
      root = ManagedDirectoryCatalog.openExclusiveMaintenance(config.path);
      if (root == null) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
      }
      return await ManagedLegacyReferenceRepair.resumeForIdentity(
        owner: root!,
        identity: entry.id,
        keys: keys,
        sourceName: request.sourceName,
      );
    } finally {
      try {
        store?.close();
      } finally {
        keys?.fillRange(0, keys.length, 0);
        if (released) {
          // Keep failed-close owners reachable for the normal close protocol.
          // Reopening uses existing roles only: a raced wipe is not creation.
          root?.close();
          root = null;
          coordinator = StorageProfileCoordinator.openExisting(config.path);
          if (coordinator == null) {
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
          }
          root = ManagedDirectoryCatalog.openExisting(config.path);
          if (root == null) {
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
          }
        }
      }
    }
  }

  late final StreamSubscription<dynamic> subscription;
  subscription = inbox.listen(_CloseReq(config.reply), (dynamic message) {
    if (message is! _Req) return;
    if (closing && message is! _CloseReq) {
      if (message is _CatalogEraseReq) {
        message.password?.fillRange(0, message.password!.length, 0);
        message.keys?.fillRange(0, message.keys!.length, 0);
      }
      if (message is _CatalogReviewEraseReq) {
        message.keys.fillRange(0, message.keys.length, 0);
      }
      if (message is _CatalogRecoverReferencesReq) {
        message.password?.fillRange(0, message.password!.length, 0);
        message.keys?.fillRange(0, message.keys!.length, 0);
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
        case _CatalogRecoverReferencesReq():
          subscription.pause();
          unawaited(() async {
            try {
              message.reply.send(_Ok(await recoverReferences(message)));
            } catch (error) {
              message.reply.send(_workerErrorReply(error, managed: true));
            } finally {
              message.password?.fillRange(0, message.password!.length, 0);
              message.keys?.fillRange(0, message.keys!.length, 0);
              subscription.resume();
            }
          }());
        case _CatalogEraseReq(
          :final entry,
          :final password,
          :final keys,
          :final review,
          :final beforeErase,
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
                  beforeErase: () =>
                      _awaitManagedEraseAdmission(inbox, beforeErase),
                );
              } else {
                await _awaitManagedEraseAdmission(inbox, beforeErase);
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
          inbox.close();
          Isolate.current.kill(priority: Isolate.immediate);
        default:
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
      }
    } catch (error) {
      message.reply.send(_workerErrorReply(error, managed: true));
    }
  });
  config.reply.send(_Ok(inbox.sendPort));
}
