import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

import 'managed_fs_contract.dart';

const _key = r'Software\network.veil\xveil\ProfileDeleteApprovalV1';
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

bool hasWindowsProfileDeleteApproval(String fingerprint) {
  if (!Platform.isWindows || !_fingerprintPattern.hasMatch(fingerprint)) {
    return false;
  }
  return using((arena) {
    if (_findAtom(_atomName(fingerprint).toNativeUtf16(allocator: arena)) !=
        0) {
      return true;
    }
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
  });
}

/// Called only after the startup warning's explicit UI action. Keep persistent
/// consent in HKCU, outside the very directory whose ACL is being waived.
bool recordWindowsProfileDeleteApproval(
  ManagedWindowsDeleteWarning warning, {
  required bool remember,
}) {
  final fingerprint = warning.fingerprint;
  if (!Platform.isWindows || !_fingerprintPattern.hasMatch(fingerprint)) {
    return false;
  }
  return using((arena) {
    if (!remember) {
      final atom = _atomName(fingerprint).toNativeUtf16(allocator: arena);
      return _findAtom(atom) != 0 || _addAtom(atom) != 0;
    }
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
      final value = arena<Uint32>()..value = 1;
      return win.RegSetValueEx(
            key.value,
            fingerprint.toNativeUtf16(allocator: arena),
            0,
            win.REG_DWORD,
            value.cast<Uint8>(),
            sizeOf<Uint32>(),
          ) ==
          win.ERROR_SUCCESS;
    } finally {
      win.RegCloseKey(key.value);
    }
  });
}

final String? windowsProfileSupportPath = Platform.isWindows
    ? using((arena) {
        final folder = arena<Pointer<Utf16>>();
        try {
          if (win.SHGetKnownFolderPath(
                    win.GUIDFromString(
                      win.FOLDERID_RoamingAppData,
                      allocator: arena,
                    ),
                    win.KF_FLAG_DONT_VERIFY,
                    0,
                    folder,
                  ) !=
                  0 ||
              folder.value == nullptr) {
            return null;
          }
          // Matches the company and product values in windows/runner/Runner.rc
          // used by path_provider.
          return '${folder.value.toDartString()}\\network.veil\\xveil';
        } finally {
          if (folder.value != nullptr) win.CoTaskMemFree(folder.value);
        }
      })
    : null;

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
