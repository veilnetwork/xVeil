import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/log.dart';
import '../../core/posix_file_facts.dart';
import 'app_profile.dart';
import 'managed_fs_platform.dart';
import 'managed_fs_posix_acl.dart';
import 'storage_acl_approval.dart';
import 'managed_fs_windows.dart' as windows;
import 'managed_identity_lease.dart'
    show ManagedLeaseFailure, ManagedLeaseFailureKind, PosixSidecarLock;

/// A file owner, not permission to perform local I/O beside its native lease.
abstract interface class ProfilePreferencesFile {
  String get path;
  Future<String?> read();
  Future<bool> write(String contents);

  /// Null means another writer changed the file. False means a write refusal.
  Future<bool?> compareAndWrite(String? expected, String contents);
  Future<void> close();
}

typedef OpenProfilePreferencesFile =
    Future<ProfilePreferencesFile> Function(String path);

/// Stable diagnostic codes, independent of paths and preference contents.
enum ProfilePreferencesFormatReason {
  invalidJson,
  unsupportedVersion,
  invalidEntries,
  invalidEncoding,
}

final class ProfilePreferencesFormatFailure implements Exception {
  const ProfilePreferencesFormatFailure(this.reason);
  final ProfilePreferencesFormatReason reason;
}

/// Classifies a refused startup; it grants no recovery or deletion authority.
final class ProfilePreferencesErasurePending implements Exception {
  const ProfilePreferencesErasurePending();
  @override
  String toString() => 'ProfilePreferencesErasurePending';
}

/// New preference files and directories start at 0600 and 0700 respectively.
/// On replacement, preserve a verifiable access policy of the existing file.
///
/// These files are the app's SECURITY POSTURE in the clear — which profile is
/// active, the VPN routing policy with its app ids and subnets, whether the
/// switcher has been found. They must be readable before anything is unlocked,
/// so they cannot go inside the container; the least that can be asked of them
/// is that no other local account can read them (audit X-05).
const int _ownerOnlyDir = 0x1C0; // 0700

/// Whether a failure to make these files owner-only must fail the write.
///
/// The same split, for the same reason, as `runtimeDirMustBePrivate` in the
/// veil stack. On macOS and Linux the app-support path can sit on a filesystem
/// other local accounts share, so a posture file at a permissive umask is a
/// real exposure and writing it is worse than not writing it. On Android and
/// iOS the app sandbox is already the boundary, and on Windows access is
/// governed by a Windows DACL, applied and checked separately below. A POSIX
/// chmod cannot establish that boundary.
bool prefsFilesMustBePrivate() => Platform.isMacOS || Platform.isLinux;

/// New POSIX directories start private. Existing permissions belong to the
/// operator and must survive saving or migrating preferences.
void _ensurePrivateDir(Directory dir) {
  if (Platform.isWindows) {
    dir.createSync(recursive: true);
    return;
  }
  if (dir.existsSync()) return;
  _ensurePrivateDir(dir.parent);
  final rc = posixMkdir(dir.path, _ownerOnlyDir);
  if (rc == null && !prefsFilesMustBePrivate()) {
    dir.createSync(recursive: true);
  } else if (rc != 0 && !dir.existsSync()) {
    throw FileSystemException(
      'Could not create a private profile directory',
      dir.path,
    );
  }
}

bool _isPrivateFile(String path) {
  if (!Platform.isWindows && !prefsFilesMustBePrivate()) return true;
  final facts = const ManagedFsPlatform().inspectAcl(path);
  return !facts.directory && facts.ownedByCurrentUser && facts.ownerOnly;
}

const _cannotPreservePolicy = ManagedFsFailure(
  ManagedFsFailureKind.unsafe,
  unsafeReason: ManagedFsUnsafeReason.preferencesAccessPolicy,
);

/// Copy only a known, owner-controlled read-only sharing policy. Staging
/// starts private, and both objects are checked before and after publication.
class _PreferenceFileAccess {
  _PreferenceFileAccess(this.witness, this.posix, [this.acl = '']);
  final ManagedPathWitness? witness;
  final PosixFileFacts? posix;
  final String acl;

