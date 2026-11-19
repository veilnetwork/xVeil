part of 'async_kv_log_store.dart';

enum _ErasureOpen {
  prepare,
  prepareApplication,
  recoverApplicationRequest,
  recover,
  reconcile,
  reconcileApplicationJournal,
  resumeBound,
}

final class _OpenManagedErasure extends _OpenConfig {
  const _OpenManagedErasure({
    required super.path,
    required super.reply,
    required this.mode,
    this.profileNamespace,
    this.legacyPath,
    this.auxiliary,
    this.binding,
    this.applicationRequest,
    this.checkpoint,
    this.finishGateStage,
    this.failFinalSyncForTesting = false,
  }) : super(paddingPresetTag: 0);
  final _ErasureOpen mode;
  final String? profileNamespace, legacyPath;
  final ProfileErasureAuxiliaryTargets? auxiliary;
  final ManagedErasureBinding? binding;
  final ManagedProfileErasureRequest? applicationRequest;
  final SendPort? checkpoint;
  final ManagedErasureFinishStage? finishGateStage;
  final bool failFinalSyncForTesting;
}

final class _ErasureSnapshotReq extends _Req {
  const _ErasureSnapshotReq(super.reply);
}

final class _ErasureRetirementSnapshotReq extends _Req {
  const _ErasureRetirementSnapshotReq(super.reply);
}

final class _ErasurePersistWitnessReq extends _Req {
  const _ErasurePersistWitnessReq(this.encoded, super.reply);
  final String encoded;
}

final class _ErasureRemoveReq extends _Req {
  const _ErasureRemoveReq(this.admission, super.reply);
  final SendPort admission;
}

final class _ErasureFinishReq extends _Req {
  const _ErasureFinishReq(this.admission, super.reply);
  final SendPort admission;
}

final class _ErasureAuxiliaryReq extends _Req {
  const _ErasureAuxiliaryReq(this.admission, super.reply);
  final SendPort admission;
}

/// UI-side, live owner check. Immutable progress alone is NOT sufficient: a
/// retained old snapshot must never acquire fresh OS scopes after its erasure.
final class ManagedErasureScopeLease {
  ManagedErasureScopeLease._(this._owner);
  final ManagedErasureWorker _owner;
  ManagedErasureSnapshot get snapshot {
    if (_owner._closed || _owner._dead || _owner._scopeRetirementSealed) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.closed);
    }
    final snapshot = _owner._snapshot;
    if (snapshot == null) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.closed);
    }
    snapshot.unlockScopes; // Terminal recovery has no reconstructible roster.
    return snapshot;
  }
}

