import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/posix_file_facts.dart';
import 'managed_fs_contract.dart';
import 'managed_linux_rename.dart';
import 'managed_fs_windows.dart' as windows;

export 'managed_fs_contract.dart';

/// Android's AID_SYSTEM (1000) owns the app-data ancestors and its protected
/// system group may write them. It is an OS authority, not an application UID.
/// Android also creates getFilesDir() as 0771 under the app's own UID/GID.
/// Only the full current app UID (including its user offset) can qualify that
/// group, and only for directory ancestry. Neither exception grants privacy to
/// a file. Ordinary shared/OEM/media/cache groups remain refused.
({bool ownerOnly, bool ownedByCurrentUser, bool safeAncestor})
managedPosixPathPolicy(
  PosixFileFacts facts, {
  required int currentUid,
  bool android = false,
}) {
  final trustedOwner =
      facts.uid == currentUid ||
      facts.uid == 0 ||
      (android && facts.uid == 1000);
  // AOSP Process.FIRST/LAST_APPLICATION_UID, scoped by UserHandle's user offset.
  // A coincidentally equal Unix UID/GID outside Android is not this authority.
  final appId = currentUid % 100000;
  final ownAndroidDirectoryGroup =
      android &&
      currentUid >= 10000 &&
      appId >= 10000 &&
      appId <= 19999 &&
      facts.isDirectory &&
      facts.uid == currentUid &&
      facts.gid == currentUid;
  final otherWrite = facts.permissions & 2 != 0;
  final groupWrite =
      facts.permissions & 0x10 != 0 &&
      !(android && facts.gid == 1000) &&
      !ownAndroidDirectoryGroup;
  return (
    ownerOnly: facts.permissions & 0x3f == 0,
    ownedByCurrentUser: facts.uid == currentUid,
    safeAncestor:
        trustedOwner &&
        (!(otherWrite || groupWrite) || (facts.isDirectory && facts.isSticky)),
  );
}

/// Filesystem primitives for managed PUBLIC storage only. No recursive delete,
/// overwrite publication, hidden-space scan or subprocess permission oracle.
class ManagedFsPlatform {
  const ManagedFsPlatform();

  ManagedPathWitness inspect(String path) {
    // POSIX lstat("link/") follows the link despite lstat's usual contract.
    // Inspect the final component itself, retaining only the filesystem root.
    if (!Platform.isWindows) {
      while (path.length > 1 && path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
    }
    try {
      if (Platform.isWindows) return windows.inspect(path);
      final current = posixEuid();
      final darwin = Platform.isMacOS || Platform.isIOS;
      var facts = posixLstat(path);
      // Darwin's stat witness checks the mode with two calls. A concurrent
      // chmod can invalidate that observation even for a stable object.
      if (darwin) facts ??= posixLstat(path);
      if (current == null || facts == null) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
      }
      if (!facts.isDirectory && !facts.isRegularFile) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      if (darwin && !_darwinAclSafe(path, facts)) {
        final refreshed = posixLstat(path);
        if (refreshed == null ||
            !facts.sameObjectAs(refreshed) ||
            facts.uid != refreshed.uid ||
            facts.mode == refreshed.mode ||
            !_darwinAclSafe(path, refreshed)) {
          throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
        }
        facts = refreshed;
      }
      final policy = managedPosixPathPolicy(
        facts,
        currentUid: current,
        android: Platform.isAndroid,
      );
      return ManagedPathWitness(
        identity: '${facts.deviceId}:${facts.inode}:${facts.uid}',
        directory: facts.isDirectory,
        ownerOnly: policy.ownerOnly,
        ownedByCurrentUser: policy.ownedByCurrentUser,
        safeAncestor: policy.safeAncestor,
      );
    } on ManagedFsFailure {
      rethrow;
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
  }

  /// The caller has already admitted the parent. Fails if any entry exists.
  bool createPrivateDirectory(String path) {
    if (Platform.isWindows) return windows.createPrivateDirectory(path);
    final rc = posixMkdir(path, 0x1c0);
    if (rc == null) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    if (rc == 0) return true;
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return false;
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.io);
  }

  /// Reserve a new leaf. On Windows explicitly set its owner and DACL at
  /// creation, since inherited permissions do not select the default owner.
  void reserveNewFile(String path) {
    if (Platform.isWindows) {
      if (!windows.createPrivateFile(path)) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
    } else {
      File(path).createSync(exclusive: true);
    }
  }

