import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

import '../vpn/native_path_acl.dart';
import 'managed_fs_contract.dart';
import 'storage_acl_approval.dart';
import 'windows_profile_delete_approval.dart';

const _administratorsSid = 'S-1-5-32-544';
// DELETE | FILE_DELETE_CHILD | WRITE_DAC | WRITE_OWNER | GENERIC_ALL |
// GENERIC_WRITE. Creating unrelated children alone does not replace ours.
const _ancestorRiskMask = 0x500d0040;
const _trustedSystemSids = {
  'S-1-5-18',
  _administratorsSid,
  'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
};

bool _isTrustedSid(String sid, String currentSid) =>
    sid == currentSid || _trustedSystemSids.contains(sid);

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

/// A dedicated runtime base outside the profile tree. The name separates
/// accounts, and callers must verify the owner and ACL before writing to it.
String? programDataRuntimeBase() {
  final folder = windowsKnownFolderPath(win.FOLDERID_ProgramData);
  if (folder == null) return null;
  final user = sha256.convert(utf8.encode(_currentSid()));
  return '$folder\\xveil-runtime-$user';
}

/// Pure policy over the existing handle-bound native ACL probe. Ignoring deny
/// rules can only refuse more often. Unknown/malformed grants fail closed.
({
  bool ownerOnly,
  bool safeAncestor,
  bool ownedByCurrentUser,
  bool otherUsersHaveReadOnlyAccess,
})?
managedWindowsAclPolicy(
  Object? value,
  String currentSid, {
  bool protectFromReparseChanges = false,
}) {
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
  var stable = _isTrustedSid(owner, currentSid);
  var otherUsersHaveReadOnlyAccess = true;
  // Sync roots and their ancestors must retain their object type. Windows
  // may allow changing a reparse point with either of these write rights.
  final reparseRights = protectFromReparseChanges
      ? win.FILE_WRITE_DATA | win.FILE_WRITE_ATTRIBUTES
      : 0;
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
    if (_isTrustedSid(sid, currentSid)) continue;
    if (rights != 0) private = false;
    // A leaf must also exclude content/attribute writes. The ancestor mask
    // below intentionally allows rights that can add children to directories.
    const readAndExecute =
        win.FILE_GENERIC_READ |
        win.FILE_GENERIC_EXECUTE |
        win.GENERIC_READ |
        win.GENERIC_EXECUTE;
    if (rights & ~readAndExecute != 0) otherUsersHaveReadOnlyAccess = false;
    if (rights & (_ancestorRiskMask | reparseRights) != 0) stable = false;
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
bool managedWindowsFinalPathMatches(
  String requested,
  String actual, {
  bool allowNetworkShare = false,
}) {
  String normalize(String value) {
    value = stripExtendedLengthPrefix(value).replaceAll('/', r'\');
    while (value.length > 3 && value.endsWith(r'\')) {
      value = value.substring(0, value.length - 1);
    }
    return value.toLowerCase();
  }

  final path = normalize(requested);
  final local = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(requested);
  final network =
      allowNetworkShare &&
      RegExp(r'^\\\\[^?\\.][^\\]*\\[^\\]+(?:\\|$)').hasMatch(path);
  return (local || network) && path == normalize(actual);
}

/// Bind consent to the observed object and its complete ACL. Keep the older
/// fingerprint for the identical Windows app-support DELETE warning.
({String fingerprint, Map<String, int> grants})? managedWindowsAclGrant({
  required Map<String, Object?> facts,
  required String path,
  required String identity,
  required String currentSid,
  String? legacySupportPath,
}) {
  final policy = managedWindowsAclPolicy(facts, currentSid);
  if (policy == null ||
      (policy.safeAncestor && policy.ownedByCurrentUser && policy.ownerOnly)) {
    return null;
  }
  final owner = facts['owner'] as String;
  final rules = facts['rules'] as List;
  final accounts = <String, int>{};
  for (final rule in rules.cast<Map>()) {
    if (rule['allow'] != true || rule['inheritOnly'] == true) continue;
    final sid = rule['sid'] as String;
    final rights = rule['rights'] as int;
    if (_isTrustedSid(sid, currentSid) || rights == 0) continue;
    accounts.update(
      sid,
      (existing) => existing | rights,
      ifAbsent: () => rights,
    );
  }
  final legacy =
      legacySupportPath != null &&
      managedWindowsFinalPathMatches(legacySupportPath, path) &&
      (owner == currentSid || owner == _administratorsSid) &&
      accounts.values.any((rights) => rights & win.DELETE != 0) &&
      accounts.values.every(
        (rights) => rights & (_ancestorRiskMask ^ win.DELETE) == 0,
      );
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            legacy
                ? 'xveil-windows-profile-delete-v1'
                : 'xveil-windows-storage-acl-v2',
            currentSid,
            path,
            identity,
            owner,
            rules,
          ]),
        ),
      )
      .toString();
  return (fingerprint: fingerprint, grants: accounts);
}