/// Owns off-UI filesystem work and accepted UI cleanup, including failure and
/// worker death. Explicit begin/recover/reconcile are never an inline fallback.
final class ManagedErasureWorker {
  ManagedErasureWorker._(this.profileDirectory, this._worker) {
    _worker._watch.future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _dead = true;
        _closed = true;
        (_retiring[profileDirectory] ??= {}).add(this);
      },
    );
  }
  final String profileDirectory;
  final WorkerKvLogStore _worker;

  /// Observed transport death, not a native-release or cleanup witness.
  bool get exitedUnexpectedly => _dead;
  ManagedErasureSnapshot? _snapshot;
  ManagedErasureRelease? _receipt;
  Future<ManagedErasureRelease>? _finishing;
  Future<void>? _closing;
  bool _closed = false, _dead = false, _superseded = false;
  bool _scopeRetirementSealed = false;
  final _accepted = <Future<void>>{};
  static final _retiring = <String, Set<ManagedErasureWorker>>{};

  static Future<ManagedErasureWorker> begin({
    required String profileDirectory,
    required String profileNamespace,
    required String legacyPath,
    ProfileErasureAuxiliaryTargets? auxiliary,
  }) => _open(
    profileDirectory,
    _ErasureOpen.prepare,
    profileNamespace: profileNamespace,
    legacyPath: legacyPath,
    auxiliary: auxiliary,
  );

  /// Called only after the enclosing application's shutdown/admission seal.
  /// The request survives an ambiguous initial reply; retry uses the distinct
  /// recovery entrypoint below, which can never publish a replacement intent.
  static Future<ManagedErasureWorker> beginApplicationProfile({
    required String profileDirectory,
    required String profileNamespace,
    required String legacyPath,
    required ManagedProfileErasureRequest request,
    ProfileErasureAuxiliaryTargets? auxiliary,
  }) => _open(
    profileDirectory,
    _ErasureOpen.prepareApplication,
    profileNamespace: profileNamespace,
    legacyPath: legacyPath,
    auxiliary:
        auxiliary ?? ProfileErasureAuxiliaryTargets(legacyPath: legacyPath),
    applicationRequest: request,
  );

  static Future<ManagedErasureWorker> recoverApplicationRequest(
    String profileDirectory,
    ManagedProfileErasureRequest request,
  ) => _open(
    profileDirectory,
    _ErasureOpen.recoverApplicationRequest,
    applicationRequest: request,
  );

  static Future<ManagedErasureWorker> recover(String profileDirectory) =>
      _open(profileDirectory, _ErasureOpen.recover);
  static Future<ManagedErasureWorker> reconcile(
    String profileDirectory,
    ManagedErasureBinding binding,
  ) => _open(profileDirectory, _ErasureOpen.reconcile, binding: binding);

  /// Cold read-only continuation after native plan/terminal removal. An
  /// application journal is required; this never manufactures mutation scopes.
  static Future<ManagedErasureWorker> reconcileApplicationJournal(
    String profileDirectory,
  ) => _open(profileDirectory, _ErasureOpen.reconcileApplicationJournal);

  @visibleForTesting
  static Future<ManagedErasureWorker>
  reconcileApplicationJournalWithReleaseGateForTesting(
    String profileDirectory,
    SendPort afterNativeRelease,
  ) => _open(
    profileDirectory,
    _ErasureOpen.reconcileApplicationJournal,
    checkpoint: afterNativeRelease,
  );

  /// Continue a retained live operation after observed worker death. Pending
  /// recovery must match its exact binding; an absent intent permits only
  /// read-only reconciliation under a new exclusive grant, never a new plan.
  static Future<ManagedErasureWorker> resumeBound(
    String profileDirectory,
    ManagedErasureBinding binding,
  ) => _open(profileDirectory, _ErasureOpen.resumeBound, binding: binding);

  @visibleForTesting
  static Future<ManagedErasureWorker> beginWithReleaseGateForTesting({
    required String profileDirectory,
    required String profileNamespace,
    required String legacyPath,
    required SendPort afterNativeRelease,
    ProfileErasureAuxiliaryTargets? auxiliary,
    ManagedProfileErasureRequest? applicationRequest,
  }) => _open(
    profileDirectory,
    applicationRequest == null
        ? _ErasureOpen.prepare
        : _ErasureOpen.prepareApplication,
    applicationRequest: applicationRequest,
    profileNamespace: profileNamespace,
    legacyPath: legacyPath,
    checkpoint: afterNativeRelease,
    auxiliary: auxiliary,
  );

  @visibleForTesting
  static Future<ManagedErasureWorker> beginWithFinishGateForTesting({
    required String profileDirectory,
    required String profileNamespace,
    required String legacyPath,
    required SendPort checkpoint,
    required ManagedErasureFinishStage stage,
    ProfileErasureAuxiliaryTargets? auxiliary,
    ManagedProfileErasureRequest? applicationRequest,
  }) => _open(
    profileDirectory,
    applicationRequest == null
        ? _ErasureOpen.prepare
        : _ErasureOpen.prepareApplication,
    applicationRequest: applicationRequest,
    profileNamespace: profileNamespace,
    legacyPath: legacyPath,
    checkpoint: checkpoint,
    finishGateStage: stage,
    auxiliary: auxiliary,
  );

  @visibleForTesting
  static Future<ManagedErasureWorker> beginWithFinalSyncFailureForTesting({
    required String profileDirectory,
    required String profileNamespace,
    required String legacyPath,
    ProfileErasureAuxiliaryTargets? auxiliary,
    ManagedProfileErasureRequest? applicationRequest,
  }) => _open(
    profileDirectory,
    applicationRequest == null
        ? _ErasureOpen.prepare
        : _ErasureOpen.prepareApplication,
    applicationRequest: applicationRequest,
    profileNamespace: profileNamespace,
    legacyPath: legacyPath,
    auxiliary: auxiliary,
    failFinalSyncForTesting: true,
  );

  @visibleForTesting
  static ManagedErasureWorker overWorkerForTesting(
    String profile,
    WorkerKvLogStore worker,
  ) => ManagedErasureWorker._(
    ManagedWorkerIdentity._profileKey(profile),
    worker,
  );
  @visibleForTesting
  void killReleasedWorkerForTesting() =>
      _worker._isolate.kill(priority: Isolate.immediate);
  @visibleForTesting
  static int get retiringCount =>
      _retiring.values.fold(0, (n, s) => n + s.length);

  static Future<ManagedErasureWorker> _open(
    String supplied,
    _ErasureOpen mode, {
    String? profileNamespace,
    String? legacyPath,
    ProfileErasureAuxiliaryTargets? auxiliary,
    ManagedErasureBinding? binding,
    ManagedProfileErasureRequest? applicationRequest,
    SendPort? checkpoint,
    ManagedErasureFinishStage? finishGateStage,
    bool failFinalSyncForTesting = false,
  }) async {
    try {
      if ((mode == _ErasureOpen.prepareApplication ||
              mode == _ErasureOpen.recoverApplicationRequest) &&
          applicationRequest == null) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
      }
      if (mode == _ErasureOpen.prepareApplication &&
          (auxiliary == null || !auxiliary.speech || !auxiliary.translation)) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
      }
      if (auxiliary != null && auxiliary.legacyPath != legacyPath) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
      }
      final profile = ManagedWorkerIdentity._profileKey(supplied);
      final dead = <ManagedErasureWorker>[];
      for (final old
          in _retiring[profile]?.toList() ?? <ManagedErasureWorker>[]) {
        await old._settleAccepted();
        if (old._dead) {
          // A new EXCLUSIVE native grant, not death alone, must permit recovery.
          // Keep this owner registered until that subsequent bootstrap succeeds.
          try {
            await old.close();
          } catch (_) {}
          dead.add(old);
        } else {
          await old.close();
        }
      }
      final raw = await ManagedWorkerIdentity._spawnOwned(
        profile,
        null,
        () => WorkerKvLogStore._spawn(
          (reply) => _OpenManagedErasure(
            path: profile,
            reply: reply,
            mode: mode,
            profileNamespace: profileNamespace,
            legacyPath: legacyPath,
            auxiliary: auxiliary,
            binding: binding,
            applicationRequest: applicationRequest,
            checkpoint: checkpoint,
            finishGateStage: finishGateStage,
            failFinalSyncForTesting: failFinalSyncForTesting,
          ),
        ),
      );
      if (raw == null) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
      }
      final result = ManagedErasureWorker._(profile, raw);
      try {
        result._snapshot = await result.snapshot();
        for (final old in dead) {
          old._superseded = true;
          _unregister(old);
        }
        return result;
      } catch (_) {
        try {
          await result.close();
        } catch (_) {}
        rethrow;
      }
    } on ManagedWorkerFailure {
      rethrow;
    } catch (_) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
    }
  }

  static void _unregister(ManagedErasureWorker owner) {
    final set = _retiring[owner.profileDirectory];
    set?.remove(owner);
    if (set?.isEmpty ?? false) _retiring.remove(owner.profileDirectory);
  }

  Future<T> _bounded<T>(Future<T> task) async {
    try {
      return await task;
    } on ManagedWorkerFailure {
      rethrow;
    } catch (_) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
    }
  }

  void _requireOpen() {
    if (_closed || _finishing != null) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.closed);
    }
  }

  Future<T> _track<T>(Future<T> task) {
    final settled = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _accepted.add(settled);
    settled.then((_) => _accepted.remove(settled));
    return task;
  }

  Future<void> _settleAccepted() => Future.wait(_accepted.toList());

  ManagedErasureScopeLease get scopeLease {
    _requireOpen();
    final lease = ManagedErasureScopeLease._(this);
    lease.snapshot;
    return lease;
  }

  Future<ManagedErasureSnapshot> snapshot() {
    _requireOpen();
    return _track(
      _bounded(
        _worker._call<ManagedErasureSnapshot>(
          (reply) => _ErasureSnapshotReq(reply),
        ),
      ).then((value) => _snapshot = value),
    );
  }

  Future<void> persistSavedEntryWitness(String encoded) {
    _requireOpen();
    scopeLease.snapshot; // Terminal progress cannot acquire this mutation.
    return _track(
      _bounded(
        _worker._call<ManagedErasureSnapshot>(
          (reply) => _ErasurePersistWitnessReq(encoded, reply),
        ),
      ).then((value) {
        _snapshot = value;
      }),
    );
  }

  Future<void> removeManagedFiles({
    required Future<void> Function() retireScopes,
  }) {
    _requireOpen();
    final admission = _ManagedEraseAdmission(retireScopes);
    return _track(
      _bounded(
        _worker._call<void>(
          (reply) => _ErasureRemoveReq(admission.port, reply),
        ),
      ).whenComplete(admission.settleAndClose),
    );
  }

  Future<void> removeAuxiliaryFiles({
    required Future<void> Function() retireScopes,
  }) {
    _requireOpen();
    final admission = _ManagedEraseAdmission(retireScopes);
    return _track(
      _bounded(
        _worker._call<void>(
          (reply) => _ErasureAuxiliaryReq(admission.port, reply),
        ),
      ).whenComplete(admission.settleAndClose),
    );
  }

  Future<ManagedErasureRelease> finish({
    required Future<void> Function() verifyOtherDataAbsent,
  }) {
    if (_receipt == null && _closed) {
      return Future.error(
        const ManagedWorkerFailure(ManagedWorkerFailureKind.closed),
      );
    }
    final pending = _finishing;
    if (pending != null) return pending;
    // Seal new admission immediately, but let previously accepted cleanup
    // finish under its original lease before entering the terminal phase.
    final earlier = _accepted.toList(growable: false);
    return _finishing = _track(
      () async {
        await Future.wait(earlier);
        // Never revive mutation from cached removing progress after an
        // ambiguous/failed terminal reply. Only a fresh native retirement
        // check of this exact operation can authorize continued removal.
        _scopeRetirementSealed = true;
        if (_receipt == null) {
          final admission = _ManagedEraseAdmission(verifyOtherDataAbsent);
          try {
            try {
              _receipt = await _bounded(
                _worker._call<ManagedErasureRelease>(
                  (reply) => _ErasureFinishReq(admission.port, reply),
                ),
              );
            } finally {
              await admission.settleAndClose();
            }
          } catch (error, trace) {
            try {
              final current = await _bounded(
                _worker._call<ManagedErasureSnapshot>(
                  (reply) => _ErasureRetirementSnapshotReq(reply),
                ),
              );
              if (_closed ||
                  _dead ||
                  _snapshot == null ||
                  !current.binding.sameOperation(_snapshot!.binding)) {
                throw const ManagedWorkerFailure(
                  ManagedWorkerFailureKind.closed,
                );
              }
              current.unlockScopes;
              _snapshot = current;
              _scopeRetirementSealed = false;
            } catch (_) {
              // An unavailable/terminal owner never reconstructs a roster or
              // turns a failed check into a new deletion grant.
            }
            Error.throwWithStackTrace(error, trace);
          }
        }
        // A receipt is not returned until the separate worker-close protocol
        // confirms success too. Retry joins a timed-out close instead of killing.
        _closed = true;
        await _closeRawOwned();
        return _receipt!;
      }().whenComplete(() => _finishing = null),
    );
  }

  Future<void> _closeRawOwned() async {
    if (_superseded) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.closed);
    }
    (_retiring[profileDirectory] ??= {}).add(this);
    await _bounded(_worker.close());
    _unregister(this);
  }

  Future<void> close() {
    if (_superseded) {
      return Future.error(
        const ManagedWorkerFailure(ManagedWorkerFailureKind.closed),
      );
    }
    _closed = true;
    (_retiring[profileDirectory] ??= {}).add(this);
    return _closing ??= () async {
      await _settleAccepted();
      await _closeRawOwned();
    }().whenComplete(() => _closing = null);
  }
}

