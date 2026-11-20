import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/log.dart';
import '../../core/posix_file_facts.dart';
import 'app_profile.dart';
import 'managed_fs_platform.dart';
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

/// Owner-only permissions for what this file writes: `0600` on the preference
/// and pointer files, `0700` on the directory holding them.
///
/// These files are the app's SECURITY POSTURE in the clear — which profile is
/// active, the VPN routing policy with its app ids and subnets, whether the
/// switcher has been found. They must be readable before anything is unlocked,
/// so they cannot go inside the container; the least that can be asked of them
/// is that no other local account can read them (audit X-05).
const int _ownerOnlyFile = 0x180; // 0600
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

/// Create [dir] and make it owner-only.
///
/// Best effort on purpose: the file mode below is the check that decides, and
/// for the default profile this directory is the app-support directory itself,
/// which the platform already places inside the app's own tree.
Future<void> _ensurePrivateDir(Directory dir) async {
  await dir.create(recursive: true);
  if (Platform.isWindows) return;
  final rc = posixChmod(dir.path, _ownerOnlyDir);
  if (rc != null && rc != 0) {
    devLog(() => 'xVeil[prefs]: could not restrict ${dir.path} to 0700');
  }
}

/// Make [path] readable by its owner ONLY, and PROVE it.
///
/// Three separate things, none of which the other two cover:
///
///   * `chmod` exiting zero means the filesystem accepted the request. Mounted
///     shares and some vendor mounts accept it and keep the old mode, so the
///     mode is read back rather than assumed.
///   * the read-back is an `lstat`, so a symlink swapped in at the name between
///     the create and here is seen as a symlink instead of being followed.
///   * the owner is checked against this process, which is what catches a file
///     that is now somebody else's.
///
/// Goes through libc, not `Process.run('chmod', …)`: a bare command name is
/// resolved through PATH, which is the substitutable oracle audit C-01 was
/// about.
bool _restrictToOwner(String path) {
  if (Platform.isWindows) {
    final facts = windows.inspect(path);
    return !facts.directory && facts.ownedByCurrentUser && facts.ownerOnly;
  }
  final rc = posixChmod(path, _ownerOnlyFile);
  if (!prefsFilesMustBePrivate()) return true;
  if (rc == null || rc != 0) {
    devLog(() => 'xVeil[prefs]: chmod 0600 refused $path');
    return false;
  }
  final facts = posixLstat(path);
  if (facts == null) {
    devLog(() => 'xVeil[prefs]: could not read the mode back for $path');
    return false;
  }
  if (!facts.isRegularFile) {
    devLog(
      () => 'xVeil[prefs]: $path is not a regular file, refusing to write',
    );
    return false;
  }
  if (facts.permissions != _ownerOnlyFile) {
    devLog(
      () =>
          'xVeil[prefs]: $path is ${facts.permissions.toRadixString(8)} after '
          'chmod, not 600',
    );
    return false;
  }
  final euid = posixEuid();
  if (euid != null && facts.uid != euid) {
    devLog(() => 'xVeil[prefs]: $path is not owned by this process');
    return false;
  }
  return true;
}

