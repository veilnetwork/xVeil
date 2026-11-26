part of 'async_kv_log_store.dart';

/// Bounded diagnostics for failed native preference operations. Keep ordinal
/// values stable in exported reports. No native error text or paths.
enum ManagedPreferencesFailureReason {
  filesystemUnavailable,
  filesystemUnsafe,
  filesystemChanged,
  filesystemIo,
  missingCatalog,
  erasurePending,
  busy,
  invalidRole,
  sqlite,
  other,
  fileType,
  fileOwner,
  filePermissions,
  invalidProfilePath,
  windowsNonDrivePath,
  windowsPathAccessDenied,
  windowsPathOpenFailed,
  windowsPathInfoFailed,
  windowsReparsePoint,
  profileNotDirectory,
  profileOwner,
  unsafeAncestor,
  privateDirectory,
  privateFile,
  invalidLifetimeLock,
  filesystemAccessDenied,
  profileChoiceUnreadable,
  profileChoiceInvalid,
  preferencesAccessPolicy,
  preferencesStagingAccess,
}

ManagedPreferencesFailureReason managedStorageFailureReason(Object error) =>
    switch (error) {
      ManagedFsFailure(:final kind, :final unsafeReason) => switch (kind) {
        ManagedFsFailureKind.unavailable =>
          ManagedPreferencesFailureReason.filesystemUnavailable,
        ManagedFsFailureKind.unsafe => switch (unsafeReason) {
          ManagedFsUnsafeReason.invalidProfilePath =>
            ManagedPreferencesFailureReason.invalidProfilePath,
          ManagedFsUnsafeReason.windowsNonDrivePath =>
            ManagedPreferencesFailureReason.windowsNonDrivePath,
          ManagedFsUnsafeReason.windowsPathAccessDenied =>
            ManagedPreferencesFailureReason.windowsPathAccessDenied,
          ManagedFsUnsafeReason.windowsPathOpenFailed =>
            ManagedPreferencesFailureReason.windowsPathOpenFailed,
          ManagedFsUnsafeReason.windowsPathInfoFailed =>
            ManagedPreferencesFailureReason.windowsPathInfoFailed,
          ManagedFsUnsafeReason.windowsReparsePoint =>
            ManagedPreferencesFailureReason.windowsReparsePoint,
          ManagedFsUnsafeReason.profileNotDirectory =>
            ManagedPreferencesFailureReason.profileNotDirectory,
          ManagedFsUnsafeReason.profileOwner =>
            ManagedPreferencesFailureReason.profileOwner,
          ManagedFsUnsafeReason.unsafeAncestor =>
            ManagedPreferencesFailureReason.unsafeAncestor,
          ManagedFsUnsafeReason.privateDirectory =>
            ManagedPreferencesFailureReason.privateDirectory,
          ManagedFsUnsafeReason.privateFile =>
            ManagedPreferencesFailureReason.privateFile,
          ManagedFsUnsafeReason.invalidLifetimeLock =>
            ManagedPreferencesFailureReason.invalidLifetimeLock,
          ManagedFsUnsafeReason.preferencesAccessPolicy =>
            ManagedPreferencesFailureReason.preferencesAccessPolicy,
          ManagedFsUnsafeReason.preferencesStagingAccess =>
            ManagedPreferencesFailureReason.preferencesStagingAccess,
          null => ManagedPreferencesFailureReason.filesystemUnsafe,
        },
        ManagedFsFailureKind.changed =>
          ManagedPreferencesFailureReason.filesystemChanged,
        ManagedFsFailureKind.io => ManagedPreferencesFailureReason.filesystemIo,
        ManagedFsFailureKind.missingCatalog =>
          ManagedPreferencesFailureReason.missingCatalog,
        ManagedFsFailureKind.erasurePending =>
          ManagedPreferencesFailureReason.erasurePending,
      },
      ManagedLeaseFailure(kind: ManagedLeaseFailureKind.busy) ||
      ManagedSqliteFailure(
        sqliteCode: 5,
      ) => ManagedPreferencesFailureReason.busy,
      ManagedLeaseFailure() ||
      ManagedCatalogFailure() => ManagedPreferencesFailureReason.invalidRole,
      ManagedSqliteFailure() => ManagedPreferencesFailureReason.sqlite,
      FileSystemException() when isWindowsFileSharingViolation(error) =>
        ManagedPreferencesFailureReason.busy,
      FileSystemException(:final osError?)
          when Platform.isWindows
              ? osError.errorCode == 5
              : osError.errorCode == 1 || osError.errorCode == 13 =>
        ManagedPreferencesFailureReason.filesystemAccessDenied,
      FileSystemException() => ManagedPreferencesFailureReason.filesystemIo,
      _ => ManagedPreferencesFailureReason.other,
    };

