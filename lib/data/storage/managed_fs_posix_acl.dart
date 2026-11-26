import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../../core/posix_file_facts.dart';
import 'managed_fs_contract.dart';

ManagedStorageAclWarning? managedPosixAclWarning(
  String path,
  PosixFileFacts facts, {
  required int currentUid,
  String darwinAcl = '',
}) {
  final linuxAcl = Platform.isLinux || Platform.isAndroid
      ? readLinuxStorageAcl(path)
      : Uint8List(0);
  if (linuxAcl == null) return null;
  final grants = _posixGrants(facts, linuxAcl);
  if (grants == null) return null;
  final after = posixLstat(path);
  if (after == null ||
      !after.sameObjectAs(facts) ||
      after.uid != facts.uid ||
      after.gid != facts.gid ||
      after.mode != facts.mode) {
    return null;
  }
  final canonicalPath = File(path).absolute.path;
  return ManagedStorageAclWarning(
    path: canonicalPath,
    directory: facts.isDirectory,
    owner: facts.uid == currentUid ? null : 'UID ${facts.uid}',
    extendedAcl: darwinAcl.isEmpty ? null : darwinAcl,
    grants: grants,
    fingerprint: sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'xveil-posix-storage-acl-v1',
              Platform.operatingSystem,
              canonicalPath,
              currentUid,
              facts.deviceId,
              facts.inode,
              facts.uid,
              facts.gid,
              facts.mode,
              darwinAcl,
              base64Encode(linuxAcl),
            ]),
          ),
        )
        .toString(),
  );
}

Set<ManagedAclRight> _modeRights(int bits) => {
  if (bits & 4 != 0) ManagedAclRight.read,
  if (bits & 2 != 0) ManagedAclRight.write,
  if (bits & 1 != 0) ManagedAclRight.execute,
};

List<ManagedAclGrant>? _posixGrants(PosixFileFacts facts, Uint8List acl) {
  final groupMask = (facts.permissions >> 3) & 7;
  final other = facts.permissions & 7;
  final grants = <ManagedAclGrant>[
    if (other != 0) (account: '', rights: _modeRights(other)),
  ];
  if (acl.isEmpty) {
    if (groupMask != 0) {
      grants.add((account: 'GID ${facts.gid}', rights: _modeRights(groupMask)));
    }
    return grants;
  }
  // Linux UAPI POSIX ACL xattr, version 2, with fixed-width LE entries.
  if (acl.length < 4 || (acl.length - 4) % 8 != 0) return null;
  final data = ByteData.sublistView(acl);
  if (data.getUint32(0, Endian.little) != 2) return null;
  for (var offset = 4; offset < acl.length; offset += 8) {
    final tag = data.getUint16(offset, Endian.little);
    final permissions = data.getUint16(offset + 2, Endian.little);
    final id = data.getUint32(offset + 4, Endian.little);
    if (permissions > 7) return null;
    final account = switch (tag) {
      2 => 'UID $id',
      4 => 'GID ${facts.gid}',
      8 => 'GID $id',
      1 || 16 || 32 => null, // owner, mask, other
      _ => '',
    };
    if (account == '') return null;
    final rights = _modeRights(permissions & groupMask);
    if (account != null && rights.isNotEmpty) {
      grants.add((account: account, rights: rights));
    }
  }
  return grants;
}

Uint8List? readLinuxStorageAcl(String path) {
  try {
    return _linuxAccessAcl(path);
  } on ArgumentError {
    return null;
  }
}

/// Apply the ACL snapshot to an already verified staging file descriptor.
/// The caller verifies the resulting ACL and mode before publishing the file.
bool writePosixStorageAcl(int fd, String acl) {
  final libc = DynamicLibrary.process();
  return using((arena) {
    if (Platform.isMacOS) {
      final parse = libc
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('acl_from_text');
      final set = libc
          .lookupFunction<
            Int32 Function(Int32, Pointer<Void>, Int32),
            int Function(int, Pointer<Void>, int)
          >('acl_set_fd_np');
      final free = libc
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('acl_free');
      final snapshot = acl.isEmpty
          ? libc.lookupFunction<
              Pointer<Void> Function(Int32),
              Pointer<Void> Function(int)
            >('acl_init')(0)
          : parse(acl.toNativeUtf8(allocator: arena));
      if (snapshot == nullptr) return false;
      try {
        return set(fd, snapshot, 0x100) == 0; // ACL_TYPE_EXTENDED
      } finally {
        free(snapshot);
      }
    }
    final attribute = 'system.posix_acl_access'.toNativeUtf8(allocator: arena);
    if (acl.isEmpty) {
      final remove = libc
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>)
          >('fremovexattr');
      return remove(fd, attribute) == 0;
    }
    final set = libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Pointer<Void>, UintPtr, Int32),
          int Function(int, Pointer<Utf8>, Pointer<Void>, int, int)
        >('fsetxattr');
    final aclBytes = base64Decode(acl);
    final bytes = arena<Uint8>(aclBytes.length);
    bytes.asTypedList(aclBytes.length).setAll(0, aclBytes);
    return set(fd, attribute, bytes.cast(), aclBytes.length, 0) == 0;
  });
}

Uint8List? _linuxAccessAcl(String path) => using((arena) {
  final libc = DynamicLibrary.process();
  final attribute = 'system.posix_acl_access'.toNativeUtf8(allocator: arena);
  final filename = path.toNativeUtf8(allocator: arena);
  final get = libc
      .lookupFunction<
        IntPtr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, UintPtr),
        int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, int)
      >('lgetxattr');
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isAndroid ? '__errno' : '__errno_location',
      );
  final size = get(filename, attribute, nullptr, 0);
  if (size < 0) {
    final code = errno().value;
    return code == 61 || code == 95 ? Uint8List(0) : null;
  }
  if (size == 0 || size > 65536) return null;
  final bytes = arena<Uint8>(size);
  if (get(filename, attribute, bytes.cast<Void>(), size) != size) return null;
  return Uint8List.fromList(bytes.asTypedList(size));
});
