part of 'async_kv_log_store.dart';

typedef ManagedLegacyCompactionResult = ({
  int before,
  int after,
  LegacyReferenceRepairOutcome recovery,
});

/// Allowlisted native publication qualifiers; never carries native error text.
enum ManagedLegacyPublicationWarning {
  publishUncertain,
  durabilityUncertain,
  contentUnverified,
  aliasesNotRevoked,
  aliasesUnknown,
  aliasesAndDurabilityUncertain,
}

ManagedLegacyPublicationWarning? _legacyPublicationWarning(String kind) =>
    switch (kind) {
      'PublishUncertain' => ManagedLegacyPublicationWarning.publishUncertain,
      'RenameVisibleDurabilityUncertain' =>
        ManagedLegacyPublicationWarning.durabilityUncertain,
      'RenameVisibleContentUnverified' =>
        ManagedLegacyPublicationWarning.contentUnverified,
      'RenameVisibleAliasesNotRevoked' =>
        ManagedLegacyPublicationWarning.aliasesNotRevoked,
      'RenameVisibleAliasesUnknown' =>
        ManagedLegacyPublicationWarning.aliasesUnknown,
      'RenameVisibleAliasesAndDurabilityUncertain' =>
        ManagedLegacyPublicationWarning.aliasesAndDurabilityUncertain,
      _ => null,
    };

/// Bounded operation outcome, including a warning after visible publication.
final class ManagedLegacyCompactionFailure extends ManagedWorkerFailure {
  const ManagedLegacyCompactionFailure(
    super.kind, {
    required this.mayHaveApplied,
    required this.recovery,
    this.warning,
  });
  final bool mayHaveApplied;
  final LegacyReferenceRepairOutcome? recovery;
  final ManagedLegacyPublicationWarning? warning;
  @override
  String toString() =>
      'ManagedLegacyCompactionFailure(${kind.name}, $mayHaveApplied, ${recovery?.name}, ${warning?.name})';
}

final class _LegacyCompactionErr extends _Reply {
  const _LegacyCompactionErr(
    this.kind,
    this.mayHaveApplied,
    this.recovery,
    this.warning,
  );
  final ManagedWorkerFailureKind kind;
  final bool mayHaveApplied;
  final LegacyReferenceRepairOutcome? recovery;
  final ManagedLegacyPublicationWarning? warning;
}

final class _OpenManagedLegacyCompaction extends _OpenConfig {
  const _OpenManagedLegacyCompaction({
    required super.path,
    required super.reply,
    required this.authorizations,
    required this.credentials,
    required this.plaintextApproved,
    required this.sourceName,
    this.beforeReply,
  }) : super(paddingPresetTag: 0);
  final Map<ManagedIdentityId, Uint8List> authorizations;
  final List<CompactionCredential> credentials;
  final Set<ManagedIdentityId> plaintextApproved;
  final String sourceName;
  final SendPort? beforeReply;
}

final class _RunManagedLegacyCompactionReq extends _Req {
  const _RunManagedLegacyCompactionReq(this.publication, super.reply);
  final SendPort publication;
}

/// One-shot full-profile publisher. All native prepare/commit/abort steps run
/// synchronously on THIS worker, which retains exclusive catalog/profile roles.
/// Callers must first quiesce local identities, catalog and preference owners.
/// No timeout, lost reply or worker death is a native release witness.
final class ManagedLegacyCompactionWorker {
  ManagedLegacyCompactionWorker._(this._profile, this._worker);
  final String _profile;
  final WorkerKvLogStore _worker;
  bool _issued = false;
  static final _retiring = <String, Set<ManagedLegacyCompactionWorker>>{};

  /// Disposable supervised worker only; no native handles cross this seam.
  @visibleForTesting
  static ManagedLegacyCompactionWorker overWorkerForTesting(
    String profile,
    WorkerKvLogStore worker,
  ) => ManagedLegacyCompactionWorker._(profile, worker);

  static Future<ManagedLegacyCompactionWorker> open({
    required String profileDirectory,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    required List<CompactionCredential> credentials,
    required Set<ManagedIdentityId> plaintextApproved,
    String sourceName = LegacyCompactionSource.defaultName,
  }) => _open(
    profileDirectory: profileDirectory,
    authorizations: authorizations,
    credentials: credentials,
    plaintextApproved: plaintextApproved,
    sourceName: sourceName,
  );