final class _OpenProfilePreferences extends _OpenConfig {
  const _OpenProfilePreferences({
    required super.path,
    required super.reply,
    this.writeGate,
  }) : super(paddingPresetTag: 0);
  final SendPort? writeGate;
}

final class _PreferencesReadReq extends _Req {
  const _PreferencesReadReq(this.approvals, super.reply);
  final Set<String> approvals;
}

final class _PreferencesWriteReq extends _Req {
  const _PreferencesWriteReq(
    this.contents,
    this.approvals,
    super.reply, {
    this.requireMatch = false,
    this.expected,
  });
  final String contents;
  final Set<String> approvals;
  final bool requireMatch;
  final String? expected;
}

final class _PreferencesReleaseGrantReq extends _Req {
  const _PreferencesReleaseGrantReq(this.admission, super.reply);
  final SendPort admission;
}

/// Fixed-file I/O and its native shared profile grant live together. The UI
/// never receives a grant to do local filesystem work outside this actor.
final class ManagedProfilePreferencesFile implements ProfilePreferencesFile {
  ManagedProfilePreferencesFile._(
    this.path,
    this._profile,
    this._worker,
    this._onAclReplaced,
  );

  final Future<void> Function(StorageAclReplacement)? _onAclReplaced;
  @override
  final String path;
  final String _profile;
  final WorkerKvLogStore _worker;
  static final _retiring = <ManagedProfilePreferencesFile>{};
  static final _active = <String, Set<ManagedProfilePreferencesFile>>{};
  static final _opening =
      <String, Set<Future<ManagedProfilePreferencesFile>>>{};
  static final _maintenance = <String>{};