  static _PreferenceFileAccess capture(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound ||
        (!Platform.isWindows && !prefsFilesMustBePrivate())) {
      return _PreferenceFileAccess(null, null);
    }
    if (type != FileSystemEntityType.file) throw _cannotPreservePolicy;
    final facts = const ManagedFsPlatform().inspectAcl(file.path);
    if (!facts.ownedByCurrentUser || !facts.otherUsersHaveReadOnlyAccess) {
      throw ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        unsafeReason: ManagedFsUnsafeReason.preferencesAccessPolicy,
        path: file.path,
        aclWarnings: [
          if (facts.aclWarning case final warning?)
            warning.withPolicy(canContinue: false, readOnlyInApp: true),
        ],
      );
    }
    if (Platform.isWindows) {
      final acl = windows.readPreferenceDacl(file.path, facts);
      final verified = const ManagedFsPlatform().inspectAcl(file.path);
      if (verified.identity != facts.identity ||
          verified.aclWarning?.fingerprint != facts.aclWarning?.fingerprint) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      return _PreferenceFileAccess(facts, null, acl);
    }
    final posix = posixLstat(file.path);
    if (posix == null ||
        !posix.isRegularFile ||
        facts.identity != '${posix.deviceId}:${posix.inode}:${posix.uid}' ||
        !facts.otherUsersHaveReadOnlyAccess ||
        posix.permissions & 0xe00 != 0) {
      throw _cannotPreservePolicy;
    }
    final linuxAcl = Platform.isLinux ? readLinuxStorageAcl(file.path) : null;
    final acl = Platform.isMacOS
        ? readDarwinStorageAcl(file.path, posix)
        : linuxAcl == null
        ? null
        : base64Encode(linuxAcl);
    if (acl == null ||
        Platform.isMacOS &&
            facts.aclWarning != null &&
            acl != (facts.aclWarning!.extendedAcl ?? '')) {
      throw _cannotPreservePolicy;
    }
    return _PreferenceFileAccess(facts, posix, acl);
  }

  bool _samePolicy(_PreferenceFileAccess current) {
    final previous = posix;
    final actual = current.posix;
    if (previous == null) return actual == null && acl == current.acl;
    return actual != null &&
        actual.uid == previous.uid &&
        actual.permissions == previous.permissions &&
        (previous.permissions & 0x38 == 0 && acl.isEmpty ||
            actual.gid == previous.gid) &&
        acl == current.acl;
  }

  void _checkDestination(File destination) {
    final current = capture(destination);
    if (current.witness?.identity != witness?.identity ||
        current.witness?.aclWarning?.fingerprint !=
            witness?.aclWarning?.fingerprint ||
        !_samePolicy(current)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  _PreferenceFileAccess prepareReplacement(File destination, File temp) {
    _checkDestination(destination);
    final previous = posix;
    final staging = capture(temp);
    if (staging.witness?.ownerOnly == false) throw _cannotPreservePolicy;
    if (witness == null || _samePolicy(staging)) return staging;
    if (Platform.isWindows) {
      windows.writePreferenceDacl(temp.path, staging.witness!, acl);
    } else {
      final next = staging.posix;
      if (previous == null ||
          next == null ||
          next.uid != previous.uid ||
          ((previous.permissions & 0x38 != 0 || acl.isNotEmpty) &&
              next.gid != previous.gid) ||
          !posixSetModeForFile(
            temp.path,
            next,
            previous.permissions,
            applyAcl: acl == staging.acl
                ? null
                : (fd) => writePosixStorageAcl(fd, acl),
          )) {
        throw _cannotPreservePolicy;
      }
    }
    final ready = capture(temp);
    if (ready.witness?.identity != staging.witness?.identity ||
        !_samePolicy(ready)) {
      throw _cannotPreservePolicy;
    }
    return ready;
  }

  _PreferenceFileAccess writeWindowsReplacement(
    File destination,
    File temp,
    String contents,
  ) {
    final prepared = prepareReplacement(destination, temp);
    windows.writePreferencePayload(
      temp.path,
      prepared.witness!,
      prepared.acl,
      contents,
    );
    _checkDestination(destination);
    return prepared;
  }

  bool checkPublished(
    File file,
    _PreferenceFileAccess prepared,
    void Function(StorageAclReplacement)? onAclReplaced,
  ) {
    final result = capture(file);
    if (result.witness?.identity != prepared.witness?.identity ||
        !prepared._samePolicy(result)) {
      return false;
    }
    final before = witness?.aclWarning;
    final after = result.witness?.aclWarning;
    if (before != null && after != null && witness!.aclApproved) {
      final replacement = (
        before: before.fingerprint,
        after: after.fingerprint,
      );
      carryStorageAclApproval(replacement);
      onAclReplaced?.call(replacement);
    }
    return true;
  }
}

void _verifyPrivateTemporary(File file) {
  try {
    if (_isPrivateFile(file.path)) return;
  } on ManagedFsFailure catch (error) {
    if (error.aclWarnings.isEmpty) rethrow;
  }
  throw const ManagedFsFailure(
    ManagedFsFailureKind.unsafe,
    unsafeReason: ManagedFsUnsafeReason.preferencesStagingAccess,
  );
}

/// Never reuse an inherited-read temporary on Windows. Tightening its DACL
/// does not revoke a reader's existing handle, which could then read the next
/// payload. Remove only an owned stable leaf and reserve a fresh private file.
/// A reader denying deletion makes the write fail before any payload changes.
bool _prepareTemporary(File temp) {
  if (FileSystemEntity.typeSync(temp.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    final facts = const ManagedFsPlatform().inspect(temp.path);
    if (facts.directory || !facts.ownedByCurrentUser || !facts.safeAncestor) {
      return false;
    }
    temp.deleteSync();
  }
  if (Platform.isWindows) return windows.createPrivateFile(temp.path);
  PosixSidecarLock.reservePrivate(temp.path);
  return true;
}

/// Inspect the installation-wide choice before using its contents to select
/// storage. Only read-only ACLs on an owned regular file are reviewable.
ManagedPathWitness? _profileChoiceAccess(File file) {
  if (!Platform.isWindows && !prefsFilesMustBePrivate()) return null;
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) {
    throw ManagedFsFailure(
      ManagedFsFailureKind.unsafe,
      unsafeReason: ManagedFsUnsafeReason.privateFile,
      path: file.path,
    );
  }
  return const ManagedFsPlatform().requirePrivateFile(
    file.path,
    allowReadOnlyAclApproval: true,
  );
}

/// A read failure on an existing entry propagates so migration cannot replace
/// a choice it was unable to read.
Future<String?> readProfileChoice(
  File file, {
  bool requireValid = false,
}) async {
  RandomAccessFile? reader;
  try {
    // On Windows keep the sharing-violation code from the actual file open.
    // Merely opening for read does not consume the choice.
    if (Platform.isWindows &&
        FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
      reader = await file.open();
    }
    var before = _profileChoiceAccess(file);
    if (before == null && (Platform.isWindows || prefsFilesMustBePrivate())) {
      // Dart type queries can report notFound for a path whose parent denies
      // traversal. Keep the system's actual open error in that case.
      reader ??= await file.open();
      before = _profileChoiceAccess(file);
      if (before == null) {
        throw ManagedFsFailure(ManagedFsFailureKind.changed, path: file.path);
      }
    }
    final bytes = reader == null
        ? await file.readAsBytes()
        : await reader.read(await reader.length());
    final after = _profileChoiceAccess(file);
    if (before?.identity != after?.identity ||
        before?.aclWarning?.fingerprint != after?.aclWarning?.fingerprint) {
      throw ManagedFsFailure(ManagedFsFailureKind.changed, path: file.path);
    }
    final name = utf8.decode(bytes, allowMalformed: true).trim();
    if (AppProfiles.isValidName(name)) return name;
    if (requireValid) throw const ProfileChoiceReadFailure.malformed();
    return null;
  } on PathNotFoundException {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      rethrow;
    }
    return null;
  } finally {
    await reader?.close();
  }
}