Set<ManagedAclRight> _displayRights(int mask) {
  final rights = {
    if (mask & (win.FILE_READ_DATA | win.GENERIC_READ) != 0)
      ManagedAclRight.read,
    if (mask & 0x40000116 != 0) ManagedAclRight.write,
    if (mask & 0x20000020 != 0) ManagedAclRight.execute,
    if (mask & win.DELETE != 0) ManagedAclRight.delete,
    if (mask & 0x40 != 0) ManagedAclRight.deleteChildren,
    if (mask & 0x40000 != 0) ManagedAclRight.changePermissions,
    if (mask & 0x80000 != 0) ManagedAclRight.changeOwner,
    if (mask & 0x10000000 != 0) ManagedAclRight.fullControl,
  };
  return rights.isEmpty ? {ManagedAclRight.other} : rights;
}

ManagedPathWitness inspect(
  String path, {
  bool includeApprovedAcl = false,
  bool allowNetworkShare = false,
  bool protectFromReparseChanges = false,
}) {
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
    if (handle == win.INVALID_HANDLE_VALUE) {
      throw ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        unsafeReason: win.GetLastError() == win.ERROR_ACCESS_DENIED
            ? ManagedFsUnsafeReason.windowsPathAccessDenied
            : ManagedFsUnsafeReason.windowsPathOpenFailed,
      );
    }
    if (win.GetFileInformationByHandle(handle, info) == 0) {
      throw const ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        unsafeReason: ManagedFsUnsafeReason.windowsPathInfoFailed,
      );
    }
    if (info.ref.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
      throw const ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        unsafeReason: ManagedFsUnsafeReason.windowsReparsePoint,
      );
    }
    final facts = veilPathSecurityFacts(path);
    final currentSid = _currentSid();
    final policy = managedWindowsAclPolicy(
      facts,
      currentSid,
      protectFromReparseChanges: protectFromReparseChanges,
    );
    final finalPath = facts?['finalPath'];
    if (policy == null ||
        finalPath is! String ||
        !managedWindowsFinalPathMatches(
          path,
          finalPath,
          allowNetworkShare: allowNetworkShare,
        )) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
    }
    final owner = facts!['owner'] as String;
    final f = info.ref;
    final identity = _fileIdentity(f, owner);
    final directory = f.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0;
    final grant =
        policy.safeAncestor && policy.ownerOnly && policy.ownedByCurrentUser
        ? null
        : managedWindowsAclGrant(
            facts: facts,
            path: finalPath,
            legacySupportPath: directory && !policy.safeAncestor
                ? windowsProfileSupportPath
                : null,
            identity: identity,
            currentSid: currentSid,
          );
    final approved = grant != null && hasStorageAclApproval(grant.fingerprint);
    return ManagedPathWitness(
      identity: identity,
      directory: directory,
      ownerOnly: policy.ownerOnly,
      ownedByCurrentUser: policy.ownedByCurrentUser,
      ownedByWindowsAdministrators: owner == _administratorsSid,
      safeAncestor: policy.safeAncestor,
      unsafeAncestorCause: policy.safeAncestor
          ? null
          : _isTrustedSid(owner, currentSid)
          ? ManagedAncestorRefusalCause.unsafePermissions
          : ManagedAncestorRefusalCause.untrustedOwner,
      aclApproved: approved,
      aclWarning: grant == null || (approved && !includeApprovedAcl)
          ? null
          : ManagedStorageAclWarning(
              path: stripExtendedLengthPrefix(finalPath),
              directory: directory,
              fingerprint: grant.fingerprint,
              owner: owner == currentSid ? null : windowsAclAccountLabel(owner),
              grants: grant.grants.entries.map(
                (entry) => (
                  account: windowsAclAccountLabel(entry.key),
                  rights: _displayRights(entry.value),
                ),
              ),
            ),
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

/// Normalize a single witnessed file within an admitted profile. An elevated
/// Windows token can create an Administrators-owned file even in a private
/// directory owned by the user. Claim only that group owner, and only when
/// accounts outside the existing trust boundary have no write access.
/// All changes are metadata on the open handle; the file bytes stay intact.
ManagedPathWitness normalizePrivateFileAccess(
  String path,
  ManagedPathWitness expected,
) {
  bool canRepair(ManagedPathWitness witness) =>
      !witness.directory &&
      (witness.ownedByCurrentUser || witness.ownedByWindowsAdministrators) &&
      witness.ownerOnly;

  if (!canRepair(expected)) {
    throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
  }
  if (expected.ownedByCurrentUser && expected.ownerOnly) return expected;
  final sid = _currentSid();
  final name = path.toNativeUtf16();
  final info = calloc<win.BY_HANDLE_FILE_INFORMATION>();
  var handle = win.INVALID_HANDLE_VALUE;
  try {
    handle = win.CreateFile(
      name,
      win.FILE_READ_ATTRIBUTES |
          win.READ_CONTROL |
          win.WRITE_DAC |
          (expected.ownedByWindowsAdministrators ? win.WRITE_OWNER : 0),
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
        expected.identity !=
            _fileIdentity(
              file,
              expected.ownedByWindowsAdministrators ? _administratorsSid : sid,
            )) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    final current = inspect(path);
    final privateIdentity = _fileIdentity(file, sid);
    if (current.identity == privateIdentity &&
        current.ownedByCurrentUser &&
        current.ownerOnly) {
      return current;
    }
    if (!expected.sameObject(current) || !canRepair(current)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    _withPrivateFileDescriptor(
      sid,
      (descriptor) => _setPrivateFileSecurity(
        handle,
        descriptor,
        setOwner: current.ownedByWindowsAdministrators,
      ),
    );
    final repaired = inspect(path);
    if (repaired.identity != privateIdentity ||
        !repaired.ownedByCurrentUser ||
        !repaired.ownerOnly) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    return repaired;
  } finally {
    if (handle != win.INVALID_HANDLE_VALUE) win.CloseHandle(handle);
    calloc.free(info);
    calloc.free(name);
  }
}

void _setPrivateFileSecurity(
  int handle,
  Pointer<Void> descriptor, {
  required bool setOwner,
}) {
  final acl = calloc<Pointer<Void>>();
  final owner = calloc<Pointer<Void>>();
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
    if (setOwner) {
      final getOwner = advapi
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Pointer<Void>>,
              Pointer<Int32>,
            ),
            int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Int32>)
          >('GetSecurityDescriptorOwner');
      if (getOwner(descriptor, owner, defaulted) == 0 ||
          owner.value == nullptr) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unavailable);
      }
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
          win.DACL_SECURITY_INFORMATION |
              protectedDacl |
              (setOwner ? win.OWNER_SECURITY_INFORMATION : 0),
          owner.value,
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
    calloc.free(owner);
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