  /// Quiesce this isolate's preference actors for the exact profile. Foreign
  /// owners are still refused by native exclusive admission. File I/O and
  /// close stay behind each actor's accepted scope; callers must not perform
  /// preference I/O from [work] itself. New actors refuse during the scope:
  /// no delayed opener may recreate data after later erasure. This helper
  /// grants no filesystem authority; [work] still needs native admission.
  static Future<T> withProfileReleased<T>(
    String profileDirectory,
    Future<T> Function() work,
  ) async {
    if (profileDirectory.isEmpty ||
        profileDirectory.contains('\x00') ||
        !Directory(profileDirectory).isAbsolute) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
    }
    final profile = ManagedWorkerIdentity._profileKey(profileDirectory);
    if (!_maintenance.add(profile)) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
    }
    try {
      await Future.wait(
        _opening[profile]?.toList() ??
            const <Future<ManagedProfilePreferencesFile>>[],
      );
      final owners =
          _active[profile]?.toList() ?? const <ManagedProfilePreferencesFile>[];
      Future<T> release(int index) => index == owners.length
          ? work()
          : owners[index]._withReleasedGrant(() => release(index + 1));
      return await release(0);
    } finally {
      _maintenance.remove(profile);
    }
  }

  Future<T> _withReleasedGrant<T>(Future<T> Function() work) async {
    late T result;
    var completed = false;
    Object? actionError;
    StackTrace? actionStack;
    final admission = _ManagedEraseAdmission(() async {
      try {
        result = await work();
        completed = true;
      } catch (error, stack) {
        actionError = error;
        actionStack = stack;
        rethrow;
      }
    });
    try {
      await _worker._call<void>(
        (reply) => _PreferencesReleaseGrantReq(admission.port, reply),
      );
      if (!completed) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
      }
      return result;
    } catch (_) {
      if (actionError != null) {
        Error.throwWithStackTrace(actionError!, actionStack!);
      }
      rethrow;
    } finally {
      // Transport death does not cancel an already accepted catalog operation.
      await admission.settleAndClose();
    }
  }

  static Future<ManagedProfilePreferencesFile> open(
    String path, {
    Future<void> Function(StorageAclReplacement)? onAclReplaced,
  }) => _open(path, onAclReplaced: onAclReplaced);

  @visibleForTesting
  static Future<ManagedProfilePreferencesFile> openWithWriteGateForTesting(
    String path,
    SendPort gate,
  ) => _open(path, writeGate: gate);

  static Future<ManagedProfilePreferencesFile> _open(
    String path, {
    SendPort? writeGate,
    Future<void> Function(StorageAclReplacement)? onAclReplaced,
  }) {
    try {
      if (path.isEmpty ||
          path.contains('\x00') ||
          !File(path).isAbsolute ||
          File(path).uri.pathSegments.last != ProfilePreferencesLayout.file) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
      }
      final profile = ManagedWorkerIdentity._profileKey(
        '${File(path).parent.path}/visible-storage',
      );
      if (_maintenance.contains(profile)) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
      }
      final opening = _openOwned(
        path,
        profile,
        writeGate: writeGate,
        onAclReplaced: onAclReplaced,
      );
      (_opening[profile] ??= {}).add(opening);
      void settled() {
        _opening[profile]?.remove(opening);
        if (_opening[profile]?.isEmpty == true) _opening.remove(profile);
      }

      unawaited(
        opening.then<void>(
          (_) => settled(),
          onError: (Object _, StackTrace _) => settled(),
        ),
      );
      return opening;
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  static Future<ManagedProfilePreferencesFile> _openOwned(
    String path,
    String profile, {
    SendPort? writeGate,
    Future<void> Function(StorageAclReplacement)? onAclReplaced,
  }) async {
    for (final old in _retiring.toList()) {
      if (old.path == path) await old.close();
    }
    try {
      final worker = await ManagedWorkerIdentity._spawnOwned(
        profile,
        null,
        () => WorkerKvLogStore._spawn(
          (reply) => _OpenProfilePreferences(
            path: path,
            reply: reply,
            writeGate: writeGate,
          ),
        ),
      );
      if (worker == null) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.backend);
      }
      final file = ManagedProfilePreferencesFile._(
        path,
        profile,
        worker,
        onAclReplaced,
      );
      (_active[profile] ??= {}).add(file);
      return file;
    } catch (_) {
      // Classification only: the failed native opener is the actual admission
      // gate, and this hint can never authorize an ordinary write or recovery.
      var pending = false;
      try {
        pending = StorageProfileCoordinator.hasErasureIntent(profile);
      } catch (_) {}
      if (pending) throw const ProfilePreferencesErasurePending();
      rethrow;
    }
  }

  @override
  Future<String?> read() => _worker._call(
    (reply) => _PreferencesReadReq(storageAclApprovalsForWorker(), reply),
  );
  @override
  Future<bool> write(String contents) async => (await _write(contents))!;

  @override
  Future<bool?> compareAndWrite(String? expected, String contents) =>
      _write(contents, expected: expected, requireMatch: true);

  Future<bool?> _write(
    String contents, {
    String? expected,
    bool requireMatch = false,
  }) async {
    final (written, replacement) = await _worker
        ._call<(bool?, StorageAclReplacement?)>(
          (reply) => _PreferencesWriteReq(
            contents,
            storageAclApprovalsForWorker(),
            reply,
            expected: expected,
            requireMatch: requireMatch,
          ),
        );
    if (replacement != null) {
      carryStorageAclApproval(replacement);
      await _onAclReplaced?.call(replacement);
    }
    return written;
  }

  @override
  Future<void> close() async {
    _retiring.add(this);
    await _worker.close();
    _retiring.remove(this);
    _active[_profile]?.remove(this);
    if (_active[_profile]?.isEmpty == true) _active.remove(_profile);
  }
}

/// A managed container override must remain beside the installed preference
/// file. Otherwise a complete wipe would target a different profile's data.
void validateManagedPreferencesContainer(
  String preferencesPath,
  String? storeOverride,
) {
  if (storeOverride == null || storeOverride.isEmpty) return;
  final prefs = File.fromUri(
    File(preferencesPath).absolute.uri.normalizePath(),
  );
  final store = File.fromUri(File(storeOverride).absolute.uri.normalizePath());
  if (!File(storeOverride).isAbsolute ||
      prefs.parent.path != store.parent.path ||
      ProfilePreferencesLayout.files.contains(store.uri.pathSegments.last) ||
      store.uri.pathSegments.last == 'visible-storage') {
    throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
  }
}