/// Read the JSON used by the legacy desktop preference plugins during profile
/// selection. An existing file must contain a JSON object.
Future<Map<String, Object>> readDesktopLegacyPreferences(File file) async {
  final String contents;
  try {
    contents = await file.readAsString();
  } on PathNotFoundException {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      rethrow;
    }
    return const {};
  }
  final decoded = jsonDecode(contents);
  if (decoded is! Map<String, Object?> || decoded.containsValue(null)) {
    throw const FormatException('Invalid legacy desktop preference file');
  }
  return {
    for (final entry in decoded.entries)
      if (entry.key.startsWith('flutter.')) entry.key: entry.value!,
  };
}

/// A saved profile choice could not be read. The cause is safe for diagnostics.
final class ProfileChoiceReadFailure implements Exception {
  const ProfileChoiceReadFailure({required this.busy, this.fromLegacy = false})
    : malformed = false;
  const ProfileChoiceReadFailure.malformed({this.fromLegacy = false})
    : busy = false,
      malformed = true;

  final bool busy;
  final bool fromLegacy;
  final bool malformed;

  // Preserve the original 0–3 codes for read failures.
  int get diagnosticCode =>
      malformed ? 4 : (fromLegacy ? 2 : 0) + (busy ? 1 : 0);
}

bool isWindowsFileSharingViolation(Object error) =>
    Platform.isWindows &&
    error is FileSystemException &&
    (error.osError?.errorCode == 32 || error.osError?.errorCode == 33);