/// Never reuse an inherited-read temporary on Windows. Tightening its DACL
/// does not revoke a reader's existing handle, which could then read the next
/// payload. Remove only an owned stable leaf and reserve a fresh private file.
/// A reader denying deletion makes the write fail before any payload changes.
bool _prepareWindowsTemporary(File temp) {
  if (FileSystemEntity.typeSync(temp.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    final facts = windows.inspect(temp.path);
    if (facts.directory || !facts.ownedByCurrentUser || !facts.safeAncestor) {
      return false;
    }
    temp.deleteSync();
  }
  return windows.createPrivateFile(temp.path);
}

/// Read a valid installation-wide choice. A read failure on an existing entry
/// propagates so a migration cannot replace a choice it was unable to read.
Future<String?> readProfileChoice(File file) async {
  try {
    final name = utf8
        .decode(await file.readAsBytes(), allowMalformed: true)
        .trim();
    return AppProfiles.isValidName(name) ? name : null;
  } on PathNotFoundException {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      rethrow;
    }
    return null;
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
  const ProfileChoiceReadFailure({required this.busy, this.fromLegacy = false});
  final bool busy;
  final bool fromLegacy;

  // Preserve the original 0/1 codes for the file-backed profile choice.
  int get diagnosticCode => (fromLegacy ? 2 : 0) + (busy ? 1 : 0);
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

Future<String?> readStartupProfileChoice(File file) async {
  try {
    return await retryProfileChoiceRead(
      () => readProfileChoice(file),
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
}) async {
  RandomAccessFile? lock;
  try {
    await _ensurePrivateDir(file.parent);
    final lockFile = File('${file.path}.lock');
    if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      if (Platform.isWindows) {
        windows.createPrivateFile(lockFile.path);
      } else {
        try {
          lockFile.createSync(exclusive: true);
        } on PathExistsException {
          // Another process reserved the same file between the two checks.
        }
      }
    }
    if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !_restrictToOwner(lockFile.path) ||
        lockFile.lengthSync() != 0) {
      return false;
    }

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
    if (onlyIfUnset && await readProfileChoice(file) != null) return true;
    return await writePrivateFileAtomically(file, contents);
  } catch (error) {
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
  await _ensurePrivateDir(file.parent);
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
      (!original.ownerOnly && !_restrictToOwner(sidecar.path))) {
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

/// Write [contents] to [file] durably, privately and atomically — or return
/// **false**, which is the entire point of the function.
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
Future<bool> writePrivateFileAtomically(File file, String contents) async {
  final temp = File('${file.path}.tmp');
  try {
    await _ensurePrivateDir(file.parent);
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

    // Create empty, restrict, THEN fill. Reversing these two would put the
    // values on disk at the umask for as long as the chmod takes to run, and
    // [_restrictToOwner]'s lstat is also what catches a link that won the race
    // between the type check above and this open.
    if (Platform.isWindows && !_prepareWindowsTemporary(temp)) return false;
    final handle = await temp.open(mode: FileMode.writeOnly);
    try {
      if (!_restrictToOwner(temp.path)) return false;
      await handle.writeString(contents);
      await handle.flush(); // fsync(2) on the file
    } finally {
      await handle.close();
    }

    await temp.rename(file.path);
    // The rename itself, made durable. Null just means no libc binding here.
    posixFsyncDir(file.parent.path);
    if (!_restrictToOwner(file.path)) return false;

    // Read it back. This is the difference between "no call reported an error"
    // and "the bytes are there".
    if (await file.readAsString() != contents) {
      devLog(() => 'xVeil[prefs]: ${file.path} did not read back as written');
      return false;
    }
    return true;
  } catch (e) {
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
bool writePrivateFileAtomicallySync(File file, String contents) {
  final temp = File('${file.path}.tmp');
  try {
    file.parent.createSync(recursive: true);
    if (!Platform.isWindows) posixChmod(file.parent.path, _ownerOnlyDir);
    final planted = FileSystemEntity.typeSync(temp.path, followLinks: false);
    if (planted == FileSystemEntityType.link) {
      Link(temp.path).deleteSync();
    } else if (planted == FileSystemEntityType.directory) {
      return false;
    }
    if (Platform.isWindows && !_prepareWindowsTemporary(temp)) return false;
    final handle = temp.openSync(mode: FileMode.writeOnly);
    try {
      if (!_restrictToOwner(temp.path)) return false;
      handle.writeStringSync(contents);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    temp.renameSync(file.path);
    posixFsyncDir(file.parent.path);
    return _restrictToOwner(file.path) && file.readAsStringSync() == contents;
  } catch (_) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } catch (_) {}
    return false;
  }
}