/// Reachable only through the explicit test constructor, never environment or
/// application configuration. Real filesystem I/O with one failed final sync.
final class _ErasureFinalSyncFault extends ManagedFsPlatform {
  bool _published = false, _failed = false;
  @override
  bool publishFileNoReplace(String from, String to) {
    final published = super.publishFileNoReplace(from, to);
    if (to.endsWith('/${ManagedRootErasure.completionName}')) {
      _published = published;
    }
    return published;
  }

  @override
  void syncDirectory(String path) {
    if (_published &&
        !_failed &&
        !path.endsWith('/${ManagedRootErasure.pendingName}') &&
        !File('$path/${ManagedRootErasure.completionName}').existsSync() &&
        !Directory('$path/${ManagedRootErasure.pendingName}').existsSync()) {
      _failed = true;
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    super.syncDirectory(path);
  }
}

Future<void> _waitAtErasureCheckpoint(SendPort checkpoint) async {
  final proceed = ReceivePort();
  try {
    checkpoint.send(proceed.sendPort);
    await proceed.first;
  } finally {
    proceed.close();
  }
}

Future<void> _managedErasureEntry(
  _OpenManagedErasure config,
  StorageWorkerInbox inbox,
) async {
  ManagedDirectoryCatalog? root;
  StorageProfileCoordinator? gate;
  ManagedRootErasure? erasure;
  ManagedErasureReconciliation? reconciliation;
  void cleanup() {
    erasure?.close();
    reconciliation?.close();
    root?.close();
    gate?.close();
  }

  try {
    switch (config.mode) {
      case _ErasureOpen.prepare:
      case _ErasureOpen.prepareApplication:
        if (config.profileNamespace == null || config.legacyPath == null) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        final rootPath = File.fromUri(
          Directory(config.path).uri.resolve('identities'),
        ).path;
        if (FileSystemEntity.typeSync(rootPath, followLinks: false) ==
            FileSystemEntityType.notFound) {
          gate = StorageProfileCoordinator.createOrOpen(
            config.path,
            exclusive: true,
          );
          await ManagedRootErasure.prepareAbsent(
            gate,
            auxiliary: config.auxiliary,
            applicationRequest: config.applicationRequest,
            unlockScopes: StorageUnlockScopes.forProfile(
              profile: config.profileNamespace!,
              legacyPath: config.legacyPath!,
              managedPath: config.path,
              identities: const [],
            ),
          );
          gate.close();
          gate = null;
        } else {
          root = ManagedDirectoryCatalog.openExclusiveMaintenance(config.path);
          if (root == null) {
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
          }
          final catalog = root.snapshot().catalog;
          await ManagedRootErasure.prepare(
            root,
            auxiliary: config.auxiliary,
            applicationRequest: config.applicationRequest,
            unlockScopes: StorageUnlockScopes.forProfile(
              profile: config.profileNamespace!,
              legacyPath: config.legacyPath!,
              managedPath: config.path,
              identities: catalog.identities.map((e) => e.locator),
            ),
          );
          root.close();
          root = null;
        }
        erasure = ManagedRootErasure.openPending(
          config.path,
          fs: config.failFinalSyncForTesting
              ? _ErasureFinalSyncFault()
              : const ManagedFsPlatform(),
        );
      case _ErasureOpen.recoverApplicationRequest:
        erasure = ManagedRootErasure.openPending(config.path);
        if (!erasure.matchesApplicationRequest(config.applicationRequest!)) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
      case _ErasureOpen.recover:
        erasure = ManagedRootErasure.openPending(config.path);
      case _ErasureOpen.reconcile:
        reconciliation = ManagedErasureReconciliation.open(
          config.path,
          config.binding!,
        );
      case _ErasureOpen.reconcileApplicationJournal:
        reconciliation = ManagedErasureReconciliation.openApplicationJournal(
          config.path,
        );
      case _ErasureOpen.resumeBound:
        final binding = config.binding;
        if (binding == null) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        // This read chooses an opener, not admission. Both openers acquire
        // actual exclusive ownership and repeat their marker/tree checks.
        if (StorageProfileCoordinator.hasErasureIntent(
          config.path,
          includeApplicationJournal: false,
        )) {
          erasure = ManagedRootErasure.openPending(config.path);
          if (!erasure.binding.sameOperation(binding)) {
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
          }
        } else {
          reconciliation = ManagedErasureReconciliation.open(
            config.path,
            binding,
          );
        }
    }
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
  ManagedErasureRelease? released;
  late StreamSubscription<dynamic> subscription;
  subscription = inbox.listen(_CloseReq(config.reply), (dynamic message) {
    if (message is! _Req) return;
    if (closing && message is! _CloseReq) {
      message.reply.send(
        const _ManagedWorkerErr(ManagedWorkerFailureKind.closed),
      );
      return;
    }
    subscription.pause();
    unawaited(() async {
      try {
        switch (message) {
          case _ErasureSnapshotReq():
            message.reply.send(
              _Ok(erasure?.snapshot() ?? reconciliation!.snapshot()),
            );
          case _ErasureRetirementSnapshotReq():
            if (erasure == null) {
              throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
            }
            message.reply.send(_Ok(erasure.retirementSnapshot()));
          case _ErasurePersistWitnessReq(:final encoded):
            if (erasure == null) {
              throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
            }
            erasure.persistSavedEntryWitness(encoded);
            message.reply.send(_Ok(erasure.snapshot()));
          case _ErasureRemoveReq(:final admission):
            if (erasure == null) {
              throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
            }
            await erasure.removeManagedFiles(
              retireScopes: (_) => _awaitManagedEraseAdmission(admission),
            );
            message.reply.send(const _Ok(null));
          case _ErasureAuxiliaryReq(:final admission):
            if (erasure == null) {
              throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
            }
            await erasure.removeAuxiliaryFiles(
              retireScopes: () => _awaitManagedEraseAdmission(admission),
            );
            message.reply.send(const _Ok(null));
          case _ErasureFinishReq(:final admission):
            if (released == null) {
              if (erasure != null) {
                await erasure.finish(
                  verifyOtherDataAbsent: () =>
                      _awaitManagedEraseAdmission(admission),
                  afterStage: config.finishGateStage == null
                      ? null
                      : (stage) async {
                          if (stage == config.finishGateStage) {
                            await _waitAtErasureCheckpoint(config.checkpoint!);
                          }
                        },
                );
                released = erasure.releaseCompleted();
              } else {
                released = await reconciliation!.verifyAndRelease(
                  verifyOtherDataAbsent: () =>
                      _awaitManagedEraseAdmission(admission),
                );
              }
              final checkpoint = config.checkpoint;
              if (checkpoint != null && config.finishGateStage == null) {
                await _waitAtErasureCheckpoint(checkpoint);
              }
            }
            message.reply.send(_Ok(released));
          case _CloseReq():
            closing = true;
            final owner = erasure;
            if (owner?.finalSyncPending ?? false) {
              if (owner!.phase == ManagedRootErasurePhase.complete) {
                owner.releaseCompleted();
              } else {
                await owner.finish(
                  verifyOtherDataAbsent: () => Future.error(
                    const ManagedFsFailure(ManagedFsFailureKind.unsafe),
                  ),
                );
              }
            }
            cleanup();
            message.reply.send(const _Ok(null));
            inbox.close();
            Isolate.current.kill(priority: Isolate.immediate);
          default:
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
        }
      } catch (error) {
        message.reply.send(_workerErrorReply(error, managed: true));
      } finally {
        subscription.resume();
      }
    }());
  });
  config.reply.send(_Ok(inbox.sendPort));
}
