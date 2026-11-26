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
  Uint8List? inheritedAcl,
}) {
  final linuxAcl = Platform.isLinux || Platform.isAndroid
      ? readLinuxStorageAcl(path)
      : Uint8List(0);
  if (linuxAcl == null) return null;
  final grants = _posixGrants(facts, linuxAcl, currentUid: currentUid);
  final inherited = inheritedAcl == null || inheritedAcl.isEmpty
      ? const <ManagedAclGrant>[]
      : _posixGrants(
          facts,
          inheritedAcl,
          defaults: true,
          currentUid: currentUid,
        );
  if (grants == null || inherited == null) return null;
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
    owner: facts.uid == currentUid ? null : _accountLabel(facts.uid),
    extendedAcl: darwinAcl.isEmpty ? null : darwinAcl,
    grants: [...grants, ..._darwinDisplayGrants(darwinAcl, currentUid)],
    inheritedGrants: [
      ...inherited,
      ..._darwinDisplayGrants(darwinAcl, currentUid, inherited: true),
    ],
    grantsArePotential: darwinAcl.isNotEmpty,
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
              if (inheritedAcl?.isNotEmpty == true) base64Encode(inheritedAcl!),
            ]),
          ),
        )
        .toString(),
  );
}

/// Interpret the human-readable entries for the local UI only. Admission and
/// consent still use the native ACL masks and the exact serialized ACL.
Iterable<ManagedAclGrant> _darwinDisplayGrants(
  String acl,
  int currentUid, {
  bool inherited = false,
}) sync* {
  for (final line in const LineSplitter().convert(acl)) {
    final fields = line.split(':');
    if (fields.length != 6 || (fields[0] != 'user' && fields[0] != 'group')) {
      continue;
    }
    final flags = fields[4].split(',');
    if (!flags.contains('allow') ||
        (inherited
            ? !flags.contains('file_inherit') &&
                  !flags.contains('directory_inherit')
            : flags.contains('only_inherit'))) {
      continue;
    }
    final name = fields[2];
    final id = int.tryParse(fields[3]);
    if (fields[0] == 'user' && id == currentUid) continue;
    final account = name == 'everyone' && fields[0] == 'group'
        ? ''
        : name.isNotEmpty
        ? name
        : id != null
        ? _accountLabel(id, group: fields[0] == 'group')
        : fields[1];
    final rights = {
      for (final right in fields[5].split(','))
        switch (right) {
          'read' ||
          'list' ||
          'readattr' ||
          'readextattr' ||
          'readsecurity' => ManagedAclRight.read,
          'write' ||
          'add_file' ||
          'add_subdirectory' ||
          'append' ||
          'writeattr' ||
          'writeextattr' => ManagedAclRight.write,
          'execute' || 'search' => ManagedAclRight.execute,
          'delete' => ManagedAclRight.delete,
          'delete_child' => ManagedAclRight.deleteChildren,
          'writesecurity' => ManagedAclRight.changePermissions,
          'chown' => ManagedAclRight.changeOwner,
          _ => ManagedAclRight.other,
        },
    };
    yield (account: account, rights: rights);
  }
}

Set<ManagedAclRight> _modeRights(int bits) => {
  if (bits & 4 != 0) ManagedAclRight.read,
  if (bits & 2 != 0) ManagedAclRight.write,
  if (bits & 1 != 0) ManagedAclRight.execute,
};

List<ManagedAclGrant>? _posixGrants(
  PosixFileFacts facts,
  Uint8List acl, {
  bool defaults = false,
  required int currentUid,
}) {
  var groupMask = (facts.permissions >> 3) & 7;
  var other = facts.permissions & 7;
  if (acl.isEmpty) {
    return [
      if (other != 0) (account: '', rights: _modeRights(other)),
      if (groupMask != 0)
        (
          account: _accountLabel(facts.gid, group: true),
          rights: _modeRights(groupMask),
        ),
    ];
  }
  // Linux UAPI POSIX ACL xattr, version 2, with fixed-width LE entries.
  if (acl.length < 4 || (acl.length - 4) % 8 != 0) return null;
  final data = ByteData.sublistView(acl);
  if (data.getUint32(0, Endian.little) != 2) return null;
  final entries = <(int, int, int)>[];
  int? defaultMask, defaultGroup;
  for (var offset = 4; offset < acl.length; offset += 8) {
    final tag = data.getUint16(offset, Endian.little);
    final permissions = data.getUint16(offset + 2, Endian.little);
    final id = data.getUint32(offset + 4, Endian.little);
    if (permissions > 7) return null;
    if (defaults) {
      if (tag == 16) defaultMask = permissions;
      if (tag == 4) defaultGroup = permissions;
      if (tag == 32) other = permissions;
    }
    entries.add((tag, permissions, id));
  }
  if (defaults) {
    if (defaultMask == null && defaultGroup == null) return null;
    groupMask = defaultMask ?? defaultGroup!;
  }
  final grants = <ManagedAclGrant>[
    if (other != 0) (account: '', rights: _modeRights(other)),
  ];
  for (final (tag, permissions, id) in entries) {
    final account = switch (tag) {
      2 => id == currentUid ? null : _accountLabel(id),
      4 => _accountLabel(facts.gid, group: true),
      8 => _accountLabel(id, group: true),
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

// passwd and group both begin with their name pointer on the supported
// POSIX hosts. The reentrant lookup keeps each isolate's buffers independent.
String _accountLabel(int id, {bool group = false}) {
  final numeric = '${group ? 'GID' : 'UID'} $id';
  try {
    final nameFor = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(
            Uint32,
            Pointer<Void>,
            Pointer<Uint8>,
            Size,
            Pointer<Pointer<Void>>,
          ),
          int Function(
            int,
            Pointer<Void>,
            Pointer<Uint8>,
            int,
            Pointer<Pointer<Void>>,
          )
        >(group ? 'getgrgid_r' : 'getpwuid_r');
    return using((arena) {
      final record = arena<Uint64>(32).cast<Void>();
      final buffer = arena<Uint8>(16384);
      final result = arena<Pointer<Void>>();
      if (nameFor(id, record, buffer, 16384, result) != 0 ||
          result.value == nullptr) {
        return numeric;
      }
      final name = result.value.cast<Pointer<Utf8>>().value;
      return name == nullptr ? numeric : '${name.toDartString()} ($numeric)';
    });
  } catch (_) {
    return numeric;
  }
}

Uint8List? readLinuxStorageAcl(String path, {bool defaultAcl = false}) {
  try {
    return _linuxAccessAcl(path, defaultAcl: defaultAcl);
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

Uint8List? _linuxAccessAcl(String path, {required bool defaultAcl}) => using((
  arena,
) {
  final libc = DynamicLibrary.process();
  final attribute =
      (defaultAcl ? 'system.posix_acl_default' : 'system.posix_acl_access')
          .toNativeUtf8(allocator: arena);
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