  @visibleForTesting
  static Future<ManagedLegacyCompactionWorker> openWithReplyGateForTesting({
    required String profileDirectory,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    required List<CompactionCredential> credentials,
    required Set<ManagedIdentityId> plaintextApproved,
    required SendPort beforeReply,
    String sourceName = LegacyCompactionSource.defaultName,
  }) => _open(
    profileDirectory: profileDirectory,
    authorizations: authorizations,
    credentials: credentials,
    plaintextApproved: plaintextApproved,
    sourceName: sourceName,
    beforeReply: beforeReply,
  );

  static Future<ManagedLegacyCompactionWorker> _open({
    required String profileDirectory,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    required List<CompactionCredential> credentials,
    required Set<ManagedIdentityId> plaintextApproved,
    SendPort? beforeReply,
    required String sourceName,
  }) async {
    LegacyCompactionSource.validateName(sourceName);
    final profile = ManagedWorkerIdentity._profileKey(profileDirectory);
    final keys = <ManagedIdentityId, Uint8List>{};
    final copied = <CompactionCredential>[];
    try {
      if (credentials.isEmpty ||
          credentials.length > 512 ||
          authorizations.length > 512) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
      }
      for (final entry in authorizations.entries) {
        if (entry.value.length != 64) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        keys[entry.key] = Uint8List.fromList(entry.value);
      }
      for (final entry in credentials) {
        if (entry.password.isEmpty ||
            entry.oldSpaceKeys.length != 64 ||
            [
              ...entry.password,
              ...entry.oldSpaceKeys,
            ].any((b) => b < 0 || b > 255)) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        try {
          utf8.decode(entry.password);
        } on FormatException {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
        copied.add((
          password: Uint8List.fromList(entry.password),
          oldSpaceKeys: Uint8List.fromList(entry.oldSpaceKeys),
        ));
      }
      final approved = Set<ManagedIdentityId>.of(plaintextApproved);
      for (final old
          in _retiring[profile]?.toList() ??
              const <ManagedLegacyCompactionWorker>[]) {
        await old.close();
      }
      final worker = await ManagedWorkerIdentity._spawnOwned(
        profile,
        null,
        () => WorkerKvLogStore._spawn(
          (reply) => _OpenManagedLegacyCompaction(
            path: profile,
            reply: reply,
            authorizations: keys,
            credentials: copied,
            plaintextApproved: approved,
            sourceName: sourceName,
            beforeReply: beforeReply,
          ),
        ),
      );
      if (worker == null) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
      }
      return ManagedLegacyCompactionWorker._(profile, worker);
    } finally {
      _wipeLegacyCompactionCredentials(keys, copied);
    }
  }

  Future<ManagedLegacyCompactionResult> run({
    required Future<void> Function() beforePublication,
  }) async {
    if (_issued) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
    }
    _issued = true;
    Object? refusal;
    StackTrace? refusalStack;
    final admission = _ManagedEraseAdmission(() async {
      try {
        await beforePublication();
      } catch (error, stack) {
        refusal = error;
        refusalStack = stack;
        rethrow;
      }
    });
    try {
      return await _worker._call<ManagedLegacyCompactionResult>(
        (reply) => _RunManagedLegacyCompactionReq(admission.port, reply),
      );
    } catch (error) {
      if (refusal != null) Error.throwWithStackTrace(refusal!, refusalStack!);
      if (error is ManagedLegacyCompactionFailure) rethrow;
      // A supervised death/lost answer supplies no native publication witness.
      // Do not expose raw worker text or pretend this operation had no effect.
      throw ManagedLegacyCompactionFailure(
        _managedFailureKind(error),
        mayHaveApplied: true,
        recovery: null,
      );
    } finally {
      await admission.settleAndClose();
    }
  }

  Future<void> close() async {
    (_retiring[_profile] ??= {}).add(this);
    await _worker.close();
    _retiring[_profile]?.remove(this);
    if (_retiring[_profile]?.isEmpty == true) _retiring.remove(_profile);
  }
}

