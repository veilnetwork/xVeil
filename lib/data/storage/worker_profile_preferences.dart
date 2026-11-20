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
}

ManagedPreferencesFailureReason _preferencesFailureReason(Object error) =>
    switch (error) {
      ManagedFsFailure(:final kind) => switch (kind) {
        ManagedFsFailureKind.unavailable =>
          ManagedPreferencesFailureReason.filesystemUnavailable,
        ManagedFsFailureKind.unsafe =>
          ManagedPreferencesFailureReason.filesystemUnsafe,
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
  const _PreferencesReadReq(super.reply);
}

final class _PreferencesWriteReq extends _Req {
  const _PreferencesWriteReq(
    this.contents,
    super.reply, {
    this.requireMatch = false,
    this.expected,
  });
  final String contents;
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
  ManagedProfilePreferencesFile._(this.path, this._profile, this._worker);
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

  static Future<ManagedProfilePreferencesFile> open(String path) => _open(path);

  @visibleForTesting
  static Future<ManagedProfilePreferencesFile> openWithWriteGateForTesting(
    String path,
    SendPort gate,
  ) => _open(path, writeGate: gate);

  static Future<ManagedProfilePreferencesFile> _open(
    String path, {
    SendPort? writeGate,
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
      final opening = _openOwned(path, profile, writeGate: writeGate);
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
      final file = ManagedProfilePreferencesFile._(path, profile, worker);
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
  Future<String?> read() =>
      _worker._call((reply) => _PreferencesReadReq(reply));
  @override
  Future<bool> write(String contents) =>
      _worker._call((reply) => _PreferencesWriteReq(contents, reply));
  @override
  Future<bool?> compareAndWrite(String? expected, String contents) =>
      _worker._call(
        (reply) => _PreferencesWriteReq(
          contents,
          reply,
          expected: expected,
          requireMatch: true,
        ),
      );
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
    final reason = _preferencesFailureReason(error);
    try {
      gate?.close();
    } catch (_) {
      config.reply.send(
        _ManagedOpenFailed(
          _managedFailureKind(error),
          _serveManagedCleanup(config, inbox, () => gate?.close()),
          preferencesOpenReason: reason,
        ),
      );
      return;
    }
    config.reply.send(
      _ManagedWorkerErr(
        _managedFailureKind(error),
        preferencesOpenReason: reason,
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
    return fs.inspect(file.path);
  }

  ManagedPreferencesFailureReason? fileFailure(ManagedPathWitness? witness) {
    if (witness == null) return null;
    if (witness.directory) return ManagedPreferencesFailureReason.fileType;
    if (!witness.ownedByCurrentUser) {
      return ManagedPreferencesFailureReason.fileOwner;
    }
    if (!witness.ownerOnly) {
      return ManagedPreferencesFailureReason.filePermissions;
    }
    return null;
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
          case _PreferencesReadReq():
            final elapsed = Stopwatch()..start();
            FileSystemException? contention;
            while (true) {
              requireHeld();
              var witness = inspectFile();
              if (Platform.isWindows &&
                  witness != null &&
                  !witness.directory &&
                  witness.ownedByCurrentUser &&
                  !witness.ownerOnly &&
                  witness.otherUsersHaveReadOnlyAccess) {
                witness = windows.restrictLegacyPreferenceReadAccess(
                  file.path,
                  witness,
                );
                requireHeld();
              }
              final failure = fileFailure(witness);
              if (failure != null) {
                message.reply.send(
                  _ManagedWorkerErr(
                    ManagedWorkerFailureKind.invalid,
                    preferencesReadReason: failure,
                  ),
                );
                break;
              }
              // A previously busy file disappearing does not establish an
              // empty preference store. Keep the original refusal in that case.
              if (witness == null && contention != null) throw contention;
              try {
                final value = witness == null ? null : file.readAsStringSync();
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
            :final requireMatch,
            :final expected,
          ):
            if (config.writeGate != null) {
              await _awaitManagedEraseAdmission(inbox, config.writeGate);
            }
            requireHeld();
            final written = await withProfilePreferencesWriteLock<bool?>(
              file,
              () {
                requireHeld();
                final witness = inspectFile();
                if (fileFailure(witness) != null) {
                  throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
                }
                if (requireMatch &&
                    (witness == null ? null : file.readAsStringSync()) !=
                        expected) {
                  return null;
                }
                return writePrivateFileAtomicallySync(file, contents);
              },
            );
            requireHeld();
            message.reply.send(_Ok(written));
          case _CloseReq():
            closing = true;
            gate?.close();
            message.reply.send(const _Ok(null));
            inbox.close();
            Isolate.current.kill(priority: Isolate.immediate);
          default:
            throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
        }
      } catch (error) {
        message.reply.send(
          message is _PreferencesReadReq
              ? _ManagedWorkerErr(
                  isWindowsFileSharingViolation(error)
                      ? ManagedWorkerFailureKind.busy
                      : _managedFailureKind(error),
                  preferencesReadReason: _preferencesFailureReason(error),
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
