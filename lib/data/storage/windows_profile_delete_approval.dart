import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

import 'managed_fs_contract.dart';

const _key = r'Software\network.veil\xveil\ProfileDeleteApprovalV1';
const _runtimeBaseValue = 'RuntimeBase';
final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

final _kernel = DynamicLibrary.open('kernel32.dll');
// The Windows local atom table is shared by the app's isolates and destroyed
// when this process exits. Environment variables and global atoms can cross
// process boundaries and aren't suitable for one-time consent.
final _findAtom = _kernel
    .lookupFunction<
      Uint16 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('FindAtomW');
final _addAtom = _kernel
    .lookupFunction<
      Uint16 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('AddAtomW');

String _atomName(String fingerprint) =>
    'xVeil.ProfileDeleteApproval.v1.$fingerprint';

bool hasWindowsProfileAclApproval(String fingerprint) {
  if (!Platform.isWindows || !_fingerprintPattern.hasMatch(fingerprint)) {
    return false;
  }
  return using(
    (arena) =>
        _findAtom(_atomName(fingerprint).toNativeUtf16(allocator: arena)) !=
            0 ||
        _rememberedApproval(fingerprint, arena),
  );
}

bool _rememberedApproval(String fingerprint, Arena arena) {
  final value = arena<Uint32>();
  final length = arena<Uint32>()..value = sizeOf<Uint32>();
  return win.RegGetValue(
            win.HKEY_CURRENT_USER,
            _key.toNativeUtf16(allocator: arena),
            fingerprint.toNativeUtf16(allocator: arena),
            win.RRF_RT_REG_DWORD,
            nullptr,
            value,
            length,
          ) ==
          win.ERROR_SUCCESS &&
      value.value == 1;
}

/// Carry a choice only after the owner has verified its own replacement.
void carryWindowsProfileAclApproval(String before, String after) {
  if (!Platform.isWindows ||
      !_fingerprintPattern.hasMatch(before) ||
      !_fingerprintPattern.hasMatch(after) ||
      before == after) {
    return;
  }
  using((arena) {
    if (_rememberedApproval(before, arena) &&
        _recordApproval(after, remember: true)) {
      win.RegDeleteKeyValue(
        win.HKEY_CURRENT_USER,
        _key.toNativeUtf16(allocator: arena),
        before.toNativeUtf16(allocator: arena),
      );
    }
  });
}

/// Called only after the startup warning's explicit UI action. Keep persistent
/// consent in HKCU, outside the very directory whose ACL is being waived.
bool recordWindowsProfileAclApproval(
  ManagedStorageAclWarning warning, {
  required bool remember,
}) => _recordApproval(warning.fingerprint, remember: remember);

bool _recordApproval(String fingerprint, {required bool remember}) {
  if (!Platform.isWindows || !_fingerprintPattern.hasMatch(fingerprint)) {
    return false;
  }
  return using((arena) {
    if (!remember) {
      final atom = _atomName(fingerprint).toNativeUtf16(allocator: arena);
      return _findAtom(atom) != 0 || _addAtom(atom) != 0;
    }
    final value = arena<Uint32>()..value = 1;
    return _writeApprovalValue(
      arena,
      fingerprint,
      win.REG_DWORD,
      value.cast<Uint8>(),
      sizeOf<Uint32>(),
    );
  });
}

bool _writeApprovalValue(
  Arena arena,
  String name,
  int type,
  Pointer<Uint8> value,
  int size,
) {
  final key = arena<IntPtr>();
  if (win.RegCreateKeyEx(
        win.HKEY_CURRENT_USER,
        _key.toNativeUtf16(allocator: arena),
        0,
        nullptr,
        win.REG_OPTION_NON_VOLATILE,
        win.KEY_SET_VALUE,
        nullptr,
        key,
        nullptr,
      ) !=
      win.ERROR_SUCCESS) {
    return false;
  }
  try {
    return win.RegSetValueEx(
          key.value,
          name.toNativeUtf16(allocator: arena),
          0,
          type,
          value,
          size,
        ) ==
        win.ERROR_SUCCESS;
  } finally {
    win.RegCloseKey(key.value);
  }
}

