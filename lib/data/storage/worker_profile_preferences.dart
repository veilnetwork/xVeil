part of 'async_kv_log_store.dart';

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
  const _PreferencesWriteReq(this.contents, super.reply);
  final String contents;
}

/// Fixed-file I/O and its native shared profile grant live together. The UI
/// never receives a grant to do local filesystem work outside this actor.
final class ManagedProfilePreferencesFile implements ProfilePreferencesFile {
  ManagedProfilePreferencesFile._(this.path, this._worker);
  @override
  final String path;
  final WorkerKvLogStore _worker;
  static final _retiring = <ManagedProfilePreferencesFile>{};

  static Future<ManagedProfilePreferencesFile> open(String path) => _open(path);

  @visibleForTesting
  static Future<ManagedProfilePreferencesFile> openWithWriteGateForTesting(
    String path,
    SendPort gate,
  ) => _open(path, writeGate: gate);

  static Future<ManagedProfilePreferencesFile> _open(
    String path, {
    SendPort? writeGate,
  }) async {
    if (path.isEmpty ||
        path.contains('\x00') ||
        !File(path).isAbsolute ||
        File(path).uri.pathSegments.last != ProfilePreferencesLayout.file) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.invalid);
    }
    for (final old in _retiring.toList()) {
      if (old.path == path) await old.close();
    }
    final profile = ManagedWorkerIdentity._profileKey(
      '${File(path).parent.path}/visible-storage',
    );
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
      return ManagedProfilePreferencesFile._(path, worker);
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
  Future<void> close() async {
    _retiring.add(this);
    await _worker.close();
    _retiring.remove(this);
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

void _profilePreferencesEntry(_OpenProfilePreferences config) {
  StorageProfileCoordinator? gate;
  const fs = ManagedFsPlatform();
  late final String base;
  late final ManagedPathWitness baseWitness;
  late final File file;
  try {
    final suppliedBase = File(config.path).parent;
    suppliedBase.createSync(recursive: true);
    gate = StorageProfileCoordinator.forPreferences(suppliedBase.path);
    base = Directory(gate.profileDirectory).parent.path;
    baseWitness = fs.inspect(base);
    file = File.fromUri(
      Directory(base).uri.resolve(ProfilePreferencesLayout.file),
    );
  } catch (error) {
    try {
      gate?.close();
    } catch (_) {
      config.reply.send(
        _ManagedOpenFailed(
          _managedFailureKind(error),
          _serveManagedCleanup(() => gate?.close()),
        ),
      );
      return;
    }
    config.reply.send(_workerErrorReply(error, managed: true));
    return;
  }
  final owner = gate;
  void requireHeld() {
    owner.requireHeld();
    if (!baseWitness.sameObject(fs.inspect(base))) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  void requireFile() {
    requireHeld();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final witness = fs.inspect(file.path);
    if (witness.directory ||
        !witness.ownedByCurrentUser ||
        !witness.ownerOnly) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
  }

  final rx = ReceivePort();
  var closing = false;
  late final StreamSubscription<dynamic> subscription;
  subscription = rx.listen((dynamic message) {
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
          case _PreferencesReadReq():
            requireFile();
            final value = file.existsSync() ? file.readAsStringSync() : null;
            requireHeld();
            message.reply.send(_Ok(value));
          case _PreferencesWriteReq(:final contents):
            if (config.writeGate != null) {
              await _awaitManagedEraseAdmission(config.writeGate);
            }
            requireFile();
            final written = writePrivateFileAtomicallySync(file, contents);
            requireHeld();
            message.reply.send(_Ok(written));
          case _CloseReq():
            closing = true;
            owner.close();
            message.reply.send(const _Ok(null));
            rx.close();
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
  config.reply.send(_Ok(rx.sendPort));
}
