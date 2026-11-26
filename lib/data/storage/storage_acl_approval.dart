import 'dart:io';

import 'windows_profile_delete_approval.dart';

Set<String> _approvals = {};

typedef StorageAclReplacement = ({String before, String after});

Set<String> storageAclApprovalsForWorker() => Set.of(_approvals);

void restoreStorageAclApprovals(Set<String> approvals) {
  _approvals = approvals;
}

void approveStorageAcl(String fingerprint) {
  _approvals.add(fingerprint);
}

void mergeStorageAclApprovals(Set<String> approvals) {
  _approvals.addAll(approvals);
}

void carryStorageAclApproval(StorageAclReplacement replacement) {
  _approvals
    ..remove(replacement.before)
    ..add(replacement.after);
}

bool hasStorageAclApproval(String fingerprint) =>
    _approvals.contains(fingerprint) ||
    (Platform.isWindows && hasWindowsProfileAclApproval(fingerprint));