/// The preferred location is only a candidate. Its current ACLs must still
/// match a separate consent fingerprint before the node can use it.
bool rememberWindowsRuntimeBase(String path) {
  if (!Platform.isWindows) return false;
  return using(
    (arena) => _writeApprovalValue(
      arena,
      _runtimeBaseValue,
      win.REG_SZ,
      path.toNativeUtf16(allocator: arena).cast<Uint8>(),
      (path.length + 1) * sizeOf<Uint16>(),
    ),
  );
}

String? rememberedWindowsRuntimeBase() {
  if (!Platform.isWindows) return null;
  return using((arena) {
    final length = arena<Uint32>()..value = 65536;
    final value = arena<Uint8>(length.value);
    final result = win.RegGetValue(
      win.HKEY_CURRENT_USER,
      _key.toNativeUtf16(allocator: arena),
      _runtimeBaseValue.toNativeUtf16(allocator: arena),
      win.RRF_RT_REG_SZ,
      nullptr,
      value,
      length,
    );
    return result == win.ERROR_SUCCESS
        ? value.cast<Utf16>().toDartString()
        : null;
  });
}

/// Delete only persisted profile permission decisions for this Windows account.
bool forgetWindowsProfileAclApprovals() {
  if (!Platform.isWindows) return false;
  return using((arena) {
    final result = win.RegDeleteTree(
      win.HKEY_CURRENT_USER,
      _key.toNativeUtf16(allocator: arena),
    );
    return result == win.ERROR_SUCCESS || result == win.ERROR_FILE_NOT_FOUND;
  });
}

final String? windowsProfileSupportPath = _windowsProfileSupportPath();

String? _windowsProfileSupportPath() {
  if (!Platform.isWindows) return null;
  final folder = windowsKnownFolderPath(win.FOLDERID_RoamingAppData);
  // Matches the company and product values in windows/runner/Runner.rc.
  return folder == null ? null : '$folder\\network.veil\\xveil';
}

/// Keep per-process control files under LocalAppData when the roaming profile
/// cannot provide safe ancestry. Return a path without creating anything.
String? windowsLocalRuntimeBase() {
  final folder = windowsKnownFolderPath(win.FOLDERID_LocalAppData);
  return folder == null ? null : '$folder\\network.veil\\xveil-runtime';
}

String? windowsKnownFolderPath(String id) => using((arena) {
  final folder = arena<Pointer<Utf16>>();
  try {
    if (win.SHGetKnownFolderPath(
              win.GUIDFromString(id, allocator: arena),
              win.KF_FLAG_DONT_VERIFY,
              0,
              folder,
            ) !=
            0 ||
        folder.value == nullptr) {
      return null;
    }
    return folder.value.toDartString();
  } finally {
    if (folder.value != nullptr) win.CoTaskMemFree(folder.value);
  }
});

final _advapi = DynamicLibrary.open('advapi32.dll');
final _parseSid = _advapi
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Pointer<Void>>),
      int Function(Pointer<Utf16>, Pointer<Pointer<Void>>)
    >('ConvertStringSidToSidW');
final _lookupAccount = _advapi
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
      )
    >('LookupAccountSidW');

String windowsAclAccountLabel(String sid) => using((arena) {
  final nativeSid = arena<Pointer<Void>>();
  if (_parseSid(sid.toNativeUtf16(allocator: arena), nativeSid) == 0) {
    return sid;
  }
  try {
    final name = arena<Uint16>(256).cast<Utf16>();
    final domain = arena<Uint16>(256).cast<Utf16>();
    final nameLength = arena<Uint32>()..value = 256;
    final domainLength = arena<Uint32>()..value = 256;
    if (_lookupAccount(
          nullptr,
          nativeSid.value,
          name,
          nameLength,
          domain,
          domainLength,
          arena<Uint32>(),
        ) ==
        0) {
      return sid;
    }
    final label = name.toDartString();
    final authority = domain.toDartString();
    return authority.isEmpty ? label : '$authority\\$label';
  } finally {
    win.LocalFree(nativeSid.value);
  }
});
