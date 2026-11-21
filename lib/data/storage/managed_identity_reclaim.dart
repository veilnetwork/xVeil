part of 'managed_directory_catalog.dart';

enum ManagedReclaimStage {
  contentDetached,
  contentPrepared,
  contentPublished,
  maintenancePrepared,
  maintenancePublished,
}

Uint8List get _repackSourceKey =>
    Uint8List.fromList([0x78, 0x56, 0x72, 0x70, 1]);

typedef ManagedReclaimObserver =
    Future<void> Function(ManagedReclaimStage stage);

extension _ManagedIdentityReclamation on _ManagedIdentityResources {
  int _payloadBytes() =>
      File(file('keybox.hv')).lengthSync() +
      File(file('content.hv')).lengthSync() +
      File(file('maintenance.hv')).lengthSync();

  void _reclaimLease() {
    validatePaths();
    lease!.requireHeld();
    owner._fs.requirePrivateFile(file('keybox.hv'));
    owner._fs.requirePrivateFile(file('content.hv'));
    owner._fs.requirePrivateFile(file('maintenance.hv'));
  }

  Future<ManagedReclaimReport> reclaim({
    required bool force,
    ManagedReclaimObserver? observer,
  }) async {
    try {
      requireOwned();
      if (entry.protection == StorageProtection.unencrypted) {
        // SQLite FULL auto-vacuum already reclaims at commit. Never invoke an
        // encrypted compactor or ask for a password on the plaintext branch.
        validatePaths();
        owner._fs.requirePrivateFile(file('data.store'));
        final bytes = File(file('data.store')).lengthSync();
        return ManagedReclaimReport(
          beforeBytes: bytes,
          afterBytes: bytes,
          contentRepacked: false,
          maintenanceRepacked: false,
        );
      }
      _reclaimLease();
      final before = _payloadBytes();
      final budget = ManagedReclaimBudget.read(maintenance!);
      final contentDue = budget.contentDue(
        File(file('content.hv')).lengthSync(),
        content!.slotUtilization()?.ownedChunks,
        force: force,
      );
      var maintenanceDue = budget.maintenanceDue(
        File(file('maintenance.hv')).lengthSync(),
        force: force,
      );
      if (!contentDue && !maintenanceDue) {
        return ManagedReclaimReport(
          beforeBytes: before,
          afterBytes: before,
          contentRepacked: false,
          maintenanceRepacked: false,
        );
      }
      reclaiming = true;
      try {
        if (contentDue) await _repackContent(observer);
        maintenanceDue =
            maintenanceDue ||
            budget.maintenanceDue(File(file('maintenance.hv')).lengthSync());
        if (maintenanceDue) await _repackMaintenance(observer);
        final next = ManagedReclaimBudget(
          contentBytes: contentDue
              ? File(file('content.hv')).lengthSync()
              : budget.contentBytes,
          contentOwned: contentDue
              ? (content!.slotUtilization()?.ownedChunks ?? 0)
              : budget.contentOwned,
          maintenanceBytes: maintenanceDue
              ? File(file('maintenance.hv')).lengthSync()
              : budget.maintenanceBytes,
        );
        next.write(maintenance!);
        return ManagedReclaimReport(
          beforeBytes: before,
          afterBytes: _payloadBytes(),
          contentRepacked: contentDue,
          maintenanceRepacked: maintenanceDue,
        );
      } finally {
        reclaiming = false;
      }
    } catch (error, trace) {
      return ManagedIdentityFiles._safe<ManagedReclaimReport>(
        () => Error.throwWithStackTrace(error, trace),
      );
    }
  }