void _wipeLegacyCompactionCredentials(
  Map<ManagedIdentityId, Uint8List> keys,
  List<CompactionCredential> credentials,
) {
  for (final key in keys.values) {
    key.fillRange(0, key.length, 0);
  }
  for (final entry in credentials) {
    entry.password.fillRange(0, entry.password.length, 0);
    entry.oldSpaceKeys.fillRange(0, entry.oldSpaceKeys.length, 0);
  }
}

void _managedLegacyCompactionEntry(
  _OpenManagedLegacyCompaction config,
  StorageWorkerInbox inbox,
) {
  ManagedDirectoryCatalog? root;
  var poisoned = false;
  void close() {
    if (poisoned) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
    }
    root?.close();
    _wipeLegacyCompactionCredentials(config.authorizations, config.credentials);
  }

  try {
    LegacyCompactionSource.validateName(config.sourceName);
    if (Platform.isWindows) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
    }
    if (!ensureHiddenVolumeLoaded()) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
    }
    root = ManagedDirectoryCatalog.openExclusiveMaintenance(config.path);
    if (root == null) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
    }
    root.requireExclusiveMaintenance();
  } catch (error) {
    try {
      close();
    } catch (_) {
      config.reply.send(
        _ManagedOpenFailed(
          _managedFailureKind(error),
          _serveManagedCleanup(config, inbox, close),
        ),
      );
      return;
    }
    config.reply.send(_workerErrorReply(error, managed: true));
    return;
  }
  final owner = root;
  final revision = owner.snapshot().revision;
  void check() {
    if (owner.snapshot().revision != revision) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
    }
  }

  final source = File(
    LegacyCompactionSource.path(owner.profileDirectory, config.sourceName),
  );

  void checkInventory() {
    check();
    final entries = owner.snapshot().catalog.identities;
    final ids = entries.map((entry) => entry.id).toSet();
    final plaintext = entries
        .where((entry) => entry.protection == StorageProtection.unencrypted)
        .map((entry) => entry.id)
        .toSet();
    if (ids.length != config.authorizations.length ||
        !ids.containsAll(config.authorizations.keys) ||
        plaintext.length != config.plaintextApproved.length ||
        !plaintext.containsAll(config.plaintextApproved)) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.authentication);
    }
    final old = config.credentials
        .map((entry) => _legacyKeyTag(entry.oldSpaceKeys))
        .toSet();
    final passwords = config.credentials
        .map((entry) => _legacyKeyTag(entry.password))
        .toSet();
    if (old.length != config.credentials.length ||
        passwords.length != config.credentials.length) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
    }
  }

  Future<void> preflight() async {
    checkInventory();
    final entries = owner.snapshot().catalog.identities;
    final old = config.credentials
        .map((entry) => _legacyKeyTag(entry.oldSpaceKeys))
        .toSet();
    Future<void> rosterCovered(HiddenVolumeStorage storage) async {
      final rows = await storage.loadRosterForMaintenance();
      try {
        if ((rows ?? []).any(
          (entry) =>
              entry.storageLocator is LegacyStorageLocator &&
              !old.contains(_legacyKeyTag(entry.spaceKeys)),
        )) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
        }
      } finally {
        for (final row in rows ?? []) {
          row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
        }
      }
    }

    // Authenticate every visible root and its strict roster before native copy.
    for (final entry in entries) {
      final storage = HiddenVolumeStorage.fromStore(
        ManagedIdentityFiles.openWithKeys(
          owner,
          id: entry.id,
          keys: config.authorizations[entry.id]!,
        ),
      );
      try {
        await rosterCovered(storage);
      } finally {
        await storage.close();
      }
      check();
    }
    // No HVS open-time migration/vacuum is allowed on the original source.
    const ManagedFsPlatform().requirePrivateFile(source.path);
    for (final entry in config.credentials) {
      final store = HvKvLogStore(
        hv.HvSpace.open(
          path: source.path,
          password: entry.password as Uint8List,
        ),
      );
      final storage = HiddenVolumeStorage.fromStore(store);
      final actual = store.exportKeys();
      try {
        if (_legacyKeyTag(actual) != _legacyKeyTag(entry.oldSpaceKeys)) {
          throw const ManagedWorkerFailure(
            ManagedWorkerFailureKind.authentication,
          );
        }
        await rosterCovered(storage);
      } finally {
        actual.fillRange(0, actual.length, 0);
        await storage.close();
      }
      check();
    }
  }

  var publicationAttempted = false,
      publicationSucceeded = false,
      nativeMayHaveApplied = false;
  LegacyReferenceRepairOutcome? lastRecovery;
  ManagedLegacyPublicationWarning? publicationWarning;
  Future<ManagedLegacyCompactionResult> run(SendPort publication) async {
    checkInventory();
    await ManagedLegacyReferenceRepair.resume(
      owner: owner,
      authorizations: config.authorizations,
      sourceName: config.sourceName,
    );
    await preflight();
    final before = source.lengthSync();
    hv.HvPreparedCompaction? plan;
    final changes = <LegacyCompactionKeyChange>[];
    var externalStarted = false;
    var recovery = LegacyReferenceRepairOutcome.none;
    try {
      plan = hv.HvPreparedCompaction.prepare(source.path, [
        for (final entry in config.credentials) entry.password as Uint8List,
      ]);
      final staged = HiddenVolumeStorage(hvSpaceOpener(plan.stagedPath));
      try {
        Future<List<String>> repair() => remapCompactionRosters(
          staged,
          config.credentials,
          check: check,
          onMapped: (before, after) => changes.add((
            before: Uint8List.fromList(before),
            after: Uint8List.fromList(after),
          )),
        );
        var failed = await repair();
        if (failed.isNotEmpty) {
          for (final change in changes) {
            change.before.fillRange(0, change.before.length, 0);
            change.after.fillRange(0, change.after.length, 0);
          }
          changes.clear();
          failed = await repair();
        }
        if (failed.isNotEmpty) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
        }
      } finally {
        await staged.close();
      }
      check();
      externalStarted = true;
      await ManagedLegacyReferenceRepair.prepare(
        owner: owner,
        authorizations: config.authorizations,
        sourceName: config.sourceName,
        changes: changes,
      );
      await _awaitManagedEraseAdmission(publication);
      check();
      publicationAttempted = true;
      try {
        plan.commit();
        publicationSucceeded = true;
      } on hv.HvException catch (error) {
        nativeMayHaveApplied = error.mayHaveApplied;
        publicationWarning = _legacyPublicationWarning(error.kind);
        rethrow;
      }
    } finally {
      try {
        try {
          plan?.close();
        } catch (_) {
          poisoned = true;
          rethrow;
        }
        if (externalStarted) {
          recovery = await ManagedLegacyReferenceRepair.resume(
            owner: owner,
            authorizations: config.authorizations,
            sourceName: config.sourceName,
          );
          lastRecovery = recovery;
        }
      } finally {
        for (final change in changes) {
          change.before.fillRange(0, change.before.length, 0);
          change.after.fillRange(0, change.after.length, 0);
        }
      }
    }
    return (before: before, after: source.lengthSync(), recovery: recovery);
  }

  late final StreamSubscription<dynamic> subscription;
  var started = false, closing = false;
  subscription = inbox.listen(_CloseReq(config.reply), (dynamic message) {
    if (message is! _Req) return;
    subscription.pause();
    unawaited(() async {
      try {
        switch (message) {
          case _RunManagedLegacyCompactionReq(:final publication):
            if (started || closing) {
              throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
            }
            started = true;
            final result = await run(publication);
            if (config.beforeReply != null) {
              await _awaitManagedEraseAdmission(config.beforeReply);
            }
            message.reply.send(_Ok(result));
          case _CloseReq():
            closing = true;
            close();
            message.reply.send(const _Ok(null));
            inbox.close();
            Isolate.current.kill(priority: Isolate.immediate);
          default:
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
        }
      } catch (error) {
        if (message is _RunManagedLegacyCompactionReq) {
          message.reply.send(
            _LegacyCompactionErr(
              _managedFailureKind(error),
              publicationSucceeded ||
                  nativeMayHaveApplied ||
                  (publicationAttempted && lastRecovery == null),
              lastRecovery,
              publicationWarning,
            ),
          );
        } else {
          message.reply.send(_workerErrorReply(error, managed: true));
        }
      } finally {
        subscription.resume();
      }
    }());
  });
  config.reply.send(_Ok(inbox.sendPort));
}

String _legacyKeyTag(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
