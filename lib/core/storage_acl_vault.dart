import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/storage/managed_fs_contract.dart';
import '../data/storage/storage_acl_approval.dart';
import '../data/storage/windows_profile_delete_approval.dart';

const _vault = FlutterSecureStorage(
  aOptions: AndroidOptions(
    storageNamespace: 'xveil_storage_acl_v1',
    resetOnError: false,
  ),
  iOptions: IOSOptions(
    accountName: 'xveil.storage.acl.v1',
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
  mOptions: MacOsOptions(
    accountName: 'xveil.storage.acl.v1',
    usesDataProtectionKeychain: false,
    synchronizable: false,
  ),
);

const _keyPrefix = 'xveil.storage.acl.v1.';
String _key(String fingerprint) => '$_keyPrefix$fingerprint';

/// The running profile and its workers keep their admission until restart.
Future<bool> forgetRememberedStorageAclApprovals() async {
  try {
    if (Platform.isWindows) return forgetWindowsProfileAclApprovals();
    final entries = await _vault.readAll();
    final decisions = entries.keys
        .where((key) => key.startsWith(_keyPrefix))
        .toList();
    for (final key in decisions) {
      await _vault.delete(key: key);
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> recordStorageAclApproval(
  ManagedStorageAclWarning warning, {
  required bool remember,
}) async {
  if (Platform.isWindows) {
    return recordWindowsProfileAclApproval(warning, remember: remember);
  }
  final fingerprint = warning.fingerprint;
  if (remember) {
    try {
      await _vault.write(key: _key(fingerprint), value: '1');
    } catch (_) {
      return false;
    }
  }
  approveStorageAcl(fingerprint);
  return true;
}

Future<bool> restoreRememberedStorageAcl(
  ManagedStorageAclWarning warning,
) async {
  // Windows checks its account registry directly, also in storage workers.
  if (Platform.isWindows || hasStorageAclApproval(warning.fingerprint)) {
    return false;
  }
  try {
    if (await _vault.read(key: _key(warning.fingerprint)) != '1') return false;
    approveStorageAcl(warning.fingerprint);
    return true;
  } catch (_) {
    return false;
  }
}