void _profilePreferencesEntry(
  _OpenProfilePreferences config,
  StorageWorkerInbox inbox,
) {
  StorageProfileCoordinator? gate;
  const fs = ManagedFsPlatform();
  late final String base;
  late final ManagedPathWitness baseWitness;
  late final String profile, roleDirectory;
  late final ManagedPathWitness profileWitness, roleWitness;
  late final File file;
  try {
    final suppliedBase = File(config.path).parent;
    suppliedBase.createSync(recursive: true);
    gate = StorageProfileCoordinator.forPreferences(suppliedBase.path);
    profile = gate.profileDirectory;
    profileWitness = fs.inspect(profile);
    roleDirectory = gate.directory;
    roleWitness = fs.inspect(roleDirectory);
    base = Directory(gate.profileDirectory).parent.path;
    baseWitness = fs.inspect(base);
    file = File.fromUri(
      Directory(base).uri.resolve(ProfilePreferencesLayout.file),
    );
  } catch (error) {
    final reason = managedStorageFailureReason(error);
    final filesystem = error is ManagedFsFailure ? error : null;
    try {
      gate?.close();
    } catch (_) {
      config.reply.send(
        _ManagedOpenFailed(
          _managedFailureKind(error),
          _serveManagedCleanup(config, inbox, () => gate?.close()),
          preferencesOpenReason: reason,
          ancestorRefusal: filesystem?.ancestorRefusal,
          filesystemFailure: filesystem,
          aclWarnings: filesystem?.aclWarnings ?? const [],
        ),
      );
      return;
    }
    config.reply.send(
      _ManagedWorkerErr(
        _managedFailureKind(error),
        preferencesOpenReason: reason,
        ancestorRefusal: filesystem?.ancestorRefusal,
        filesystemFailure: filesystem,
        aclWarnings: filesystem?.aclWarnings ?? const [],
      ),
    );
    return;
  }
  void requireStablePath() {
    if (!baseWitness.sameObject(fs.inspect(base)) ||
        !profileWitness.sameObject(fs.inspect(profile)) ||
        !roleWitness.sameObject(fs.inspect(roleDirectory))) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  void requireHeld() {
    final owner = gate;
    if (owner == null) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.closed);
    }
    owner.requireHeld();
    requireStablePath();
  }

  ManagedPathWitness? inspectFile() {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    try {
      return fs.inspect(file.path);
    } on ManagedFsFailure catch (error) {
      if (error.aclWarnings.isEmpty) rethrow;
      var canSave = false;
      try {
        final acl = fs.inspectAcl(file.path);
        canSave = acl.ownedByCurrentUser && acl.otherUsersHaveReadOnlyAccess;
      } on ManagedFsFailure {
        // A policy that cannot be preserved still allows informed reading.
      }
      throw ManagedFsFailure(
        error.kind,
        unsafeReason: error.unsafeReason,
        path: file.path,
        aclWarnings: [
          for (final warning in error.aclWarnings)
            warning.withPolicy(readOnlyInApp: !canSave),
        ],
      );
    }
  }

  ManagedPreferencesFailureReason? fileFailure(ManagedPathWitness? witness) {
    if (witness == null) return null;
    if (witness.directory) return ManagedPreferencesFailureReason.fileType;
    if (witness.aclApproved) return null;
    if (!witness.ownedByCurrentUser) {
      return ManagedPreferencesFailureReason.fileOwner;
    }
    if (!witness.ownerOnly) {
      return ManagedPreferencesFailureReason.filePermissions;
    }
    return null;
  }

  String? readSnapshot(ManagedPathWitness? witness) {
    if (witness == null) return null;
    // File.readAsStringSync wraps a UTF-8 decoder error as a filesystem error.
    // Keep decoding separate so startup can report the format refusal.
    final bytes = file.readAsBytesSync();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const ProfilePreferencesFormatFailure(
        ProfilePreferencesFormatReason.invalidEncoding,
      );
    }
  }

  var closing = false;
  late final StreamSubscription<dynamic> subscription;
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
          case _PreferencesReleaseGrantReq(:final admission):
            requireHeld();
            gate!.close();
            gate = null;
            try {
              await _awaitManagedEraseAdmission(inbox, admission);
            } finally {
              requireStablePath();
              gate = StorageProfileCoordinator.openExisting(profile, fs: fs);
              requireHeld();
            }
            message.reply.send(const _Ok(null));
          case _PreferencesReadReq(:final approvals):
            mergeStorageAclApprovals(approvals);
            final elapsed = Stopwatch()..start();
            FileSystemException? contention;
            while (true) {
              requireHeld();
              final witness = inspectFile();
              final failure = fileFailure(witness);
              if (failure != null) {
                message.reply.send(
                  _ManagedWorkerErr(
                    ManagedWorkerFailureKind.invalid,
                    preferencesReadReason: failure,
                    aclWarnings: [
                      if (failure != ManagedPreferencesFailureReason.fileType)
                        ?witness?.aclWarning?.withPolicy(
                          readOnlyInApp:
                              !witness.otherUsersHaveReadOnlyAccess ||
                              !witness.ownedByCurrentUser,
                        ),
                    ],
                  ),
                );
                break;
              }
              // A previously busy file disappearing does not establish an
              // empty preference store. Keep the original refusal in that case.
              if (witness == null && contention != null) throw contention;
              try {
                final value = readSnapshot(witness);
                requireHeld();
                message.reply.send(_Ok(value));
                break;
              } on FileSystemException catch (error) {
                if (!isWindowsFileSharingViolation(error) ||
                    elapsed.elapsed >= const Duration(seconds: 1)) {
                  rethrow;
                }
                contention = error;
                // Antivirus or another process can temporarily deny sharing.
                // Retry with the same grant and freshly checked file witness.
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
            }
          case _PreferencesWriteReq(
            :final contents,
            :final approvals,
            :final requireMatch,
            :final expected,
          ):
            mergeStorageAclApprovals(approvals);
            if (config.writeGate != null) {
              await _awaitManagedEraseAdmission(inbox, config.writeGate);
            }
            requireHeld();
            StorageAclReplacement? replacement;
            final written = await withProfilePreferencesWriteLock<bool?>(
              file,
              () {
                requireHeld();
                final witness = inspectFile();
                final refusal = fileFailure(witness);
                if (refusal != null) {
                  throw ManagedWorkerFailure(
                    ManagedWorkerFailureKind.invalid,
                    preferencesWriteReason: refusal,
                    aclWarnings: [
                      if (refusal != ManagedPreferencesFailureReason.fileType)
                        ?witness?.aclWarning?.withPolicy(
                          canContinue:
                              witness.otherUsersHaveReadOnlyAccess &&
                              witness.ownedByCurrentUser,
                        ),
                    ],
                  );
                }
                if (requireMatch && readSnapshot(witness) != expected) {
                  return null;
                }
                return writePrivateFileAtomicallySync(
                  file,
                  contents,
                  reportFailure: true,
                  onAclReplaced: (receipt) => replacement = receipt,
                );
              },
            );
            requireHeld();
            message.reply.send(_Ok((written, replacement)));
          case _CloseReq():
            closing = true;
            gate?.close();
            message.reply.send(const _Ok(null));
            inbox.close();
            Isolate.current.kill(priority: Isolate.immediate);
          default:
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
        }
      } on ProfilePreferencesFormatFailure catch (error) {
        message.reply.send(error);
      } catch (error) {
        final filesystem = error is ManagedFsFailure ? error : null;
        message.reply.send(
          message is _PreferencesReadReq
              ? _ManagedWorkerErr(
                  isWindowsFileSharingViolation(error)
                      ? ManagedWorkerFailureKind.busy
                      : _managedFailureKind(error),
                  preferencesReadReason: managedStorageFailureReason(error),
                  ancestorRefusal: filesystem?.ancestorRefusal,
                  aclWarnings: filesystem?.aclWarnings ?? const [],
                )
              : message is _PreferencesWriteReq
              ? _ManagedWorkerErr(
                  _managedFailureKind(error),
                  preferencesWriteReason: error is ManagedWorkerFailure
                      ? error.preferencesWriteReason
                      : managedStorageFailureReason(error),
                  ancestorRefusal: filesystem?.ancestorRefusal,
                  aclWarnings: error is ManagedWorkerFailure
                      ? error.aclWarnings
                      : filesystem?.aclWarnings ?? const [],
                )
              : _workerErrorReply(error, managed: true),
        );
      } finally {
        subscription.resume();
      }
    }());
  });
  config.reply.send(_Ok(inbox.sendPort));
}
