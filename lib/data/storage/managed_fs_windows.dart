import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

import '../vpn/native_path_acl.dart';
import 'managed_fs_contract.dart';

const _administratorsSid = 'S-1-5-32-544';
const _trustedSystemSids = {
  'S-1-5-18',
  _administratorsSid,
  'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
};

String _currentSid() {
  final token = calloc<IntPtr>();
  final size = calloc<Uint32>();
  Pointer<Uint8> user = nullptr;
  try {
    if (win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, token) ==
        0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    win.GetTokenInformation(token.value, 1, nullptr, 0, size);
    if (size.value < sizeOf<Pointer<Void>>() || size.value > 16384) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    user = calloc<Uint8>(size.value);
    if (win.GetTokenInformation(token.value, 1, user, size.value, size) == 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    final sid = user.cast<Pointer<Void>>().value; // TOKEN_USER.User.Sid
    final text = calloc<Pointer<Utf16>>();
    try {
      final convert = DynamicLibrary.open('advapi32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
            int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
          >('ConvertSidToStringSidW');
      if (convert(sid, text) == 0 || text.value == nullptr) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
      }
      return text.value.toDartString();
    } finally {
      if (text.value != nullptr) win.LocalFree(text.value);
      calloc.free(text);
    }
  } finally {
    if (token.value != 0) win.CloseHandle(token.value);
    calloc.free(token);
    calloc.free(size);
    if (user != nullptr) calloc.free(user);
  }
}

/// Pure policy over the existing handle-bound native ACL probe. Ignoring deny
/// rules can only refuse more often. Unknown/malformed grants fail closed.
({
  bool ownerOnly,
  bool safeAncestor,
  bool ownedByCurrentUser,
  bool otherUsersHaveReadOnlyAccess,
})?
managedWindowsAclPolicy(Object? value, String currentSid) {
  if (!RegExp(r'^S-1-[0-9]+(?:-[0-9]+)+$').hasMatch(currentSid) ||
      value is! Map ||
      value.containsKey('error')) {
    return null;
  }
  final owner = value['owner'];
  final rules = value['rules'];
  if (owner is! String ||
      owner.isEmpty ||
      rules is! List ||
      rules.length > 4096) {
    return null;
  }
  var private = true;
  var stable = owner == currentSid || _trustedSystemSids.contains(owner);
  var otherUsersHaveReadOnlyAccess = true;
  for (final rule in rules) {
    if (rule is! Map ||
        rule['allow'] is! bool ||
        rule['inheritOnly'] is! bool) {
      return null;
    }
    if (rule['allow'] == false || rule['inheritOnly'] == true) continue;
    final sid = rule['sid'];
    final rights = rule['rights'];
    if (sid is! String || sid.isEmpty || rights is! int || rights < 0) {
      return null;
    }
    if (sid == currentSid || _trustedSystemSids.contains(sid)) continue;
    if (rights != 0) private = false;
    // A leaf must also exclude content/attribute writes. The ancestor mask
    // below intentionally allows rights that can add children to directories.
    const readAndExecute =
        win.FILE_GENERIC_READ |
        win.FILE_GENERIC_EXECUTE |
        win.GENERIC_READ |
        win.GENERIC_EXECUTE;
    if (rights & ~readAndExecute != 0) otherUsersHaveReadOnlyAccess = false;
    // DELETE | FILE_DELETE_CHILD | WRITE_DAC | WRITE_OWNER | GENERIC_ALL |
    // GENERIC_WRITE. Creating unrelated children alone does not replace ours.
    if (rights & 0x500d0040 != 0) stable = false;
  }
  return (
    ownerOnly: private,
    safeAncestor: stable,
    ownedByCurrentUser: owner == currentSid,
    otherUsersHaveReadOnlyAccess: otherUsersHaveReadOnlyAccess,
  );
}

/// Separator/case normalization is required even for app-generated paths:
/// Dart accepts '/', while GetFinalPathNameByHandle returns '\\'.
bool managedWindowsFinalPathMatches(String requested, String actual) {
  String normalize(String value) {
    value = stripExtendedLengthPrefix(value).replaceAll('/', r'\');
    while (value.length > 3 && value.endsWith(r'\')) {
      value = value.substring(0, value.length - 1);
    }
    return value.toLowerCase();
  }

  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(requested) &&
      normalize(requested) == normalize(actual);
}

ManagedPathWitness inspect(String path) {
  final name = path.toNativeUtf16();
  final info = calloc<win.BY_HANDLE_FILE_INFORMATION>();
  var handle = win.INVALID_HANDLE_VALUE;
  try {
    handle = win.CreateFile(
      name,
      win.FILE_READ_ATTRIBUTES,
      win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
      nullptr,
      win.OPEN_EXISTING,
      win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT,
      0,
    );
    if (handle == win.INVALID_HANDLE_VALUE ||
        win.GetFileInformationByHandle(handle, info) == 0 ||
        info.ref.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final facts = veilPathSecurityFacts(path);
    final policy = managedWindowsAclPolicy(facts, _currentSid());
    final finalPath = facts?['finalPath'];
    if (policy == null ||
        finalPath is! String ||
        !managedWindowsFinalPathMatches(path, finalPath)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    final f = info.ref;
    return ManagedPathWitness(
      identity: _fileIdentity(f, facts!['owner'] as String),
      directory: f.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0,
      ownerOnly: policy.ownerOnly,
      ownedByCurrentUser: policy.ownedByCurrentUser,
      ownedByWindowsAdministrators: facts['owner'] == _administratorsSid,
      safeAncestor: policy.safeAncestor,
      otherUsersHaveReadOnlyAccess: policy.otherUsersHaveReadOnlyAccess,
    );
  } finally {
    if (handle != win.INVALID_HANDLE_VALUE) win.CloseHandle(handle);
    calloc.free(info);
    calloc.free(name);
  }
}

String _fileIdentity(win.BY_HANDLE_FILE_INFORMATION file, String owner) =>
    '${file.dwVolumeSerialNumber}:${file.nFileIndexHigh}:'
    '${file.nFileIndexLow}:$owner';

/// Flush an existing, already-admitted source parent. Unlike ordinary managed
/// publication, recovery has no live MOVEFILE_WRITE_THROUGH result to retain.
/// Bind the directory handle to the caller's witness and refuse unsupported
/// filesystems/access instead of treating a visible source name as durable.
void syncSourceDirectory(String path, ManagedPathWitness expected) {
  final name = path.toNativeUtf16();
  final info = calloc<win.BY_HANDLE_FILE_INFORMATION>();
  var handle = win.INVALID_HANDLE_VALUE;
  try {
    handle = win.CreateFile(
      name,
      win.GENERIC_WRITE,
      win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
      nullptr,
      win.OPEN_EXISTING,
      win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT,
      0,
    );
    if (handle == win.INVALID_HANDLE_VALUE ||
        win.GetFileInformationByHandle(handle, info) == 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    final f = info.ref;
    final identity =
        '${f.dwVolumeSerialNumber}:${f.nFileIndexHigh}:${f.nFileIndexLow}:';
    if (!expected.directory ||
        !expected.identity.startsWith(identity) ||
        f.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 ||
        f.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    if (win.FlushFileBuffers(handle) == 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
  } on ManagedFsFailure {
    rethrow;
  } catch (_) {
    throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
  } finally {
    if (handle != win.INVALID_HANDLE_VALUE) win.CloseHandle(handle);
    calloc.free(info);
    calloc.free(name);
  }
}

bool createPrivateDirectory(String path) {
  final sid = _currentSid();
  final sddl = 'O:${sid}D:P(A;OICI;FA;;;$sid)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
      .toNativeUtf16();
  final descriptor = calloc<Pointer<Void>>();
  final attributes = calloc<win.SECURITY_ATTRIBUTES>();
  final name = path.toNativeUtf16();
  try {
    final convert = DynamicLibrary.open('advapi32.dll')
        .lookupFunction<
          Int32 Function(
            Pointer<Utf16>,
            Uint32,
            Pointer<Pointer<Void>>,
            Pointer<Uint32>,
          ),
          int Function(
            Pointer<Utf16>,
            int,
            Pointer<Pointer<Void>>,
            Pointer<Uint32>,
          )
        >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
    if (convert(sddl, 1, descriptor, nullptr) == 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    attributes.ref
      ..nLength = sizeOf<win.SECURITY_ATTRIBUTES>()
      ..lpSecurityDescriptor = descriptor.value
      ..bInheritHandle = 0;
    // win32 resolves its GetLastError symbol lazily. Do that before the call
    // whose error matters: the first lookup can overwrite ERROR_ALREADY_EXISTS
    // and turn an occupied name into a spurious I/O failure in a fresh isolate.
    win.GetLastError();
    if (win.CreateDirectory(name, attributes) != 0) return true;
    final error = win.GetLastError();
    if (error == win.ERROR_ALREADY_EXISTS || error == win.ERROR_FILE_EXISTS) {
      return false;
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.io);
  } finally {
    if (descriptor.value != nullptr) win.LocalFree(descriptor.value);
    calloc.free(descriptor);
    calloc.free(attributes);
    calloc.free(sddl);
    calloc.free(name);
  }
}

/// Reserve an empty regular file with a protected DACL from its first instant.
/// Existing entries are refused. The caller owns the parent and must keep its
/// grant through publication; this is not a path admission capability.
bool createPrivateFile(String path) {
  final sid = _currentSid();
  final attributes = calloc<win.SECURITY_ATTRIBUTES>();
  final name = path.toNativeUtf16();
  try {
    return _withPrivateFileDescriptor(sid, (descriptor) {
      attributes.ref
        ..nLength = sizeOf<win.SECURITY_ATTRIBUTES>()
        ..lpSecurityDescriptor = descriptor
        ..bInheritHandle = 0;
      final handle = win.CreateFile(
        name,
        win.GENERIC_WRITE,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
        attributes,
        win.CREATE_NEW,
        win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_OPEN_REPARSE_POINT,
        0,
      );
      if (handle != win.INVALID_HANDLE_VALUE) {
        win.CloseHandle(handle);
        return true;
      }
      final error = win.GetLastError();
      if (error == win.ERROR_ALREADY_EXISTS ||
          error == win.ERROR_FILE_EXISTS ||
          FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        return false;
      }
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    });
  } finally {
    calloc.free(attributes);
    calloc.free(name);
  }
}

T _withPrivateFileDescriptor<T>(String sid, T Function(Pointer<Void>) action) {
  final sddl = 'O:${sid}D:P(A;;FA;;;$sid)(A;;FA;;;SY)(A;;FA;;;BA)'
      .toNativeUtf16();
  final descriptor = calloc<Pointer<Void>>();
  try {
    final convert = DynamicLibrary.open('advapi32.dll')
        .lookupFunction<
          Int32 Function(
            Pointer<Utf16>,
            Uint32,
            Pointer<Pointer<Void>>,
            Pointer<Uint32>,
          ),
          int Function(
            Pointer<Utf16>,
            int,
            Pointer<Pointer<Void>>,
            Pointer<Uint32>,
          )
        >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
    if (convert(sddl, 1, descriptor, nullptr) == 0 ||
        descriptor.value == nullptr) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    return action(descriptor.value);
  } finally {
    if (descriptor.value != nullptr) win.LocalFree(descriptor.value);
    calloc.free(descriptor);
    calloc.free(sddl);
  }
}

/// Tighten the ACL of an existing user-owned preferences file that legacy
/// xVeil could create with inherited read grants. The caller holds the profile
/// lease. This is a metadata change on the witnessed file handle; it writes
/// no preference bytes, so a concurrent open or an old reader cannot expose
/// new content or overwrite newer settings.
ManagedPathWitness restrictLegacyPreferenceReadAccess(
  String path,
  ManagedPathWitness expected,
) {
  if (expected.directory ||
      !expected.ownedByCurrentUser ||
      !expected.otherUsersHaveReadOnlyAccess) {
    throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
  }
  final sid = _currentSid();
  final name = path.toNativeUtf16();
  final info = calloc<win.BY_HANDLE_FILE_INFORMATION>();
  var handle = win.INVALID_HANDLE_VALUE;
  try {
    const readControl = 0x00020000;
    const writeDac = 0x00040000;
    handle = win.CreateFile(
      name,
      win.FILE_READ_ATTRIBUTES | readControl | writeDac,
      win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
      nullptr,
      win.OPEN_EXISTING,
      win.FILE_FLAG_OPEN_REPARSE_POINT,
      0,
    );
    if (handle == win.INVALID_HANDLE_VALUE ||
        win.GetFileInformationByHandle(handle, info) == 0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
    final file = info.ref;
    if (file.dwFileAttributes &
                (win.FILE_ATTRIBUTE_DIRECTORY |
                    win.FILE_ATTRIBUTE_REPARSE_POINT) !=
            0 ||
        file.nNumberOfLinks != 1 ||
        expected.identity != _fileIdentity(file, sid)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    final current = inspect(path);
    if (!expected.sameObject(current) ||
        !current.otherUsersHaveReadOnlyAccess) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    if (current.ownerOnly) return current;
    _withPrivateFileDescriptor(
      sid,
      (descriptor) => _setPrivateFileDacl(handle, descriptor),
    );
    final repaired = inspect(path);
    if (!expected.sameObject(repaired) || !repaired.ownerOnly) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    return repaired;
  } finally {
    if (handle != win.INVALID_HANDLE_VALUE) win.CloseHandle(handle);
    calloc.free(info);
    calloc.free(name);
  }
}

void _setPrivateFileDacl(int handle, Pointer<Void> descriptor) {
  final acl = calloc<Pointer<Void>>();
  final present = calloc<Int32>();
  final defaulted = calloc<Int32>();
  try {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final getDacl = advapi
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Pointer<Int32>,
            Pointer<Pointer<Void>>,
            Pointer<Int32>,
          ),
          int Function(
            Pointer<Void>,
            Pointer<Int32>,
            Pointer<Pointer<Void>>,
            Pointer<Int32>,
          )
        >('GetSecurityDescriptorDacl');
    if (getDacl(descriptor, present, acl, defaulted) == 0 ||
        present.value == 0 ||
        acl.value == nullptr) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    final setSecurity = advapi
        .lookupFunction<
          Uint32 Function(
            IntPtr,
            Int32,
            Uint32,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
          ),
          int Function(
            int,
            int,
            int,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
          )
        >('SetSecurityInfo');
    const fileObject = 1;
    const protectedDacl = 0x80000000;
    if (setSecurity(
          handle,
          fileObject,
          win.DACL_SECURITY_INFORMATION | protectedDacl,
          nullptr,
          nullptr,
          acl.value,
          nullptr,
        ) !=
        0) {
      throw const ManagedFsFailure(ManagedFsFailureKind.io);
    }
  } finally {
    calloc.free(defaulted);
    calloc.free(present);
    calloc.free(acl);
  }
}

bool publishNoReplace(String source, String destination) {
  final from = source.toNativeUtf16();
  final to = destination.toNativeUtf16();
  try {
    if (win.MoveFileEx(from, to, win.MOVEFILE_WRITE_THROUGH) != 0) return true;
    final error = win.GetLastError();
    if (error == win.ERROR_ALREADY_EXISTS ||
        error == win.ERROR_FILE_EXISTS ||
        FileSystemEntity.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
      return false;
    }
    throw const ManagedFsFailure(ManagedFsFailureKind.io);
  } finally {
    calloc.free(from);
    calloc.free(to);
  }
}