  ManagedRepackTransfer _detachReclaimPayloads() {
    final result = (backend! as ManagedEncryptedKvLogStore)
        .releasePayloadsForRepack();
    backend = null;
    content = null;
    maintenance = null;
    if (!identical(result.keybox, keybox)) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.backend);
    }
    return result;
  }

  void _reattachReclaimPayloads(
    ManagedRepackTransfer transfer, {
    bool contentMayAdvance = false,
  }) {
    // Do not discard a failed-close owner. Fields are cleared only after that
    // handle confirms release, and identity/keybox leases remain held.
    reclaimStaged?.close();
    reclaimStaged = null;
    content?.close();
    content = null;
    maintenance?.close();
    maintenance = null;
    _reclaimLease();
    _openInner(); // validates role and durably settles PREPARED before exposure
    try {
      final attached = backend! as ManagedEncryptedKvLogStore;
      final current = attached.commitSeq();
      final source = transfer.source;
      if ((current != source.sequence &&
              !(contentMayAdvance &&
                  current > source.sequence &&
                  current - source.sequence == 1)) ||
          attached.commitRoots()[source.sequence] !=
              source.roots[source.sequence]) {
        throw const ManagedIdentityFailure(ManagedIdentityFailureKind.backend);
      }
    } catch (_) {
      // Never expose an authenticated BUT older replacement after a refused
      // copy. Raw owned handles remain tracked if their close itself fails.
      final rejected = backend;
      try {
        rejected?.close();
      } finally {
        backend = null;
      }
      rethrow;
    }
  }

  HvKvLogStore _openReclaimStaged(String stagedPath, Uint8List password) {
    _reclaimLease();
    if (File(stagedPath).parent.absolute.path !=
        Directory(path!).absolute.path) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final before = owner._fs.requirePrivateNativeOutput(stagedPath);
    final space = hv.HvSpace.open(path: stagedPath, password: password);
    final opened = HvKvLogStore(space);
    reclaimStaged = opened;
    try {
      space.cancelDeferredVacuum();
      space.setPaddingPolicy(hv.PaddingPreset.none);
      _reclaimLease();
      ManagedDirectoryCatalog._assertSame(stagedPath, before, owner._fs);
      return opened;
    } catch (_) {
      opened.close();
      reclaimStaged = null;
      rethrow;
    }
  }

  Future<void> _repackContent(ManagedReclaimObserver? observer) async {
    final random = Random.secure();
    final seal = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    // This fresh native transaction binds the CURRENT authenticated data to a
    // value no older source image contains. Comparing only a role/generation
    // would let a replayed file be copied under a new logical checkpoint.
    content!.commit([PutOp(ManagedStoreTag.namespace, _repackSourceKey, seal)]);
    final transfer = _detachReclaimPayloads();
    final password = keybox!.copyContentPassword();
    final maintenancePassword = keybox!.copyMaintenancePassword();
    try {
      try {
        await observer?.call(ManagedReclaimStage.contentDetached);
        maintenance = _native('maintenance.hv', password: maintenancePassword);
        await hv.compactKnownPreparedAsync(
          file('content.hv'),
          [password],
          dylibPath: envLibPath('XVEIL_HV_DYLIB'),
          repairMetadata: (stagedPath) async {
            final staged = _openReclaimStaged(stagedPath, password);
            try {
              final previous = ManagedStoreTag.read(
                staged,
                identity: entry.id,
                role: ManagedStoreRole.content,
              );
              if (previous.generation != transfer.state.active.marker ||
                  !_ManagedIdentityResources._equal(
                    staged.get(ManagedStoreTag.namespace, _repackSourceKey) ??
                        Uint8List(0),
                    seal,
                  )) {
                throw const ManagedIdentityFailure(
                  ManagedIdentityFailureKind.backend,
                );
              }
              final marker = ManagedGeneration.fresh(
                innerFloor: 1,
                offset: 0,
              ).marker;
              staged.commit([
                ManagedStoreTag(
                  identity: entry.id,
                  role: ManagedStoreRole.content,
                  generation: marker,
                ).putOp(),
              ]);
              final floor = staged.commitSeq();
              final prepared = transfer.state.prepare(
                source: transfer.source,
                replacement: ManagedGeneration(
                  marker: marker,
                  innerFloor: floor,
                  offset: transfer.source.sequence + 1 - floor,
                ),
              );
              ManagedMetadataBlob(maintenance!).write(prepared.encode());
            } finally {
              staged.close();
              reclaimStaged = null;
            }
            await observer?.call(ManagedReclaimStage.contentPrepared);
            _reclaimLease();
          },
        );
        await observer?.call(ManagedReclaimStage.contentPublished);
      } finally {
        _reattachReclaimPayloads(transfer, contentMayAdvance: true);
      }
    } finally {
      seal.fillRange(0, seal.length, 0);
      password.fillRange(0, password.length, 0);
      maintenancePassword.fillRange(0, maintenancePassword.length, 0);
    }
  }

  Future<void> _repackMaintenance(ManagedReclaimObserver? observer) async {
    final transfer = _detachReclaimPayloads();
    final password = keybox!.copyMaintenancePassword();
    Uint8List? expected;
    try {
      try {
        maintenance = _native('maintenance.hv', password: password);
        expected = ManagedMetadataBlob(maintenance!).read();
        final expectedBudget = ManagedReclaimBudget.read(maintenance!).encode();
        maintenance!.close();
        maintenance = null;
        await hv.compactKnownPreparedAsync(
          file('maintenance.hv'),
          [password],
          dylibPath: envLibPath('XVEIL_HV_DYLIB'),
          repairMetadata: (stagedPath) async {
            final staged = _openReclaimStaged(stagedPath, password);
            try {
              ManagedStoreTag.read(
                staged,
                identity: entry.id,
                role: ManagedStoreRole.maintenance,
              );
              if (!_ManagedIdentityResources._equal(
                    ManagedMetadataBlob(staged).read(),
                    expected!,
                  ) ||
                  !_ManagedIdentityResources._equal(
                    ManagedReclaimBudget.read(staged).encode(),
                    expectedBudget,
                  )) {
                throw const ManagedIdentityFailure(
                  ManagedIdentityFailureKind.backend,
                );
              }
            } finally {
              staged.close();
              reclaimStaged = null;
            }
            await observer?.call(ManagedReclaimStage.maintenancePrepared);
            _reclaimLease();
          },
        );
        await observer?.call(ManagedReclaimStage.maintenancePublished);
      } finally {
        _reattachReclaimPayloads(transfer);
      }
    } finally {
      password.fillRange(0, password.length, 0);
      expected?.fillRange(0, expected.length, 0);
    }
  }
}