  /// Only for a newly reserved, still-empty file, before writing any payload.
  void restrictNewFile(String path) {
    if (!Platform.isWindows && posixChmod(path, 0x180) != 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    requirePrivateFile(path);
  }

  ManagedPathWitness requirePrivateFile(String path) {
    final facts = inspect(path);
    if (facts.directory || !facts.ownerOnly || !facts.ownedByCurrentUser) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    return facts;
  }

  /// Whole-directory bootstrap: the final root becomes visible only after its
  /// catalog is complete. No check-then-rename fallback on unsupported hosts.
  bool publishDirectoryNoReplace(String source, String destination) {
    final witness = inspect(source);
    if (!witness.directory ||
        !witness.ownerOnly ||
        !witness.ownedByCurrentUser) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    return _publishNoReplace(source, destination);
  }

  /// A privately reserved regular file is flushed by its owner before this
  /// atomic publication. Neither an existing file nor a directory is replaced.
  /// The caller must sync the parent after publication and retain its lease.
  bool publishFileNoReplace(String source, String destination) {
    requirePrivateFile(source);
    return _publishNoReplace(source, destination);
  }

  bool _publishNoReplace(String source, String destination) {
    if (Directory(source).parent.path != Directory(destination).parent.path) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    if (Platform.isWindows) {
      return windows.publishNoReplace(source, destination);
    }
    final from = source.toNativeUtf8();
    final to = destination.toNativeUtf8();
    try {
      final lib = DynamicLibrary.process();
      final int rc;
      if (Platform.isMacOS || Platform.isIOS) {
        final rename = lib
            .lookupFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
              int Function(Pointer<Utf8>, Pointer<Utf8>, int)
            >('renamex_np');
        rc = rename(from, to, 4); // RENAME_EXCL
      } else if (Platform.isLinux || Platform.isAndroid) {
        rc = managedLinuxRenameNoReplace(from, to);
      } else {
        throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
      }
      if (rc == 0) return true;
      if (FileSystemEntity.typeSync(destination, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    } on ManagedFsFailure {
      rethrow;
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }

  void syncDirectory(String path) {
    // Windows publication uses MOVEFILE_WRITE_THROUGH. There is no portable
    // Windows directory-fsync equivalent; power-loss qualification is separate.
    if (Platform.isWindows) return;
    if (posixFsyncDir(path) != 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
  }

  /// A separate recovery barrier for an existing source NAME. The Windows
  /// publication no-op above cannot authorize clearing another file's journal.
  /// Keep both the directory object and its admission stable across the flush.
  void syncSourceDirectory(String path) {
    final before = inspect(path);
    void admit(ManagedPathWitness value) {
      if (!value.directory ||
          !value.ownedByCurrentUser ||
          !value.safeAncestor ||
          value.identity != before.identity) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
    }

    admit(before);
    if (Platform.isWindows) {
      windows.syncSourceDirectory(path, before);
    } else {
      syncDirectory(path);
    }
    admit(inspect(path));
  }
}

/// POSIX mode bits bound named ACL grants on Linux. Darwin extended ACLs are
/// independent of those bits. Conservatively accept only empty/deny-only ACLs,
/// including the standard home-directory deny-delete entry; never ignore an
/// allow just because chmod reports 0700. No owner UUID/name is logged.
bool _darwinAclSafe(String path, PosixFileFacts before) {
  final lib = DynamicLibrary.process();
  final name = path.toNativeUtf8();
  Pointer<Void> acl = nullptr;
  final entry = calloc<Pointer<Void>>();
  final tag = calloc<Int32>();
  try {
    final get = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>, Int32),
          Pointer<Void> Function(Pointer<Utf8>, int)
        >('acl_get_link_np');
    final next = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
          int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
        >('acl_get_entry');
    final readTag = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Int32>),
          int Function(Pointer<Void>, Pointer<Int32>)
        >('acl_get_tag_type');
    final errno = lib
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          '__error',
        );
    acl = get(name, 0x100); // ACL_TYPE_EXTENDED
    if (acl == nullptr) {
      final error = errno().value;
      // Darwin reports ENOENT for an absent extended ACL as well as an absent
      // path. Accept only if the same previously inspected object still exists.
      if (error != 2 && error != 45) return false;
      final after = posixLstat(path);
      return after != null &&
          before.sameObjectAs(after) &&
          before.uid == after.uid &&
          before.mode == after.mode;
    }
    final valid = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('acl_valid');
    if (valid(acl) != 0) return false;
    for (var index = 0; index <= 1024; index++) {
      final rc = next(acl, index == 0 ? 0 : -1, entry);
      // Darwin's documented end-of-list is EINVAL, not Linux's return 0.
      // The ACL was validated above; other errors and allow/unknown tags refuse.
      if (rc != 0) return rc == -1 && errno().value == 22;
      if (readTag(entry.value, tag) != 0 || tag.value != 2) return false;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    if (acl != nullptr) {
      lib.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free')(acl);
    }
    calloc.free(tag);
    calloc.free(entry);
    calloc.free(name);
  }
}
