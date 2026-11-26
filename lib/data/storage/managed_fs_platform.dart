import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../core/posix_file_facts.dart';
import 'managed_fs_contract.dart';
import 'managed_fs_posix_acl.dart';
import 'storage_acl_approval.dart';
import 'managed_linux_rename.dart';
import 'managed_fs_windows.dart' as windows;

export 'managed_fs_contract.dart';

ManagedFsFailure managedFilesystemFailure(FileSystemException error) {
  final code = error.osError?.errorCode;
  return ManagedFsFailure(
    ManagedFsFailureKind.io,
    path: error.path,
    posixError: Platform.isWindows ? null : code,
    unsafeReason: Platform.isWindows && code == 5
        ? ManagedFsUnsafeReason.windowsPathAccessDenied
        : null,
  );
}

bool _isTrustedPosixOwner(int uid, int currentUid, bool android) =>
    uid == currentUid || uid == 0 || (android && uid == 1000);

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
  final trustedOwner = _isTrustedPosixOwner(facts.uid, currentUid, android);
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

  ManagedPathWitness inspect(String path) =>
      _inspect(path, includeApprovedAcl: false);

  ManagedPathWitness inspectAcl(
    String path, {
    bool allowDirectoryContentGrants = false,
  }) => _inspect(
    path,
    includeApprovedAcl: true,
    allowDirectoryContentGrants: allowDirectoryContentGrants,
  );

  ManagedPathWitness _inspect(
    String path, {
    required bool includeApprovedAcl,
    bool allowDirectoryContentGrants = false,
    bool observeUnsafeDirectory = false,
  }) {
    // POSIX lstat("link/") follows the link despite lstat's usual contract.
    // Inspect the final component itself, retaining only the filesystem root.
    if (!Platform.isWindows) {
      while (path.length > 1 && path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
    }
    try {
      if (Platform.isWindows) {
        return windows.inspect(path, includeApprovedAcl: includeApprovedAcl);
      }
      final current = posixEuid();
      final darwin = Platform.isMacOS || Platform.isIOS;
      // The witness compares libc and Dart observations. The first writer
      // can tighten an admitted profile directory between those calls.
      // Retry the complete check once before refusing the path.
      int? posixError;
      void recordError(int code) => posixError = code;
      var facts = posixLstat(path, onError: recordError);
      if (facts == null) {
        posixError = null;
        facts = posixLstat(path, onError: recordError);
      }
      if (current == null || facts == null) {
        throw ManagedFsFailure(
          posixError == 1 || posixError == 13
              ? ManagedFsFailureKind.io
              : ManagedFsFailureKind.unavailable,
          path: path,
          posixError: posixError,
        );
      }
      if (!facts.isDirectory && !facts.isRegularFile) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      var appleAcl = darwin
          ? _readDarwinAcl(path, facts)
          : (safe: true, readOnly: true, contentOnly: true, text: '');
      if (appleAcl == null) {
        final refreshed = posixLstat(path);
        if (refreshed == null ||
            !facts.sameObjectAs(refreshed) ||
            facts.uid != refreshed.uid ||
            facts.mode == refreshed.mode) {
          throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
        }
        facts = refreshed;
        appleAcl = _readDarwinAcl(path, refreshed);
        if (appleAcl == null) {
          throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
        }
      }
      final android = Platform.isAndroid;
      final policy = managedPosixPathPolicy(
        facts,
        currentUid: current,
        android: android,
      );
      final reviewableAppleAcl =
          appleAcl.readOnly ||
          (allowDirectoryContentGrants &&
              facts.isDirectory &&
              appleAcl.contentOnly);
      final safeAncestor =
          policy.safeAncestor &&
          (appleAcl.safe || includeApprovedAcl && reviewableAppleAcl);
      final inspectInherited = allowDirectoryContentGrants && facts.isDirectory;
      final inheritedAcl = inspectInherited && !darwin
          ? readLinuxStorageAcl(path, defaultAcl: true)
          : Uint8List(0);
      if (inheritedAcl == null) {
        throw ManagedFsFailure(ManagedFsFailureKind.unavailable, path: path);
      }
      final warning =
          safeAncestor &&
              policy.ownerOnly &&
              policy.ownedByCurrentUser &&
              appleAcl.safe &&
              inheritedAcl.isEmpty
          ? null
          : managedPosixAclWarning(
              path,
              facts,
              currentUid: current,
              darwinAcl: appleAcl.text,
              inheritedAcl: inheritedAcl,
            );
      if (inspectInherited && inheritedAcl.isNotEmpty && warning == null) {
        throw ManagedFsFailure(ManagedFsFailureKind.unavailable, path: path);
      }
      final inheritedGrants = inspectInherited
          ? warning?.inheritedGrants ?? const <ManagedAclGrant>[]
          : const <ManagedAclGrant>[];
      final ownerOnly =
          policy.ownerOnly && appleAcl.safe && inheritedGrants.isEmpty;
      final approved =
          warning != null && hasStorageAclApproval(warning.fingerprint);
      // Unapproved Darwin ACLs previously stopped inspection itself. Preserve
      // that property even for callers that use a witness only for identity.
      if (!appleAcl.safe &&
          !(includeApprovedAcl ? reviewableAppleAcl : approved) &&
          !(observeUnsafeDirectory && facts.isDirectory && warning != null)) {
        throw ManagedFsFailure(
          ManagedFsFailureKind.unsafe,
          unsafeReason: facts.isDirectory
              ? ManagedFsUnsafeReason.unsafeAncestor
              : ManagedFsUnsafeReason.privateFile,
          path: path,
          aclWarnings: [?warning],
        );
      }
      return ManagedPathWitness(
        identity: '${facts.deviceId}:${facts.inode}:${facts.uid}',
        directory: facts.isDirectory,
        ownerOnly: ownerOnly,
        permissionFingerprint: sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  facts.uid,
                  facts.gid,
                  facts.mode,
                  appleAcl.text,
                  warning?.fingerprint,
                ]),
              ),
            )
            .toString(),
        ownedByCurrentUser: policy.ownedByCurrentUser,
        safeAncestor: safeAncestor,
        aclWarning: approved && !includeApprovedAcl ? null : warning,
        aclApproved: approved,
        otherUsersHaveReadOnlyAccess:
            !facts.groupOrOtherWritable &&
            appleAcl.readOnly &&
            inheritedGrants.every(
              (grant) => grant.rights.every(
                (right) =>
                    right == ManagedAclRight.read ||
                    right == ManagedAclRight.execute,
              ),
            ),
        unsafeAncestorCause: safeAncestor
            ? null
            : _isTrustedPosixOwner(facts.uid, current, android)
            ? ManagedAncestorRefusalCause.unsafePermissions
            : ManagedAncestorRefusalCause.untrustedOwner,
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
    final result = posixMkdirResult(path, 0x1c0);
    if (result == null) {
      throw ManagedFsFailure(ManagedFsFailureKind.unavailable, path: path);
    }
    if (result.code == 0) return true;
    if (result.errno == 17) return false; // EEXIST
    throw ManagedFsFailure(
      ManagedFsFailureKind.io,
      path: path,
      posixError: result.errno,
    );
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
    if (!Platform.isWindows) {
      final outcome = posixChmodResult(path, 0x180);
      if (outcome?.code != 0) {
        final error = outcome?.errno;
        if (error == 1 || error == 13) {
          throw FileSystemException(
            'Cannot protect the new file',
            path,
            OSError('Access denied', error!),
          );
        }
        throw const ManagedFsFailure(ManagedFsFailureKind.io);
      }
    }
    requirePrivateFile(path);
  }

  void makeEmptyFilePrivate(String path) {
    if (Platform.isMacOS) {
      final facts = posixLstat(path);
      if (facts != null &&
          facts.isRegularFile &&
          facts.uid == posixEuid() &&
          readDarwinStorageAcl(path, facts)?.isNotEmpty == true) {
        posixSetModeForFile(
          path,
          facts,
          0x180,
          applyAcl: (fd) => writePosixStorageAcl(fd, ''),
        );
      }
    }
    restrictNewFile(path);
  }

  ManagedPathWitness requirePrivateFile(
    String path, {
    bool allowAclApproval = false,
    bool allowReadOnlyAclApproval = false,
  }) {
    final ManagedPathWitness facts;
    try {
      facts = allowReadOnlyAclApproval ? inspectAcl(path) : inspect(path);
    } on ManagedFsFailure catch (error) {
      if (error.aclWarnings.isNotEmpty) {
        throw ManagedFsFailure(
          ManagedFsFailureKind.unsafe,
          unsafeReason: ManagedFsUnsafeReason.privateFile,
          path: path,
          aclWarnings: [
            for (final warning in error.aclWarnings)
              warning.withPolicy(canContinue: allowAclApproval),
          ],
        );
      }
      rethrow;
    }
    final readOnlyGrant =
        allowReadOnlyAclApproval &&
        facts.ownedByCurrentUser &&
        facts.safeAncestor &&
        facts.otherUsersHaveReadOnlyAccess;
    final canApprove = allowAclApproval || readOnlyGrant;
    if (facts.directory ||
        (!(canApprove && facts.aclApproved) &&
            (!facts.ownerOnly || !facts.ownedByCurrentUser))) {
      var warning = facts.aclWarning;
      if (warning == null && facts.aclApproved) {
        // A stricter operation still needs local evidence for an ACL accepted
        // by another operation. Refresh only for the exact object.
        try {
          final current = inspectAcl(path);
          if (current.sameObject(facts)) warning = current.aclWarning;
        } on ManagedFsFailure catch (error) {
          warning = error.aclWarnings.firstOrNull;
        }
      }
      throw ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        unsafeReason: ManagedFsUnsafeReason.privateFile,
        path: path,
        aclWarnings: [
          if (warning != null && !facts.directory)
            warning.withPolicy(canContinue: canApprove),
        ],
      );
    }
    return facts;
  }

  /// Native container writers create their own files. On Windows an elevated
  /// writer can inherit a private DACL but still get the group owner. Call
  /// this only on a fresh output under an already-admitted private directory.
  ManagedPathWitness requirePrivateNativeOutput(String path) {
    if (Platform.isWindows) {
      final witness = inspect(path);
      if (witness.ownedByWindowsAdministrators) {
        return windows.normalizePrivateFileAccess(path, witness);
      }
    }
    return requirePrivateFile(path);
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
      final errno = posixErrnoSlot();
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
      final error = errno?.value;
      if (error == 1 || error == 13) {
        throw FileSystemException(
          'Cannot publish the private entry',
          destination,
          OSError('Access denied', error!),
        );
      }
      if (FileSystemEntity.typeSync(destination, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    } on ManagedFsFailure {
      rethrow;
    } on FileSystemException {
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

/// Resolve the selected directory and bind its canonical ancestors to their
/// identities and access policy before admitting a named filesystem operation.
final class ManagedDirectoryAccess {
  ManagedDirectoryAccess._(this.requestedPath, this.canonicalPath, this._chain);

  final String requestedPath;
  final String canonicalPath;
  final Map<String, ManagedPathWitness> _chain;

  Iterable<ManagedStorageAclWarning> get warnings sync* {
    for (final entry in _chain.entries) {
      if (!entry.value.safeAncestor) {
        yield entry.value.aclWarning!;
      }
    }
  }

  static ManagedDirectoryAccess capture(String path) {
    final requested = p.normalize(p.absolute(path));
    final String canonical;
    try {
      canonical = Directory(requested).resolveSymbolicLinksSync();
    } on FileSystemException catch (error) {
      throw managedFilesystemFailure(error);
    }
    final chain = <String, ManagedPathWitness>{};
    var current = canonical;
    while (true) {
      final witness = Platform.isWindows
          ? windows.inspect(
              current,
              includeApprovedAcl: true,
              allowNetworkShare: true,
            )
          : const ManagedFsPlatform()._inspect(
              current,
              includeApprovedAcl: true,
              observeUnsafeDirectory: true,
            );
      if (!witness.directory ||
          !witness.safeAncestor && witness.aclWarning == null) {
        throw ManagedFsFailure(ManagedFsFailureKind.unsafe, path: current);
      }
      chain[current] = witness;
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return ManagedDirectoryAccess._(requested, canonical, chain);
  }

  void verify() {
    final current = capture(requestedPath);
    if (current.canonicalPath != canonicalPath ||
        current._chain.length != _chain.length ||
        _chain.entries.any((entry) {
          final now = current._chain[entry.key];
          return now == null ||
              !now.sameObject(entry.value) ||
              now.accessPolicy != entry.value.accessPolicy;
        })) {
      throw ManagedFsFailure(ManagedFsFailureKind.changed, path: requestedPath);
    }
  }
}

String? readDarwinStorageAcl(String path, PosixFileFacts facts) =>
    _readDarwinAcl(path, facts)?.text;

/// POSIX mode bits bound named ACL grants on Linux. Darwin extended ACLs are
/// independent of those bits. Conservatively accept only empty/deny-only ACLs,
/// including the standard home-directory deny-delete entry; never ignore an
/// allow just because chmod reports 0700. No owner UUID/name is logged.
({bool safe, bool readOnly, bool contentOnly, String text})? _readDarwinAcl(
  String path,
  PosixFileFacts before,
) {
  final lib = DynamicLibrary.process();
  final name = path.toNativeUtf8();
  Pointer<Void> acl = nullptr;
  final entry = calloc<Pointer<Void>>();
  final tag = calloc<Int32>();
  final flags = calloc<Pointer<Void>>();
  final mask = calloc<Uint64>();
  final currentUser = calloc<Uint8>(16);
  final length = calloc<IntPtr>();
  Pointer<Utf8> text = nullptr;
  try {
    final get = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>, Int32),
          Pointer<Void> Function(Pointer<Utf8>, int)
        >('acl_get_link_np');
    final currentUid = Platform.isMacOS ? posixEuid() : null;
    final haveCurrentUser =
        currentUid != null &&
        lib.lookupFunction<
              Int32 Function(Uint32, Pointer<Uint8>),
              int Function(int, Pointer<Uint8>)
            >('mbr_uid_to_uuid')(currentUid, currentUser) ==
            0;
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
      if (error != 2 && error != 45) return null;
      final after = posixLstat(path);
      return after != null &&
              before.sameObjectAs(after) &&
              before.uid == after.uid &&
              before.gid == after.gid &&
              before.mode == after.mode
          ? (safe: true, readOnly: true, contentOnly: true, text: '')
          : null;
    }
    final valid = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('acl_valid');
    if (valid(acl) != 0) return null;
    final readMask = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint64>),
          int Function(Pointer<Void>, Pointer<Uint64>)
        >('acl_get_permset_mask_np');
    final readFlagSet = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
          int Function(Pointer<Void>, Pointer<Pointer<Void>>)
        >('acl_get_flagset_np');
    final hasFlag = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('acl_get_flag_np');
    // Darwin ACL read data, execute/search, read attributes, read extended
    // attributes, read security and synchronize.
    const readRights = 0x100a8a;
    var hasAllow = false;
    var readOnly = true;
    var contentOnly = true;
    // add_file and add_subdirectory apply to the directory contents.
    const addEntries = (1 << 2) | (1 << 5);
    for (var index = 0; index <= 1024; index++) {
      final rc = next(acl, index == 0 ? 0 : -1, entry);
      // Darwin's end-of-list is EINVAL. Unreadable or unknown entries cannot
      // participate in a consent fingerprint.
      if (rc != 0) {
        if (rc != -1 || errno().value != 22) return null;
        text = lib
            .lookupFunction<
              Pointer<Utf8> Function(Pointer<Void>, Pointer<IntPtr>),
              Pointer<Utf8> Function(Pointer<Void>, Pointer<IntPtr>)
            >('acl_to_text')(acl, length);
        if (text == nullptr || length.value < 0) return null;
        return (
          safe: !hasAllow,
          readOnly: readOnly,
          contentOnly: contentOnly,
          text: text.toDartString(length: length.value),
        );
      }
      if (readTag(entry.value, tag) != 0 ||
          (tag.value != 1 && tag.value != 2)) {
        return null;
      }
      if (tag.value == 1) {
        if (haveCurrentUser &&
            _darwinAclIsCurrentUser(lib, entry.value, currentUser)) {
          continue;
        }
        hasAllow = true;
        if (readMask(entry.value, mask) != 0) return null;
        if (mask.value & ~readRights != 0) readOnly = false;
        if (readFlagSet(entry.value, flags) != 0) return null;
        const inheritOnlyFlag = 1 << 8;
        final inheritOnly = hasFlag(flags.value, inheritOnlyFlag);
        if (inheritOnly < 0) return null;
        if (inheritOnly == 0 && mask.value & ~(readRights | addEntries) != 0) {
          contentOnly = false;
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    if (text != nullptr) {
      lib.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free')(text.cast<Void>());
    }
    calloc.free(length);
    if (acl != nullptr) {
      lib.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free')(acl);
    }
    calloc.free(currentUser);
    calloc.free(mask);
    calloc.free(tag);
    calloc.free(flags);
    calloc.free(entry);
    calloc.free(name);
  }
}

bool _darwinAclIsCurrentUser(
  DynamicLibrary lib,
  Pointer<Void> entry,
  Pointer<Uint8> currentUser,
) {
  final account = lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)
      >('acl_get_qualifier')(entry);
  if (account == nullptr) return false;
  try {
    for (var byte = 0; byte < 16; byte++) {
      if (account[byte] != currentUser[byte]) return false;
    }
    return true;
  } finally {
    lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('acl_free')(account.cast());
  }
}
