import 'dart:io';

import 'windows_profile_delete_approval.dart';

Set<String> _approvals = {};

Set<String> storageAclApprovalsForWorker() => Set.of(_approvals);

void restoreStorageAclApprovals(Set<String> approvals) {
  _approvals = approvals;
}

void approveStorageAcl(String fingerprint) {
  _approvals.add(fingerprint);
}

bool hasStorageAclApproval(String fingerprint) =>
    _approvals.contains(fingerprint) ||
    (Platform.isWindows && hasWindowsProfileAclApproval(fingerprint));