/// Retry a short Windows share denial. An absent result after contention
/// cannot establish that there was no saved choice.
Future<T> retryProfileChoiceRead<T>(
  Future<T> Function() read, {
  required bool Function(T value) isAbsent,
}) async {
  final elapsed = Stopwatch()..start();
  (FileSystemException, StackTrace)? contention;
  while (true) {
    final T value;
    try {
      value = await read();
    } on FileSystemException catch (error, stack) {
      if (!isWindowsFileSharingViolation(error) ||
          elapsed.elapsed >= const Duration(seconds: 1)) {
        rethrow;
      }
      contention = (error, stack);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      continue;
    }
    if (contention != null && isAbsent(value)) {
      Error.throwWithStackTrace(contention.$1, contention.$2);
    }
    return value;
  }
}

Future<String?> readStartupProfileChoice(
  File file, {
  bool requireValid = false,
}) async {
  try {
    return await retryProfileChoiceRead(
      () => readProfileChoice(file, requireValid: requireValid),
      isAbsent: (choice) => choice == null,
    );
  } on FileSystemException catch (error, stack) {
    Error.throwWithStackTrace(
      ProfileChoiceReadFailure(busy: isWindowsFileSharingViolation(error)),
      stack,
    );
  }
}

/// Save the installation-wide profile choice shared by separate app processes.
/// The empty lock file stays in place so every writer locks the same object.
Future<bool> writeProfileChoiceAtomically(
  File file,
  String contents, {
  bool onlyIfUnset = false,
  void Function(Object)? onFailure,
  Future<void> Function(StorageAclReplacement)? onAclReplaced,
}) async {
  RandomAccessFile? lock;
  try {
    _ensurePrivateDir(file.parent);
    final lockFile = File('${file.path}.lock');
    if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      if (Platform.isWindows) {
        windows.createPrivateFile(lockFile.path);
      } else {
        PosixSidecarLock.reservePrivate(lockFile.path);
      }
    }
    if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        lockFile.lengthSync() != 0) {
      return false;
    }
    _verifyPrivateTemporary(lockFile);

    lock = await lockFile.open(mode: FileMode.append);
    final elapsed = Stopwatch()..start();
    while (true) {
      try {
        await lock.lock();
        break;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        // EAGAIN differs between Darwin and Linux.
        final tryAgain = Platform.isMacOS || Platform.isIOS ? 35 : 11;
        final busy = Platform.isWindows
            ? code == 33
            : code == 13 || code == tryAgain;
        if (!busy || elapsed.elapsed >= const Duration(seconds: 2)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    // Migration may have resolved the old choice before another process saved
    // a new one. Read again while holding the same lock used by manual saves.
    if (onlyIfUnset &&
        await readProfileChoice(file, requireValid: true) != null) {
      return true;
    }
    final expected = _profileChoiceAccess(file);
    StorageAclReplacement? replacement;
    final written = await writePrivateFileAtomically(
      file,
      contents,
      onFailure: onFailure,
      expectedAccess: expected,
      requireExpectedAccess: Platform.isWindows || prefsFilesMustBePrivate(),
      onAclReplaced: (value) => replacement = value,
    );
    if (written && replacement != null) await onAclReplaced?.call(replacement!);
    return written;
  } catch (error) {
    onFailure?.call(error);
    devLog(() => 'xVeil[prefs]: could not save the profile choice: $error');
    return false;
  } finally {
    try {
      await lock?.close();
    } catch (error) {
      devLog(
        () => 'xVeil[prefs]: could not close the profile choice lock: $error',
      );
    }
  }
}

/// All preference writers use an empty, stable lock beside the replaced file.
/// On POSIX flock also excludes other isolates of this process.
Future<T> withProfilePreferencesWriteLock<T>(
  File file,
  FutureOr<T> Function() work,
) async {
  _ensurePrivateDir(file.parent);
  final sidecar = File('${file.path}.lock');
  if (FileSystemEntity.typeSync(sidecar.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    if (Platform.isWindows) {
      windows.createPrivateFile(sidecar.path);
    } else {
      PosixSidecarLock.reservePrivate(sidecar.path);
    }
  }
  const fs = ManagedFsPlatform();
  final original = fs.inspect(sidecar.path);
  if (original.directory ||
      !original.ownedByCurrentUser ||
      sidecar.lengthSync() != 0 ||
      !original.ownerOnly) {
    throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
  }

  final elapsed = Stopwatch()..start();
  RandomAccessFile? windowsLock;
  PosixSidecarLock? posixLock;
  try {
    while (true) {
      try {
        if (Platform.isWindows) {
          windowsLock ??= sidecar.openSync(mode: FileMode.append);
          windowsLock.lockSync();
        } else {
          posixLock = PosixSidecarLock.acquire(file.path)!;
        }
        break;
      } catch (error) {
        final busy = switch (error) {
          ManagedLeaseFailure(kind: ManagedLeaseFailureKind.busy) => true,
          FileSystemException(:final osError) when Platform.isWindows =>
            osError?.errorCode == 32 || osError?.errorCode == 33,
          _ => false,
        };
        if (!busy) rethrow;
        if (elapsed.elapsed >= const Duration(seconds: 2)) {
          throw const ManagedLeaseFailure(ManagedLeaseFailureKind.busy);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    if (!original.sameObject(fs.requirePrivateFile(sidecar.path))) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    return await work();
  } finally {
    windowsLock?.closeSync();
    posixLock?.close();
  }
}

Future<bool?> compareAndWritePrivatePreferences(
  File file,
  String? expected,
  String contents,
) async {
  try {
    return await withProfilePreferencesWriteLock<bool?>(file, () async {
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        return false;
      }
      final current = type == FileSystemEntityType.file
          ? await file.readAsString()
          : null;
      if (current != expected) return null;
      return writePrivateFileAtomically(file, contents);
    });
  } catch (error) {
    devLog(() => 'xVeil[prefs]: could not publish legacy preferences: $error');
    return false;
  }
}

/// Stage [contents] privately and replace [file] atomically with the verified
/// access policy. False means the save could not be confirmed.
///
/// The version this replaces caught every exception, logged it, and let its
/// callers report success (audit X-02); the migration then emptied the only
/// other copy of the data on the strength of that report. What it now
/// establishes before it says yes:
///
///   * **atomic** — the bytes land under a temporary name and are renamed over
///     the target, so a crash mid-write cannot leave a truncated file that the
///     next launch reads as "no preferences at all";
///   * **durable** — the file is fsynced before the rename and the DIRECTORY
///     after it. Syncing only the file makes the CONTENT survive a power cut
///     while the rename that gave it its name does not (audit X-02);
///   * **private** — the mode is applied to the temporary while it is still
///     empty, so the values never exist on disk at the process umask, not even
///     between two syscalls (audit X-05);
///   * **actually there** — the file is read back and compared. A filesystem
///     that accepted every call is not the same thing as a filesystem that
///     kept the result.
Future<bool> writePrivateFileAtomically(
  File file,
  String contents, {
  void Function(Object)? onFailure,
  ManagedPathWitness? expectedAccess,
  bool requireExpectedAccess = false,
  void Function(StorageAclReplacement)? onAclReplaced,
}) async {
  final temp = File('${file.path}.tmp');
  try {
    _ensurePrivateDir(file.parent);
    final access = _PreferenceFileAccess.capture(file);
    if (requireExpectedAccess &&
        (expectedAccess?.identity != access.witness?.identity ||
            expectedAccess?.aclWarning?.fingerprint !=
                access.witness?.aclWarning?.fingerprint)) {
      throw ManagedFsFailure(ManagedFsFailureKind.changed, path: file.path);
    }
    // Never write THROUGH a link someone else planted at the temporary name:
    // that is how a 0600 file ends up being somebody else's file, with our
    // posture in it. A directory in the way is not something to clear out.
    final planted = FileSystemEntity.typeSync(temp.path, followLinks: false);
    if (planted == FileSystemEntityType.link) {
      await Link(temp.path).delete();
    } else if (planted == FileSystemEntityType.directory) {
      devLog(() => 'xVeil[prefs]: ${temp.path} is a directory, refusing');
      return false;
    }

    if (!_prepareTemporary(temp)) return false;
    _verifyPrivateTemporary(temp);
    final _PreferenceFileAccess prepared;
    if (Platform.isWindows) {
      prepared = access.writeWindowsReplacement(file, temp, contents);
    } else {
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        _verifyPrivateTemporary(temp);
        await handle.writeString(contents);
        await handle.flush();
      } finally {
        await handle.close();
      }
      prepared = access.prepareReplacement(file, temp);
    }
    await temp.rename(file.path);
    // The rename itself, made durable. Null just means no libc binding here.
    posixFsyncDir(file.parent.path);
    // Read it back. This is the difference between "no call reported an error"
    // and "the bytes are there".
    if (await file.readAsString() != contents) {
      devLog(() => 'xVeil[prefs]: ${file.path} did not read back as written');
      return false;
    }
    return access.checkPublished(file, prepared, onAclReplaced);
  } catch (e) {
    onFailure?.call(e);
    devLog(() => 'xVeil[prefs]: could not write ${file.path}: $e');
    try {
      if (temp.existsSync()) await temp.delete();
    } catch (_) {
      /* the temporary is litter, not a reason to fail differently */
    }
    return false;
  }
}

/// Worker-only synchronous counterpart. The native shared profile grant and
/// these filesystem calls live in the SAME isolate. No async filesystem task
/// can publish a late rename after the worker has exited and lost its grant.
bool writePrivateFileAtomicallySync(
  File file,
  String contents, {
  bool reportFailure = false,
  void Function(StorageAclReplacement)? onAclReplaced,
}) {
  final temp = File('${file.path}.tmp');
  try {
    _ensurePrivateDir(file.parent);
    final access = _PreferenceFileAccess.capture(file);
    final planted = FileSystemEntity.typeSync(temp.path, followLinks: false);
    if (planted == FileSystemEntityType.link) {
      Link(temp.path).deleteSync();
    } else if (planted == FileSystemEntityType.directory) {
      return false;
    }
    if (!_prepareTemporary(temp)) return false;
    _verifyPrivateTemporary(temp);
    final _PreferenceFileAccess prepared;
    if (Platform.isWindows) {
      prepared = access.writeWindowsReplacement(file, temp, contents);
    } else {
      final handle = temp.openSync(mode: FileMode.writeOnly);
      try {
        _verifyPrivateTemporary(temp);
        handle.writeStringSync(contents);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      prepared = access.prepareReplacement(file, temp);
    }
    temp.renameSync(file.path);
    posixFsyncDir(file.parent.path);
    return file.readAsStringSync() == contents &&
        access.checkPublished(file, prepared, onAclReplaced);
  } catch (_) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } catch (_) {}
    if (reportFailure) rethrow;
    return false;
  }
}
